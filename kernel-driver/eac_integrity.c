#include "kernel_spoofer.h"
#include "hook.h"
#include "modules.h"

#ifndef MM_COPY_MEMORY_VIRTUAL
typedef struct _MM_COPY_ADDRESS {
    union {
        PVOID VirtualAddress;
        PHYSICAL_ADDRESS PhysicalAddress;
    };
} MM_COPY_ADDRESS, *PMM_COPY_ADDRESS;
#define MM_COPY_MEMORY_VIRTUAL 0x2
#endif

extern EACSPOOF_CONFIG g_Config;
extern EACSPOOF_STATS  g_Stats;
extern KSPIN_LOCK      g_Lock;
extern PDRIVER_OBJECT  g_DriverObject;

#define PATCH_MAX 32

typedef struct _SAVED_PATCH {
    PVOID address;
    ULONG length;
    UCHAR original[32];
    BOOLEAN used;
} SAVED_PATCH;

static SAVED_PATCH g_Patches[PATCH_MAX];
static BOOLEAN g_ImageNotify;
static JUMP_HOOK g_CopyMemHook;
static JUMP_HOOK g_RvmHook;

typedef NTSTATUS (NTAPI *PFN_OBREG)(PVOID, PVOID);
typedef NTSTATUS (NTAPI *PFN_CMREG)(PVOID, PVOID, PVOID);
typedef NTSTATUS (NTAPI *PFN_PSNOTIFY)(PVOID, BOOLEAN);

static PFN_OBREG g_ObReg;
static JUMP_HOOK g_ObHook;
static JUMP_HOOK g_CmHook;
static JUMP_HOOK g_PsProcHook;
static JUMP_HOOK g_PsThrHook;
static JUMP_HOOK g_PsImgHook;

static VOID Bump(ULONG64 *c)
{
    KIRQL irql;
    KeAcquireSpinLock(&g_Lock, &irql);
    (*c)++;
    KeReleaseSpinLock(&g_Lock, irql);
}

static BOOLEAN NameHasEac(PUNICODE_STRING u)
{
    USHORT i;
    if (!u || !u->Buffer) return FALSE;
    for (i = 0; i + 2 < u->Length / sizeof(WCHAR); i++) {
        WCHAR a = u->Buffer[i], b = u->Buffer[i+1], c = u->Buffer[i+2];
        if ((a == L'E' || a == L'e') && (b == L'A' || b == L'a') && (c == L'C' || c == L'c'))
            return TRUE;
    }
    return FALSE;
}

static NTSTATUS NTAPI ObRegisterCallbacks_Detour(PVOID cb, PVOID handle)
{
    if ((g_Config.modules & EACSPOOF_MOD_EAC) && g_Config.eac.stripObCallbacks) {
        /* Pretend success so EAC's init continues, but do not register. */
        if (handle) *(PVOID *)handle = (PVOID)(ULONG_PTR)0xEAC00001;
        Bump(&g_Stats.callbacksStripped);
        return STATUS_SUCCESS;
    }
    return g_ObReg ? g_ObReg(cb, handle) : STATUS_UNSUCCESSFUL;
}

static NTSTATUS NTAPI CmRegisterCallbackEx_Detour(PVOID fn, PVOID alt, PVOID ctx, PVOID altitude, PVOID cookie, PVOID reserved)
{
    typedef NTSTATUS (NTAPI *PFN)(PVOID, PVOID, PVOID, PVOID, PVOID, PVOID);
    if ((g_Config.modules & EACSPOOF_MOD_EAC) && g_Config.eac.stripRegCallbacks) {
        if (cookie) *(PVOID *)cookie = (PVOID)(ULONG_PTR)0xEAC00002;
        Bump(&g_Stats.callbacksStripped);
        return STATUS_SUCCESS;
    }
    return ((PFN)g_CmHook.trampoline)(fn, alt, ctx, altitude, cookie, reserved);
}

