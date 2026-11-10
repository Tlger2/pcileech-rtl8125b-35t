#include "kernel_spoofer.h"
#include "hook.h"
#include "modules.h"

extern EACSPOOF_CONFIG g_Config;
extern EACSPOOF_STATS  g_Stats;
extern KSPIN_LOCK      g_Lock;

#ifndef SystemFirmwareTableInformation
#define SystemFirmwareTableInformation 76
#endif

typedef struct _SYSTEM_FIRMWARE_TABLE_INFORMATION {
    ULONG ProviderSignature;
    ULONG Action;
    ULONG TableID;
    ULONG TableBufferLength;
    UCHAR TableBuffer[1];
} SYSTEM_FIRMWARE_TABLE_INFORMATION, *PSYSTEM_FIRMWARE_TABLE_INFORMATION;

typedef NTSTATUS (NTAPI *PFN_NTQUERYSYSINFO)(
    ULONG SystemInformationClass,
    PVOID SystemInformation,
    ULONG SystemInformationLength,
    PULONG ReturnLength);

static JUMP_HOOK g_NtqHook;
static PFN_NTQUERYSYSINFO g_NtqOrig;
static PVOID g_SmbiosCopy;
static ULONG g_SmbiosCopySize;

static UCHAR SmbiosChecksum(const UCHAR *p, ULONG n)
{
    ULONG i;
    UCHAR s = 0;
    for (i = 0; i < n; i++) s = (UCHAR)(s + p[i]);
    return (UCHAR)(0u - s);
}

static UCHAR *SmbiosNext(UCHAR *p, UCHAR *end)
{
    UCHAR len;
    if (p + 2 > end) return end;
    len = p[1];
    p += len;
    while (p + 1 < end && !(p[0] == 0 && p[1] == 0)) p++;
    if (p + 2 <= end) p += 2;
    return p;
}

static const char *SmbiosString(UCHAR *start, UCHAR idx)
{
    UCHAR *p;
    UCHAR n = 1;
    if (!idx) return "";
    p = start + start[1];
    while (n < idx && *p) {
        while (*p) p++;
        p++;
        n++;
    }
    return (const char *)p;
}

static VOID OverwriteString(char *slot, SIZE_T cap, const char *src)
{
    SIZE_T i = 0;
    if (!slot || !cap) return;
    while (src[i] && i + 1 < cap) { slot[i] = src[i]; i++; }
    slot[i] = 0;
}

static VOID PatchType1Uuid(UCHAR *hdr, EACSPOOF_SMBIOS *s)
{
    if (hdr[1] < 0x19) return;
    RtlCopyMemory(hdr + 8, s->sysUuid, 16);
}

static VOID RewriteSmbiosTable(UCHAR *table, ULONG size)
{
    UCHAR *p = table;
    UCHAR *end = table + size;
    EACSPOOF_SMBIOS *s = &g_Config.smbios;

    while (p + 4 < end && p[0] != 127) {
        UCHAR type = p[0];
        UCHAR *strbase = p + p[1];
        if (type == 0) {
            OverwriteString((char *)SmbiosString(p, p[4]), 31, s->biosVendor);
            OverwriteString((char *)SmbiosString(p, p[5]), 31, s->biosVersion);
            OverwriteString((char *)SmbiosString(p, p[8]), 15, s->biosDate);
        } else if (type == 1) {
            PatchType1Uuid(p, s);
            OverwriteString((char *)SmbiosString(p, p[4]), 31, s->sysManufacturer);
            OverwriteString((char *)SmbiosString(p, p[5]), 31, s->sysProduct);
            OverwriteString((char *)SmbiosString(p, p[7]), 31, s->sysSerial);
        } else if (type == 2) {
            OverwriteString((char *)SmbiosString(p, p[4]), 31, s->boardManufacturer);
            OverwriteString((char *)SmbiosString(p, p[5]), 31, s->boardProduct);
            OverwriteString((char *)SmbiosString(p, p[7]), 31, s->boardSerial);
            OverwriteString((char *)SmbiosString(p, p[8]), 31, s->boardAsset);
        } else if (type == 3) {
            OverwriteString((char *)SmbiosString(p, p[7]), 31, s->chassisSerial);
        } else if (type == 4) {
            OverwriteString((char *)SmbiosString(p, p[0x20 < p[1] ? 0x20 : 7]), 31, s->cpuSerial);
        }
        UNREFERENCED_PARAMETER(strbase);
        p = SmbiosNext(p, end);
    }
}

