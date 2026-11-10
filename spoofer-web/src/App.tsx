import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { DEFAULT_PROFILE, randomizeProfile } from "./defaults";
import {
  applySequence,
  downloadText,
  emptyStats,
  loadSequence,
  log as makeLog,
  sectionOff,
  sectionOn,
  tickLogs,
  tickStats,
  unloadSequence,
} from "./sim";
import {
  SECTION_SUB,
  SECTION_TITLE,
  type IdentityProfile,
  type LogLine,
  type SectionId,
  type Stats,
} from "./types";

const LS = "hw-identity-lab-v1";
const SECTIONS: SectionId[] = ["storage", "smbios", "network"];

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

function fmt(ts: number) {
  const d = new Date(ts);
  return d.toLocaleTimeString("en-US", { hour12: false }) + "." + String(d.getMilliseconds()).padStart(3, "0");
}

export default function App() {
  const [cfg, setCfg] = useState<IdentityProfile>(loadSaved);
  const [applied, setApplied] = useState<IdentityProfile | null>(null);
  const [stats, setStats] = useState<Stats>(emptyStats);
  const [logs, setLogs] = useState<LogLine[]>(() => [
    makeLog("sys", "info", "Hardware Identity Lab online"),
    makeLog("sys", "info", "Load a session, edit disk / SMBIOS / NIC fields, then Apply"),
  ]);
  const [filter, setFilter] = useState<"all" | SectionId | "sys">("all");
  const [err, setErr] = useState<string | null>(null);
  const logEnd = useRef<HTMLDivElement>(null);
  const statsRef = useRef(stats);
  const cfgRef = useRef(cfg);
  statsRef.current = stats;
  cfgRef.current = cfg;

  const push = useCallback((lines: LogLine[]) => {
    setLogs((prev) => [...prev, ...lines].slice(-400));
  }, []);

  useEffect(() => {
    localStorage.setItem(LS, JSON.stringify(cfg));
  }, [cfg]);

  useEffect(() => {
    logEnd.current?.scrollIntoView({ block: "end" });
  }, [logs]);

  useEffect(() => {
    const id = window.setInterval(() => {
      const s = statsRef.current;
      if (!s.session) return;
      const next = tickStats(s);
      setStats(next);
      const extra = tickLogs(next, cfgRef.current);
      if (extra.length) push(extra);
    }, 900);
    return () => window.clearInterval(id);
  }, [push]);

  const loadSession = useCallback(() => {
    setErr(null);
    setStats((s) => ({ ...s, session: true }));
    setApplied(structuredClone(cfgRef.current));
    push(loadSequence(cfgRef.current));
  }, [push]);

  const unloadSession = useCallback(() => {
    setStats(emptyStats());
    push(unloadSequence());
  }, [push]);

  const toggleSection = useCallback(
    (id: SectionId) => {
      if (!statsRef.current.session) {
        setErr("session not loaded — Load first");
        push([makeLog("sys", "err", "monitor start rejected: no active session")]);
        return;
      }
      setErr(null);
      const on = !statsRef.current.sections[id];
      setStats((s) => ({ ...s, sections: { ...s.sections, [id]: on } }));
      push(on ? sectionOn(id, cfgRef.current) : sectionOff(id));
    },
    [push],
  );

  const applyCfg = useCallback(() => {
    if (!stats.session) {
      setErr("session not loaded");
      return;
    }
    setErr(null);
    setApplied(structuredClone(cfg));
    setStats((s) => ({ ...s, applies: s.applies + 1 }));
    push(applySequence(cfg));
  }, [cfg, stats.session, push]);

  const randomize = useCallback(() => {
    const next = randomizeProfile(cfg);
    setCfg(next);
    setStats((s) => ({ ...s, randomizes: s.randomizes + 1 }));
    push([
      makeLog(
        "sys",
        "ok",
        `randomized serial=${next.disks[0].serial} uuid=${next.smbios.sysUuid} mac=${next.nics[0].currentMac}`,
      ),
    ]);
  }, [cfg, push]);

  const exportCfg = useCallback(() => {
    downloadText("identity-profile.json", JSON.stringify(cfg, null, 2));
    setStats((s) => ({ ...s, exports: s.exports + 1 }));
    push([makeLog("sys", "info", "exported identity-profile.json")]);
  }, [cfg, push]);

  const importCfg = useCallback(
    (file: File) => {
      file.text().then((t) => {
        try {
          const parsed = JSON.parse(t) as Partial<IdentityProfile>;
          const next: IdentityProfile = {
            ...DEFAULT_PROFILE,
            ...parsed,
            disks: parsed.disks?.length ? parsed.disks : DEFAULT_PROFILE.disks,
            smbios: { ...DEFAULT_PROFILE.smbios, ...parsed.smbios },
            nics: parsed.nics?.length ? parsed.nics : DEFAULT_PROFILE.nics,
          };
          setCfg(next);
          setStats((s) => ({ ...s, imports: s.imports + 1 }));
          push([makeLog("sys", "ok", `imported ${file.name}`)]);
        } catch {
          setErr("profile JSON parse failed");
        }
      });
    },
    [push],
  );

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
      if (e.key === "l" || e.key === "L") loadSession();
      if (e.key === "u" || e.key === "U") unloadSession();
      if (e.key === "1") toggleSection("storage");
      if (e.key === "2") toggleSection("smbios");
      if (e.key === "3") toggleSection("network");
      if (e.key === "Escape") setFilter("all");
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [loadSession, unloadSession, toggleSection]);

  const visibleLogs = useMemo(
    () => (filter === "all" ? logs : logs.filter((l) => l.section === filter)),
    [logs, filter],
  );

  const liveCount = SECTIONS.filter((m) => stats.sections[m]).length;
  const jsonPreview = JSON.stringify(cfg, null, 2);
  const dirty = applied !== null && JSON.stringify(applied) !== JSON.stringify(cfg);

  return (
    <div className="app">
      <header className="top">
        <div className="brand">
          <span className={`led ${stats.session ? "on" : ""}`} />
          <div>
            <h1>Hardware Identity Lab</h1>
            <p>RTL8125B · CaptainDMA · disk / SMBIOS / NIC identity profiles</p>
          </div>
        </div>
        <div className="top-actions">
          <button className="btn primary" onClick={loadSession} disabled={stats.session}>
            Load
          </button>
          <button className="btn danger" onClick={unloadSession} disabled={!stats.session}>
            Unload
          </button>
          <button className="btn" onClick={applyCfg}>
            Apply
          </button>
          <button className="btn" onClick={randomize}>
            Randomize
          </button>
          <button className="btn" onClick={exportCfg}>
            Export JSON
          </button>
          <label className="btn file">
            Import
            <input
              type="file"
              accept="application/json"
              hidden
              onChange={(e) => {
                const f = e.target.files?.[0];
                if (f) importCfg(f);
                e.target.value = "";
              }}
            />
          </label>
        </div>
      </header>

      {err ? <div className="banner err">{err}</div> : null}
      {!stats.session ? (
        <div className="banner">
          Session idle. Load to arm live counters, then Apply to record the current identity profile.
        </div>
      ) : dirty ? (
        <div className="banner warn">Editor differs from last apply — Apply to record the new values.</div>
      ) : null}

      <section className="stats-row">
        <Stat k="Applies" v={stats.applies} />
        <Stat k="Randomize" v={stats.randomizes} />
        <Stat k="Imports" v={stats.imports} />
        <Stat k="Exports" v={stats.exports} />
        <Stat k="Disk reads" v={stats.diskReads} />
        <Stat k="SMBIOS" v={stats.smbiosReads} />
        <Stat k="NIC queries" v={stats.nicQueries} />
        <Stat k="Monitors" v={`${liveCount}/3`} />
      </section>

      <div className="grid">
        <article className="panel module meta">
          <div className="panel-h">
            <div>
              <span className="led on dim" />
              <strong>Profile</strong>
            </div>
            <span className="tag">{cfg.name}</span>
          </div>
          <p className="sub">Named JSON document for this RTL8125B lab identity.</p>
          <div className="fields">
            <Field label="Name" value={cfg.name} onChange={(v) => setCfg({ ...cfg, name: v })} />
            <label className="field">
              Notes
              <textarea value={cfg.notes} onChange={(e) => setCfg({ ...cfg, notes: e.target.value })} rows={3} />
            </label>
          </div>
        </article>

        <SectionCard id="storage" live={stats.sections.storage} onToggle={() => toggleSection("storage")}>
          <Field
            label="Serial"
            value={cfg.disks[0].serial}
            onChange={(v) => setCfg({ ...cfg, disks: [{ ...cfg.disks[0], serial: v }] })}
          />
          <Field
            label="Model"
            value={cfg.disks[0].model}
            onChange={(v) => setCfg({ ...cfg, disks: [{ ...cfg.disks[0], model: v }] })}
          />
          <Field
            label="Firmware"
            value={cfg.disks[0].firmware}
            onChange={(v) => setCfg({ ...cfg, disks: [{ ...cfg.disks[0], firmware: v }] })}
          />
        </SectionCard>

        <SectionCard id="smbios" live={stats.sections.smbios} onToggle={() => toggleSection("smbios")}>
          <Field
            label="UUID"
            value={cfg.smbios.sysUuid}
            onChange={(v) => setCfg({ ...cfg, smbios: { ...cfg.smbios, sysUuid: v } })}
          />
          <Field
            label="Sys serial"
            value={cfg.smbios.sysSerial}
            onChange={(v) => setCfg({ ...cfg, smbios: { ...cfg.smbios, sysSerial: v } })}
          />
          <Field
            label="Board serial"
            value={cfg.smbios.boardSerial}
            onChange={(v) => setCfg({ ...cfg, smbios: { ...cfg.smbios, boardSerial: v } })}
          />
          <Field
            label="Board product"
            value={cfg.smbios.boardProduct}
            onChange={(v) => setCfg({ ...cfg, smbios: { ...cfg.smbios, boardProduct: v } })}
          />
        </SectionCard>

        <SectionCard id="network" live={stats.sections.network} onToggle={() => toggleSection("network")}>
          <Field
            label="MAC"
            value={cfg.nics[0].currentMac}
            onChange={(v) => setCfg({ ...cfg, nics: [{ ...cfg.nics[0], currentMac: v }] })}
          />
          <Field
            label="IfGuid"
            value={cfg.nics[0].adapterGuid}
            onChange={(v) => setCfg({ ...cfg, nics: [{ ...cfg.nics[0], adapterGuid: v }] })}
          />
          <Field
            label="IPv4"
            value={cfg.nics[0].ipv4}
            onChange={(v) => setCfg({ ...cfg, nics: [{ ...cfg.nics[0], ipv4: v }] })}
          />
          <Field
            label="Adapter"
            value={cfg.nics[0].adapterName}
            onChange={(v) => setCfg({ ...cfg, nics: [{ ...cfg.nics[0], adapterName: v }] })}
          />
        </SectionCard>
      </div>

      <div className="bottom">
        <div className="panel log-panel">
          <div className="panel-h">
            <span>Apply / monitor log</span>
            <div className="filters">
              {(["all", "sys", ...SECTIONS] as const).map((f) => (
                <button key={f} className={filter === f ? "on" : ""} onClick={() => setFilter(f)}>
                  {f}
                </button>
              ))}
            </div>
          </div>
          <div className="log" role="log">
            {visibleLogs.length === 0 ? <div className="empty">no events</div> : null}
            {visibleLogs.map((l) => (
              <div key={l.id} className={`line ${l.level}`}>
                <span className="t">{fmt(l.ts)}</span>
                <span className={`m ${l.section}`}>{l.section}</span>
                <span className="x">{l.text}</span>
              </div>
            ))}
            <div ref={logEnd} />
          </div>
        </div>

        <div className="panel src-panel">
          <div className="panel-h">
            <span>Profile JSON</span>
            <div className="filters">
              <button onClick={exportCfg}>Download</button>
            </div>
          </div>
          <pre className="src">{jsonPreview}</pre>
        </div>
      </div>

      <footer>keys 1–3 monitors · L load · U unload · Esc reset filter · JSON stays in the browser</footer>
    </div>
  );
}

function Stat({ k, v }: { k: string; v: number | string }) {
  return (
    <div className="stat">
      <em>{k}</em>
      <strong>{v}</strong>
    </div>
  );
}

function SectionCard({
  id,
  live,
  onToggle,
  children,
}: {
  id: SectionId;
  live: boolean;
  onToggle: () => void;
  children: ReactNode;
}) {
  return (
    <article className={`panel module ${id} ${live ? "live" : ""}`}>
      <div className="panel-h">
        <div>
          <span className={`led ${live ? "on" : ""}`} />
          <strong>{SECTION_TITLE[id]}</strong>
        </div>
        <button className={`btn sm ${live ? "danger" : "primary"}`} onClick={onToggle}>
          {live ? "Stop" : "Start"}
        </button>
      </div>
      <p className="sub">{SECTION_SUB[id]}</p>
      <div className="fields">{children}</div>
    </article>
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
  return (
    <label className="field">
      {label}
      <input value={value} onChange={(e) => onChange(e.target.value)} spellCheck={false} />
    </label>
  );
}
