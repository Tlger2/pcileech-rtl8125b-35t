import { useEffect, useRef } from "react";
import { paintTerrainCanvas, type Terrain } from "./mapgen";
import {
  basemapUrls,
  isAllowedBasemapSrc,
  visibleMeters,
  worldToScreen,
  type RadarView,
} from "./rustMap";
import { passesFilter } from "./sim";
import type { AppSettings, Entity, WorldSnapshot } from "./types";

interface Props {
  snapshot: WorldSnapshot;
  terrain: Terrain;
  settings: AppSettings;
  view: RadarView;
  dmaSourceUrl?: string;
  onView: (v: RadarView) => void;
  onHover: (e: Entity | null, sx: number, sy: number) => void;
  onClickEntity: (e: Entity) => void;
}

function colorFor(e: Entity, chams: AppSettings["chams"]): string {
  if (e.category === "monument") return "#d8d4c8";
  if (e.category.startsWith("player")) {
    if (chams === "full-pink") return "#ff4fa3";
    if (e.admin) return "#e7c15a";
    if (e.npc) return "#6adf6a";
    if (e.sleeping) return "#c9a0ff";
    return "#e05252";
  }
  switch (e.category) {
    case "ore-sulfur":
      return "#e7d34a";
    case "ore-metal":
      return "#e05252";
    case "ore-stone":
      return "#c8c0a8";
    case "ore-hqm":
      return "#7ec8ff";
    case "hemp":
      return "#4cde6a";
    case "berry":
      return "#e08a3c";
    case "food":
      return "#d9a85c";
    case "vehicle":
    case "sleeping-bag":
      return "#d94cff";
    case "dropped":
    case "loot-military":
      return "#c9b8ff";
    default:
      return "#9ad4c8";
  }
}

function shouldLabel(e: Entity, zoomedOut: boolean, zoomedIn: boolean): boolean {
  if (e.category === "monument") return true;
  if (e.category.startsWith("player")) return true;
  if (zoomedOut) return false;
  if (!zoomedIn) {
    return e.category === "vehicle" || e.category === "helicopter" || e.category === "bradley";
  }
  return (
    e.category === "ore-sulfur" ||
    e.category === "ore-metal" ||
    e.category === "hemp" ||
    e.category === "berry" ||
    e.category === "vehicle" ||
    e.category === "sleeping-bag" ||
    e.category === "dropped" ||
    e.category === "loot-military" ||
    e.category === "base"
  );
}

function drawPlayerArrow(
  ctx: CanvasRenderingContext2D,
  sx: number,
  sy: number,
  yawDeg: number,
  fill: string,
  stroke: string,
  size = 11,
): void {
  const yaw = (yawDeg * Math.PI) / 180;
  ctx.save();
  ctx.translate(sx, sy);
  ctx.rotate(yaw);
  ctx.beginPath();
  ctx.moveTo(0, -size);
  ctx.lineTo(size * 0.62, size * 0.72);
  ctx.lineTo(0, size * 0.28);
  ctx.lineTo(-size * 0.62, size * 0.72);
  ctx.closePath();
  ctx.fillStyle = fill;
  ctx.strokeStyle = stroke;
  ctx.lineWidth = 1.4;
  ctx.fill();
  ctx.stroke();
  ctx.restore();
}

