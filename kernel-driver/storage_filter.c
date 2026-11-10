#include "kernel_spoofer.h"
#include <ntdddisk.h>
#include <ntddstor.h>
#include <ntstrsafe.h>
#include <scsi.h>
#include <ata.h>

extern EACSPOOF_CONFIG g_Config;
extern EACSPOOF_STATS  g_Stats;
extern KSPIN_LOCK      g_Lock;

#ifndef IOCTL_MOUNTDEV_QUERY_UNIQUE_ID
#define IOCTL_MOUNTDEV_QUERY_UNIQUE_ID CTL_CODE(0x4D, 0, METHOD_BUFFERED, FILE_ANY_ACCESS)
#endif

#define FILTER_TAG 'fpSE'
#define MAX_FILTER_DEV 8

typedef struct _FILTER_EXT {
    PDEVICE_OBJECT lower;
    PDEVICE_OBJECT self;
    ULONG diskIndex;
    BOOLEAN attached;
} FILTER_EXT, *PFILTER_EXT;

static PDEVICE_OBJECT g_FilterDev[MAX_FILTER_DEV];
static ULONG g_FilterCount;

static EACSPOOF_DISK *DiskForIndex(ULONG idx)
{
    ULONG i;
    for (i = 0; i < g_Config.diskCount && i < EACSPOOF_MAX_DISKS; i++) {
        if (g_Config.disks[i].diskIndex == idx && g_Config.disks[i].enabled)
            return &g_Config.disks[i];
    }
    if (idx < g_Config.diskCount) return &g_Config.disks[idx];
    return NULL;
}

static VOID AtaSwapSerial(UCHAR *identify, const char *serial)
{
    /* ATA IDENTIFY DEVICE words 10-19: 20 bytes, swapped pairs. */
    UCHAR tmp[20];
    SIZE_T i, n;
    RtlFillMemory(tmp, 20, ' ');
    n = 0;
    while (serial[n] && n < 20) { tmp[n] = (UCHAR)serial[n]; n++; }
    for (i = 0; i < 20; i += 2) {
        identify[20 + i]     = tmp[i + 1];
        identify[20 + i + 1] = tmp[i];
    }
}

static VOID PatchStorageProperty(PSTORAGE_DEVICE_DESCRIPTOR desc, EACSPOOF_DISK *disk)
{
    char *buf = (char *)desc;
    if (desc->SerialNumberOffset && desc->SerialNumberOffset < desc->Size) {
        SIZE_T room = desc->Size - desc->SerialNumberOffset;
        SIZE_T n = 0;
        while (disk->serial[n] && n + 1 < room) n++;
        RtlZeroMemory(buf + desc->SerialNumberOffset, room);
        RtlCopyMemory(buf + desc->SerialNumberOffset, disk->serial, n);
    }
    if (desc->ProductIdOffset && desc->ProductIdOffset < desc->Size) {
        SIZE_T room = desc->Size - desc->ProductIdOffset;
        SIZE_T n = 0;
        while (disk->model[n] && n + 1 < room) n++;
        RtlZeroMemory(buf + desc->ProductIdOffset, room);
        RtlCopyMemory(buf + desc->ProductIdOffset, disk->model, n);
    }
}

static VOID PatchInquiryVpd(UCHAR *data, ULONG len, EACSPOOF_DISK *disk)
{
    /* VPD 0x80: serial. Byte 1 = page, 3 = length. */
    if (len < 4) return;
    if (data[1] == 0x80) {
        UCHAR n = 0;
        while (disk->serial[n] && n < 20) n++;
        if ((ULONG)(4 + n) <= len) {
            data[3] = n;
            RtlCopyMemory(data + 4, disk->serial, n);
        }
    }
}

typedef struct _COMPLETION_CTX {
    ULONG diskIndex;
    ULONG ioctl;
    PIO_COMPLETION_ROUTINE oldRoutine;
    PVOID oldContext;
    BOOLEAN oldControl;
} COMPLETION_CTX, *PCOMPLETION_CTX;

