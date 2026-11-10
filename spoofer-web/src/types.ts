export type SectionId = "storage" | "smbios" | "network";

export interface DiskIdentity {
  diskIndex: number;
  serial: string;
  firmware: string;
  model: string;
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
}

export interface NicIdentity {
  ifIndex: number;
  adapterName: string;
  currentMac: string;
  adapterGuid: string;
  pnpInstance: string;
  ipv4: string;
  ipv6: string;
}

export interface IdentityProfile {
  name: string;
  notes: string;
  disks: DiskIdentity[];
  smbios: SmbiosIdentity;
  nics: NicIdentity[];
}

export interface Stats {
  session: boolean;
  sections: Record<SectionId, boolean>;
  applies: number;
  randomizes: number;
  imports: number;
  exports: number;
  diskReads: number;
  smbiosReads: number;
  nicQueries: number;
}

export interface LogLine {
  id: number;
  ts: number;
  section: SectionId | "sys";
  level: "info" | "ok" | "warn" | "err";
  text: string;
}

export const SECTION_TITLE: Record<SectionId, string> = {
  storage: "Disk",
  smbios: "Computer",
  network: "Network",
};

export const SECTION_SUB: Record<SectionId, string> = {
  storage: "Serial number and product name of the main disk",
  smbios: "Name and serial number of this computer",
  network: "MAC address and adapter used on the network",
};