export function RadarCanvas({
  snapshot,
  terrain,
  settings,
  view,
  dmaSourceUrl,
  onView,
  onHover,
  onClickEntity,
}: Props) {
  const ref = useRef<HTMLCanvasElement>(null);
  const viewRef = useRef(view);
  const snapRef = useRef(snapshot);
  const setRef = useRef(settings);
  const dmaUrlRef = useRef(dmaSourceUrl);
  viewRef.current = view;
  snapRef.current = snapshot;
  setRef.current = settings;
  dmaUrlRef.current = dmaSourceUrl;

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    let raf = 0;
    let terrainBmp: HTMLCanvasElement | null = null;
    let terrainKey = "";
    let baseImg: HTMLImageElement | null = null;
    let baseKey = "";

    const ensureTerrain = (s: AppSettings) => {
      const key = `${terrain.seed}:${terrain.size}:${terrain.resolution}:${s.hacks.brightNight}:${s.hacks.brightCaves}`;
      if (terrainBmp && terrainKey === key) return terrainBmp;
      terrainBmp = paintTerrainCanvas(terrain, s.hacks.brightNight, s.hacks.brightCaves);
      terrainKey = key;
      return terrainBmp;
    };

    const ensureBasemap = (snap: WorldSnapshot) => {
      const path = snap.mapImagePath ?? null;
      const source = dmaUrlRef.current;
      const key = `${path ?? ""}|${source ?? ""}`;
      if (key === baseKey) return baseImg;
      baseKey = key;
      baseImg = null;
      if (!path && !snap.dmaConnected) return null;
      const urls = basemapUrls(path, source);
      const img = new Image();
      img.crossOrigin = "anonymous";
      let i = 0;
      const tryNext = () => {
        while (i < urls.length) {
          const next = urls[i++];
          if (!isAllowedBasemapSrc(next)) continue;
          img.src = next;
          return;
        }
      };
      img.onload = () => {
        if (baseKey === key) baseImg = img;
      };
      img.onerror = tryNext;
      tryNext();
      return null;
    };

    const resize = () => {
      const r = canvas.getBoundingClientRect();
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = Math.max(1, Math.floor(r.width * dpr));
      canvas.height = Math.max(1, Math.floor(r.height * dpr));
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    };
    resize();
    const ro = new ResizeObserver(resize);
    ro.observe(canvas);

    const draw = () => {
      const rect = canvas.getBoundingClientRect();
      const w = Math.max(1, rect.width);
      const h = Math.max(1, rect.height);
      const v = viewRef.current;
      const snap = snapRef.current;
      const s = setRef.current;
      ctx.clearRect(0, 0, w, h);
      ctx.fillStyle = s.hacks.brightNight ? "#1a5a72" : "#083044";
      ctx.fillRect(0, 0, w, h);

      const origin = worldToScreen(0, snap.worldSize, v, w, h);
      const corner = worldToScreen(snap.worldSize, 0, v, w, h);
      const dw = corner.sx - origin.sx;
      const dh = corner.sy - origin.sy;
      const bmp = ensureTerrain(s);
      const overlay = ensureBasemap(snap);
      ctx.imageSmoothingEnabled = true;
      ctx.imageSmoothingQuality = "high";
      ctx.drawImage(overlay ?? bmp, origin.sx, origin.sy, dw, dh);

      const visM = visibleMeters(v, w, h);
      const zoomedOut = visM > 1800;
      const zoomedIn = visM < 1100;

      const local = snap.localPlayer;
      if (local) {
        const { sx, sy } = worldToScreen(local.position.x, local.position.z, v, w, h);
        const yaw = (local.yaw * Math.PI) / 180;
        ctx.save();
        ctx.translate(sx, sy);
        ctx.rotate(yaw);
        ctx.beginPath();
        ctx.moveTo(0, 0);
        const reach = Math.max(28, 90 * v.scale);
        ctx.arc(0, 0, reach, -Math.PI / 2 - 0.38, -Math.PI / 2 + 0.38);
        ctx.closePath();
        ctx.fillStyle = "rgba(120, 220, 150, 0.12)";
        ctx.fill();
        ctx.restore();
      }

      const ents = snap.entities.filter((e) => {
        if (e.category === "monument") return true;
        if (e.category.startsWith("player")) {
          if (s.chams === "not-see" && !e.admin) return false;
          if (e.admin && !s.hacks.adminEsp && e.category === "player-admin") return true;
          return true;
        }
        if (zoomedOut) return false;
        return passesFilter(e, s);
      });

      for (const e of ents) {
        const { sx, sy } = worldToScreen(e.position.x, e.position.z, v, w, h);
        if (sx < -40 || sy < -40 || sx > w + 40 || sy > h + 40) continue;
        const col = colorFor(e, s.chams);
        const hidden = e.visible === false;
        ctx.globalAlpha = hidden ? 0.28 : 1;
        ctx.fillStyle = col;
        ctx.strokeStyle = "rgba(0,0,0,.55)";
        ctx.lineWidth = 1;
        if (e.category === "monument") {
          ctx.fillStyle = "rgba(160, 160, 152, 0.95)";
          ctx.fillRect(sx - 5, sy - 5, 10, 10);
          ctx.strokeRect(sx - 5, sy - 5, 10, 10);
        } else if (e.category.startsWith("player")) {
          ctx.beginPath();
          ctx.arc(sx, sy, e.sleeping ? 3.5 : 4.5, 0, Math.PI * 2);
          ctx.fill();
          ctx.stroke();
        } else if (e.category === "vehicle" || e.category === "sleeping-bag") {
          ctx.fillRect(sx - 4, sy - 4, 8, 8);
        } else {
          ctx.beginPath();
          ctx.arc(sx, sy, 3, 0, Math.PI * 2);
          ctx.fill();
        }
        if (!s.classicRadar && shouldLabel(e, zoomedOut, zoomedIn) && !hidden) {
          ctx.font = e.category === "monument" ? "bold 12px Segoe UI, sans-serif" : "11px Segoe UI, sans-serif";
          ctx.lineWidth = 3;
          ctx.strokeStyle = "rgba(0,0,0,.55)";
          ctx.fillStyle = e.category === "monument" ? "#f0ead8" : col;
          ctx.strokeText(e.label, sx + 6, sy - 6);
          ctx.fillText(e.label, sx + 6, sy - 6);
        }
        ctx.globalAlpha = 1;
      }

      if (local) {
        const { sx, sy } = worldToScreen(local.position.x, local.position.z, v, w, h);
        drawPlayerArrow(ctx, sx, sy, local.yaw, "#5dff7a", "#063018", 12);
      }

      raf = requestAnimationFrame(draw);
    };
    draw();
    raf = requestAnimationFrame(draw);
    const interval = window.setInterval(draw, 120);

    const hit = (mx: number, my: number): Entity | null => {
      const rect = canvas.getBoundingClientRect();
      const v = viewRef.current;
      const snap = snapRef.current;
      let best: Entity | null = null;
      let bestD = 14;
      for (const e of snap.entities) {
        const p = worldToScreen(e.position.x, e.position.z, v, rect.width, rect.height);
        const d = Math.hypot(p.sx - mx, p.sy - my);
        if (d < bestD) {
          bestD = d;
          best = e;
        }
      }
      return best;
    };

    let drag: { x: number; z: number; px: number; py: number; pan: boolean } | null = null;
    const down = (ev: PointerEvent) => {
      if (ev.button !== 0) return;
      canvas.setPointerCapture(ev.pointerId);
      drag = {
        x: viewRef.current.x,
        z: viewRef.current.z,
        px: ev.clientX,
        py: ev.clientY,
        pan: setRef.current.hacks.interactiveCamera,
      };
    };
    const move = (ev: PointerEvent) => {
      const rect = canvas.getBoundingClientRect();
      const mx = ev.clientX - rect.left;
      const my = ev.clientY - rect.top;
      if (drag?.pan) {
        const dx = (ev.clientX - drag.px) / viewRef.current.scale;
        const dy = (ev.clientY - drag.py) / viewRef.current.scale;
        onView({ ...viewRef.current, x: drag.x - dx, z: drag.z + dy });
      } else {
        onHover(hit(mx, my), ev.clientX, ev.clientY);
      }
    };
    const up = (ev: PointerEvent) => {
      const rect = canvas.getBoundingClientRect();
      const mx = ev.clientX - rect.left;
      const my = ev.clientY - rect.top;
      if (drag && Math.hypot(ev.clientX - drag.px, ev.clientY - drag.py) < 4) {
        const e = hit(mx, my);
        if (e) onClickEntity(e);
      }
      drag = null;
    };
    const wheel = (ev: WheelEvent) => {
      ev.preventDefault();
      const next = Math.max(0.08, Math.min(2.8, viewRef.current.scale * (ev.deltaY > 0 ? 0.9 : 1.1)));
      onView({ ...viewRef.current, scale: next });
    };
    const leave = () => onHover(null, 0, 0);

    canvas.addEventListener("pointerdown", down);
    canvas.addEventListener("pointermove", move);
    canvas.addEventListener("pointerup", up);
    canvas.addEventListener("wheel", wheel, { passive: false });
    canvas.addEventListener("pointerleave", leave);
    return () => {
      cancelAnimationFrame(raf);
      window.clearInterval(interval);
      ro.disconnect();
      canvas.removeEventListener("pointerdown", down);
      canvas.removeEventListener("pointermove", move);
      canvas.removeEventListener("pointerup", up);
      canvas.removeEventListener("wheel", wheel);
      canvas.removeEventListener("pointerleave", leave);
    };
  }, [onClickEntity, onHover, onView, terrain]);

  return (
    <canvas
      ref={ref}
      data-map="rust"
      data-grid="az"
      style={{ width: "100%", height: "100%", display: "block", touchAction: "none" }}
    />
  );
}

