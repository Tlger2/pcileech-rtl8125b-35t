import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { EspCanvas, RadarCanvas } from "./RadarCanvas";
import { DEFAULT_DMA_URL, loadDmaSourceUrl, probeDma, pullSnapshot, saveDmaSourceUrl } from "./dma";
import { HELP } from "./help";
import { joinFormatView, stageSize } from "./rustMap";
import { loadSettings, saveSettings, WorldSim } from "./sim";
import type {
  AppSettings,
  ChamsMode,
  Entity,
  LootFilterKey,
  WorldSnapshot,
} from "./types";

const FILTERS: { key: LootFilterKey; label: string; color: string }[] = [
  { key: "collectibles", label: "Collectibles", color: "#3dcdc0" },
  { key: "ores", label: "Ores", color: "#e05252" },
  { key: "food", label: "Food", color: "#d9a85c" },
  { key: "hemp", label: "Hemp", color: "#4cde6a" },
  { key: "berries", label: "Berries", color: "#e08a3c" },
  { key: "loot", label: "Loot Container", color: "#3dcdc0" },
  { key: "base", label: "Base", color: "#8eb0b0" },
  { key: "misc", label: "Misc", color: "#c8c0a8" },
  { key: "animals", label: "Animals", color: "#6adf6a" },
  { key: "vehicle", label: "Vehicle", color: "#d94cff" },
];

function formatJoin(world: WorldSnapshot) {
  const local = world.localPlayer;
  if (!local) return null;
  const { w, h } = stageSize();
  return joinFormatView(local.position, w, h);
}

