import type { IdentityProfile, LogLine, SectionId, Stats } from "./types";

let seq = 1;

export function emptyStats(): Stats {
  return {
    session: true,
    sections: { storage: false, smbios: false, network: false },
    applies: 0,
    randomizes: 0,
    imports: 0,
    exports: 0,
    diskReads: 0,
    smbiosReads: 0,
    nicQueries: 0,
  };
}

export function log(
  section: LogLine["section"],
  level: LogLine["level"],
  text: string,
): LogLine {
  return { id: seq++, ts: Date.now(), section, level, text };
}

export function loadSequence(profile: IdentityProfile): LogLine[] {
  return [
    log("sys", "info", `Opened profile “${profile.name}”`),
    log("storage", "info", `Disk ${profile.disks[0]?.model} · ${profile.disks[0]?.serial}`),
    log("smbios", "info", `Computer ${profile.smbios.sysProduct} · ${profile.smbios.sysSerial}`),
    log("network", "info", `${profile.nics[0]?.adapterName} · ${profile.nics[0]?.currentMac}`),
  ];
}

export function unloadSequence(): LogLine[] {
  return [log("sys", "info", "Session closed. Your edits are still here.")];
}

export function applySequence(profile: IdentityProfile): LogLine[] {
  return [
    log("sys", "ok", `Saved “${profile.name}”`),
    log("storage", "ok", `Disk serial number ${profile.disks[0]?.serial}`),
    log("smbios", "ok", `Computer ${profile.smbios.sysProduct} · ${profile.smbios.sysSerial}`),
    log("network", "ok", `MAC address ${profile.nics[0]?.currentMac}`),
  ];
}

export function sectionOn(id: SectionId, profile: IdentityProfile): LogLine[] {
  switch (id) {
    case "storage":
      return [log("storage", "ok", `Watching disk ${profile.disks[0]?.model}`)];
    case "smbios":
      return [log("smbios", "ok", "Watching computer identity")];
    case "network":
      return [log("network", "ok", `Watching ${profile.nics[0]?.adapterName}`)];
  }
}

export function sectionOff(id: SectionId): LogLine[] {
  return [log(id, "info", "Stopped watching")];
}

export function tickStats(s: Stats): Stats {
  const n = { ...s, sections: { ...s.sections } };
  if (n.sections.storage) n.diskReads += 1 + ((Math.random() * 2) | 0);
  if (n.sections.smbios && Math.random() < 0.55) n.smbiosReads += 1;
  if (n.sections.network) n.nicQueries += 1 + ((Math.random() * 2) | 0);
  return n;
}

export function tickLogs(s: Stats, profile: IdentityProfile): LogLine[] {
  const out: LogLine[] = [];
  if (s.sections.storage && Math.random() < 0.4) {
    out.push(log("storage", "ok", `Read disk serial ${profile.disks[0]?.serial}`));
  }
  if (s.sections.smbios && Math.random() < 0.28) {
    out.push(log("smbios", "ok", `Read computer ID ${profile.smbios.sysUuid}`));
  }
  if (s.sections.network && Math.random() < 0.35) {
    out.push(log("network", "ok", `Read MAC address ${profile.nics[0]?.currentMac}`));
  }
  return out;
}

export function downloadText(name: string, body: string) {
  const blob = new Blob([body], { type: "application/json;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  URL.revokeObjectURL(url);
}
