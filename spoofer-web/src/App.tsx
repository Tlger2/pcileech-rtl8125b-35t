import { useCallback, useEffect, useId, useRef, useState, type ReactNode } from "react";
import { DEFAULT_PROFILE, randomizeProfile } from "./defaults";
import { applySequence, downloadText, log as makeLog } from "./sim";
import { SECTION_SUB, SECTION_TITLE, type IdentityProfile, type LogLine, type SectionId } from "./types";

const LS = "hw-identity-lab-v1";

function loadSaved(): IdentityProfile {
  try {
    const raw = localStorage.getItem(LS);
    if (raw) {
      const parsed = JSON.parse(raw) as Partial<IdentityProfile>;
      return {
        ...DEFAULT_PROFILE,
        ...parsed,
        disks: parsed.disks?.length ? parsed.disks : DEFAULT_PROFILE.disks,
        smbios: { ...DEFAULT_PROFILE.smbios, ...parsed.smbios },
        nics: parsed.nics?.length ? parsed.nics : DEFAULT_PROFILE.nics,
      };
    }
  } catch {
    /* keep default */
  }
  return structuredClone(DEFAULT_PROFILE);
}

function mergeProfile(parsed: Partial<IdentityProfile>): IdentityProfile {
  return {
    ...DEFAULT_PROFILE,
    ...parsed,
    disks: parsed.disks?.length ? parsed.disks : DEFAULT_PROFILE.disks,
    smbios: { ...DEFAULT_PROFILE.smbios, ...parsed.smbios },
    nics: parsed.nics?.length ? parsed.nics : DEFAULT_PROFILE.nics,
  };
}

function clock(ts: number) {
  return new Date(ts).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}

type Notice = { kind: "ok" | "err" | "info"; text: string } | null;

