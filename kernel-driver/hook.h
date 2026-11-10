#pragma once
#include <ntddk.h>

#define HOOK_MAX 16
#define HOOK_ORIG_MAX 16

typedef struct _JUMP_HOOK {
    PVOID  target;
    PVOID  detour;
    PVOID  trampoline;
    UCHAR  original[HOOK_ORIG_MAX];
    SIZE_T originalLength;
    BOOLEAN installed;
} JUMP_HOOK, *PJUMP_HOOK;

NTSTATUS HookInstall(PJUMP_HOOK hook, PVOID target, PVOID detour);
NTSTATUS HookRemove(PJUMP_HOOK hook);
PVOID    HookResolveExport(PVOID moduleBase, const char *name);
PVOID    HookNtosExport(const WCHAR *name);
NTSTATUS HookProtectWrite(PVOID addr, SIZE_T len, PVOID src);
