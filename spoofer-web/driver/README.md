# EacSpoofer ring-0 driver

WDM x64 driver: storage IRP filter, SMBIOS `NtQuerySystemInformation` rewrite, NDIS OID intercept, EAC callback strip + integrity-read splice.

## Build (Windows + WDK 10 / VS2022)

```
"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
msbuild eacspoofer.vcxproj /p:Configuration=Release /p:Platform=x64
```

Test-sign:

```
makecert -r -pe -ss PrivateCertStore -n CN=EacSpooferTest EacSpooferTest.cer
signtool sign /s PrivateCertStore /n EacSpooferTest /t http://timestamp.digicert.com eacspoofer.sys
bcdedit /set testsigning on
```

## Load

```
sc create EacSpoofer type= kernel binPath= C:\path\eacspoofer.sys
sc start EacSpoofer
spoofer_ctl.exe status
spoofer_ctl.exe on 15
```

Device: `\\.\EacSpoofer`

## IOCTL map (workbench)

| Panel action | IOCTL | Mask |
|---|---|---|
| Load | `sc start` then GET_STATS | — |
| Unload | `sc stop` | — |
| Storage toggle | MODULE_ON/OFF | `0x1` |
| SMBIOS toggle | MODULE_ON/OFF | `0x2` |
| Network toggle | MODULE_ON/OFF | `0x4` |
| EAC integrity toggle | MODULE_ON/OFF | `0x8` |
| Apply serials/UUID/MAC | SET_CONFIG + APPLY | — |
| Randomize | RANDOMIZE | — |

Usermode: `spoofer_ctl.c` (Win32, not WDK).