static NTSTATUS BuildSmbiosCopy(VOID)
{
    ULONG needed = 0;
    NTSTATUS st;
    PSYSTEM_FIRMWARE_TABLE_INFORMATION info;
    ULONG alloc;

    if (!g_NtqOrig) return STATUS_INVALID_DEVICE_STATE;

    st = g_NtqOrig(SystemFirmwareTableInformation, NULL, 0, &needed);
    alloc = needed ? needed : 0x10000;
    info = (PSYSTEM_FIRMWARE_TABLE_INFORMATION)ExAllocatePoolWithTag(NonPagedPoolNx, alloc, 'bmSE');
    if (!info) return STATUS_INSUFFICIENT_RESOURCES;
    RtlZeroMemory(info, alloc);
    info->ProviderSignature = 'RSMB';
    info->Action = 1; /* SystemFirmwareTable_Get */
    info->TableID = 0;
    info->TableBufferLength = alloc - FIELD_OFFSET(SYSTEM_FIRMWARE_TABLE_INFORMATION, TableBuffer);

    st = g_NtqOrig(SystemFirmwareTableInformation, info, alloc, &needed);
    if (!NT_SUCCESS(st) && st != STATUS_BUFFER_TOO_SMALL) {
        ExFreePoolWithTag(info, 'bmSE');
        return st;
    }

    g_SmbiosCopySize = info->TableBufferLength;
    g_SmbiosCopy = ExAllocatePoolWithTag(NonPagedPoolNx, g_SmbiosCopySize, 'bmSE');
    if (!g_SmbiosCopy) {
        ExFreePoolWithTag(info, 'bmSE');
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    RtlCopyMemory(g_SmbiosCopy, info->TableBuffer, g_SmbiosCopySize);
    RewriteSmbiosTable((UCHAR *)g_SmbiosCopy, g_SmbiosCopySize);
    ExFreePoolWithTag(info, 'bmSE');
    return STATUS_SUCCESS;
}

static NTSTATUS NTAPI NtQuerySystemInformation_Detour(
    ULONG class,
    PVOID info,
    ULONG length,
    PULONG retLen)
{
    NTSTATUS st;
    KIRQL irql;

    if (class != SystemFirmwareTableInformation || !(g_Config.modules & EACSPOOF_MOD_SMBIOS) || !g_SmbiosCopy) {
        return g_NtqOrig(class, info, length, retLen);
    }

    {
        PSYSTEM_FIRMWARE_TABLE_INFORMATION req = (PSYSTEM_FIRMWARE_TABLE_INFORMATION)info;
        ULONG need = FIELD_OFFSET(SYSTEM_FIRMWARE_TABLE_INFORMATION, TableBuffer) + g_SmbiosCopySize;
        if (!req || length < FIELD_OFFSET(SYSTEM_FIRMWARE_TABLE_INFORMATION, TableBuffer)) {
            if (retLen) *retLen = need;
            return STATUS_INFO_LENGTH_MISMATCH;
        }
        if (req->ProviderSignature != 'RSMB')
            return g_NtqOrig(class, info, length, retLen);

        KeAcquireSpinLock(&g_Lock, &irql);
        g_Stats.smbiosQueries++;
        KeReleaseSpinLock(&g_Lock, irql);

        if (length < need) {
            req->TableBufferLength = g_SmbiosCopySize;
            if (retLen) *retLen = need;
            return STATUS_BUFFER_TOO_SMALL;
        }
        RtlCopyMemory(req->TableBuffer, g_SmbiosCopy, g_SmbiosCopySize);
        req->TableBufferLength = g_SmbiosCopySize;
        if (retLen) *retLen = need;
        st = STATUS_SUCCESS;
    }
    return st;
}

NTSTATUS SmbiosStart(VOID)
{
    PVOID ntq;
    NTSTATUS st;

    ntq = HookNtosExport(L"NtQuerySystemInformation");
    if (!ntq) ntq = HookNtosExport(L"ZwQuerySystemInformation");
    if (!ntq) return STATUS_PROCEDURE_NOT_FOUND;

    /* Install hook first with orig trampoline, then snapshot via trampoline. */
    st = HookInstall(&g_NtqHook, ntq, (PVOID)NtQuerySystemInformation_Detour);
    if (!NT_SUCCESS(st)) return st;
    g_NtqOrig = (PFN_NTQUERYSYSINFO)g_NtqHook.trampoline;

    st = BuildSmbiosCopy();
    if (!NT_SUCCESS(st)) {
        HookRemove(&g_NtqHook);
        g_NtqOrig = NULL;
        return st;
    }
    return STATUS_SUCCESS;
}

VOID SmbiosStop(VOID)
{
    HookRemove(&g_NtqHook);
    g_NtqOrig = NULL;
    if (g_SmbiosCopy) {
        ExFreePoolWithTag(g_SmbiosCopy, 'bmSE');
        g_SmbiosCopy = NULL;
        g_SmbiosCopySize = 0;
    }
}
