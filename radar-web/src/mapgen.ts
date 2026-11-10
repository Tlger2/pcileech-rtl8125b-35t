import { fbm, lerp } from "./rng";

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
}

export const BIOME_OCEAN = 0;
export const BIOME_SAND = 1;
export const BIOME_GRASS = 2;
export const BIOME_FOREST = 3;
export const BIOME_ROCK = 4;
export const BIOME_SNOW = 5;
export const BIOME_ROAD = 6;
export const BIOME_MONUMENT = 7;
export const BIOME_DESERT = 8;

export const RUST_MONUMENTS: MonumentSpec[] = [
  { name: "Airfield", nx: 0.58, nz: 0.44, radius: 0.038 },
  { name: "Launch Site", nx: 0.7, nz: 0.62, radius: 0.042 },
  { name: "Military Tunnel", nx: 0.4, nz: 0.52, radius: 0.03 },
  { name: "Harbor", nx: 0.52, nz: 0.7, radius: 0.032 },
  { name: "Train Yard", nx: 0.33, nz: 0.38, radius: 0.03 },
  { name: "Power Plant", nx: 0.66, nz: 0.36, radius: 0.034 },
  { name: "Outpost", nx: 0.48, nz: 0.48, radius: 0.02 },
  { name: "Satellite Dish", nx: 0.28, nz: 0.58, radius: 0.024 },
];

function landField(nx: number, ny: number): number {
  const d1 = Math.hypot(nx - 0.46, ny - 0.4) / 0.36;
  const d2 = Math.hypot(nx - 0.62, ny - 0.58) / 0.3;
  const d3 = Math.hypot(nx - 0.32, ny - 0.62) / 0.22;
  const d4 = Math.hypot(nx - 0.72, ny - 0.32) / 0.16;
  const radial = Math.min(d1, d2, d3, d4);
  const n = fbm(nx * 5.2, ny * 5.2, 5);
  const coast = fbm(nx * 14, ny * 14, 3);
  return 0.7 - radial * 0.92 + n * 0.28 + coast * 0.06;
}

export function generateTerrain(size: number, seed: number, resolution = 768): Terrain {
  const n = resolution * resolution;
  const height = new Float32Array(n);
  const land = new Uint8Array(n);
  const biome = new Uint8Array(n);
  const jitter = ((seed % 97) - 48) * 0.0004;

  for (let y = 0; y < resolution; y++) {
    for (let x = 0; x < resolution; x++) {
      const i = y * resolution + x;
      const nx = x / (resolution - 1);
      const ny = y / (resolution - 1);
      const field = landField(nx + jitter, ny - jitter * 0.4);
      const h = fbm(nx * 8 + seed * 0.01, ny * 8, 4);
      const arid = fbm(nx * 2.2 + 4, ny * 2.2, 3);
      height[i] = field * 0.65 + h * 0.35;
      const isLand = field > 0.34;
      land[i] = isLand ? 1 : 0;
      if (!isLand) {
        biome[i] = BIOME_OCEAN;
      } else if (field < 0.4) {
        biome[i] = BIOME_SAND;
      } else if (ny > 0.74 && height[i] > 0.5) {
        biome[i] = BIOME_SNOW;
      } else if (height[i] > 0.78) {
        biome[i] = BIOME_SNOW;
      } else if (height[i] > 0.68) {
        biome[i] = BIOME_ROCK;
      } else if (arid > 0.62 && ny < 0.42 && field > 0.42) {
        biome[i] = BIOME_DESERT;
      } else if (h > 0.58 && field > 0.48) {
        biome[i] = BIOME_FOREST;
      } else {
        biome[i] = BIOME_GRASS;
      }
    }
  }

  paintRoadsAndMonuments(biome, land, resolution);
  return { size, seed, resolution, height, land, biome };
}

