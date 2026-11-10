import { CLEAN_FLAGS, type HwFlags, type IdentityProfile } from "./types";

export const QUOTE = "in the end you are never truly banned";
export const ATTRIBUTION = "Hellon Wong";
export const APP_TITLE = "Identity Lab";

export const DEFAULT_PROFILE: IdentityProfile = {
  name: "My computer",
  notes: "",
  disks: [
    {
      diskIndex: 0,
      serial: "ZL2C4T9H",
      firmware: "SC16B",
      model: "Samsung SSD 990 PRO 2TB",
    },
  ],
  smbios: {
    biosVendor: "American Megatrends Inc.",
    biosVersion: "F.25",
    biosDate: "03/18/2024",
    sysManufacturer: "Micro-Star International Co., Ltd.",
    sysProduct: "MS-7D75",
    sysSerial: "07D7512345678",
    sysUuid: "7A3B91C4-12E0-4C00-A1B2-C3D4E5F60718",
    boardManufacturer: "Micro-Star International Co., Ltd.",
    boardProduct: "PRO Z790-A WIFI (MS-7D75)",
    boardSerial: "07D75-K8G4N2",
    boardAsset: "Default string",
    chassisSerial: "07D7512345678",
  },
  nics: [
    {
      ifIndex: 12,
      adapterName: "Realtek RTL8125B 2.5GbE Controller",
      currentMac: "00:E0:4C:44:91:B3",
      adapterGuid: "{8F3A1C2E-7B90-4D11-A6E2-00E04C7A3B91}",
      pnpInstance: "PCI\\VEN_10EC&DEV_8125&SUBSYS_012310EC&REV_05\\4&1A2B3C4D&0&00E0",
      ipv4: "192.168.1.104",
      ipv6: "fe80::7a3b:91ff:fe4c:e012",
    },
  ],
};

export function randomHex(n: number): string {
  const a = "0123456789ABCDEF";
  let s = "";
  for (let i = 0; i < n; i++) s += a[(Math.random() * 16) | 0];
  return s;
}

export function randomizeProfile(profile: IdentityProfile): IdentityProfile {
  const macTail = `${randomHex(2)}:${randomHex(2)}:${randomHex(2)}`;
  const mac = `00:E0:4C:${macTail}`;
  const uuid = `${randomHex(8)}-${randomHex(4)}-4${randomHex(3)}-A${randomHex(3)}-${randomHex(12)}`;
  return {
    ...profile,
    disks: profile.disks.map((d) => ({
      ...d,
      serial: randomHex(8),
      firmware: `SC${randomHex(2)}B`,
    })),
    smbios: {
      ...profile.smbios,
      sysSerial: `07D75${randomHex(7)}`,
      sysUuid: uuid,
      boardSerial: `07D75-${randomHex(6)}`,
      chassisSerial: `07D75${randomHex(7)}`,
    },
    nics: profile.nics.map((n) => ({
      ...n,
      currentMac: mac,
      adapterGuid: `{${uuid}}`,
      ipv4: `192.168.1.${20 + ((Math.random() * 200) | 0)}`,
    })),
  };
}

export function stockProfile(): IdentityProfile {
  return structuredClone(DEFAULT_PROFILE);
}

export function stockFlags(): HwFlags {
  return { ...CLEAN_FLAGS };
}
