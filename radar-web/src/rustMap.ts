import { clamp } from "./rng";

export const GRID_COLUMNS = 26;
/** Visible world span (meters) when opening the G-map / joining a server. */
export const JOIN_VIEW_METERS = 750;

export interface RadarView {
  x: number;
  z: number;
  scale: number;
}

export function gridCellSize(worldSize: number): number {
  return worldSize / GRID_COLUMNS;
}

/** In-game grid cell, e.g. `C4`. Columns A–Z west→east, rows 0–N north→south. */
export function rustGrid(x: number, z: number, worldSize: number): string {
  const cell = gridCellSize(worldSize);
  if (!(cell > 0) || !Number.isFinite(x) || !Number.isFinite(z)) return "—";
  const col = clamp(Math.floor(x / cell), 0, GRID_COLUMNS - 1);
  const row = clamp(Math.floor((worldSize - z) / cell), 0, GRID_COLUMNS - 1);
  return `${String.fromCharCode(65 + col)}${row}`;
}

export function worldToScreen(
  x: number,
  z: number,
  view: RadarView,
  w: number,
  h: number,
): { sx: number; sy: number } {
  return {
    sx: (x - view.x) * view.scale + w / 2,
    sy: (view.z - z) * view.scale + h / 2,
  };
}

export function screenToWorld(
  sx: number,
  sy: number,
  view: RadarView,
  w: number,
  h: number,
): { x: number; z: number } {
  return {
    x: view.x + (sx - w / 2) / view.scale,
    z: view.z - (sy - h / 2) / view.scale,
  };
}

export function stageSize(): { w: number; h: number } {
  const el = document.querySelector(".stage") as HTMLElement | null;
  return {
    w: el?.clientWidth || window.innerWidth || 1200,
    h: el?.clientHeight || Math.max(420, (window.innerHeight || 800) - 36),
  };
}

export function joinFormatView(
  local: { x: number; z: number },
  canvasW = stageSize().w,
  canvasH = stageSize().h,
  spanMeters = JOIN_VIEW_METERS,
): RadarView {
  const dim = Math.max(280, Math.min(canvasW, canvasH));
  return {
    x: local.x,
    z: local.z,
    scale: clamp(dim / spanMeters, 0.12, 3.4),
  };
}

export function visibleMeters(view: RadarView, canvasW: number, canvasH: number): number {
  const dim = Math.max(1, Math.min(canvasW, canvasH));
  return dim / Math.max(0.0001, view.scale);
}

export function snapshotMapImagePath(raw: Record<string, unknown>): string | null {
  if (typeof raw.map_image_path === "string" && raw.map_image_path) return raw.map_image_path;
  const world = raw.world;
  if (world && typeof world === "object") {
    const path = (world as { map_image_path?: unknown }).map_image_path;
    if (typeof path === "string" && path) return path;
  }
  return null;
}

export function snapshotWorldSize(raw: Record<string, unknown>, fallback: number): number {
  if (typeof raw.world_size === "number" && raw.world_size > 0) return raw.world_size;
  const world = raw.world;
  if (world && typeof world === "object") {
    const size = (world as { size?: unknown; world_size?: unknown }).size
      ?? (world as { world_size?: unknown }).world_size;
    if (typeof size === "number" && size > 0) return size;
  }
  return fallback;
}

export function basemapUrls(path: string | null | undefined): string[] {
  const urls = [
    "/api/map",
    "http://127.0.0.1:1738/map",
    "http://127.0.0.1:8080/map",
  ];
  if (path && /^(https?:|data:|blob:|\/)/i.test(path)) urls.unshift(path);
  return urls;
}
