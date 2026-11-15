import { useCallback, useEffect, useId, useRef, useState, type ReactNode } from "react";
import {
  APP_TITLE,
  ATTRIBUTION,
  QUOTE,
  randomizeProfile,
  stockFlags,
  stockProfile,
} from "./defaults";
import { downloadText } from "./sim";
import {
  CLEAN_FLAGS,
  SPOOFED_FLAGS,
  type HwFlags,
  type IdentityProfile,
  type LineStatus,
  type SectionId,
} from "./types";

const LS = "hw-identity-lab-v1";

type PersistShape = IdentityProfile & { flags?: HwFlags };
type OpenRow = SectionId | "all" | null;

function mergeProfile(parsed: Partial<IdentityProfile>): IdentityProfile {
  const stock = stockProfile();
  return {
    ...stock,
    ...parsed,
    disks: parsed.disks?.length ? parsed.disks : stock.disks,
    smbios: { ...stock.smbios, ...parsed.smbios },
    nics: parsed.nics?.length ? parsed.nics : stock.nics,
  };
}

function loadSaved(): { cfg: IdentityProfile; flags: HwFlags } {
  try {
    const raw = localStorage.getItem(LS);
    if (raw) {
      const parsed = JSON.parse(raw) as PersistShape;
      return {
        cfg: mergeProfile(parsed),
        flags: parsed.flags ?? { ...CLEAN_FLAGS },
      };
    }
  } catch {
    /* keep stock */
  }
  return { cfg: stockProfile(), flags: stockFlags() };
}

