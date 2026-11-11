#include "kernel_spoofer.h"
#include "modules.h"
#include <ntstrsafe.h>

DRIVER_INITIALIZE DriverEntry;
DRIVER_UNLOAD     DriverUnload;

PDRIVER_OBJECT  g_DriverObject;
PDEVICE_OBJECT  g_ControlDevice;
EACSPOOF_CONFIG g_Config;
EACSPOOF_STATS  g_Stats;
KSPIN_LOCK      g_Lock;

static UNICODE_STRING g_DevName;
static UNICODE_STRING g_SymName;

static VOID SeedDefaultConfig(VOID)
{
    static const UCHAR kUuid[16] = {
        0x7A,0x3B,0x91,0xC4, 0x12,0xE0, 0x4C,0x00,
        0xA1,0xB2,0xC3,0xD4,0xE5,0xF6,0x07,0x18
    };
    RtlZeroMemory(&g_Config, sizeof(g_Config));
    g_Config.modules = 0;
    g_Config.diskCount = 1;
    g_Config.disks[0].diskIndex = 0;
    g_Config.disks[0].enabled = 1;
    RtlCopyMemory(g_Config.disks[0].serial,   "ZL2C4T9H", 8);
    RtlCopyMemory(g_Config.disks[0].firmware, "SC16B", 5);
    RtlCopyMemory(g_Config.disks[0].model,    "Samsung SSD 990 PRO 2TB", 23);

    RtlCopyMemory(g_Config.smbios.biosVendor,        "American Megatrends Inc.", 25);
    RtlCopyMemory(g_Config.smbios.biosVersion,       "F.25", 4);
    RtlCopyMemory(g_Config.smbios.biosDate,          "03/18/2024", 10);
    RtlCopyMemory(g_Config.smbios.sysManufacturer,   "Micro-Star International Co., Ltd.", 34);
    RtlCopyMemory(g_Config.smbios.sysProduct,        "MS-7D75", 7);
    RtlCopyMemory(g_Config.smbios.sysSerial,         "07D7512345678", 13);
    RtlCopyMemory(g_Config.smbios.sysUuid, kUuid, 16);
    RtlCopyMemory(g_Config.smbios.boardManufacturer, "Micro-Star International Co., Ltd.", 34);
    RtlCopyMemory(g_Config.smbios.boardProduct,      "PRO Z790-A WIFI (MS-7D75)", 25);
    RtlCopyMemory(g_Config.smbios.boardSerial,       "07D75-K8G4N2", 12);
    RtlCopyMemory(g_Config.smbios.boardAsset,        "Default string", 14);
    RtlCopyMemory(g_Config.smbios.chassisSerial,     "07D7512345678", 13);
    RtlCopyMemory(g_Config.smbios.cpuSerial,         "To Be Filled By O.E.M.", 22);

    g_Config.nicCount = 1;
    g_Config.nics[0].ifIndex = 12;
    g_Config.nics[0].enabled = 1;
    g_Config.nics[0].rewriteArp = 1;
    g_Config.nics[0].rewriteNd = 1;
    /* Locally administered, unicast: x2 bit set. */
    g_Config.nics[0].permanentMac[0] = 0x02;
    g_Config.nics[0].permanentMac[1] = 0x1A;
    g_Config.nics[0].permanentMac[2] = 0x7C;
    g_Config.nics[0].permanentMac[3] = 0x44;
    g_Config.nics[0].permanentMac[4] = 0x91;
    g_Config.nics[0].permanentMac[5] = 0xB3;
    RtlCopyMemory(g_Config.nics[0].currentMac, g_Config.nics[0].permanentMac, 6);
    RtlCopyMemory(g_Config.nics[0].adapterGuid, "{8F3A1C2E-7B90-4D11-A6E2-00E04C7A3B91}", 38);
    RtlCopyMemory(g_Config.nics[0].pnpInstance, "PCI\\VEN_10EC&DEV_8125&SUBSYS_012310EC&REV_05\\4&1A2B3C4D&0&00E0", 62);
    RtlCopyMemory(g_Config.nics[0].ipv4, "192.168.1.104", 13);
    RtlCopyMemory(g_Config.nics[0].ipv6, "fe80::7a3b:91ff:fe4c:e012", 25);

    g_Config.eac.stripObCallbacks = 1;
    g_Config.eac.stripRegCallbacks = 1;
    g_Config.eac.stripProcNotify = 1;
    g_Config.eac.stripThreadNotify = 1;
    g_Config.eac.stripImageNotify = 1;
    g_Config.eac.hideFromModuleList = 1;
    g_Config.eac.spoofIntegrityReads = 1;
    g_Config.eac.hideDeviceObject = 0;
}