function paintRoadsAndMonuments(biome: Uint8Array, land: Uint8Array, res: number): void {
  for (const m of RUST_MONUMENTS) {
    const cx = Math.floor(m.nx * res);
    const cy = Math.floor(m.nz * res);
    const rr = Math.max(2, Math.floor(m.radius * res));
    for (let y = cy - rr; y <= cy + rr; y++) {
      for (let x = cx - rr; x <= cx + rr; x++) {
        if (x < 0 || y < 0 || x >= res || y >= res) continue;
        const i = y * res + x;
        if (!land[i]) continue;
        biome[i] = BIOME_MONUMENT;
      }
    }
  }

  const roads: Array<[number, number, number, number]> = [
    [0.4, 0.52, 0.58, 0.44],
    [0.58, 0.44, 0.7, 0.62],
    [0.52, 0.7, 0.58, 0.44],
    [0.32, 0.6, 0.4, 0.52],
    [0.33, 0.38, 0.48, 0.48],
    [0.48, 0.48, 0.66, 0.36],
    [0.28, 0.58, 0.4, 0.52],
    [0.7, 0.62, 0.66, 0.36],
    [0.4, 0.52, 0.52, 0.7],
  ];
  for (const [x0, y0, x1, y1] of roads) {
    const steps = 280;
    for (let s = 0; s <= steps; s++) {
      const t = s / steps;
      const px = lerp(x0, x1, t);
      const py = lerp(y0, y1, t);
      const cx = Math.floor(px * res);
      const cy = Math.floor(py * res);
      for (let oy = -2; oy <= 2; oy++) {
        for (let ox = -2; ox <= 2; ox++) {
          if (Math.abs(ox) === 2 && Math.abs(oy) === 2) continue;
          const x = cx + ox;
          const y = cy + oy;
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

const DEEP = [8, 42, 58];
const OCEAN = [18, 72, 92];
const SHALLOW = [36, 102, 118];
const SAND = [210, 188, 132];
const GRASS = [110, 132, 58];
const GRASS2 = [86, 112, 48];
const FOREST = [46, 78, 36];
const ROCK = [118, 114, 104];
const SNOW = [214, 220, 216];
const ROAD = [110, 84, 52];
const MON = [138, 138, 132];
const DESERT = [186, 154, 92];

function mix(a: number[], b: number[], t: number): number[] {
  return [lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t)];
}

export function biomeRgb(
  biome: number,
  height: number,
  brightNight: boolean,
  brightCaves: boolean,
): [number, number, number] {
  const lift = brightNight ? 22 : 0;
  const cave = brightCaves && biome !== BIOME_OCEAN && height < 0.42 ? 16 : 0;
  let col: number[];
  if (biome === BIOME_OCEAN) col = mix(DEEP, height < 0.28 ? OCEAN : SHALLOW, clamp01(height * 1.6));
  else if (biome === BIOME_SAND) col = SAND;
  else if (biome === BIOME_DESERT) col = mix(DESERT, SAND, height * 0.35);
  else if (biome === BIOME_FOREST) col = mix(FOREST, GRASS2, height);
  else if (biome === BIOME_ROCK) col = ROCK;
  else if (biome === BIOME_SNOW) col = SNOW;
  else if (biome === BIOME_ROAD) col = ROAD;
  else if (biome === BIOME_MONUMENT) col = MON;
  else col = mix(GRASS2, GRASS, height);
  const shade = biome === BIOME_OCEAN ? 0.88 + height * 0.18 : 0.78 + height * 0.32;
  const r = Math.min(255, col[0] * shade + lift + cave);
  const g = Math.min(255, col[1] * shade + lift + cave);
  const b = Math.min(255, col[2] * shade + lift * 0.45);
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

function clamp01(v: number): number {
  return Math.max(0, Math.min(1, v));
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
  for (let py = 0; py < res; py++) {
    const tz = res - 1 - py;
    for (let px = 0; px < res; px++) {
      const i = tz * res + px;
      const [r, g, b] = biomeRgb(terrain.biome[i], terrain.height[i], brightNight, brightCaves);
      const o = (py * res + px) * 4;
      data[o] = r;
      data[o + 1] = g;
      data[o + 2] = b;
      data[o + 3] = 255;
    }
  }
  ctx.putImageData(img, 0, 0);
  return canvas;
}
