import { clamp, fbm, hash2, lerp } from "./rng";

export interface Terrain {
  size: number;
  seed: number;
  resolution: number;
  height: Float32Array;
  land: Uint8Array;
  biome: Uint8Array;
}

export interface MonumentSpec {
  name: string;
  nx: number;
  nz: number;
  radius: number;
  kind: MonumentKind;
}

export type MonumentKind =
  | "airfield"
  | "launch"
  | "tunnel"
  | "harbor"
  | "yard"
  | "plant"
  | "outpost"
  | "dish";

export const BIOME_OCEAN = 0;
export const BIOME_SAND = 1;
export const BIOME_GRASS = 2;
export const BIOME_FOREST = 3;
export const BIOME_ROCK = 4;
export const BIOME_SNOW = 5;
export const BIOME_ROAD = 6;
export const BIOME_MONUMENT = 7;
export const BIOME_DESERT = 8;

/** Facepunch-style teal ocean behind / around the island. */
export const SATELLITE_OCEAN_FILL = "#2a7a8c";

export const RUST_MONUMENTS: MonumentSpec[] = [
  { name: "Airfield", nx: 0.58, nz: 0.44, radius: 0.038, kind: "airfield" },
  { name: "Launch Site", nx: 0.7, nz: 0.62, radius: 0.042, kind: "launch" },
  { name: "Military Tunnel", nx: 0.4, nz: 0.52, radius: 0.03, kind: "tunnel" },
  { name: "Harbor", nx: 0.52, nz: 0.7, radius: 0.032, kind: "harbor" },
  { name: "Train Yard", nx: 0.33, nz: 0.38, radius: 0.03, kind: "yard" },
  { name: "Power Plant", nx: 0.66, nz: 0.36, radius: 0.034, kind: "plant" },
  { name: "Outpost", nx: 0.48, nz: 0.48, radius: 0.02, kind: "outpost" },
  { name: "Satellite Dish", nx: 0.28, nz: 0.58, radius: 0.024, kind: "dish" },
];

const ROAD_SEGMENTS: Array<[number, number, number, number]> = [
  [0.4, 0.52, 0.58, 0.44],
  [0.58, 0.44, 0.7, 0.62],
  [0.52, 0.7, 0.58, 0.44],
  [0.32, 0.6, 0.4, 0.52],
  [0.33, 0.38, 0.48, 0.48],
  [0.48, 0.48, 0.66, 0.36],
  [0.28, 0.58, 0.4, 0.52],
  [0.7, 0.62, 0.66, 0.36],
  [0.4, 0.52, 0.52, 0.7],
  [0.48, 0.48, 0.4, 0.52],
];

/** Island mass with inlets / a western cape, similar to a temperate Rust procgen. */
function landField(nx: number, ny: number): number {
  const blobs = [
    [0.47, 0.42, 0.37],
    [0.62, 0.56, 0.29],
    [0.3, 0.6, 0.23],
    [0.71, 0.33, 0.15],
    [0.22, 0.4, 0.13],
    [0.54, 0.28, 0.14],
  ] as const;
  let radial = 9;
  for (const [cx, cy, r] of blobs) {
    radial = Math.min(radial, Math.hypot(nx - cx, ny - cy) / r);
  }
  const inlet1 = Math.hypot(nx - 0.18, ny - 0.52) / 0.09;
  const inlet2 = Math.hypot(nx - 0.78, ny - 0.48) / 0.08;
  const n = fbm(nx * 5.4, ny * 5.4, 5);
  const coast = fbm(nx * 16, ny * 16, 4);
  const jag = fbm(nx * 38, ny * 38, 2);
  let field = 0.72 - radial * 0.94 + n * 0.26 + coast * 0.07 + jag * 0.025;
  if (inlet1 < 1) field -= (1 - inlet1) * 0.28;
  if (inlet2 < 1) field -= (1 - inlet2) * 0.22;
  return field;
}