export default function App() {
  const initial = loadSaved();
  const [cfg, setCfg] = useState<IdentityProfile>(initial.cfg);
  const [flags, setFlags] = useState<HwFlags>(initial.flags);
  const [openRow, setOpenRow] = useState<OpenRow>(null);
  const [aboutOpen, setAboutOpen] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  const disk = cfg.disks[0] ?? stockProfile().disks[0];
  const nic = cfg.nics[0] ?? stockProfile().nics[0];

  useEffect(() => {
    localStorage.setItem(LS, JSON.stringify({ ...cfg, flags }));
  }, [cfg, flags]);

  const setDisk = (patch: Partial<typeof disk>) => {
    setCfg((c) => ({ ...c, disks: [{ ...(c.disks[0] ?? stockProfile().disks[0]), ...patch }] }));
  };
  const setSmbios = (patch: Partial<IdentityProfile["smbios"]>) => {
    setCfg((c) => ({ ...c, smbios: { ...c.smbios, ...patch } }));
  };
  const setNic = (patch: Partial<typeof nic>) => {
    setCfg((c) => ({ ...c, nics: [{ ...(c.nics[0] ?? stockProfile().nics[0]), ...patch }] }));
  };

  const spoof = useCallback(() => {
    setCfg((c) => randomizeProfile(c));
    setFlags({ ...SPOOFED_FLAGS });
    setOpenRow(null);
  }, []);

  const clean = useCallback(() => {
    setCfg(stockProfile());
    setFlags(stockFlags());
    setOpenRow(null);
  }, []);

  const toggleRow = (id: SectionId) => {
    setOpenRow((cur) => (cur === id || cur === "all" ? null : id));
  };

  const exportCfg = useCallback(() => {
    downloadText("identity-profile.json", JSON.stringify(cfg, null, 2));
  }, [cfg]);

  const importCfg = useCallback((file: File) => {
    file.text().then((t) => {
      if (!t.trim()) return;
      try {
        const parsed = JSON.parse(t) as PersistShape;
        setCfg(mergeProfile(parsed));
        setFlags(parsed.flags ?? { ...SPOOFED_FLAGS });
      } catch {
        /* ignore invalid files */
      }
    });
  }, []);

  const detailsOpen = openRow !== null;

  return (
    <div className="win">
      <header className="chrome" aria-hidden="true">
        <span className="chrome-dot" />
        <span className="chrome-title">{APP_TITLE}</span>
        <span className="chrome-btns">
          <span className="chrome-btn">–</span>
          <span className="chrome-btn">☐</span>
          <span className="chrome-btn">×</span>
        </span>
      </header>

      <main className="stage">
        <section className="hero" aria-label="Quote">
          <div className="pill">
            <p className="quote">
              <span>in the end you are</span>
              <span>never truly banned</span>
            </p>
          </div>
          <p className="attr">— {ATTRIBUTION}</p>
        </section>

        <section className="block" aria-label="License">
          <h2 className="kicker">License status</h2>
          <p className="value">No Expiration</p>
        </section>

        <section className="block" aria-label="Hardware information">
          <div className="kicker-row">
            <h2 className="kicker">Hardware information</h2>
            <button
              type="button"
              className="ghost-link"
              aria-expanded={detailsOpen}
              onClick={() => setOpenRow((cur) => (cur === "all" ? null : "all"))}
            >
              Details
            </button>
          </div>

          <ul className="hw">
            <HwRow
              id="storage"
              label="DiskDrive"
              status={flags.disk}
              open={openRow === "storage" || openRow === "all"}
              onToggle={() => toggleRow("storage")}
            >
              <Field
                label="Serial"
                value={disk.serial}
                onChange={(v) => setDisk({ serial: v })}
              />
            </HwRow>
            <HwRow
              id="smbios"
              label="SMBIOS"
              status={flags.smbios}
              open={openRow === "smbios" || openRow === "all"}
              onToggle={() => toggleRow("smbios")}
            >
              <Field
                label="Board serial"
                value={cfg.smbios.boardSerial}
                onChange={(v) => setSmbios({ boardSerial: v })}
              />
              <Field
                label="UUID"
                value={cfg.smbios.sysUuid}
                onChange={(v) => setSmbios({ sysUuid: v })}
              />
            </HwRow>
            <HwRow
              id="network"
              label="MACAddress"
              status={flags.nic}
              open={openRow === "network" || openRow === "all"}
              onToggle={() => toggleRow("network")}
            >
              <Field
                label="MAC"
                value={nic.currentMac}
                onChange={(v) => setNic({ currentMac: v })}
              />
            </HwRow>
          </ul>
        </section>

        <section className="actions">
          <button type="button" className="cmd" onClick={spoof}>
            HWID SPOOF
          </button>
          <button type="button" className="cmd" onClick={clean}>
            CLEAN
          </button>
        </section>

        <footer className="dock">
          <button
            type="button"
            className="about-btn"
            aria-haspopup="dialog"
            aria-expanded={aboutOpen}
            onClick={() => setAboutOpen(true)}
          >
            About
          </button>
        </footer>
      </main>

      {aboutOpen ? (
        <div
          className="scrim"
          role="presentation"
          onClick={(e) => {
            if (e.target === e.currentTarget) setAboutOpen(false);
          }}
        >
          <div
            className="about"
            role="dialog"
            aria-labelledby="about-title"
            aria-modal="true"
          >
            <p className="about-quote" id="about-title">
              “{QUOTE}”
            </p>
            <p className="about-attr">— {ATTRIBUTION}</p>
            <dl className="about-dl">
              <div>
                <dt>DiskDrive</dt>
                <dd>Serial number of the main disk.</dd>
              </div>
              <div>
                <dt>SMBIOS</dt>
                <dd>Board serial and computer UUID.</dd>
              </div>
              <div>
                <dt>MACAddress</dt>
                <dd>Hardware address of the network adapter.</dd>
              </div>
            </dl>
            <div className="about-row">
              <button type="button" className="ghost-link" onClick={exportCfg}>
                Export
              </button>
              <button
                type="button"
                className="ghost-link"
                onClick={() => fileRef.current?.click()}
              >
                Import
              </button>
              <button type="button" className="ghost-link" onClick={() => setAboutOpen(false)}>
                Close
              </button>
            </div>
          </div>
        </div>
      ) : null}

      <input
        ref={fileRef}
        type="file"
        accept="application/json,.json"
        hidden
        onChange={(e) => {
          const f = e.target.files?.[0];
          if (f) importCfg(f);
          e.target.value = "";
        }}
      />
    </div>
  );
}

function HwRow({
  id,
  label,
  status,
  open,
  onToggle,
  children,
}: {
  id: SectionId;
  label: string;
  status: LineStatus;
  open: boolean;
  onToggle: () => void;
  children: ReactNode;
}) {
  return (
    <li className={open ? "hw-item open" : "hw-item"}>
      <button
        type="button"
        className="hw-line"
        aria-expanded={open}
        aria-controls={`edit-${id}`}
        onClick={onToggle}
      >
        <span className="hw-label">{label}:</span>
        <span className={status === "Spoofed" ? "hw-status spoofed" : "hw-status"}>{status}</span>
      </button>
      {open ? (
        <div className="hw-edit" id={`edit-${id}`}>
          {children}
        </div>
      ) : null}
    </li>
  );
}

function Field({
  label,
  value,
  onChange,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
}) {
  const id = useId();
  return (
    <label className="field" htmlFor={id}>
      {label}
      <input
        id={id}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        spellCheck={false}
        autoComplete="off"
      />
    </label>
  );
}