static NTSTATUS FilterComplete(PDEVICE_OBJECT dev, PIRP irp, PVOID ctx)
{
    PCOMPLETION_CTX cc = (PCOMPLETION_CTX)ctx;
    EACSPOOF_DISK *disk;
    PIO_STACK_LOCATION sp;
    KIRQL irql;

    UNREFERENCED_PARAMETER(dev);

    if (irp->PendingReturned) IoMarkIrpPending(irp);

    if (!NT_SUCCESS(irp->IoStatus.Status) || !cc) {
        if (cc) ExFreePoolWithTag(cc, FILTER_TAG);
        return STATUS_SUCCESS;
    }

    disk = DiskForIndex(cc->diskIndex);
    if (!disk || !(g_Config.modules & EACSPOOF_MOD_STORAGE)) {
        ExFreePoolWithTag(cc, FILTER_TAG);
        return STATUS_SUCCESS;
    }

    sp = IoGetCurrentIrpStackLocation(irp);

    switch (cc->ioctl) {
    case IOCTL_STORAGE_QUERY_PROPERTY: {
        PSTORAGE_PROPERTY_QUERY q;
        q = (PSTORAGE_PROPERTY_QUERY)irp->AssociatedIrp.SystemBuffer;
        if (q && q->PropertyId == StorageDeviceProperty && irp->IoStatus.Information >= sizeof(STORAGE_DEVICE_DESCRIPTOR)) {
            PatchStorageProperty((PSTORAGE_DEVICE_DESCRIPTOR)irp->AssociatedIrp.SystemBuffer, disk);
            KeAcquireSpinLock(&g_Lock, &irql);
            g_Stats.irpFiltered++;
            KeReleaseSpinLock(&g_Lock, irql);
        }
        break;
    }
    case IOCTL_ATA_PASS_THROUGH:
    case IOCTL_ATA_PASS_THROUGH_DIRECT: {
        ATA_PASS_THROUGH_EX *ata = (ATA_PASS_THROUGH_EX *)irp->AssociatedIrp.SystemBuffer;
        if (ata && ata->DataBufferOffset && irp->IoStatus.Information > ata->DataBufferOffset + 46) {
            UCHAR *ident = (UCHAR *)ata + ata->DataBufferOffset;
            AtaSwapSerial(ident, disk->serial);
            KeAcquireSpinLock(&g_Lock, &irql);
            g_Stats.identifyRewrites++;
            g_Stats.irpFiltered++;
            KeReleaseSpinLock(&g_Lock, irql);
        }
        break;
    }
    case SMART_RCV_DRIVE_DATA: {
        SENDCMDINPARAMS *in = (SENDCMDINPARAMS *)irp->AssociatedIrp.SystemBuffer;
        if (in && irp->IoStatus.Information > sizeof(SENDCMDINPARAMS) + 46) {
            AtaSwapSerial(in->bBuffer, disk->serial);
            KeAcquireSpinLock(&g_Lock, &irql);
            g_Stats.identifyRewrites++;
            KeReleaseSpinLock(&g_Lock, irql);
        }
        break;
    }
    case IOCTL_SCSI_PASS_THROUGH:
    case IOCTL_SCSI_PASS_THROUGH_DIRECT: {
        SCSI_PASS_THROUGH *spt = (SCSI_PASS_THROUGH *)irp->AssociatedIrp.SystemBuffer;
        if (spt && spt->Cdb[0] == SCSIOP_INQUIRY && (spt->Cdb[1] & 1) && irp->IoStatus.Information > spt->DataBufferOffset) {
            UCHAR *vpd = (UCHAR *)spt + spt->DataBufferOffset;
            PatchInquiryVpd(vpd, spt->DataTransferLength, disk);
            KeAcquireSpinLock(&g_Lock, &irql);
            g_Stats.inquiryRewrites++;
            KeReleaseSpinLock(&g_Lock, irql);
        }
        break;
    }
    case IOCTL_DISK_GET_DRIVE_LAYOUT_EX: {
        PDRIVE_LAYOUT_INFORMATION_EX lay = (PDRIVE_LAYOUT_INFORMATION_EX)irp->AssociatedIrp.SystemBuffer;
        if (lay) {
            RtlCopyMemory(&lay->Gpt.DiskId, disk->layoutSignature, sizeof(GUID));
            KeAcquireSpinLock(&g_Lock, &irql);
            g_Stats.irpFiltered++;
            KeReleaseSpinLock(&g_Lock, irql);
        }
        break;
    }
    default:
        break;
    }

    UNREFERENCED_PARAMETER(sp);
    ExFreePoolWithTag(cc, FILTER_TAG);
    return STATUS_SUCCESS;
}