export function App() {
  const simRef = useRef(new WorldSim(1337, 4000));
  const [settings, setSettings] = useState<AppSettings>(() => loadSettings());
  const settingsRef = useRef(settings);
  settingsRef.current = settings;
  const [snap, setSnap] = useState<WorldSnapshot>(() =>
    simRef.current.tick(0, loadSettings()),
  );
  const [fps, setFps] = useState(60);
  const [help, setHelp] = useState<string | null>(null);
  const [hover, setHover] = useState<{ e: Entity; x: number; y: number } | null>(null);
  const [view, setView] = useState(() => {
    const local = simRef.current.local.position;
    return joinFormatView(local);
  });
  const [mapRev, setMapRev] = useState(0);
  const [dmaMsg, setDmaMsg] = useState("SIM world");
  const [dmaUrl, setDmaUrl] = useState(() => loadDmaSourceUrl());
  const dmaUrlRef = useRef(dmaUrl);
  dmaUrlRef.current = dmaUrl;
  const joinRef = useRef({
    didSimStart: false,
    hadLiveLocal: false,
    worldSize: simRef.current.size,
  });

  const applyJoinFormat = useCallback((world: WorldSnapshot) => {
    const next = formatJoin(world);
    if (next) setView(next);
  }, []);

  useEffect(() => saveSettings(settings), [settings]);
  useEffect(() => saveDmaSourceUrl(dmaUrl), [dmaUrl]);

  useEffect(() => {
    const world = simRef.current.tick(0, settingsRef.current);
    applyJoinFormat(world);
    joinRef.current.didSimStart = true;
    joinRef.current.worldSize = world.worldSize;
  }, [applyJoinFormat]);

  useEffect(() => {
    let frames = 0;
    let lastHud = performance.now();
    let last = performance.now();
    const pulse = () => {
      const now = performance.now();
      const dt = Math.min(0.08, (now - last) / 1000);
      last = now;
      const world = simRef.current.tick(dt, settingsRef.current);
      frames += 1;
      if (now - lastHud > 50) {
        const hz = Math.max(1, Math.round((frames * 1000) / (now - lastHud)));
        frames = 0;
        lastHud = now;
        setFps(hz);
        setSnap({ ...world, fps: hz });
        const s = settingsRef.current;
        if (!s.hacks.interactiveCamera && world.localPlayer) {
          setView((v) => ({
            ...v,
            x: world.localPlayer!.position.x,
            z: world.localPlayer!.position.z,
          }));
        }
      }
    };
    pulse();
    const id = window.setInterval(pulse, 50);
    return () => window.clearInterval(id);
  }, []);

  useEffect(() => {
    if (!snap.dmaConnected) return;
    const id = window.setInterval(() => {
      void (async () => {
        const raw = await pullSnapshot(dmaUrlRef.current);
        if (!raw) return;
        const result = simRef.current.ingestSnapshot(raw);
        const world = simRef.current.tick(0, settingsRef.current);
        if (result.sizeChanged) setMapRev((n) => n + 1);
        if (result.spawnedLocal || result.sizeChanged) applyJoinFormat(world);
        joinRef.current.hadLiveLocal = world.liveLocal;
        joinRef.current.worldSize = world.worldSize;
      })();
    }, 400);
    return () => window.clearInterval(id);
  }, [snap.dmaConnected, applyJoinFormat]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        setHelp(null);
        setSettings((s) => ({ ...s, showMenu: false }));
      }
      if (e.key === "Insert" || e.key === "F1") {
        e.preventDefault();
        setSettings((s) => ({ ...s, showMenu: !s.showMenu }));
      }
      if (e.key === "F2") setSettings((s) => ({ ...s, showLoot: !s.showLoot }));
      if (e.key === "F3") setSettings((s) => ({ ...s, showEsp: !s.showEsp }));
      if (e.key === "F4") setSettings((s) => ({ ...s, classicRadar: !s.classicRadar }));
      if (e.key === "f" || e.key === "F") {
        const p = simRef.current.local.position;
        setView((v) => ({ ...v, x: p.x, z: p.z }));
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const connectDma = async (on: boolean) => {
    if (!on) {
      simRef.current.dmaConnected = false;
      simRef.current.provider = "sim";
      simRef.current.liveLocal = true;
      joinRef.current.hadLiveLocal = false;
      setDmaMsg("SIM world");
      return;
    }
    const st = await probeDma(dmaUrlRef.current);
    simRef.current.dmaConnected = st.connected;
    simRef.current.provider = st.provider;
    setDmaMsg(st.connected ? `LIVE ${st.provider}` : st.detail);
    if (st.connected) {
      const raw = await pullSnapshot(dmaUrlRef.current);
      if (raw) {
        const result = simRef.current.ingestSnapshot(raw);
        const world = simRef.current.tick(0, settingsRef.current);
        if (result.sizeChanged) setMapRev((n) => n + 1);
        if (world.liveLocal || result.sizeChanged) applyJoinFormat(world);
        joinRef.current.hadLiveLocal = world.liveLocal;
        joinRef.current.worldSize = world.worldSize;
      }
    }
  };

  const reloadRadar = async () => {
    if (simRef.current.dmaConnected) {
      const raw = await pullSnapshot(dmaUrlRef.current);
      if (raw) {
        const result = simRef.current.ingestSnapshot(raw);
        const world = simRef.current.tick(0, settingsRef.current);
        if (result.sizeChanged) setMapRev((n) => n + 1);
        applyJoinFormat(world);
        joinRef.current.hadLiveLocal = world.liveLocal;
        joinRef.current.worldSize = world.worldSize;
      }
    } else {
      simRef.current.reloadMap(simRef.current.seed);
      setMapRev((n) => n + 1);
      applyJoinFormat(simRef.current.tick(0, settingsRef.current));
    }
  };

  const patch = useCallback((fn: (s: AppSettings) => AppSettings) => {
    setSettings((s) => fn(s));
  }, []);

  const onHover = useCallback((e: Entity | null, x: number, y: number) => {
    setHover(e ? { e, x, y } : null);
  }, []);
  const onClickEntity = useCallback((e: Entity) => {
    setHelp(`${e.label}  ${e.category}${e.held ? `  held ${e.held}` : ""}${e.health != null ? `  hp ${e.health.toFixed(0)}` : ""}`);
  }, []);

  const counts = useMemo(() => {
    const ents = snap.entities;
    const humans = ents.filter((e) => e.category === "player").length;
    const sleeping = ents.filter((e) => e.category === "player-sleeping").length;
    const npcs = ents.filter((e) => e.category === "player-npc").length;
    const admins = ents.filter((e) => e.admin || e.category === "player-admin").length;
    return { humans, sleeping, npcs, admins, total: humans + sleeping + npcs, entities: ents.length };
  }, [snap.entities]);

  const classic = settings.classicRadar;
  const sim = simRef.current;

  return (
    <div className="app">
      <header className="titlebar">
        <div className="brand">
          <b>Never Banned - Rust</b>
          <span className="quote-row">
            <span className="quote">“in the end you are never truly banned”</span>
            <span className="byline">— Hellon Wong</span>
          </span>
        </div>
        <span className="fps">
          {fps.toFixed(1)} FPS {snap.frameMs.toFixed(1)}ms
        </span>
        <span className={`badge ${snap.dmaConnected ? "live" : "sim"}`}>
          {snap.dmaConnected ? "DMA" : "SIM"}
        </span>
        <span className="spacer" />
        <div className="icons">
          <button className={settings.showLoot ? "active" : ""} title="Loot filter (F2)" onClick={() => patch((s) => ({ ...s, showLoot: !s.showLoot }))}>▣</button>
          <button className={settings.showEsp ? "active" : ""} title="ESP (F3)" onClick={() => patch((s) => ({ ...s, showEsp: !s.showEsp }))}>◎</button>
          <button className={classic ? "active" : ""} title="Classic radar (F4)" onClick={() => patch((s) => ({ ...s, classicRadar: !s.classicRadar }))}>⌖</button>
          <button className={settings.showMenu ? "active" : ""} title="Menu (Insert)" onClick={() => patch((s) => ({ ...s, showMenu: !s.showMenu }))}>☰</button>
        </div>
      </header>

      <div
        className="stage"
        data-map="rust"
        data-world-size={snap.worldSize}
        data-view-scale={view.scale.toFixed(3)}
        data-view-x={view.x.toFixed(0)}
        data-view-z={view.z.toFixed(0)}
      >
        <RadarCanvas
          key={mapRev}
          snapshot={snap}
          terrain={sim.terrain}
          settings={settings}
          view={view}
          dmaSourceUrl={dmaUrl}
          onView={setView}
          onHover={onHover}
          onClickEntity={onClickEntity}
        />

        <div className="hud">
          {settings.showStats && !classic && (
            <aside className="stats">
              <div>Networkables: {snap.networkables.toFixed(1)}ms</div>
              <div>Players: {(counts.humans + counts.sleeping).toFixed(1)}ms</div>
              <div>Entities: {snap.frameMs.toFixed(1)}ms</div>
              <div>Aimbot: 0.00ms</div>
              <br />
              <div>
                Human: {counts.humans}, Sleeping: {counts.sleeping}, Npcs: {counts.npcs}
              </div>
              <div>
                Admins: {counts.admins}, Total: {counts.total}
              </div>
              <div>Networkables: {snap.networkables}</div>
              <div>Entities: {counts.entities}</div>
              <div className="hot">Map seed: {snap.seed}</div>
              <div>Map size: {snap.worldSize}</div>
            </aside>
          )}

          {settings.showLoot && !classic && (
            <section className="panel loot">
              <h3>
                Loot Filter
                <button className="x" onClick={() => patch((s) => ({ ...s, showLoot: false }))}>✕</button>
              </h3>
              <div className="loot-grid">
                {FILTERS.map((f) => (
                  <button
                    key={f.key}
                    className={`pill ${settings.loot[f.key] ? "on" : ""}`}
                    onClick={() =>
                      patch((s) => ({ ...s, loot: { ...s.loot, [f.key]: !s.loot[f.key] } }))
                    }
                  >
                    <span className="swatch" style={{ background: f.color }} />
                    {f.label}
                    <span className="eye">{settings.loot[f.key] ? "◉" : "○"}</span>
                  </button>
                ))}
              </div>
            </section>
          )}

          {settings.showEsp && (
            <section className={`panel esp ${classic ? "classic" : ""}`}>
              <h3>
                Esp Widget
                <button className="x" onClick={() => patch((s) => ({ ...s, showEsp: false }))}>✕</button>
              </h3>
              <div className="esp-body">
                <EspCanvas snapshot={snap} settings={settings} />
                <div className="esp-dist">{snap.nearestDistance ? snap.nearestDistance.toFixed(0) : "—"}</div>
              </div>
            </section>
          )}

          {settings.showMenu && !classic && (
            <section className="panel menu">
              <h3>
                Main Menu
                <button className="x" onClick={() => patch((s) => ({ ...s, showMenu: false }))}>✕</button>
              </h3>

              <div className="block">
                <div className="lbl">
                  DMA Connection
                  <span className={`badge ${snap.dmaConnected ? "live" : "sim"}`}>{dmaMsg}</span>
                </div>
                <label className="url-lbl" htmlFor="dma-url">
                  DMA source
                </label>
                <input
                  id="dma-url"
                  className="url-input"
                  type="url"
                  spellCheck={false}
                  autoComplete="off"
                  placeholder={DEFAULT_DMA_URL}
                  value={dmaUrl}
                  onChange={(e) => setDmaUrl(e.target.value)}
                  onBlur={() => setDmaUrl((u) => u.trim() || DEFAULT_DMA_URL)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") {
                      e.preventDefault();
                      void connectDma(true);
                    }
                  }}
                />
                <div className="row">
                  <button className="btn green" onClick={() => void connectDma(!snap.dmaConnected)}>
                    {snap.dmaConnected ? "Disconnect DMA" : "Connect DMA"}
                  </button>
                  <button className="btn teal" onClick={() => void reloadRadar()}>Reload Radar</button>
                </div>
              </div>

              <div className="block">
                <div className="lbl">
                  Map Control <button className="readme" onClick={() => setHelp(HELP.map)}>(Read me)</button>
                </div>
                <button
                  className="btn ghost"
                  onClick={() => {
                    simRef.current.reloadMap(simRef.current.seed);
                    setMapRev((n) => n + 1);
                    applyJoinFormat(simRef.current.tick(0, settingsRef.current));
                  }}
                >
                  Reload Map
                </button>
              </div>

              <div className="block">
                <div className="lbl">
                  Chams <button className="readme" onClick={() => setHelp(HELP.chams)}>(Read me)</button>
                </div>
                <select
                  className="select"
                  value={settings.chams}
                  onChange={(e) => patch((s) => ({ ...s, chams: e.target.value as ChamsMode }))}
                >
                  <option value="default">Default</option>
                  <option value="full-pink">Full Pink</option>
                  <option value="not-see">Not see</option>
                </select>
              </div>

              <div className="block hack-list">
                <div className="lbl">Hack Functions ** Risky **</div>
                {(
                  [
                    ["visCheckChams", "Enable Visibility Check Chams", "vis"],
                    ["adminEsp", "Admin Esp", "adminEsp"],
                    ["interactiveCamera", "Interactive camera", "camera"],
                    ["brightNight", "Bright Night", "night"],
                    ["brightCaves", "Bright Caves", "caves"],
                  ] as const
                ).map(([key, label, helpKey]) => (
                  <label className="check" key={key}>
                    <span>
                      <input
                        type="checkbox"
                        checked={settings.hacks[key]}
                        onChange={(e) =>
                          patch((s) => ({ ...s, hacks: { ...s.hacks, [key]: e.target.checked } }))
                        }
                      />
                      {label}
                    </span>
                    <button className="readme" onClick={() => setHelp(HELP[helpKey])} type="button">
                      (Read me)
                    </button>
                  </label>
                ))}
              </div>
            </section>
          )}

          {hover && (
            <div className="panel inspect" style={{ left: hover.x + 12, top: hover.y + 12 }}>
              <b>{hover.e.label}</b>
              <div>{hover.e.category}</div>
              {hover.e.health != null && <div>HP {hover.e.health.toFixed(0)}</div>}
              {hover.e.held && <div>{hover.e.held}</div>}
            </div>
          )}

          {help && (
            <div className="panel help">
              <h3>
                Read me
                <button className="x" onClick={() => setHelp(null)}>✕</button>
              </h3>
              <p>{help}</p>
            </div>
          )}

          <div className="hint">Insert menu · F2 loot · F3 ESP · F4 classic radar · F follow · drag/wheel map</div>
        </div>
      </div>
    </div>
  );
}
