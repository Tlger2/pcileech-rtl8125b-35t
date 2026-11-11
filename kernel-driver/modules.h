#pragma once
#include <ntddk.h>

NTSTATUS StorageStart(PDRIVER_OBJECT drv);
VOID     StorageStop(VOID);
NTSTATUS StorageDispatch(PDEVICE_OBJECT dev, PIRP irp);

NTSTATUS SmbiosStart(VOID);
VOID     SmbiosStop(VOID);

NTSTATUS NetworkStart(VOID);
VOID     NetworkStop(VOID);

NTSTATUS EacStart(VOID);
VOID     EacStop(VOID);
VOID     EacOnUnload(VOID);