export function generateTerrain(size: number, seed: number, resolution = 768): Terrain {
  const n = resolution * resolution;
  const height = new Float32Array(n);
  const land = new Uint8Array(n);
  const biome = new Uint8Array(n);
  const jitter = ((seed % 97) - 48) * 0.0004;

  for (let y = 0; y < resolution; y++) {
    const ny = y / (resolution - 1);
    for (let x = 0; x < resolution; x++) {
      const i = y * resolution + x;
      const nx = x / (resolution - 1);
      const field = landField(nx + jitter, ny - jitter * 0.4);
      const h = fbm(nx * 7.5 + seed * 0.01, ny * 7.5, 5);
      const arid = fbm(nx * 2.1 + 4, ny * 2.1, 3);
      const grove = fbm(nx * 6.2 + 1.7, ny * 6.2, 4);
      height[i] = field * 0.62 + h * 0.38;
      const isLand = field > 0.335;
      land[i] = isLand ? 1 : 0;
      if (!isLand) {
        biome[i] = BIOME_OCEAN;
      } else if (field < 0.392) {
        biome[i] = BIOME_SAND;
      } else if (height[i] > 0.8 && grove > 0.5) {
        // Ice caps on peaks only — never a northern fog blanket.
        biome[i] = BIOME_SNOW;
      } else if (height[i] > 0.72 && arid > 0.5) {
        biome[i] = BIOME_ROCK;
      } else if (arid > 0.68 && ny < 0.34 && field > 0.45) {
        biome[i] = BIOME_DESERT;
      } else if (grove > 0.34 && field > 0.41) {
        biome[i] = BIOME_FOREST;
      } else {
        biome[i] = BIOME_GRASS;
      }
    }
  }

  paintRoadsAndMonuments(biome, land, resolution);
  return { size, seed, resolution, height, land, biome };
}

function paintDisk(
  biome: Uint8Array,
  land: Uint8Array,
  res: number,
  cx: number,
  cy: number,
  rr: number,
  value: number,
  landOnly = true,
): void {
  const r2 = rr * rr;
  const x0 = Math.max(0, Math.floor(cx - rr));
  const x1 = Math.min(res - 1, Math.ceil(cx + rr));
  const y0 = Math.max(0, Math.floor(cy - rr));
  const y1 = Math.min(res - 1, Math.ceil(cy + rr));
  for (let y = y0; y <= y1; y++) {
    for (let x = x0; x <= x1; x++) {
      const dx = x - cx;
      const dy = y - cy;
      if (dx * dx + dy * dy > r2) continue;
      const i = y * res + x;
      if (landOnly && !land[i]) continue;
      biome[i] = value;
    }
  }
}

function paintRect(
  biome: Uint8Array,
  land: Uint8Array,
  res: number,
  x0: number,
  y0: number,
  x1: number,
  y1: number,
  value: number,
  landOnly = true,
): void {
  const xa = Math.max(0, Math.floor(Math.min(x0, x1)));
  const xb = Math.min(res - 1, Math.ceil(Math.max(x0, x1)));
  const ya = Math.max(0, Math.floor(Math.min(y0, y1)));
  const yb = Math.min(res - 1, Math.ceil(Math.max(y0, y1)));
  for (let y = ya; y <= yb; y++) {
    for (let x = xa; x <= xb; x++) {
      const i = y * res + x;
      if (landOnly && !land[i]) continue;
      biome[i] = value;
    }
  }
}

function paintRoadsAndMonuments(biome: Uint8Array, land: Uint8Array, res: number): void {
  for (const m of RUST_MONUMENTS) {
    const cx = m.nx * res;
    const cy = m.nz * res;
    const rr = Math.max(3, m.radius * res);
    if (m.kind === "airfield") {
      paintRect(biome, land, res, cx - rr * 1.6, cy - rr * 0.28, cx + rr * 1.6, cy + rr * 0.28, BIOME_MONUMENT);
      paintRect(biome, land, res, cx - rr * 1.55, cy - rr * 0.1, cx + rr * 1.55, cy + rr * 0.1, BIOME_ROAD, false);
    } else if (m.kind === "harbor") {
      paintRect(biome, land, res, cx - rr, cy - rr * 0.7, cx + rr, cy + rr * 0.9, BIOME_MONUMENT, false);
    } else if (m.kind === "outpost" || m.kind === "yard" || m.kind === "plant") {
      paintRect(biome, land, res, cx - rr * 0.9, cy - rr * 0.75, cx + rr * 0.9, cy + rr * 0.75, BIOME_MONUMENT);
    } else {
      paintDisk(biome, land, res, cx, cy, rr, BIOME_MONUMENT);
    }
  }

  for (const [x0, y0, x1, y1] of ROAD_SEGMENTS) {
    const steps = Math.max(220, Math.floor(Math.hypot(x1 - x0, y1 - y0) * res * 1.4));
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = Math.hypot(dx, dy) || 1;
    const px = -dy / len;
    const py = dx / len;
    for (let s = 0; s <= steps; s++) {
      const t = s / steps;
      const wobble = (fbm(t * 9 + x0 * 3, t * 9 + y0 * 3, 3) - 0.5) * 0.01;
      const rx = x0 + dx * t + px * wobble;
      const ry = y0 + dy * t + py * wobble;
      const cx = rx * res;
      const cy = ry * res;
      const half = 2.1;
      for (let oy = -3; oy <= 3; oy++) {
        for (let ox = -3; ox <= 3; ox++) {
          if (ox * ox + oy * oy > half * half + 1.2) continue;
          const x = Math.floor(cx + ox);
          const y = Math.floor(cy + oy);
          if (x < 0 || y < 0 || x >= res || y >= res) continue;
          const i = y * res + x;
          if (land[i] && biome[i] !== BIOME_MONUMENT) biome[i] = BIOME_ROAD;
        }
      }
    }
  }
}

