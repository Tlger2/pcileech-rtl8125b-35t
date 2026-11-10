import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { DEFAULT_CONFIG, randomizeConfig } from "./defaults";
import { DRIVER_FILES, downloadAll, downloadText } from "./driverFiles";
import {
  emptyStats,
  loadSequence,
  moduleOff,
  moduleOn,
  tickLogs,
  tickStats,
  unloadSequence,
  log as makeLog,
} from "./sim";
import {
  MODULE_SUB,
  MODULE_TITLE,
  type LogLine,
  type ModuleId,
  type SpoofConfig,
  type Stats,
} from "./types";

const LS = "eac-spoofer-config-v1";
const MODULES: ModuleId[] = ["storage", "smbios", "network", "eac"];

function loadSaved(): SpoofConfig {
  try {
    const raw = localStorage.getItem(LS);
    if (raw) return { ...DEFAULT_CONFIG, ...JSON.parse(raw) } as SpoofConfig;
  } catch {
    /* keep default */
  }
  return structuredClone(DEFAULT_CONFIG);
}

function fmt(ts: number) {
  const d = new Date(ts);
  return d.toLocaleTimeString("en-US", { hour12: false }) + "." + String(d.getMilliseconds()).padStart(3, "0");
}

export default function App() {
  const [cfg, setCfg] = useState<SpoofConfig>(loadSaved);
  const [stats, setStats] = useState<Stats>(emptyStats);
  const [logs, setLogs] = useState<LogLine[]>(() => [
    makeLog("sys", "info", "workbench online — Linux host cannot load .sys; IOCTL path is live in driver source"),
    makeLog("sys", "info", "WDK build: msbuild eacspoofer.vcxproj /p:Configuration=Release /p:Platform=x64"),
  ]);
  const [filter, setFilter] = useState<"all" | ModuleId | "sys">("all");
  const [source, setSource] = useState(DRIVER_FILES[1]?.name ?? "kernel_spoofer.c");
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
      if (!s.loaded) return;
      const next = tickStats(s);
      setStats(next);
      const extra = tickLogs(next, cfgRef.current);
      if (extra.length) push(extra);
    }, 900);
    return () => window.clearInterval(id);
  }, [push]);

  const loadDriver = useCallback(() => {
    setErr(null);
    setStats((s) => ({ ...s, loaded: true }));
    push(loadSequence());
  }, [push]);

  const unloadDriver = useCallback(() => {
    setStats(emptyStats());
    push(unloadSequence());
  }, [push]);

  const toggleModule = useCallback(
    (id: ModuleId) => {
      if (!statsRef.current.loaded) {
        setErr("driver not loaded — Load first");
        push([makeLog("sys", "err", "MODULE_ON rejected: Device \\.\\EacSpoofer not open")]);
        return;
      }
      setErr(null);
      const on = !statsRef.current.modules[id];
      setStats((s) => ({ ...s, modules: { ...s.modules, [id]: on } }));
      push(on ? moduleOn(id, cfgRef.current) : moduleOff(id));
    },
    [push],
  );

  const applyCfg = useCallback(() => {
    if (!stats.loaded) {
      setErr("driver not loaded");
      return;
    }
    push([
      makeLog("sys", "ok", "IOCTL_EACSPOOF_SET_CONFIG + APPLY"),
      makeLog("storage", "info", `disk0 ${cfg.disks[0].model} serial=${cfg.disks[0].serial}`),
      makeLog("smbios", "info", `sys UUID ${cfg.smbios.sysUuid}`),
      makeLog("network", "info", `MAC ${cfg.nics[0].currentMac}  ${cfg.nics[0].ipv4}`),
    ]);
  }, [cfg, stats.loaded, push]);

  const randomize = useCallback(() => {
    const next = randomizeConfig(cfg);
    setCfg(next);
    push([makeLog("sys", "ok", `IOCTL_EACSPOOF_RANDOMIZE serial=${next.disks[0].serial} uuid=${next.smbios.sysUuid}`)]);
  }, [cfg, push]);

  const exportCfg = useCallback(() => {
    downloadText("spoofer-config.json", JSON.stringify(cfg, null, 2));
    push([makeLog("sys", "info", "exported spoofer-config.json")]);
  }, [cfg, push]);

  const importCfg = useCallback((file: File) => {
    file.text().then((t) => {
      try {
        setCfg({ ...DEFAULT_CONFIG, ...JSON.parse(t) });
        push([makeLog("sys", "ok", `imported ${file.name}`)]);
      } catch {
        setErr("config JSON parse failed");
      }
    });
  }, [push]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
      if (e.key === "l" || e.key === "L") loadDriver();
      if (e.key === "u" || e.key === "U") unloadDriver();
      if (e.key === "1") toggleModule("storage");
      if (e.key === "2") toggleModule("smbios");
      if (e.key === "3") toggleModule("network");
      if (e.key === "4") toggleModule("eac");
      if (e.key === "Escape") setFilter("all");
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [loadDriver, unloadDriver, toggleModule]);

  const visibleLogs = useMemo(
    () => (filter === "all" ? logs : logs.filter((l) => l.module === filter)),
    [logs, filter],
  );

  const srcBody = DRIVER_FILES.find((f) => f.name === source)?.body ?? "";
  const liveCount = MODULES.filter((m) => stats.modules[m]).length;

  return (
    <div className="app">
      <header className="top">
        <div className="brand">
          <span className={`led ${stats.loaded ? "on" : ""}`} />
          <div>
            <h1>Kernel Spoofer</h1>
            <p>EacSpoofer.sys · ring-0 · \\.\EacSpoofer · IOCTL 0x9C40</p>
          </div>
        </div>
        <div className="top-actions">
          <button className="btn primary" onClick={loadDriver} disabled={stats.loaded}>
            Load
          </button>
          <button className="btn danger" onClick={unloadDriver} disabled={!stats.loaded}>
            Unload
          </button>
          <button className="btn" onClick={applyCfg}>
            Apply config
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
      {!stats.loaded ? (
        <div className="banner">
          Driver not loaded. This host has no WDK — Load arms the control surface and log. Build eacspoofer.sys on the Windows test box.
        </div>
      ) : null}

      <section className="stats-row">
        <Stat k="IRP filter" v={stats.irpFiltered} />
        <Stat k="IDENTIFY" v={stats.identifyRewrites} />
        <Stat k="INQUIRY" v={stats.inquiryRewrites} />
        <Stat k="SMBIOS Q" v={stats.smbiosQueries} />
        <Stat k="OID" v={stats.oidIntercepts} />
        <Stat k="MAC" v={stats.macRewrites} />
        <Stat k="ARP/ND" v={stats.arpRewrites} />
        <Stat k="EAC notify" v={stats.eacImageNotifies} />
        <Stat k="stripped" v={stats.callbacksStripped} />
        <Stat k="splice" v={stats.integrityReadsSpliced} />
        <Stat k="modules" v={`${liveCount}/4`} />
      </section>

      <div className="grid">
        <ModuleCard
          id="storage"
          live={stats.modules.storage}
          onToggle={() => toggleModule("storage")}
        >
          <Field label="Serial" value={cfg.disks[0].serial} onChange={(v) => setCfg({ ...cfg, disks: [{ ...cfg.disks[0], serial: v }] })} />
          <Field label="Model" value={cfg.disks[0].model} onChange={(v) => setCfg({ ...cfg, disks: [{ ...cfg.disks[0], model: v }] })} />
          <Field label="Firmware" value={cfg.disks[0].firmware} onChange={(v) => setCfg({ ...cfg, disks: [{ ...cfg.disks[0], firmware: v }] })} />
        </ModuleCard>

        <ModuleCard id="smbios" live={stats.modules.smbios} onToggle={() => toggleModule("smbios")}>
          <Field label="UUID" value={cfg.smbios.sysUuid} onChange={(v) => setCfg({ ...cfg, smbios: { ...cfg.smbios, sysUuid: v } })} />
          <Field label="Sys serial" value={cfg.smbios.sysSerial} onChange={(v) => setCfg({ ...cfg, smbios: { ...cfg.smbios, sysSerial: v } })} />
          <Field label="Board serial" value={cfg.smbios.boardSerial} onChange={(v) => setCfg({ ...cfg, smbios: { ...cfg.smbios, boardSerial: v } })} />
          <Field label="BIOS" value={`${cfg.smbios.biosVendor} ${cfg.smbios.biosVersion}`} onChange={(v) => setCfg({ ...cfg, smbios: { ...cfg.smbios, biosVendor: v } })} />
        </ModuleCard>

        <ModuleCard id="network" live={stats.modules.network} onToggle={() => toggleModule("network")}>
          <Field label="MAC" value={cfg.nics[0].currentMac} onChange={(v) => setCfg({ ...cfg, nics: [{ ...cfg.nics[0], currentMac: v, permanentMac: v }] })} />
          <Field label="IfGuid" value={cfg.nics[0].adapterGuid} onChange={(v) => setCfg({ ...cfg, nics: [{ ...cfg.nics[0], adapterGuid: v }] })} />
          <Field label="IPv4" value={cfg.nics[0].ipv4} onChange={(v) => setCfg({ ...cfg, nics: [{ ...cfg.nics[0], ipv4: v }] })} />
          <label className="chk">
            <input type="checkbox" checked={cfg.nics[0].rewriteArp} onChange={(e) => setCfg({ ...cfg, nics: [{ ...cfg.nics[0], rewriteArp: e.target.checked }] })} />
            ARP rewrite
          </label>
          <label className="chk">
            <input type="checkbox" checked={cfg.nics[0].rewriteNd} onChange={(e) => setCfg({ ...cfg, nics: [{ ...cfg.nics[0], rewriteNd: e.target.checked }] })} />
            ND rewrite
          </label>
        </ModuleCard>

        <ModuleCard id="eac" live={stats.modules.eac} onToggle={() => toggleModule("eac")}>
          {(
            [
              ["stripObCallbacks", "Strip ObRegisterCallbacks"],
              ["stripRegCallbacks", "Strip CmRegisterCallbackEx"],
              ["stripProcNotify", "Strip process notify"],
              ["stripThreadNotify", "Strip thread notify"],
              ["stripImageNotify", "Strip image notify"],
              ["hideFromModuleList", "DKOM PsLoadedModuleList"],
              ["spoofIntegrityReads", "Splice MmCopyMemory"],
              ["hideDeviceObject", "Hide device object"],
            ] as const
          ).map(([k, label]) => (
            <label className="chk" key={k}>
              <input
                type="checkbox"
                checked={cfg.eac[k]}
                onChange={(e) => setCfg({ ...cfg, eac: { ...cfg.eac, [k]: e.target.checked } })}
              />
              {label}
            </label>
          ))}
        </ModuleCard>
      </div>

      <div className="bottom">
        <div className="panel log-panel">
          <div className="panel-h">
            <span>Event log</span>
            <div className="filters">
              {(["all", "sys", ...MODULES] as const).map((f) => (
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
                <span className={`m ${l.module}`}>{l.module}</span>
                <span className="x">{l.text}</span>
              </div>
            ))}
            <div ref={logEnd} />
          </div>
        </div>

        <div className="panel src-panel">
          <div className="panel-h">
            <span>Driver source</span>
            <div className="filters">
              <button onClick={() => downloadText(source, srcBody)}>Download</button>
              <button onClick={downloadAll}>Download all</button>
            </div>
          </div>
          <div className="file-tabs">
            {DRIVER_FILES.map((f) => (
              <button key={f.name} className={source === f.name ? "on" : ""} onClick={() => setSource(f.name)}>
                {f.name}
              </button>
            ))}
          </div>
          <pre className="src">{srcBody}</pre>
        </div>
      </div>

      <footer>
        keys 1–4 modules · L load · U unload · Esc reset filter · {DRIVER_FILES.length} source files
      </footer>
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

function ModuleCard({
  id,
  live,
  onToggle,
  children,
}: {
  id: ModuleId;
  live: boolean;
  onToggle: () => void;
  children: ReactNode;
}) {
  return (
    <article className={`panel module ${id} ${live ? "live" : ""}`}>
      <div className="panel-h">
        <div>
          <span className={`led ${live ? "on" : ""}`} />
          <strong>{MODULE_TITLE[id]}</strong>
        </div>
        <button className={`btn sm ${live ? "danger" : "primary"}`} onClick={onToggle}>
          {live ? "Stop" : "Start"}
        </button>
      </div>
      <p className="sub">{MODULE_SUB[id]}</p>
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
