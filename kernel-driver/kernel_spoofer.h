#pragma once

#ifdef _KERNEL_MODE
#include <ntddk.h>
#else
#include <windows.h>
#include <winioctl.h>
#endif

#define EACSPOOF_DEVICE_NAME     L"\\Device\\EacSpoofer"
#define EACSPOOF_SYMLINK_NAME    L"\\DosDevices\\EacSpoofer"
#define EACSPOOF_WIN32_NAME      "\\\\.\\EacSpoofer"
#define EACSPOOF_SERVICE_NAME    L"EacSpoofer"

#define EACSPOOF_TYPE 0x9C40

#define IOCTL_EACSPOOF_GET_STATUS   CTL_CODE(EACSPOOF_TYPE, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_EACSPOOF_SET_CONFIG   CTL_CODE(EACSPOOF_TYPE, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_EACSPOOF_GET_CONFIG   CTL_CODE(EACSPOOF_TYPE, 0x802, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_EACSPOOF_APPLY        CTL_CODE(EACSPOOF_TYPE, 0x803, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_EACSPOOF_MODULE_ON    CTL_CODE(EACSPOOF_TYPE, 0x804, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_EACSPOOF_MODULE_OFF   CTL_CODE(EACSPOOF_TYPE, 0x805, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_EACSPOOF_GET_STATS    CTL_CODE(EACSPOOF_TYPE, 0x806, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_EACSPOOF_RANDOMIZE    CTL_CODE(EACSPOOF_TYPE, 0x807, METHOD_BUFFERED, FILE_ANY_ACCESS)

#define EACSPOOF_MOD_STORAGE  0x00000001u
#define EACSPOOF_MOD_SMBIOS   0x00000002u
#define EACSPOOF_MOD_NETWORK  0x00000004u
#define EACSPOOF_MOD_EAC      0x00000008u
#define EACSPOOF_MOD_ALL      0x0000000Fu

#define EACSPOOF_MAX_DISKS    8
#define EACSPOOF_SERIAL_CCH   32
#define EACSPOOF_MODEL_CCH    48
#define EACSPOOF_MAC_LEN      6
#define EACSPOOF_GUID_CCH     40
#define EACSPOOF_IP_CCH       48

#pragma pack(push, 1)

typedef struct _EACSPOOF_DISK {
    ULONG  diskIndex;
    CHAR   serial[EACSPOOF_SERIAL_CCH];
    CHAR   firmware[16];
    CHAR   model[EACSPOOF_MODEL_CCH];
    UCHAR  layoutSignature[16];
    ULONG  enabled;
} EACSPOOF_DISK;

typedef struct _EACSPOOF_SMBIOS {
    CHAR   biosVendor[32];
    CHAR   biosVersion[32];
    CHAR   biosDate[16];
    CHAR   sysManufacturer[32];
    CHAR   sysProduct[32];
    CHAR   sysSerial[32];
    UCHAR  sysUuid[16];
    CHAR   boardManufacturer[32];
    CHAR   boardProduct[32];
    CHAR   boardSerial[32];
    CHAR   boardAsset[32];
    CHAR   chassisSerial[32];
    CHAR   cpuSerial[32];
} EACSPOOF_SMBIOS;

typedef struct _EACSPOOF_NIC {
    ULONG  ifIndex;
    UCHAR  permanentMac[EACSPOOF_MAC_LEN];
    UCHAR  currentMac[EACSPOOF_MAC_LEN];
    CHAR   adapterGuid[EACSPOOF_GUID_CCH];
    CHAR   pnpInstance[128];
    CHAR   ipv4[EACSPOOF_IP_CCH];
    CHAR   ipv6[EACSPOOF_IP_CCH];
    ULONG  rewriteArp;
    ULONG  rewriteNd;
    ULONG  enabled;
} EACSPOOF_NIC;

typedef struct _EACSPOOF_EACFLAGS {
    ULONG stripObCallbacks;
    ULONG stripRegCallbacks;
    ULONG stripProcNotify;
    ULONG stripThreadNotify;
    ULONG stripImageNotify;
    ULONG hideFromModuleList;
    ULONG spoofIntegrityReads;
    ULONG hideDeviceObject;
} EACSPOOF_EACFLAGS;

typedef struct _EACSPOOF_CONFIG {
    ULONG            modules;
    ULONG            diskCount;
    EACSPOOF_DISK    disks[EACSPOOF_MAX_DISKS];
    EACSPOOF_SMBIOS  smbios;
    ULONG            nicCount;
    EACSPOOF_NIC     nics[4];
    EACSPOOF_EACFLAGS eac;
} EACSPOOF_CONFIG;

typedef struct _EACSPOOF_STATS {
    ULONG loaded;
    ULONG modulesLive;
    ULONG64 irpFiltered;
    ULONG64 identifyRewrites;
    ULONG64 inquiryRewrites;
    ULONG64 smbiosQueries;
    ULONG64 oidIntercepts;
    ULONG64 macRewrites;
    ULONG64 arpRewrites;
    ULONG64 eacImageNotifies;
    ULONG64 callbacksStripped;
    ULONG64 integrityReadsSpliced;
    ULONG64 moduleListHides;
} EACSPOOF_STATS;

typedef struct _EACSPOOF_MODULE_OP {
    ULONG moduleMask;
} EACSPOOF_MODULE_OP;

#pragma pack(pop)