static NTSTATUS NTAPI PsSetCreateProcessNotifyRoutineEx_Detour(PVOID fn, BOOLEAN remove)
{
    typedef NTSTATUS (NTAPI *PFN)(PVOID, BOOLEAN);
    if (!remove && (g_Config.modules & EACSPOOF_MOD_EAC) && g_Config.eac.stripProcNotify) {
        Bump(&g_Stats.callbacksStripped);
        return STATUS_SUCCESS;
    }
    return ((PFN)g_PsProcHook.trampoline)(fn, remove);
}

static NTSTATUS NTAPI PsSetCreateThreadNotifyRoutine_Detour(PVOID fn)
{
    typedef NTSTATUS (NTAPI *PFN)(PVOID);
    if ((g_Config.modules & EACSPOOF_MOD_EAC) && g_Config.eac.stripThreadNotify) {
        Bump(&g_Stats.callbacksStripped);
        return STATUS_SUCCESS;
    }
    return ((PFN)g_PsThrHook.trampoline)(fn);
}

static NTSTATUS NTAPI PsSetLoadImageNotifyRoutine_Detour(PVOID fn)
{
    typedef NTSTATUS (NTAPI *PFN)(PVOID);
    if ((g_Config.modules & EACSPOOF_MOD_EAC) && g_Config.eac.stripImageNotify) {
        Bump(&g_Stats.callbacksStripped);
        return STATUS_SUCCESS;
    }
    return ((PFN)g_PsImgHook.trampoline)(fn);
}

static VOID RememberPatch(PVOID addr, ULONG len, PUCHAR orig)
{
    ULONG i;
    for (i = 0; i < PATCH_MAX; i++) {
        if (!g_Patches[i].used) {
            g_Patches[i].used = TRUE;
            g_Patches[i].address = addr;
            g_Patches[i].length = len > 32 ? 32 : len;
            RtlCopyMemory(g_Patches[i].original, orig, g_Patches[i].length);
            return;
        }
    }
}

static VOID SpliceOriginal(PVOID dest, PVOID src, SIZE_T n)
{
    ULONG i;
    PUCHAR d = (PUCHAR)dest;
    PUCHAR s = (PUCHAR)src;
    for (i = 0; i < PATCH_MAX; i++) {
        PUCHAR pa;
        ULONG off, take;
        if (!g_Patches[i].used) continue;
        pa = (PUCHAR)g_Patches[i].address;
        if (s + n <= pa || s >= pa + g_Patches[i].length) continue;
        off = (ULONG)(s < pa ? (pa - s) : 0);
        take = g_Patches[i].length;
        if (s > pa) {
            ULONG skip = (ULONG)(s - pa);
            if (skip >= take) continue;
            take -= skip;
            pa += skip;
        }
        if (off + take > n) take = (ULONG)(n - off);
        RtlCopyMemory(d + off, g_Patches[i].original + (pa - (PUCHAR)g_Patches[i].address), take);
        Bump(&g_Stats.integrityReadsSpliced);
    }
}

typedef NTSTATUS (NTAPI *PFN_MMCOPY)(PVOID, MM_COPY_ADDRESS, SIZE_T, ULONG, PSIZE_T);

static NTSTATUS NTAPI MmCopyMemory_Detour(
    PVOID target,
    MM_COPY_ADDRESS source,
    SIZE_T n,
    ULONG flags,
    PSIZE_T copied)
{
    NTSTATUS st = ((PFN_MMCOPY)g_CopyMemHook.trampoline)(target, source, n, flags, copied);
    if (NT_SUCCESS(st) && (g_Config.modules & EACSPOOF_MOD_EAC) && g_Config.eac.spoofIntegrityReads) {
        PVOID va = source.VirtualAddress;
        SpliceOriginal(target, va, n);
    }
    return st;
}

typedef struct _KLDR_DATA_TABLE_ENTRY {
    LIST_ENTRY InLoadOrderLinks;
    LIST_ENTRY InMemoryOrderLinks;
    LIST_ENTRY InInitializationOrderLinks;
    PVOID DllBase;
    PVOID EntryPoint;
    ULONG SizeOfImage;
    UNICODE_STRING FullDllName;
    UNICODE_STRING BaseDllName;
} KLDR_DATA_TABLE_ENTRY, *PKLDR_DATA_TABLE_ENTRY;