export function sampleHeight(terrain: Terrain, x: number, z: number): number {
  const u = (x / terrain.size) * (terrain.resolution - 1);
  const v = (z / terrain.size) * (terrain.resolution - 1);
  const x0 = Math.floor(u);
  const y0 = Math.floor(v);
  if (x0 < 0 || y0 < 0 || x0 >= terrain.resolution - 1 || y0 >= terrain.resolution - 1) {
    return 0;
  }
  const fx = u - x0;
  const fy = v - y0;
  const i00 = y0 * terrain.resolution + x0;
  const h00 = terrain.height[i00];
  const h10 = terrain.height[i00 + 1];
  const h01 = terrain.height[i00 + terrain.resolution];
  const h11 = terrain.height[i00 + terrain.resolution + 1];
  return lerp(lerp(h00, h10, fx), lerp(h01, h11, fx), fy);
}

export function isLandAt(terrain: Terrain, x: number, z: number): boolean {
  const u = Math.floor((x / terrain.size) * (terrain.resolution - 1));
  const v = Math.floor((z / terrain.size) * (terrain.resolution - 1));
  if (u < 0 || v < 0 || u >= terrain.resolution || v >= terrain.resolution) return false;
  return terrain.land[v * terrain.resolution + u] === 1;
}

export function lineOfSight(
  terrain: Terrain,
  ax: number,
  az: number,
  bx: number,
  bz: number,
): boolean {
  const dist = Math.hypot(bx - ax, bz - az);
  const steps = Math.max(4, Math.ceil(dist / 18));
  const h0 = sampleHeight(terrain, ax, az);
  const h1 = sampleHeight(terrain, bx, bz);
  for (let i = 1; i < steps; i++) {
    const t = i / steps;
    const x = lerp(ax, bx, t);
    const z = lerp(az, bz, t);
    const ground = sampleHeight(terrain, x, z);
    const ray = lerp(h0, h1, t) + 0.04;
    if (ground > ray + 0.035) return false;
  }
  return true;
}

const DEEP = [30, 94, 120];
const OCEAN = [42, 118, 140];
const SHALLOW = [74, 148, 158];
const REEF = [112, 168, 160];
const SAND = [214, 196, 148];
const SAND2 = [196, 176, 128];
const GRASS = [126, 148, 72];
const GRASS2 = [108, 132, 60];
const CLEARING = [142, 158, 82];
const CANOPY = [58, 98, 42];
const CANOPY2 = [72, 112, 48];
const UNDERSTORY = [90, 122, 52];
const ROCK = [132, 124, 108];
const ROCK2 = [116, 110, 96];
const ICE = [206, 218, 220];
const ICE_EDGE = [168, 184, 186];
const ROAD = [178, 150, 102];
const ROAD_EDGE = [150, 124, 82];
const MON = [168, 156, 128];
const MON2 = [148, 138, 114];
const DESERT = [186, 158, 98];

function mix(a: number[], b: number[], t: number): number[] {
  return [lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t)];
}

