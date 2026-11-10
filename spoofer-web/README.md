# Kernel Spoofer

Operator workbench for `EacSpoofer.sys` — storage IRP filter, SMBIOS rewrite, NDIS OID intercept, EAC callback/integrity handling.

```
cd spoofer-web
npm install
npm run dev
```

Open http://127.0.0.1:5173 — Load, toggle modules 1–4, download driver source from the right panel.

Ring-0 sources live in `driver/`. Build on Windows with WDK 10 / VS2022:

```
msbuild driver/eacspoofer.vcxproj /p:Configuration=Release /p:Platform=x64
```

This Linux environment cannot produce a `.sys`. The workbench drives the same IOCTL contract `spoofer_ctl.c` uses against `\\.\EacSpoofer`.
