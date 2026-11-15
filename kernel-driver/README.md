# kernel-driver (local / WDK only)

Windows Driver Kit sources that live in this git repository for local
development. They are **not** part of the hosted Hardware Identity Lab
web app. Cursor `publish-app` uses `project_dir` `spoofer-web/`, which
does not include this folder.

Build on a Windows machine with WDK 10 and Visual Studio 2022. This
Linux environment cannot produce a `.sys` binary.

```
msbuild eacspoofer.vcxproj /p:Configuration=Release /p:Platform=x64
```