export function biomeRgb(
  biome: number,
  height: number,
  brightNight: boolean,
  brightCaves: boolean,
  texture = 0.5,
  slope = 0,
): [number, number, number] {
  const lift = brightNight ? 20 : 0;
  const cave = brightCaves && biome !== BIOME_OCEAN && height < 0.42 ? 14 : 0;
  let col: number[];
  if (biome === BIOME_OCEAN) {
    col = mix(DEEP, height < 0.3 ? OCEAN : mix(SHALLOW, REEF, clamp(height * 2.2, 0, 1)), clamp(height * 1.7, 0, 1));
  } else if (biome === BIOME_SAND) {
    col = mix(SAND2, SAND, texture);
  } else if (biome === BIOME_DESERT) {
    col = mix(DESERT, SAND, height * 0.35 + texture * 0.15);
  } else if (biome === BIOME_FOREST) {
    if (texture > 0.62) col = mix(CANOPY, CANOPY2, (texture - 0.62) / 0.38);
    else if (texture > 0.38) col = mix(UNDERSTORY, CANOPY2, texture);
    else col = mix(GRASS2, CLEARING, texture * 1.4);
  } else if (biome === BIOME_ROCK) {
    col = mix(ROCK2, ROCK, texture);
  } else if (biome === BIOME_SNOW) {
    col = mix(ICE_EDGE, ICE, 0.35 + texture * 0.5);
  } else if (biome === BIOME_ROAD) {
    col = mix(ROAD_EDGE, ROAD, texture > 0.45 ? 0.75 : 0.25);
  } else if (biome === BIOME_MONUMENT) {
    col = mix(MON2, MON, texture);
  } else {
    col = mix(GRASS2, mix(GRASS, CLEARING, texture), height * 0.45 + 0.2);
  }
  if (slope > 0.045 && biome !== BIOME_OCEAN && biome !== BIOME_ROAD && biome !== BIOME_SNOW) {
    col = mix(col, ROCK2, clamp((slope - 0.045) * 8, 0, 0.55));
  }
  const shade = biome === BIOME_OCEAN ? 0.92 + height * 0.12 : 0.82 + height * 0.28;
  const r = Math.min(255, col[0] * shade + lift + cave);
  const g = Math.min(255, col[1] * shade + lift + cave);
  const b = Math.min(255, col[2] * shade + lift * 0.4);
  return [r | 0, g | 0, b | 0];
}

export function biomeFill(
  biome: number,
  height: number,
  brightNight: boolean,
  brightCaves = false,
): string {
  const [r, g, b] = biomeRgb(biome, height, brightNight, brightCaves);
  return `rgb(${r},${g},${b})`;
}

export function sampleBiome(terrain: Terrain, x: number, z: number): { biome: number; height: number } {
  const u = Math.max(0, Math.min(terrain.resolution - 1, Math.floor((x / terrain.size) * (terrain.resolution - 1))));
  const v = Math.max(0, Math.min(terrain.resolution - 1, Math.floor((z / terrain.size) * (terrain.resolution - 1))));
  const i = v * terrain.resolution + u;
  return { biome: terrain.biome[i], height: terrain.height[i] };
}

export function randomLandPoint(
  terrain: Terrain,
  rand: () => number,
  tries = 80,
): { x: number; z: number } | null {
  for (let i = 0; i < tries; i++) {
    const x = rand() * terrain.size;
    const z = rand() * terrain.size;
    if (isLandAt(terrain, x, z)) return { x, z };
  }
  return null;
}

export function biomeCoverage(terrain: Terrain): Record<string, number> {
  const counts: Record<string, number> = {
    ocean: 0,
    sand: 0,
    grass: 0,
    forest: 0,
    rock: 0,
    snow: 0,
    road: 0,
    monument: 0,
    desert: 0,
  };
  const names = ["ocean", "sand", "grass", "forest", "rock", "snow", "road", "monument", "desert"];
  for (let i = 0; i < terrain.biome.length; i++) {
    const key = names[terrain.biome[i]] ?? "ocean";
    counts[key] += 1;
  }
  const n = terrain.biome.length || 1;
  for (const k of Object.keys(counts)) counts[k] /= n;
  return counts;
}

function shadeFromSlope(height: Float32Array, res: number, x: number, y: number): { slope: number; hill: number } {
  const xm = Math.max(0, x - 1);
  const xp = Math.min(res - 1, x + 1);
  const ym = Math.max(0, y - 1);
  const yp = Math.min(res - 1, y + 1);
  const dx = height[y * res + xp] - height[y * res + xm];
  const dy = height[yp * res + x] - height[ym * res + x];
  const slope = Math.hypot(dx, dy);
  const hill = clamp(0.72 + (-dx * 0.9 + dy * 0.45) * 2.8, 0.55, 1.18);
  return { slope, hill };
}

