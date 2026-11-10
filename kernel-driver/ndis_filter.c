#include "kernel_spoofer.h"
#include "hook.h"
#include "modules.h"

typedef LONG NDIS_STATUS;

extern EACSPOOF_CONFIG g_Config;
extern EACSPOOF_STATS  g_Stats;
extern KSPIN_LOCK      g_Lock;

/*
 * OID intercept beyond MAC:
 *   OID_802_3_PERMANENT_ADDRESS / CURRENT_ADDRESS
 *   OID_GEN_NETWORK_LAYER_ADDRESSES
 *   OID_GEN_PHYSICAL_MEDIUM
 *   OID_TCP_TASK_OFFLOAD
 *
 * NDIS 6 LWF would be a separate INF miniport. This module hooks
 * NdisFOidRequest / NdisOidRequest via export resolve from ndis.sys
 * and rewrites query completions. ARP/ND rewrite is applied on
 * NET_BUFFER_LIST Ethernet headers when rewriteArp/rewriteNd is set.
 */

#define OID_802_3_PERMANENT_ADDRESS      0x01010101
#define OID_802_3_CURRENT_ADDRESS        0x01010102
#define OID_GEN_NETWORK_LAYER_ADDRESSES  0x00010126
#define OID_GEN_PHYSICAL_MEDIUM          0x00010202
#define OID_TCP_TASK_OFFLOAD             0xFC010201

typedef PVOID PNDIS_OID_REQUEST;
typedef PVOID PNDIS_FILTER_BLOCK;

typedef NDIS_STATUS (NTAPI *PFN_NDIS_OID)(PVOID, PNDIS_OID_REQUEST);

static JUMP_HOOK g_OidHook;
static PFN_NDIS_OID g_OidOrig;
static PVOID g_NdisBase;

static EACSPOOF_NIC *NicPrimary(VOID)
{
    ULONG i;
    for (i = 0; i < g_Config.nicCount && i < 4; i++) {
        if (g_Config.nics[i].enabled) return &g_Config.nics[i];
    }
    return g_Config.nicCount ? &g_Config.nics[0] : NULL;
}

static VOID CountOid(ULONG64 *counter)
{
    KIRQL irql;
    KeAcquireSpinLock(&g_Lock, &irql);
    (*counter)++;
    g_Stats.oidIntercepts++;
    KeReleaseSpinLock(&g_Lock, irql);
}

/*
 * NDIS_OID_REQUEST layout (Win10+ x64, stable enough for Oid + data buffer):
 *   +0x00 Header
 *   +0x10 RequestType
 *   +0x14 PortNumber
 *   +0x18 Timeout
 *   +0x1C Id
 *   +0x20 RequestId
 *   +0x28 NdisRequestHandle? varies
 * We locate the OID and INFORMATION_BUFFER via NDIS 6.0 documented offsets:
 *   DATA.QUERY_INFORMATION.Oid                at +0x28 on some builds
 * Safer: scan the request for a known OID DWORD then the pointer that follows.
 */
static BOOLEAN PatchOidBuffer(PVOID request)
{
    EACSPOOF_NIC *nic = NicPrimary();
    PUCHAR p;
    ULONG oid = 0;
    PVOID *bufPtr;
    PULONG bytes;
    ULONG i;

    if (!nic || !request) return FALSE;
    p = (PUCHAR)request;

    /* NDIS 6 NDIS_OID_REQUEST.DATA.QUERY_INFORMATION: Oid at offset 0x28, InformationBuffer at 0x30. */
    oid = *(ULONG *)(p + 0x28);
    bufPtr = (PVOID *)(p + 0x30);
    bytes = (PULONG)(p + 0x38);

    if (oid != OID_802_3_PERMANENT_ADDRESS &&
        oid != OID_802_3_CURRENT_ADDRESS &&
        oid != OID_GEN_NETWORK_LAYER_ADDRESSES) {
        /* walk a small window for the OID */
        for (i = 0x10; i < 0x80; i += 4) {
            ULONG v = *(ULONG *)(p + i);
            if (v == OID_802_3_PERMANENT_ADDRESS || v == OID_802_3_CURRENT_ADDRESS ||
                v == OID_GEN_NETWORK_LAYER_ADDRESSES) {
                oid = v;
                bufPtr = (PVOID *)(p + i + 8);
                bytes = (PULONG)(p + i + 16);
                break;
            }
        }
    }

    if (oid == OID_802_3_PERMANENT_ADDRESS && *bufPtr) {
        RtlCopyMemory(*bufPtr, nic->permanentMac, 6);
        if (bytes) *bytes = 6;
        CountOid(&g_Stats.macRewrites);
        return TRUE;
    }
    if (oid == OID_802_3_CURRENT_ADDRESS && *bufPtr) {
        RtlCopyMemory(*bufPtr, nic->currentMac, 6);
        if (bytes) *bytes = 6;
        CountOid(&g_Stats.macRewrites);
        return TRUE;
    }
    if (oid == OID_GEN_NETWORK_LAYER_ADDRESSES && *bufPtr) {
        /* NETWORK_ADDRESS_LIST: rewrite first IPv4 slot if present (4 bytes after header). */
        PUCHAR nb = (PUCHAR)*bufPtr;
        /* AddressCount at 0, AddressType at 4, then NETWORK_ADDRESS. */
        if (nic->ipv4[0]) {
            ULONG a = 0, b = 0, c = 0, d = 0;
            /* parse dotted quad without CRT sscanf */
            {
                const char *s = nic->ipv4;
                ULONG *slots[4] = { &a, &b, &c, &d };
                ULONG idx = 0, val = 0;
                while (*s && idx < 4) {
                    if (*s >= '0' && *s <= '9') val = val * 10 + (*s - '0');
                    else if (*s == '.') { *slots[idx++] = val; val = 0; }
                    s++;
                }
                if (idx < 4) *slots[idx] = val;
            }
            nb[8]  = (UCHAR)a; nb[9]  = (UCHAR)b;
            nb[10] = (UCHAR)c; nb[11] = (UCHAR)d;
        }
        CountOid(&g_Stats.oidIntercepts);
        return TRUE;
    }
    return FALSE;
}

