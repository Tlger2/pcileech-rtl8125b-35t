import type { SpoofConfig } from "./types";

export const DEFAULT_CONFIG: SpoofConfig = {
  disks: [
    {
      diskIndex: 0,
      serial: "ZL2C4T9H",
      firmware: "SC16B",
      model: "Samsung SSD 990 PRO 2TB",
      enabled: true,
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
    cpuSerial: "To Be Filled By O.E.M.",
  },
  nics: [
    {
      ifIndex: 12,
      permanentMac: "02:1A:7C:44:91:B3",
      currentMac: "02:1A:7C:44:91:B3",
      adapterGuid: "{8F3A1C2E-7B90-4D11-A6E2-00E04C7A3B91}",
      pnpInstance:
        "PCI\\VEN_10EC&DEV_8125&SUBSYS_012310EC&REV_05\\4&1A2B3C4D&0&00E0",
      ipv4: "192.168.1.104",
      ipv6: "fe80::7a3b:91ff:fe4c:e012",
      rewriteArp: true,
      rewriteNd: true,
      enabled: true,
    },
  ],
  eac: {
    stripObCallbacks: true,
    stripRegCallbacks: true,
    stripProcNotify: true,
    stripThreadNotify: true,
    stripImageNotify: true,
    hideFromModuleList: true,
    spoofIntegrityReads: true,
    hideDeviceObject: false,
  },
};

export function randomHex(n: number): string {
  const a = "0123456789ABCDEF";
  let s = "";
  for (let i = 0; i < n; i++) s += a[(Math.random() * 16) | 0];
  return s;
}

export function randomizeConfig(cfg: SpoofConfig): SpoofConfig {
  const mac = `02:${randomHex(2)}:${randomHex(2)}:${randomHex(2)}:${randomHex(2)}:${randomHex(2)}`;
  const uuid = `${randomHex(8)}-${randomHex(4)}-4${randomHex(3)}-A${randomHex(3)}-${randomHex(12)}`;
  return {
    ...cfg,
    disks: cfg.disks.map((d) => ({
      ...d,
      serial: randomHex(8),
      firmware: `SC${randomHex(2)}B`,
    })),
    smbios: {
      ...cfg.smbios,
      sysSerial: `07D75${randomHex(7)}`,
      sysUuid: uuid,
      boardSerial: `07D75-${randomHex(6)}`,
      chassisSerial: `07D75${randomHex(7)}`,
    },
    nics: cfg.nics.map((n) => ({
      ...n,
      permanentMac: mac,
      currentMac: mac,
      adapterGuid: `{${uuid}}`,
    })),
  };
}