function writeRgb(data: Uint8ClampedArray, o: number, rgb: [number, number, number], hill: number, grain: number): void {
  data[o] = clamp(rgb[0] * hill + grain, 0, 255) | 0;
  data[o + 1] = clamp(rgb[1] * hill + grain, 0, 255) | 0;
  data[o + 2] = clamp(rgb[2] * hill + grain * 0.7, 0, 255) | 0;
  data[o + 3] = 255;
}

/** Orthographic satellite G-map: teal shallows, mottled canopy, dirt roads, ice caps. */
export function paintTerrainCanvas(
  terrain: Terrain,
  brightNight: boolean,
  brightCaves: boolean,
): HTMLCanvasElement {
  const res = terrain.resolution;
  const canvas = document.createElement("canvas");
  canvas.width = res;
  canvas.height = res;
  const ctx = canvas.getContext("2d");
  if (!ctx) return canvas;
  const img = ctx.createImageData(res, res);
  const data = img.data;
  const { height, biome } = terrain;

  for (let py = 0; py < res; py++) {
    const tz = res - 1 - py;
    for (let px = 0; px < res; px++) {
      const i = tz * res + px;
      const o = (py * res + px) * 4;
      const b = biome[i];
      const h = height[i];
      const { slope, hill } = shadeFromSlope(height, res, px, tz);
      const tex = hash2(px * 3 + 11, tz * 5 + 7);
      const grain = (hash2(px, tz) - 0.5) * 10;
      let rgb: [number, number, number];
      if (b === BIOME_OCEAN) {
        const shallow = clamp(h * 1.55, 0, 1);
        const water = mix(DEEP, mix(OCEAN, mix(SHALLOW, REEF, shallow), shallow), shallow);
        const wave = (hash2(px + 19, tz * 3) - 0.5) * 6;
        rgb = [
          clamp(water[0] + wave, 0, 255) | 0,
          clamp(water[1] + wave * 0.6, 0, 255) | 0,
          clamp(water[2] + wave * 0.3, 0, 255) | 0,
        ];
        if (brightNight) {
          rgb = [Math.min(255, rgb[0] + 18), Math.min(255, rgb[1] + 16), Math.min(255, rgb[2] + 8)];
        }
        writeRgb(data, o, rgb, 1, grain * 0.35);
        continue;
      }
      rgb = biomeRgb(b, h, brightNight, brightCaves, tex, slope);
      writeRgb(data, o, rgb, hill, grain);
    }
  }
  ctx.putImageData(img, 0, 0);
  paintMonumentFootprints(ctx, res);
  return canvas;
}

function canvasXY(nx: number, nz: number, res: number): { x: number; y: number } {
  return { x: nx * res, y: (1 - nz) * res };
}

