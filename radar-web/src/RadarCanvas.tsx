import { useEffect, useRef } from "react";
import { sampleBiome, type Terrain } from "./mapgen";
import { passesFilter } from "./sim";
import type { AppSettings, Entity, WorldSnapshot } from "./types";

interface View {
  x: number;
  z: number;
  scale: number;
}

interface Props {
  snapshot: WorldSnapshot;
  terrain: Terrain;
  settings: AppSettings;
  view: View;
  onView: (v: View) => void;
  onHover: (e: Entity | null, sx: number, sy: number) => void;
  onClickEntity: (e: Entity) => void;
}

function colorFor(e: Entity, chams: AppSettings["chams"]): string {
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

function shouldLabel(e: Entity, scale: number): boolean {
  if (e.category.startsWith("player")) return true;
  if (scale < 0.18) return false;
  return (
    e.category === "ore-sulfur" ||
    e.category === "ore-metal" ||
    e.category === "hemp" ||
    e.category === "berry" ||
    e.category === "vehicle" ||
    e.category === "sleeping-bag" ||
    e.category === "dropped" ||
    e.category === "loot-military"
  );
}

export function RadarCanvas({
  snapshot,
  terrain,
  settings,
  view,
  onView,
  onHover,
  onClickEntity,
}: Props) {
  const ref = useRef<HTMLCanvasElement>(null);
  const viewRef = useRef(view);
  const snapRef = useRef(snapshot);
  const setRef = useRef(settings);
  viewRef.current = view;
  snapRef.current = snapshot;
  setRef.current = settings;


  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    let raf = 0;

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

    const worldToScreen = (x: number, z: number, v: View, w: number, h: number) => {
      return {
        sx: (x - v.x) * v.scale + w / 2,
        sy: (z - v.z) * v.scale + h / 2,
      };
    };

    const draw = () => {
      const rect = canvas.getBoundingClientRect();
      const w = Math.max(1, rect.width);
      const h = Math.max(1, rect.height);
      const v = viewRef.current;
      const snap = snapRef.current;
      const s = setRef.current;
      ctx.clearRect(0, 0, w, h);
      ctx.fillStyle = s.hacks.brightNight ? "#4a90aa" : "#2d7aa0";
      ctx.fillRect(0, 0, w, h);

      const tile = Math.max(32, 48 / Math.max(0.2, v.scale));
      const worldLeft = v.x - w / 2 / v.scale;
      const worldTop = v.z - h / 2 / v.scale;
      const worldRight = v.x + w / 2 / v.scale;
      const worldBottom = v.z + h / 2 / v.scale;
      const pix = tile * v.scale + 1.25;
      for (let wz = worldTop; wz < worldBottom + tile; wz += tile) {
        for (let wx = worldLeft; wx < worldRight + tile; wx += tile) {
          if (wx < 0 || wz < 0 || wx > snap.worldSize || wz > snap.worldSize) continue;
          const sample = sampleBiome(terrain, wx, wz);
          const fills = [
            "#2d8ab4",
            "#d6c494",
            "#7eb056",
            "#3d7a38",
            "#8a8674",
            "#e4e8e2",
            "#b4a87a",
            "#c4b490",
          ];
          ctx.fillStyle = fills[sample.biome] ?? "#7eb056";
          if (s.hacks.brightNight && sample.biome !== 0) ctx.fillStyle = "#9ec86a";
          const p = worldToScreen(wx, wz, v, w, h);
          ctx.fillRect(p.sx, p.sy, pix, pix);
        }
      }

      const local = snap.localPlayer;
      if (local && s.aim.enabled && s.aim.fov) {
        const { sx, sy } = worldToScreen(local.position.x, local.position.z, v, w, h);
        const yaw = (local.yaw * Math.PI) / 180;
        ctx.save();
        ctx.translate(sx, sy);
        ctx.rotate(yaw);
        ctx.beginPath();
        ctx.moveTo(0, 0);
        const reach = s.aim.fov * 6 * v.scale;
        ctx.arc(0, 0, reach, -0.35, 0.35);
        ctx.closePath();
        ctx.fillStyle = "rgba(80, 220, 200, 0.08)";
        ctx.fill();
        ctx.restore();
      }

      const ents = snap.entities.filter((e) => {
        if (e.category.startsWith("player")) {
          if (s.chams === "not-see" && !e.admin) return false;
          if (e.admin && !s.hacks.adminEsp && e.category === "player-admin") return true;
          return true;
        }
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
        if (e.category.startsWith("player")) {
          ctx.beginPath();
          ctx.arc(sx, sy, e.sleeping ? 3.5 : 4.5, 0, Math.PI * 2);
          ctx.fill();
          ctx.stroke();
          if (!e.sleeping && e.yaw != null) {
            const rad = ((e.yaw ?? 0) * Math.PI) / 180;
            ctx.beginPath();
            ctx.moveTo(sx, sy);
            ctx.lineTo(sx + Math.sin(rad) * 10, sy + Math.cos(rad) * 10);
            ctx.strokeStyle = col;
            ctx.stroke();
          }
        } else if (e.category === "vehicle" || e.category === "sleeping-bag") {
          ctx.fillRect(sx - 4, sy - 4, 8, 8);
        } else {
          ctx.beginPath();
          ctx.arc(sx, sy, 3, 0, Math.PI * 2);
          ctx.fill();
        }
        if (!s.classicRadar && shouldLabel(e, v.scale) && !hidden) {
          ctx.font = "11px Segoe UI, sans-serif";
          ctx.lineWidth = 3;
          ctx.strokeStyle = "rgba(0,0,0,.55)";
          ctx.fillStyle = col;
          ctx.strokeText(e.label, sx + 6, sy - 6);
          ctx.fillText(e.label, sx + 6, sy - 6);
        }
        ctx.globalAlpha = 1;
      }

      if (local) {
        const { sx, sy } = worldToScreen(local.position.x, local.position.z, v, w, h);
        ctx.fillStyle = "#5dff7a";
        ctx.beginPath();
        ctx.arc(sx, sy, 5, 0, Math.PI * 2);
        ctx.fill();
        ctx.strokeStyle = "#062";
        ctx.stroke();
        const rad = (local.yaw * Math.PI) / 180;
        ctx.beginPath();
        ctx.moveTo(sx, sy);
        ctx.lineTo(sx + Math.sin(rad) * 14, sy + Math.cos(rad) * 14);
        ctx.strokeStyle = "#5dff7a";
        ctx.lineWidth = 2;
        ctx.stroke();
      }

      if (snap.aim.world && local) {
        const a = worldToScreen(local.position.x, local.position.z, v, w, h);
        const b = worldToScreen(snap.aim.world.x, snap.aim.world.z, v, w, h);
        ctx.strokeStyle = "rgba(255, 70, 70, 0.85)";
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(a.sx, a.sy);
        ctx.lineTo(b.sx, b.sy);
        ctx.stroke();
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
        const sx = (e.position.x - v.x) * v.scale + rect.width / 2;
        const sy = (e.position.z - v.z) * v.scale + rect.height / 2;
        const d = Math.hypot(sx - mx, sy - my);
        if (d < bestD) {
          bestD = d;
          best = e;
        }
      }
      return best;
    };

    let drag: { x: number; z: number; px: number; py: number } | null = null;
    const down = (ev: PointerEvent) => {
      if (ev.button !== 0) return;
      canvas.setPointerCapture(ev.pointerId);
      drag = { x: viewRef.current.x, z: viewRef.current.z, px: ev.clientX, py: ev.clientY };
    };
    const move = (ev: PointerEvent) => {
      const rect = canvas.getBoundingClientRect();
      const mx = ev.clientX - rect.left;
      const my = ev.clientY - rect.top;
      if (drag) {
        const dx = (ev.clientX - drag.px) / viewRef.current.scale;
        const dz = (ev.clientY - drag.py) / viewRef.current.scale;
        onView({ ...viewRef.current, x: drag.x - dx, z: drag.z - dz });
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
      const next = Math.max(0.08, Math.min(2.4, viewRef.current.scale * (ev.deltaY > 0 ? 0.9 : 1.1)));
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

  return <canvas ref={ref} style={{ width: "100%", height: "100%", display: "block", touchAction: "none" }} />;
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
        const sy = cy + rz * scale;
        if (sx < 2 || sy < 2 || sx > w - 2 || sy > h - 2) continue;
        ctx.fillStyle = e.admin ? "#e7c15a" : e.npc ? "#6adf6a" : e.sleeping ? "#c9a0ff" : "#e05252";
        if (settings.chams === "full-pink" && e.category.startsWith("player")) ctx.fillStyle = "#ff4fa3";
        ctx.beginPath();
        ctx.arc(sx, sy, 2.4, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.fillStyle = "#5dff7a";
      ctx.beginPath();
      ctx.arc(cx, cy, 3, 0, Math.PI * 2);
      ctx.fill();
      raf = requestAnimationFrame(draw);
    };
    raf = requestAnimationFrame(draw);
    return () => cancelAnimationFrame(raf);
  }, []);
  return <canvas ref={ref} />;
}
