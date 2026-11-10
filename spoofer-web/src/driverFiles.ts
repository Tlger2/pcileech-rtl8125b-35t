import kernel_spoofer_h from "../driver/kernel_spoofer.h?raw";
import kernel_spoofer_c from "../driver/kernel_spoofer.c?raw";
import hook_h from "../driver/hook.h?raw";
import hook_c from "../driver/hook.c?raw";
import modules_h from "../driver/modules.h?raw";
import storage_c from "../driver/storage_filter.c?raw";
import smbios_c from "../driver/smbios_spoof.c?raw";
import ndis_c from "../driver/ndis_filter.c?raw";
import eac_c from "../driver/eac_integrity.c?raw";
import ctl_c from "../driver/spoofer_ctl.c?raw";
import inf from "../driver/eacspoofer.inf?raw";
import vcxproj from "../driver/eacspoofer.vcxproj?raw";
import readme from "../driver/README.md?raw";

export const DRIVER_FILES: { name: string; body: string }[] = [
  { name: "kernel_spoofer.h", body: kernel_spoofer_h },
  { name: "kernel_spoofer.c", body: kernel_spoofer_c },
  { name: "hook.h", body: hook_h },
  { name: "hook.c", body: hook_c },
  { name: "modules.h", body: modules_h },
  { name: "storage_filter.c", body: storage_c },
  { name: "smbios_spoof.c", body: smbios_c },
  { name: "ndis_filter.c", body: ndis_c },
  { name: "eac_integrity.c", body: eac_c },
  { name: "spoofer_ctl.c", body: ctl_c },
  { name: "eacspoofer.inf", body: inf },
  { name: "eacspoofer.vcxproj", body: vcxproj },
  { name: "README.md", body: readme },
];

export function downloadText(name: string, body: string) {
  const blob = new Blob([body], { type: "text/plain;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  URL.revokeObjectURL(url);
}

export function downloadAll() {
  for (const f of DRIVER_FILES) downloadText(f.name, f.body);
}