function paintMonumentFootprints(ctx: CanvasRenderingContext2D, res: number): void {
  ctx.save();
  ctx.imageSmoothingEnabled = true;
  for (const m of RUST_MONUMENTS) {
    const { x, y } = canvasXY(m.nx, m.nz, res);
    const r = m.radius * res;
    ctx.save();
    ctx.translate(x, y);
    if (m.kind === "airfield") {
      ctx.fillStyle = "rgba(150, 140, 118, 0.95)";
      ctx.fillRect(-r * 1.65, -r * 0.55, r * 3.3, r * 1.1);
      ctx.fillStyle = "#9a9078";
      ctx.fillRect(-r * 1.55, -r * 0.12, r * 3.1, r * 0.24);
      ctx.fillStyle = "#c4b89a";
      for (let i = -4; i <= 4; i++) ctx.fillRect(i * r * 0.32 - 2, -3, 8, 6);
      ctx.fillStyle = "#8a8070";
      ctx.fillRect(-r * 0.55, -r * 0.48, r * 0.7, r * 0.28);
      ctx.fillRect(r * 0.4, r * 0.18, r * 0.5, r * 0.22);
    } else if (m.kind === "launch") {
      ctx.fillStyle = "rgba(142, 136, 118, 0.92)";
      ctx.beginPath();
      ctx.arc(0, 0, r * 0.95, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = "#7a7468";
      ctx.fillRect(-r * 0.55, -r * 0.18, r * 1.1, r * 0.36);
      ctx.fillStyle = "#9a9280";
      ctx.beginPath();
      ctx.arc(-r * 0.35, r * 0.28, r * 0.16, 0, Math.PI * 2);
      ctx.arc(r * 0.32, r * 0.22, r * 0.14, 0, Math.PI * 2);
      ctx.fill();
    } else if (m.kind === "harbor") {
      ctx.fillStyle = "rgba(154, 146, 122, 0.94)";
      ctx.fillRect(-r * 0.9, -r * 0.5, r * 1.8, r * 1.15);
      ctx.fillStyle = "#6a8a8c";
      ctx.fillRect(-r * 0.15, r * 0.35, r * 0.18, r * 0.7);
      ctx.fillRect(r * 0.2, r * 0.35, r * 0.16, r * 0.55);
      ctx.fillStyle = "#8a8070";
      ctx.fillRect(-r * 0.7, -r * 0.35, r * 0.45, r * 0.28);
      ctx.fillRect(r * 0.15, -r * 0.28, r * 0.5, r * 0.22);
    } else if (m.kind === "outpost") {
      ctx.fillStyle = "rgba(176, 160, 122, 0.96)";
      ctx.fillRect(-r * 0.95, -r * 0.8, r * 1.9, r * 1.6);
      ctx.strokeStyle = "rgba(90, 80, 60, 0.55)";
      ctx.lineWidth = 1.4;
      ctx.strokeRect(-r * 0.95, -r * 0.8, r * 1.9, r * 1.6);
      ctx.fillStyle = "#9a8a6e";
      ctx.fillRect(-r * 0.7, -r * 0.55, r * 0.55, r * 0.4);
      ctx.fillRect(r * 0.05, -r * 0.5, r * 0.62, r * 0.38);
      ctx.fillRect(-r * 0.35, r * 0.05, r * 0.7, r * 0.42);
      ctx.fillStyle = "#c4b48a";
      ctx.fillRect(-r * 0.15, -r * 0.12, r * 0.3, r * 0.18);
    } else if (m.kind === "yard") {
      ctx.fillStyle = "rgba(160, 150, 128, 0.94)";
      ctx.fillRect(-r * 0.95, -r * 0.7, r * 1.9, r * 1.4);
      ctx.strokeStyle = "#6a6258";
      ctx.lineWidth = 1.2;
      for (let i = -2; i <= 2; i++) {
        ctx.beginPath();
        ctx.moveTo(-r * 0.85, i * r * 0.18);
        ctx.lineTo(r * 0.85, i * r * 0.18);
        ctx.stroke();
      }
      ctx.fillStyle = "#8a8070";
      ctx.fillRect(-r * 0.8, -r * 0.62, r * 0.4, r * 0.28);
    } else if (m.kind === "plant") {
      ctx.fillStyle = "rgba(150, 148, 132, 0.94)";
      ctx.fillRect(-r * 0.9, -r * 0.7, r * 1.8, r * 1.4);
      ctx.fillStyle = "#7a8688";
      ctx.beginPath();
      ctx.arc(-r * 0.28, 0, r * 0.28, 0, Math.PI * 2);
      ctx.arc(r * 0.32, r * 0.08, r * 0.24, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = "#6a6860";
      ctx.fillRect(r * 0.05, -r * 0.55, r * 0.18, r * 0.7);
    } else if (m.kind === "dish") {
      ctx.fillStyle = "rgba(156, 150, 132, 0.9)";
      ctx.beginPath();
      ctx.arc(0, 0, r * 0.85, 0, Math.PI * 2);
      ctx.fill();
      ctx.strokeStyle = "#d0d4d0";
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(-r * 0.18, -r * 0.08, r * 0.32, 0, Math.PI * 2);
      ctx.stroke();
      ctx.beginPath();
      ctx.arc(r * 0.28, r * 0.16, r * 0.2, 0, Math.PI * 2);
      ctx.stroke();
    } else {
      ctx.fillStyle = "rgba(140, 136, 122, 0.9)";
      ctx.fillRect(-r * 0.7, -r * 0.35, r * 1.4, r * 0.7);
      ctx.fillStyle = "#5a5850";
      ctx.fillRect(-r * 0.2, -r * 0.12, r * 0.4, r * 0.22);
    }
    ctx.restore();
  }
  ctx.restore();
}
