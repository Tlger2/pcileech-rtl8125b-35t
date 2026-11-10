import type { IdentityProfile, LogLine, SectionId, Stats } from "./types";

let seq = 1;

export function emptyStats(): Stats {
  return {
    session: false,
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
    log("sys", "info", `session start — profile "${profile.name}"`),
    log("storage", "info", `disk0 ${profile.disks[0]?.model} serial=${profile.disks[0]?.serial}`),
    log("smbios", "info", `UUID ${profile.smbios.sysUuid}  board ${profile.smbios.boardSerial}`),
    log("network", "info", `${profile.nics[0]?.adapterName}  MAC ${profile.nics[0]?.currentMac}`),
    log("sys", "ok", "identity lab session live — counters armed"),
  ];
}

export function unloadSequence(): LogLine[] {
  return [
    log("sys", "warn", "session stop — counters frozen, editor kept"),
    log("sys", "ok", "identity lab idle"),
  ];
}

export function applySequence(profile: IdentityProfile): LogLine[] {
  return [
    log("sys", "ok", `applied profile "${profile.name}"`),
    log("storage", "ok", `disk0 serial=${profile.disks[0]?.serial}  model=${profile.disks[0]?.model}  fw=${profile.disks[0]?.firmware}`),
    log("smbios", "ok", `sys UUID ${profile.smbios.sysUuid}  serial ${profile.smbios.sysSerial}`),
    log("smbios", "ok", `board ${profile.smbios.boardProduct}  serial ${profile.smbios.boardSerial}`),
    log("network", "ok", `MAC ${profile.nics[0]?.currentMac}  IfGuid ${profile.nics[0]?.adapterGuid}`),
    log("network", "ok", `IPv4 ${profile.nics[0]?.ipv4}  ifIndex ${profile.nics[0]?.ifIndex}`),
  ];
}

export function sectionOn(id: SectionId, profile: IdentityProfile): LogLine[] {
  switch (id) {
    case "storage":
      return [
        log("storage", "ok", `disk monitor on — ${profile.disks[0]?.model}`),
        log("storage", "info", `serial=${profile.disks[0]?.serial} firmware=${profile.disks[0]?.firmware}`),
      ];
    case "smbios":
      return [
        log("smbios", "ok", "SMBIOS monitor on"),
        log("smbios", "info", `UUID ${profile.smbios.sysUuid}  board ${profile.smbios.boardSerial}`),
      ];
    case "network":
      return [
        log("network", "ok", `NIC monitor on — ${profile.nics[0]?.adapterName}`),
        log("network", "info", `MAC ${profile.nics[0]?.currentMac}  ${profile.nics[0]?.ipv4}`),
      ];
  }
}

export function sectionOff(id: SectionId): LogLine[] {
  return [log(id, "warn", "monitor stop")];
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
    out.push(log("storage", "ok", `disk identity read serial=${profile.disks[0]?.serial}`));
  }
  if (s.sections.smbios && Math.random() < 0.28) {
    out.push(log("smbios", "ok", `SMBIOS UUID query → ${profile.smbios.sysUuid}`));
  }
  if (s.sections.network && Math.random() < 0.35) {
    out.push(log("network", "ok", `NIC address query → ${profile.nics[0]?.currentMac}`));
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
