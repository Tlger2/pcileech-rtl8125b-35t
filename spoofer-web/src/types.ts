export type ModuleId = "storage" | "smbios" | "network" | "eac";

export interface DiskIdentity {
  diskIndex: number;
  serial: string;
  firmware: string;
  model: string;
  enabled: boolean;
}

export interface SmbiosIdentity {
  biosVendor: string;
  biosVersion: string;
  biosDate: string;
  sysManufacturer: string;
  sysProduct: string;
  sysSerial: string;
  sysUuid: string;
  boardManufacturer: string;
  boardProduct: string;
  boardSerial: string;
  boardAsset: string;
  chassisSerial: string;
  cpuSerial: string;
}

export interface NicIdentity {
  ifIndex: number;
  permanentMac: string;
  currentMac: string;
  adapterGuid: string;
  pnpInstance: string;
  ipv4: string;
  ipv6: string;
  rewriteArp: boolean;
  rewriteNd: boolean;
  enabled: boolean;
}

export interface EacFlags {
  stripObCallbacks: boolean;
  stripRegCallbacks: boolean;
  stripProcNotify: boolean;
  stripThreadNotify: boolean;
  stripImageNotify: boolean;
  hideFromModuleList: boolean;
  spoofIntegrityReads: boolean;
  hideDeviceObject: boolean;
}

export interface SpoofConfig {
  disks: DiskIdentity[];
  smbios: SmbiosIdentity;
  nics: NicIdentity[];
  eac: EacFlags;
}

export interface Stats {
  loaded: boolean;
  modules: Record<ModuleId, boolean>;
  irpFiltered: number;
  identifyRewrites: number;
  inquiryRewrites: number;
  smbiosQueries: number;
  oidIntercepts: number;
  macRewrites: number;
  arpRewrites: number;
  eacImageNotifies: number;
  callbacksStripped: number;
  integrityReadsSpliced: number;
  moduleListHides: number;
}

export interface LogLine {
  id: number;
  ts: number;
  module: ModuleId | "sys";
  level: "info" | "ok" | "warn" | "err";
  text: string;
}

export const MODULE_MASK: Record<ModuleId, number> = {
  storage: 1,
  smbios: 2,
  network: 4,
  eac: 8,
};

export const MODULE_TITLE: Record<ModuleId, string> = {
  storage: "Storage stack",
  smbios: "SMBIOS / firmware",
  network: "NDIS / network",
  eac: "EAC integrity",
};

export const MODULE_SUB: Record<ModuleId, string> = {
  storage: "IRP filter · IDENTIFY · INQUIRY VPD 80/83 · GPT DiskId",
  smbios: "NtQuerySystemInformation(76) · Type 0–4 rewrite · checksums",
  network: "OID MAC · IfGuid · IPv4/6 · ARP/ND Ethernet rewrite",
  eac: "Ob/Cm/Ps notify strip · MmCopyMemory splice · DKOM unlink",
};