export default function App() {
  const [cfg, setCfg] = useState<IdentityProfile>(loadSaved);
  const [applied, setApplied] = useState<IdentityProfile | null>(null);
  const [logs, setLogs] = useState<LogLine[]>([]);
  const [notice, setNotice] = useState<Notice>(null);
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);
  const noticeTimer = useRef<number>(0);

  const disk = cfg.disks[0] ?? DEFAULT_PROFILE.disks[0];
  const nic = cfg.nics[0] ?? DEFAULT_PROFILE.nics[0];

  useEffect(() => {
    localStorage.setItem(LS, JSON.stringify(cfg));
  }, [cfg]);

  useEffect(() => {
    return () => window.clearTimeout(noticeTimer.current);
  }, []);

  const flash = useCallback((kind: NonNullable<Notice>["kind"], text: string) => {
    setNotice({ kind, text });
    window.clearTimeout(noticeTimer.current);
    noticeTimer.current = window.setTimeout(() => setNotice(null), 4200);
  }, []);

  const push = useCallback((lines: LogLine[]) => {
    setLogs((prev) => [...prev, ...lines].slice(-200));
  }, []);

  const setDisk = (patch: Partial<typeof disk>) => {
    setCfg((c) => ({ ...c, disks: [{ ...(c.disks[0] ?? DEFAULT_PROFILE.disks[0]), ...patch }] }));
  };
  const setSmbios = (patch: Partial<IdentityProfile["smbios"]>) => {
    setCfg((c) => ({ ...c, smbios: { ...c.smbios, ...patch } }));
  };
  const setNic = (patch: Partial<typeof nic>) => {
    setCfg((c) => ({ ...c, nics: [{ ...(c.nics[0] ?? DEFAULT_PROFILE.nics[0]), ...patch }] }));
  };

  const dirty = applied !== null && JSON.stringify(applied) !== JSON.stringify(cfg);
  const saved = applied !== null && !dirty;

  const saveProfile = useCallback(() => {
    setApplied(structuredClone(cfg));
    push(applySequence(cfg));
    flash("ok", "Profile saved.");
  }, [cfg, push, flash]);

  const generateIdentity = useCallback(() => {
    const next = randomizeProfile(cfg);
    setCfg(next);
    push([makeLog("sys", "info", "Generated a new identity")]);
    flash("info", "New identity ready. Save it to keep it.");
  }, [cfg, push, flash]);

  const exportCfg = useCallback(() => {
    downloadText("identity-profile.json", JSON.stringify(cfg, null, 2));
    push([makeLog("sys", "info", "Downloaded identity-profile.json")]);
    flash("ok", "Downloaded identity-profile.json.");
  }, [cfg, push, flash]);

  const importCfg = useCallback(
    (file: File) => {
      file.text().then((t) => {
        if (!t.trim()) {
          flash("err", "That file is empty. Choose a saved identity profile.");
          return;
        }
        try {
          const next = mergeProfile(JSON.parse(t) as Partial<IdentityProfile>);
          setCfg(next);
          push([makeLog("sys", "ok", `Imported ${file.name}`)]);
          flash("ok", "Profile imported.");
        } catch {
          flash("err", "That file isn’t a valid identity profile.");
        }
      });
    },
    [push, flash],
  );

  return (
    <div className="page">
      <header className="hero">
        <p className="eyebrow">Hardware identity</p>
        <h1>Hardware Identity Lab</h1>
        <p className="lede">
          Review the disk, computer, and network names stored in this browser. Change a field, then
          save. That’s it.
        </p>

        <div className="actions">
          <button type="button" className="btn ghost" onClick={generateIdentity}>
            Generate new identity
          </button>
          <button type="button" className="btn primary" onClick={saveProfile}>
            {saved ? "Saved" : "Save profile"}
          </button>
        </div>

        <div className="secondary-row">
          <button type="button" className="text-btn" onClick={exportCfg}>
            Export
          </button>
          <button type="button" className="text-btn" onClick={() => fileRef.current?.click()}>
            Import
          </button>
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

        {notice ? (
          <div className={`notice ${notice.kind}`} role={notice.kind === "err" ? "alert" : "status"}>
            {notice.text}
          </div>
        ) : dirty ? (
          <div className="notice info" role="status">
            You have unsaved changes.
          </div>
        ) : (
          <p className="hint">Saved only on this device. Nothing is sent anywhere.</p>
        )}
      </header>

      <section className="cards" aria-label="Identity">
        <Card icon={<DiskIcon />} id="storage">
          <Field
            label="Serial number"
            value={disk.serial}
            placeholder="Add a serial number"
            onChange={(v) => setDisk({ serial: v })}
          />
          <Field
            label="Product name"
            value={disk.model}
            placeholder="Add a product name"
            onChange={(v) => setDisk({ model: v })}
          />
          <Field
            label="Firmware version"
            value={disk.firmware}
            placeholder="Add a firmware version"
            onChange={(v) => setDisk({ firmware: v })}
          />
        </Card>

        <Card icon={<ComputerIcon />} id="smbios">
          <Field
            label="Product name"
            value={cfg.smbios.sysProduct}
            placeholder="Add a product name"
            onChange={(v) => setSmbios({ sysProduct: v })}
          />
          <Field
            label="Serial number"
            value={cfg.smbios.sysSerial}
            placeholder="Add a serial number"
            onChange={(v) => setSmbios({ sysSerial: v })}
          />
          <Field
            label="Board serial number"
            value={cfg.smbios.boardSerial}
            placeholder="Add a board serial number"
            onChange={(v) => setSmbios({ boardSerial: v })}
          />
        </Card>

        <Card icon={<NetworkIcon />} id="network">
          <Field
            label="MAC address"
            value={nic.currentMac}
            placeholder="Add a MAC address"
            onChange={(v) => setNic({ currentMac: v })}
          />
          <Field
            label="IP address"
            value={nic.ipv4}
            placeholder="Add an IP address"
            onChange={(v) => setNic({ ipv4: v })}
          />
          <Field
            label="Adapter name"
            value={nic.adapterName}
            placeholder="Add an adapter name"
            onChange={(v) => setNic({ adapterName: v })}
          />
        </Card>
      </section>

      <details
        className="advanced"
        open={advancedOpen}
        onToggle={(e) => setAdvancedOpen((e.target as HTMLDetailsElement).open)}
      >
        <summary>Advanced</summary>
        <div className="advanced-body">
          <p className="advanced-lede">Extra fields, a copy of the saved file, and a quiet activity list.</p>

          <div className="extra-grid">
            <Field label="Profile name" value={cfg.name} onChange={(v) => setCfg({ ...cfg, name: v })} />
            <label className="field span-2">
              Notes
              <textarea
                value={cfg.notes}
                rows={3}
                placeholder="Optional notes about this profile"
                onChange={(e) => setCfg({ ...cfg, notes: e.target.value })}
              />
            </label>
            <Field
              label="Manufacturer"
              value={cfg.smbios.sysManufacturer}
              onChange={(v) => setSmbios({ sysManufacturer: v })}
            />
            <Field
              label="Motherboard"
              value={cfg.smbios.boardProduct}
              onChange={(v) => setSmbios({ boardProduct: v })}
            />
            <Field
              label="BIOS version"
              value={cfg.smbios.biosVersion}
              onChange={(v) => setSmbios({ biosVersion: v })}
            />
            <Field
              label="Adapter ID"
              value={nic.adapterGuid}
              onChange={(v) => setNic({ adapterGuid: v })}
            />
            <Field
              className="span-2"
              label="Computer ID"
              value={cfg.smbios.sysUuid}
              onChange={(v) => setSmbios({ sysUuid: v })}
            />
          </div>

          <div className="advanced-split">
            <section className="well">
              <h3>Activity</h3>
              {logs.length === 0 ? (
                <p className="empty">Nothing recorded yet. Save or generate an identity to see activity here.</p>
              ) : (
                <ol className="activity">
                  {logs.map((l) => (
                    <li key={l.id} className={l.level}>
                      <time dateTime={new Date(l.ts).toISOString()}>{clock(l.ts)}</time>
                      <span>{l.text}</span>
                    </li>
                  ))}
                </ol>
              )}
            </section>
            <section className="well">
              <div className="well-h">
                <h3>Profile file</h3>
                <button type="button" className="text-btn" onClick={exportCfg}>
                  Download
                </button>
              </div>
              <pre className="json">{JSON.stringify(cfg, null, 2)}</pre>
            </section>
          </div>
        </div>
      </details>
    </div>
  );
}