export function EspCanvas({
  snapshot,
  settings,
}: {
  snapshot: WorldSnapshot;
  settings: AppSettings;
}) {
  const ref = useRef<HTMLCanvasElement>(null);
  const snapRef = useRef(snapshot);
  const setRef = useRef(settings);
  snapRef.current = snapshot;
  setRef.current = settings;
  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    let raf = 0;
    const draw = () => {
      const snapshot = snapRef.current;
      const settings = setRef.current;
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      const r = canvas.getBoundingClientRect();
      canvas.width = Math.max(1, Math.floor(r.width * dpr));
      canvas.height = Math.max(1, Math.floor(r.height * dpr));
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      const w = r.width;
      const h = r.height;
      ctx.fillStyle = "#05080a";
      ctx.fillRect(0, 0, w, h);
      const local = snapshot.localPlayer;
      if (!local) {
        raf = requestAnimationFrame(draw);
        return;
      }
      const range = settings.espRange;
      const yaw = (local.yaw * Math.PI) / 180;
      const cx = w / 2;
      const cy = h / 2;
      const scale = Math.min(w, h) / 2 / range;
      ctx.strokeStyle = "#1b2a2a";
      ctx.beginPath();
      ctx.arc(cx, cy, range * scale * 0.7, 0, Math.PI * 2);
      ctx.stroke();
      for (const e of snapshot.entities) {
        if (!e.category.startsWith("player") && e.category !== "vehicle") continue;
        const dx = e.position.x - local.position.x;
        const dz = e.position.z - local.position.z;
        const rx = dx * Math.cos(-yaw) - dz * Math.sin(-yaw);
        const rz = dx * Math.sin(-yaw) + dz * Math.cos(-yaw);
        const sx = cx + rx * scale;
        const sy = cy - rz * scale;
        if (sx < 2 || sy < 2 || sx > w - 2 || sy > h - 2) continue;
        ctx.fillStyle = e.admin ? "#e7c15a" : e.npc ? "#6adf6a" : e.sleeping ? "#c9a0ff" : "#e05252";
        if (settings.chams === "full-pink" && e.category.startsWith("player")) ctx.fillStyle = "#ff4fa3";
        ctx.beginPath();
        ctx.arc(sx, sy, 2.4, 0, Math.PI * 2);
        ctx.fill();
      }
      drawPlayerArrow(ctx, cx, cy, 0, "#5dff7a", "#063018", 7);
      raf = requestAnimationFrame(draw);
    };
    raf = requestAnimationFrame(draw);
    return () => cancelAnimationFrame(raf);
  }, []);
  return <canvas ref={ref} data-esp="readonly" />;
}
