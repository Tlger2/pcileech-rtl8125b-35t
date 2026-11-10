export type SectionId = "storage" | "smbios" | "network";
export type LineStatus = "Spoofed" | "Clean";

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

export interface HwFlags {
  disk: LineStatus;
  smbios: LineStatus;
  nic: LineStatus;
}

export const CLEAN_FLAGS: HwFlags = {
  disk: "Clean",
  smbios: "Clean",
  nic: "Clean",
};

export const SPOOFED_FLAGS: HwFlags = {
  disk: "Spoofed",
  smbios: "Spoofed",
  nic: "Spoofed",
};