static VOID UnlinkDriver(VOID)
{
    PKLDR_DATA_TABLE_ENTRY e;
    KIRQL irql;
    if (!g_DriverObject || !g_Config.eac.hideFromModuleList) return;
    e = (PKLDR_DATA_TABLE_ENTRY)g_DriverObject->DriverSection;
    if (!e) return;
    KeRaiseIrql(HIGH_LEVEL, &irql);
    if (e->InLoadOrderLinks.Flink && e->InLoadOrderLinks.Blink) {
        e->InLoadOrderLinks.Flink->Blink = e->InLoadOrderLinks.Blink;
        e->InLoadOrderLinks.Blink->Flink = e->InLoadOrderLinks.Flink;
        e->InLoadOrderLinks.Flink = (PLIST_ENTRY)&e->InLoadOrderLinks;
        e->InLoadOrderLinks.Blink = (PLIST_ENTRY)&e->InLoadOrderLinks;
        Bump(&g_Stats.moduleListHides);
    }
    KeLowerIrql(irql);
}

static VOID ImageNotify(
    PUNICODE_STRING full,
    HANDLE pid,
    PIMAGE_INFO info)
{
    UNREFERENCED_PARAMETER(pid);
    UNREFERENCED_PARAMETER(info);
    if (!(g_Config.modules & EACSPOOF_MOD_EAC)) return;
    if (!NameHasEac(full)) return;
    Bump(&g_Stats.eacImageNotifies);

    /* EAC's DriverEntry will call ObRegisterCallbacks / CmRegisterCallbackEx /
       PsSet*Notify. Those exports are already detoured; the next calls from
       EasyAntiCheat_EOS.sys return success without installing watches. */

    if (g_Config.eac.hideFromModuleList)
        UnlinkDriver();
}

NTSTATUS EacStart(VOID)
{
    PVOID p;
    NTSTATUS st;

    p = HookNtosExport(L"ObRegisterCallbacks");
    if (p) {
        RtlCopyMemory(g_Patches[0].original, p, 12);
        RememberPatch(p, 12, (PUCHAR)p);
        st = HookInstall(&g_ObHook, p, (PVOID)ObRegisterCallbacks_Detour);
        if (NT_SUCCESS(st)) g_ObReg = (PFN_OBREG)g_ObHook.trampoline;
    }

    p = HookNtosExport(L"CmRegisterCallbackEx");
    if (p) HookInstall(&g_CmHook, p, (PVOID)CmRegisterCallbackEx_Detour);

    p = HookNtosExport(L"PsSetCreateProcessNotifyRoutineEx");
    if (p) HookInstall(&g_PsProcHook, p, (PVOID)PsSetCreateProcessNotifyRoutineEx_Detour);

    p = HookNtosExport(L"PsSetCreateThreadNotifyRoutine");
    if (p) HookInstall(&g_PsThrHook, p, (PVOID)PsSetCreateThreadNotifyRoutine_Detour);

    p = HookNtosExport(L"PsSetLoadImageNotifyRoutine");
    if (p) HookInstall(&g_PsImgHook, p, (PVOID)PsSetLoadImageNotifyRoutine_Detour);

    p = HookNtosExport(L"MmCopyMemory");
    if (p) HookInstall(&g_CopyMemHook, p, (PVOID)MmCopyMemory_Detour);

    st = PsSetLoadImageNotifyRoutine(ImageNotify);
    if (NT_SUCCESS(st)) g_ImageNotify = TRUE;

    if (g_Config.eac.hideFromModuleList)
        UnlinkDriver();

    return STATUS_SUCCESS;
}

VOID EacStop(VOID)
{
    if (g_ImageNotify) {
        PsRemoveLoadImageNotifyRoutine(ImageNotify);
        g_ImageNotify = FALSE;
    }
    HookRemove(&g_ObHook);
    HookRemove(&g_CmHook);
    HookRemove(&g_PsProcHook);
    HookRemove(&g_PsThrHook);
    HookRemove(&g_PsImgHook);
    HookRemove(&g_CopyMemHook);
    HookRemove(&g_RvmHook);
}

VOID EacOnUnload(VOID)
{
    EacStop();
}