function Card({ id, icon, children }: { id: SectionId; icon: ReactNode; children: ReactNode }) {
  return (
    <article className="card">
      <div className="card-h">
        <span className="icon" aria-hidden="true">
          {icon}
        </span>
        <div>
          <h2>{SECTION_TITLE[id]}</h2>
          <p>{SECTION_SUB[id]}</p>
        </div>
      </div>
      <div className="fields">{children}</div>
    </article>
  );
}

function Field({
  label,
  value,
  onChange,
  placeholder,
  className,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  className?: string;
}) {
  const id = useId();
  return (
    <label className={className ? `field ${className}` : "field"} htmlFor={id}>
      {label}
      <input
        id={id}
        value={value}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        spellCheck={false}
        autoComplete="off"
      />
    </label>
  );
}

function DiskIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7">
      <ellipse cx="12" cy="6" rx="8" ry="3" />
      <path d="M4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6" />
      <path d="M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3" />
    </svg>
  );
}

function ComputerIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7">
      <rect x="3" y="4" width="18" height="12" rx="2" />
      <path d="M8 20h8M12 16v4" />
    </svg>
  );
}

function NetworkIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7">
      <circle cx="12" cy="12" r="2.2" />
      <path d="M5.2 8.2a9 9 0 0 1 13.6 0M3 12a9 9 0 0 1 18 0M5.2 15.8a9 9 0 0 0 13.6 0" />
    </svg>
  );
}
