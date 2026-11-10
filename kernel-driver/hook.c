#include "hook.h"

typedef struct _IMAGE_DOS_HEADER_K {
    USHORT e_magic;
    USHORT pad[29];
    LONG   e_lfanew;
} IMAGE_DOS_HEADER_K;

typedef struct _IMAGE_DATA_DIRECTORY_K {
    ULONG VirtualAddress;
    ULONG Size;
} IMAGE_DATA_DIRECTORY_K;

typedef struct _IMAGE_OPTIONAL_HEADER64_K {
    USHORT Magic;
    UCHAR  unused0[14];
    ULONG  unused1[5];
    ULONGLONG ImageBase;
    ULONG  unused2[4];
    USHORT unused3[6];
    ULONG  unused4[4];
    USHORT unused5[2];
    ULONGLONG unused6[4];
    ULONG  LoaderFlags, NumberOfRvaAndSizes;
    IMAGE_DATA_DIRECTORY_K DataDirectory[16];
} IMAGE_OPTIONAL_HEADER64_K;

typedef struct _IMAGE_FILE_HEADER_K {
    USHORT Machine, NumberOfSections;
    ULONG  TimeDateStamp, PointerToSymbolTable, NumberOfSymbols;
    USHORT SizeOfOptionalHeader, Characteristics;
} IMAGE_FILE_HEADER_K;

typedef struct _IMAGE_NT_HEADERS64_K {
    ULONG Signature;
    IMAGE_FILE_HEADER_K FileHeader;
    IMAGE_OPTIONAL_HEADER64_K OptionalHeader;
} IMAGE_NT_HEADERS64_K;

typedef struct _IMAGE_EXPORT_DIRECTORY_K {
    ULONG Characteristics, TimeDateStamp;
    USHORT MajorVersion, MinorVersion;
    ULONG Name, Base, NumberOfFunctions, NumberOfNames;
    ULONG AddressOfFunctions, AddressOfNames, AddressOfNameOrdinals;
} IMAGE_EXPORT_DIRECTORY_K;

static int kstrcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

static UCHAR g_AbsJmp[] = {
    0x48, 0xB8, 0,0,0,0,0,0,0,0,
    0xFF, 0xE0
};

NTSTATUS HookProtectWrite(PVOID addr, SIZE_T len, PVOID src)
{
    PMDL mdl;
    PVOID mapped;
    NTSTATUS st = STATUS_SUCCESS;

    mdl = IoAllocateMdl(addr, (ULONG)len, FALSE, FALSE, NULL);
    if (!mdl) return STATUS_INSUFFICIENT_RESOURCES;

    __try {
        MmProbeAndLockPages(mdl, KernelMode, IoReadAccess);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        IoFreeMdl(mdl);
        return GetExceptionCode();
    }

    mapped = MmMapLockedPagesSpecifyCache(mdl, KernelMode, MmNonCached, NULL, FALSE, NormalPagePriority);
    if (!mapped) {
        MmUnlockPages(mdl);
        IoFreeMdl(mdl);
        return STATUS_UNSUCCESSFUL;
    }

    __try {
        RtlCopyMemory(mapped, src, len);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        st = GetExceptionCode();
    }

    MmUnmapLockedPages(mapped, mdl);
    MmUnlockPages(mdl);
    IoFreeMdl(mdl);
    return st;
}

NTSTATUS HookInstall(PJUMP_HOOK hook, PVOID target, PVOID detour)
{
    UCHAR jmp[12];
    NTSTATUS st;
    PHYSICAL_ADDRESS low, high, skip;
    ULONG_PTR cont;

    if (!hook || !target || !detour) return STATUS_INVALID_PARAMETER;
    if (hook->installed) return STATUS_ALREADY_REGISTERED;

    RtlZeroMemory(hook, sizeof(*hook));
    hook->target = target;
    hook->detour = detour;
    hook->originalLength = 12;
    RtlCopyMemory(hook->original, target, 12);

    low.QuadPart = 0;
    high.QuadPart = ~0ULL;
    skip.QuadPart = 0;
    hook->trampoline = MmAllocateContiguousMemorySpecifyCache(64, low, high, skip, MmNonCached);
    if (!hook->trampoline) return STATUS_INSUFFICIENT_RESOURCES;

    RtlCopyMemory(hook->trampoline, hook->original, 12);
    RtlCopyMemory(jmp, g_AbsJmp, sizeof(jmp));
    cont = (ULONG_PTR)target + 12;
    RtlCopyMemory(jmp + 2, &cont, sizeof(cont));
    RtlCopyMemory((PUCHAR)hook->trampoline + 12, jmp, sizeof(jmp));

    RtlCopyMemory(jmp, g_AbsJmp, sizeof(jmp));
    RtlCopyMemory(jmp + 2, &detour, sizeof(detour));
    st = HookProtectWrite(target, sizeof(jmp), jmp);
    if (!NT_SUCCESS(st)) {
        MmFreeContiguousMemory(hook->trampoline);
        hook->trampoline = NULL;
        return st;
    }

    hook->installed = TRUE;
    return STATUS_SUCCESS;
}

NTSTATUS HookRemove(PJUMP_HOOK hook)
{
    NTSTATUS st;
    if (!hook || !hook->installed) return STATUS_INVALID_DEVICE_STATE;
    st = HookProtectWrite(hook->target, hook->originalLength, hook->original);
    if (hook->trampoline) {
        MmFreeContiguousMemory(hook->trampoline);
        hook->trampoline = NULL;
    }
    hook->installed = FALSE;
    return st;
}

PVOID HookResolveExport(PVOID moduleBase, const char *name)
{
    IMAGE_DOS_HEADER_K *dos;
    IMAGE_NT_HEADERS64_K *nt;
    IMAGE_EXPORT_DIRECTORY_K *exp;
    ULONG *names, *funcs;
    USHORT *ords;
    ULONG i;

    if (!moduleBase || !name) return NULL;
    dos = (IMAGE_DOS_HEADER_K *)moduleBase;
    if (dos->e_magic != 0x5A4D) return NULL;
    nt = (IMAGE_NT_HEADERS64_K *)((PUCHAR)moduleBase + dos->e_lfanew);
    if (nt->Signature != 0x00004550) return NULL;
    if (!nt->OptionalHeader.DataDirectory[0].VirtualAddress) return NULL;

    exp = (IMAGE_EXPORT_DIRECTORY_K *)((PUCHAR)moduleBase +
          nt->OptionalHeader.DataDirectory[0].VirtualAddress);
    names = (ULONG *)((PUCHAR)moduleBase + exp->AddressOfNames);
    funcs = (ULONG *)((PUCHAR)moduleBase + exp->AddressOfFunctions);
    ords  = (USHORT *)((PUCHAR)moduleBase + exp->AddressOfNameOrdinals);

    for (i = 0; i < exp->NumberOfNames; i++) {
        const char *n = (const char *)((PUCHAR)moduleBase + names[i]);
        if (kstrcmp(n, name) == 0)
            return (PVOID)((PUCHAR)moduleBase + funcs[ords[i]]);
    }
    return NULL;
}

PVOID HookNtosExport(const WCHAR *name)
{
    UNICODE_STRING u;
    RtlInitUnicodeString(&u, name);
    return MmGetSystemRoutineAddress(&u);
}