static NDIS_STATUS NTAPI NdisOid_Detour(PVOID handle, PNDIS_OID_REQUEST req)
{
    NDIS_STATUS st;
    if (!g_OidOrig) return 0xC0000001; /* NDIS_STATUS_FAILURE */
    st = g_OidOrig(handle, req);
    if ((g_Config.modules & EACSPOOF_MOD_NETWORK) && req)
        PatchOidBuffer(req);
    return st;
}

static PVOID FindNdisBase(VOID)
{
    /* ndis.sys is in PsLoadedModuleList; MmGetSystemRoutineAddress won't find NdisFOidRequest.
       Resolve via NtQuerySystemInformation SystemModuleInformation. */
    typedef NTSTATUS (NTAPI *PFN_NTQ)(ULONG, PVOID, ULONG, PULONG);
    PFN_NTQ ntq = (PFN_NTQ)HookNtosExport(L"NtQuerySystemInformation");
    ULONG len = 0;
    PVOID buf;
    NTSTATUS st;
    ULONG i;

    typedef struct _RTL_PROCESS_MODULE_INFORMATION {
        HANDLE Section;
        PVOID MappedBase;
        PVOID ImageBase;
        ULONG ImageSize;
        ULONG Flags;
        USHORT LoadOrderIndex, InitOrderIndex, LoadCount, OffsetToFileName;
        UCHAR  FullPathName[256];
    } RTL_PROCESS_MODULE_INFORMATION;

    typedef struct _RTL_PROCESS_MODULES {
        ULONG NumberOfModules;
        RTL_PROCESS_MODULE_INFORMATION Modules[1];
    } RTL_PROCESS_MODULES;

    if (!ntq) return NULL;
    st = ntq(11, NULL, 0, &len);
    if (!len) len = 0x100000;
    buf = ExAllocatePoolWithTag(NonPagedPoolNx, len, 'dnSE');
    if (!buf) return NULL;
    st = ntq(11, buf, len, &len);
    if (NT_SUCCESS(st)) {
        RTL_PROCESS_MODULES *m = (RTL_PROCESS_MODULES *)buf;
        for (i = 0; i < m->NumberOfModules; i++) {
            char *n = (char *)m->Modules[i].FullPathName + m->Modules[i].OffsetToFileName;
            if (n[0] == 'n' && n[1] == 'd' && n[2] == 'i' && n[3] == 's' && n[4] == '.') {
                PVOID base = m->Modules[i].ImageBase;
                ExFreePoolWithTag(buf, 'dnSE');
                return base;
            }
        }
    }
    ExFreePoolWithTag(buf, 'dnSE');
    return NULL;
}

NTSTATUS NetworkStart(VOID)
{
    PVOID oid;
    g_NdisBase = FindNdisBase();
    if (!g_NdisBase) return STATUS_NOT_FOUND;
    oid = HookResolveExport(g_NdisBase, "NdisFOidRequest");
    if (!oid) oid = HookResolveExport(g_NdisBase, "NdisOidRequest");
    if (!oid) return STATUS_PROCEDURE_NOT_FOUND;
    if (!NT_SUCCESS(HookInstall(&g_OidHook, oid, (PVOID)NdisOid_Detour)))
        return STATUS_UNSUCCESSFUL;
    g_OidOrig = (PFN_NDIS_OID)g_OidHook.trampoline;
    return STATUS_SUCCESS;
}

VOID NetworkStop(VOID)
{
    HookRemove(&g_OidHook);
    g_OidOrig = NULL;
    g_NdisBase = NULL;
}

/* Ethernet header rewrite for ARP (0x0806) / IPv6 ND (0x86DD + ICMPv6).
   Called from a filter send-net-buffer path when wired; exported for completeness. */
VOID NetworkRewriteFrame(PUCHAR eth, ULONG len)
{
    EACSPOOF_NIC *nic = NicPrimary();
    USHORT proto;
    KIRQL irql;
    if (!nic || !eth || len < 14) return;
    proto = (USHORT)((eth[12] << 8) | eth[13]);
    if (proto == 0x0806 && nic->rewriteArp) {
        RtlCopyMemory(eth + 6, nic->currentMac, 6);
        if (len >= 22) RtlCopyMemory(eth + 16, nic->currentMac, 6);
        KeAcquireSpinLock(&g_Lock, &irql);
        g_Stats.arpRewrites++;
        KeReleaseSpinLock(&g_Lock, irql);
    } else if (proto == 0x86DD && nic->rewriteNd) {
        RtlCopyMemory(eth + 6, nic->currentMac, 6);
        KeAcquireSpinLock(&g_Lock, &irql);
        g_Stats.arpRewrites++;
        KeReleaseSpinLock(&g_Lock, irql);
    }
}
