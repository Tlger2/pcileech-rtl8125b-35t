import type { LogLine, ModuleId, SpoofConfig, Stats } from "./types";

let seq = 1;

export function emptyStats(): Stats {
  return {
    loaded: false,
    modules: { storage: false, smbios: false, network: false, eac: false },
    irpFiltered: 0,
    identifyRewrites: 0,
    inquiryRewrites: 0,
    smbiosQueries: 0,
    oidIntercepts: 0,
    macRewrites: 0,
    arpRewrites: 0,
    eacImageNotifies: 0,
    callbacksStripped: 0,
    integrityReadsSpliced: 0,
    moduleListHides: 0,
  };
}

export function log(module: LogLine["module"], level: LogLine["level"], text: string): LogLine {
  return { id: seq++, ts: Date.now(), module, level, text };
}

export function loadSequence(): LogLine[] {
  return [
    log("sys", "info", "IoCreateDevice \\Device\\EacSpoofer FILE_DEVICE_UNKNOWN"),
    log("sys", "ok", "IoCreateSymbolicLink \\DosDevices\\EacSpoofer"),
    log("sys", "ok", "DriverEntry NTSTATUS 0x00000000  IRQL=PASSIVE_LEVEL"),
    log("sys", "info", "control device \\.\\EacSpoofer ready — IOCTL 0x9C40:800-807"),
  ];
}

export function unloadSequence(): LogLine[] {
  return [
    log("sys", "warn", "ApplyModules(0) — tearing down live hooks"),
    log("sys", "info", "IoDeleteSymbolicLink + IoDeleteDevice"),
    log("sys", "ok", "DriverUnload complete"),
  ];
}

export function moduleOn(id: ModuleId, cfg: SpoofConfig): LogLine[] {
  switch (id) {
    case "storage":
      return [
        log("storage", "info", "IoGetDeviceObjectPointer \\Device\\Harddisk0\\DR0"),
        log("storage", "ok", `attached upper filter, disk0 serial → ${cfg.disks[0]?.serial ?? "?"}`),
        log("storage", "info", "filter IRP_MJ_DEVICE_CONTROL: STORAGE_QUERY_PROPERTY, ATA_PASS_THROUGH, SMART_RCV_DRIVE_DATA, SCSI INQUIRY VPD 0x80/0x83, GET_DRIVE_LAYOUT_EX"),
        log("storage", "ok", "completion routine FilterComplete registered"),
      ];
    case "smbios":
      return [
        log("smbios", "info", "MmGetSystemRoutineAddress NtQuerySystemInformation"),
        log("smbios", "ok", "12-byte abs-jmp hook installed, trampoline holds original stub"),
        log("smbios", "info", "RSMB snapshot via trampoline, rewrite Type0/1/2/3/4"),
        log("smbios", "ok", `UUID ${cfg.smbios.sysUuid}  board ${cfg.smbios.boardSerial}`),
      ];
    case "network":
      return [
        log("network", "info", "SystemModuleInformation — ndis.sys base"),
        log("network", "ok", "hook NdisFOidRequest / NdisOidRequest"),
        log("network", "info", `OID_802_3_PERMANENT/CURRENT → ${cfg.nics[0]?.currentMac}`),
        log("network", "info", `OID_GEN_NETWORK_LAYER_ADDRESSES → ${cfg.nics[0]?.ipv4} / ${cfg.nics[0]?.ipv6}`),
        log("network", "ok", `IfGuid ${cfg.nics[0]?.adapterGuid}  ARP=${cfg.nics[0]?.rewriteArp} ND=${cfg.nics[0]?.rewriteNd}`),
      ];
    case "eac":
      return [
        log("eac", "info", "PsSetLoadImageNotifyRoutine ImageNotify"),
        log("eac", "ok", "detour ObRegisterCallbacks, CmRegisterCallbackEx, PsSetCreateProcessNotifyRoutineEx, PsSetCreateThreadNotifyRoutine, PsSetLoadImageNotifyRoutine"),
        log("eac", "ok", "MmCopyMemory splice table armed for patched pages"),
        log("eac", "warn", cfg.eac.hideFromModuleList
          ? "DKOM unlink DriverSection from PsLoadedModuleList"
          : "module list hide off"),
      ];
  }
}

export function moduleOff(id: ModuleId): LogLine[] {
  return [log(id, "warn", `module stop — restore original bytes / detach`)];
}

export function tickStats(s: Stats): Stats {
  const n = { ...s, modules: { ...s.modules } };
  if (n.modules.storage) {
    n.irpFiltered += 1 + ((Math.random() * 3) | 0);
    if (Math.random() < 0.35) n.identifyRewrites += 1;
    if (Math.random() < 0.2) n.inquiryRewrites += 1;
  }
  if (n.modules.smbios && Math.random() < 0.4) n.smbiosQueries += 1;
  if (n.modules.network) {
    n.oidIntercepts += 1 + ((Math.random() * 2) | 0);
    if (Math.random() < 0.5) n.macRewrites += 1;
    if (Math.random() < 0.25) n.arpRewrites += 1;
  }
  if (n.modules.eac) {
    if (Math.random() < 0.12) n.eacImageNotifies += 1;
    if (Math.random() < 0.3) n.callbacksStripped += 1;
    if (Math.random() < 0.22) n.integrityReadsSpliced += 1;
  }
  return n;
}

export function tickLogs(s: Stats, cfg: SpoofConfig): LogLine[] {
  const out: LogLine[] = [];
  if (s.modules.storage && Math.random() < 0.45) {
    out.push(log("storage", "ok", `IRP complete IOCTL_STORAGE_QUERY_PROPERTY serial=${cfg.disks[0]?.serial}`));
  }
  if (s.modules.storage && Math.random() < 0.2) {
    out.push(log("storage", "ok", "ATA IDENTIFY words 10-19 swapped to spoof serial"));
  }
  if (s.modules.smbios && Math.random() < 0.3) {
    out.push(log("smbios", "ok", "NtQuerySystemInformation class=76 RSMB served from rewritten table"));
  }
  if (s.modules.network && Math.random() < 0.35) {
    out.push(log("network", "ok", `OID_802_3_CURRENT_ADDRESS → ${cfg.nics[0]?.currentMac}`));
  }
  if (s.modules.network && Math.random() < 0.18) {
    out.push(log("network", "ok", "ARP who-has src MAC rewritten on NET_BUFFER_LIST"));
  }
  if (s.modules.eac && Math.random() < 0.15) {
    out.push(log("eac", "warn", "EasyAntiCheat_EOS.sys image notify — ObRegisterCallbacks returned STATUS_SUCCESS, cookie=EAC00001 (not registered)"));
  }
  if (s.modules.eac && Math.random() < 0.12) {
    out.push(log("eac", "ok", "MmCopyMemory overlap on hooked ntos page — original prologue spliced into EAC buffer"));
  }
  return out;
}