static NTSTATUS ApplyModules(ULONG want)
{
    NTSTATUS st = STATUS_SUCCESS;
    ULONG have = g_Stats.modulesLive;

    if ((want & EACSPOOF_MOD_STORAGE) && !(have & EACSPOOF_MOD_STORAGE)) {
        st = StorageStart(g_DriverObject);
        if (NT_SUCCESS(st)) g_Stats.modulesLive |= EACSPOOF_MOD_STORAGE;
        else return st;
    } else if (!(want & EACSPOOF_MOD_STORAGE) && (have & EACSPOOF_MOD_STORAGE)) {
        StorageStop();
        g_Stats.modulesLive &= ~EACSPOOF_MOD_STORAGE;
    }

    if ((want & EACSPOOF_MOD_SMBIOS) && !(have & EACSPOOF_MOD_SMBIOS)) {
        st = SmbiosStart();
        if (NT_SUCCESS(st)) g_Stats.modulesLive |= EACSPOOF_MOD_SMBIOS;
        else return st;
    } else if (!(want & EACSPOOF_MOD_SMBIOS) && (have & EACSPOOF_MOD_SMBIOS)) {
        SmbiosStop();
        g_Stats.modulesLive &= ~EACSPOOF_MOD_SMBIOS;
    }

    if ((want & EACSPOOF_MOD_NETWORK) && !(have & EACSPOOF_MOD_NETWORK)) {
        st = NetworkStart();
        if (NT_SUCCESS(st)) g_Stats.modulesLive |= EACSPOOF_MOD_NETWORK;
        else return st;
    } else if (!(want & EACSPOOF_MOD_NETWORK) && (have & EACSPOOF_MOD_NETWORK)) {
        NetworkStop();
        g_Stats.modulesLive &= ~EACSPOOF_MOD_NETWORK;
    }

    if ((want & EACSPOOF_MOD_EAC) && !(have & EACSPOOF_MOD_EAC)) {
        st = EacStart();
        if (NT_SUCCESS(st)) g_Stats.modulesLive |= EACSPOOF_MOD_EAC;
        else return st;
    } else if (!(want & EACSPOOF_MOD_EAC) && (have & EACSPOOF_MOD_EAC)) {
        EacStop();
        g_Stats.modulesLive &= ~EACSPOOF_MOD_EAC;
    }

    g_Config.modules = want;
    return STATUS_SUCCESS;
}

static NTSTATUS CopyOut(PIRP irp, PVOID src, ULONG len, ULONG outLen)
{
    if (outLen < len) {
        irp->IoStatus.Status = STATUS_BUFFER_TOO_SMALL;
        irp->IoStatus.Information = 0;
        return STATUS_BUFFER_TOO_SMALL;
    }
    RtlCopyMemory(irp->AssociatedIrp.SystemBuffer, src, len);
    irp->IoStatus.Information = len;
    irp->IoStatus.Status = STATUS_SUCCESS;
    return STATUS_SUCCESS;
}