NTSTATUS StorageDispatch(PDEVICE_OBJECT dev, PIRP irp)
{
    PFILTER_EXT ext = (PFILTER_EXT)dev->DeviceExtension;
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(irp);
    ULONG ioctl;
    PCOMPLETION_CTX cc;

    if (!ext || !ext->lower) {
        irp->IoStatus.Status = STATUS_INVALID_DEVICE_STATE;
        IoCompleteRequest(irp, IO_NO_INCREMENT);
        return STATUS_INVALID_DEVICE_STATE;
    }

    if (sp->MajorFunction != IRP_MJ_DEVICE_CONTROL &&
        sp->MajorFunction != IRP_MJ_INTERNAL_DEVICE_CONTROL) {
        IoSkipCurrentIrpStackLocation(irp);
        return IoCallDriver(ext->lower, irp);
    }

    ioctl = sp->Parameters.DeviceIoControl.IoControlCode;
    switch (ioctl) {
    case IOCTL_STORAGE_QUERY_PROPERTY:
    case IOCTL_ATA_PASS_THROUGH:
    case IOCTL_ATA_PASS_THROUGH_DIRECT:
    case SMART_RCV_DRIVE_DATA:
    case IOCTL_SCSI_PASS_THROUGH:
    case IOCTL_SCSI_PASS_THROUGH_DIRECT:
    case IOCTL_DISK_GET_DRIVE_LAYOUT_EX:
    case IOCTL_MOUNTDEV_QUERY_UNIQUE_ID:
        break;
    default:
        IoSkipCurrentIrpStackLocation(irp);
        return IoCallDriver(ext->lower, irp);
    }

    cc = (PCOMPLETION_CTX)ExAllocatePoolWithTag(NonPagedPoolNx, sizeof(*cc), FILTER_TAG);
    if (!cc) {
        IoSkipCurrentIrpStackLocation(irp);
        return IoCallDriver(ext->lower, irp);
    }
    RtlZeroMemory(cc, sizeof(*cc));
    cc->diskIndex = ext->diskIndex;
    cc->ioctl = ioctl;

    IoCopyCurrentIrpStackLocationToNext(irp);
    IoSetCompletionRoutine(irp, FilterComplete, cc, TRUE, TRUE, TRUE);
    return IoCallDriver(ext->lower, irp);
}

NTSTATUS StorageAttachDisk(PDRIVER_OBJECT drv, ULONG index)
{
    WCHAR path[64];
    UNICODE_STRING u;
    PFILE_OBJECT file = NULL;
    PDEVICE_OBJECT target = NULL, filter = NULL, lower = NULL;
    PFILTER_EXT ext;
    NTSTATUS st;

    if (g_FilterCount >= MAX_FILTER_DEV) return STATUS_INSUFFICIENT_RESOURCES;

    RtlStringCbPrintfW(path, sizeof(path), L"\\Device\\Harddisk%u\\DR0", index);
    RtlInitUnicodeString(&u, path);
    st = IoGetDeviceObjectPointer(&u, FILE_READ_ATTRIBUTES, &file, &target);
    if (!NT_SUCCESS(st)) return st;

    st = IoCreateDevice(drv, sizeof(FILTER_EXT), NULL, target->DeviceType,
                        target->Characteristics, FALSE, &filter);
    if (!NT_SUCCESS(st)) {
        ObDereferenceObject(file);
        return st;
    }

    ext = (PFILTER_EXT)filter->DeviceExtension;
    RtlZeroMemory(ext, sizeof(*ext));
    ext->self = filter;
    ext->diskIndex = index;

    lower = IoAttachDeviceToDeviceStack(filter, target);
    if (!lower) {
        IoDeleteDevice(filter);
        ObDereferenceObject(file);
        return STATUS_NO_SUCH_DEVICE;
    }
    ext->lower = lower;
    ext->attached = TRUE;
    filter->Flags |= target->Flags & (DO_BUFFERED_IO | DO_DIRECT_IO | DO_POWER_PAGABLE);
    filter->Flags &= ~DO_DEVICE_INITIALIZING;

    g_FilterDev[g_FilterCount++] = filter;
    ObDereferenceObject(file);
    return STATUS_SUCCESS;
}

NTSTATUS StorageStart(PDRIVER_OBJECT drv)
{
    ULONG i;
    NTSTATUS last = STATUS_NOT_FOUND;
    g_FilterCount = 0;
    for (i = 0; i < EACSPOOF_MAX_DISKS; i++) {
        NTSTATUS st = StorageAttachDisk(drv, i);
        if (NT_SUCCESS(st)) last = st;
    }
    return (g_FilterCount > 0) ? STATUS_SUCCESS : last;
}

VOID StorageStop(VOID)
{
    ULONG i;
    for (i = 0; i < g_FilterCount; i++) {
        PFILTER_EXT ext;
        if (!g_FilterDev[i]) continue;
        ext = (PFILTER_EXT)g_FilterDev[i]->DeviceExtension;
        if (ext && ext->lower) IoDetachDevice(ext->lower);
        IoDeleteDevice(g_FilterDev[i]);
        g_FilterDev[i] = NULL;
    }
    g_FilterCount = 0;
}