static NTSTATUS ControlDispatch(PDEVICE_OBJECT dev, PIRP irp)
{
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(irp);
    ULONG code, inLen, outLen;
    NTSTATUS st = STATUS_SUCCESS;
    PVOID buf;

    UNREFERENCED_PARAMETER(dev);
    buf = irp->AssociatedIrp.SystemBuffer;
    inLen = sp->Parameters.DeviceIoControl.InputBufferLength;
    outLen = sp->Parameters.DeviceIoControl.OutputBufferLength;
    code = sp->Parameters.DeviceIoControl.IoControlCode;

    if (sp->MajorFunction != IRP_MJ_DEVICE_CONTROL) {
        irp->IoStatus.Status = STATUS_SUCCESS;
        irp->IoStatus.Information = 0;
        IoCompleteRequest(irp, IO_NO_INCREMENT);
        return STATUS_SUCCESS;
    }

    switch (code) {
    case IOCTL_EACSPOOF_GET_STATUS:
    case IOCTL_EACSPOOF_GET_STATS:
        g_Stats.loaded = 1;
        st = CopyOut(irp, &g_Stats, sizeof(g_Stats), outLen);
        break;
    case IOCTL_EACSPOOF_GET_CONFIG:
        st = CopyOut(irp, &g_Config, sizeof(g_Config), outLen);
        break;
    case IOCTL_EACSPOOF_SET_CONFIG:
        if (inLen < sizeof(EACSPOOF_CONFIG) || !buf) {
            st = STATUS_BUFFER_TOO_SMALL;
            break;
        }
        RtlCopyMemory(&g_Config, buf, sizeof(EACSPOOF_CONFIG));
        irp->IoStatus.Information = 0;
        break;
    case IOCTL_EACSPOOF_APPLY:
        st = ApplyModules(g_Config.modules);
        irp->IoStatus.Information = 0;
        break;
    case IOCTL_EACSPOOF_MODULE_ON:
    case IOCTL_EACSPOOF_MODULE_OFF: {
        EACSPOOF_MODULE_OP *op = (EACSPOOF_MODULE_OP *)buf;
        ULONG want;
        if (inLen < sizeof(*op) || !op) { st = STATUS_BUFFER_TOO_SMALL; break; }
        want = g_Config.modules;
        if (code == IOCTL_EACSPOOF_MODULE_ON) want |= op->moduleMask;
        else want &= ~op->moduleMask;
        st = ApplyModules(want);
        irp->IoStatus.Information = 0;
        break;
    }
    case IOCTL_EACSPOOF_RANDOMIZE:
        SeedDefaultConfig();
        st = CopyOut(irp, &g_Config, sizeof(g_Config), outLen);
        break;
    default:
        st = STATUS_INVALID_DEVICE_REQUEST;
        irp->IoStatus.Information = 0;
        break;
    }

    irp->IoStatus.Status = st;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
    return st;
}

static NTSTATUS DispatchPass(PDEVICE_OBJECT dev, PIRP irp)
{
    if (dev == g_ControlDevice)
        return ControlDispatch(dev, irp);
    return StorageDispatch(dev, irp);
}

VOID DriverUnload(PDRIVER_OBJECT drv)
{
    UNREFERENCED_PARAMETER(drv);
    ApplyModules(0);
    EacOnUnload();
    if (g_SymName.Buffer) IoDeleteSymbolicLink(&g_SymName);
    if (g_ControlDevice) IoDeleteDevice(g_ControlDevice);
    g_ControlDevice = NULL;
    g_Stats.loaded = 0;
}

NTSTATUS DriverEntry(PDRIVER_OBJECT drv, PUNICODE_STRING reg)
{
    NTSTATUS st;
    ULONG i;
    UNREFERENCED_PARAMETER(reg);

    g_DriverObject = drv;
    KeInitializeSpinLock(&g_Lock);
    RtlZeroMemory(&g_Stats, sizeof(g_Stats));
    SeedDefaultConfig();

    RtlInitUnicodeString(&g_DevName, EACSPOOF_DEVICE_NAME);
    RtlInitUnicodeString(&g_SymName, EACSPOOF_SYMLINK_NAME);

    st = IoCreateDevice(drv, 0, &g_DevName, FILE_DEVICE_UNKNOWN, FILE_DEVICE_SECURE_OPEN, FALSE, &g_ControlDevice);
    if (!NT_SUCCESS(st)) return st;

    st = IoCreateSymbolicLink(&g_SymName, &g_DevName);
    if (!NT_SUCCESS(st)) {
        IoDeleteDevice(g_ControlDevice);
        g_ControlDevice = NULL;
        return st;
    }

    for (i = 0; i <= IRP_MJ_MAXIMUM_FUNCTION; i++)
        drv->MajorFunction[i] = DispatchPass;
    drv->DriverUnload = DriverUnload;
    g_ControlDevice->Flags &= ~DO_DEVICE_INITIALIZING;
    g_Stats.loaded = 1;
    return STATUS_SUCCESS;
}
