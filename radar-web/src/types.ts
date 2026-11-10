export type LootFilterKey =
  | "collectibles"
  | "ores"
  | "food"
  | "hemp"
  | "berries"
  | "loot"
  | "base"
  | "misc"
  | "animals"
  | "vehicle";

export type EntityCategory =
  | "player"
  | "player-sleeping"
  | "player-npc"
  | "player-admin"
  | "animal"
  | "animal-bear"
  | "animal-wolf"
  | "ore-stone"
  | "ore-metal"
  | "ore-sulfur"
  | "ore-hqm"
  | "loot-basic"
  | "loot-military"
  | "loot-elite"
  | "loot-barrel"
  | "supply-drop"
  | "vehicle"
  | "bradley"
  | "helicopter"
  | "hemp"
  | "berry"
  | "food"
  | "base"
  | "dropped"
  | "sleeping-bag"
  | "collectible";

export type Bone = "head" | "neck" | "body";

export type ChamsMode = "default" | "full-pink" | "not-see";

export interface Vec3 {
  x: number;
  y: number;
  z: number;
}

export interface Entity {
  id: string;
  category: EntityCategory;
  position: Vec3;
  label: string;
  amount?: number;
  health?: number;
  maxHealth?: number;
  held?: string | null;
  yaw?: number;
  sleeping?: boolean;
  npc?: boolean;
  admin?: boolean;
  local?: boolean;
  team?: number;
  visible?: boolean;
  boneHead?: Vec3;
  boneNeck?: Vec3;
  boneBody?: Vec3;
}

export interface LocalPlayer {
  position: Vec3;
  health: number;
  yaw: number;
  pitch: number;
  name: string;
  airborne: boolean;
  recoilPitch: number;
  recoilYaw: number;
}

export interface AimSolution {
  targetId: string | null;
  bone: Bone;
  world: Vec3 | null;
  pitch: number;
  yaw: number;
  deltaPitch: number;
  deltaYaw: number;
  fov: number;
  distance: number;
  locked: boolean;
  elapsedMs: number;
}

export interface WorldSnapshot {
  ts: number;
  worldSize: number;
  seed: number;
  provider: "sim" | "memprocfs" | "ft601" | "snapshot";
  dmaConnected: boolean;
  localPlayer: LocalPlayer | null;
  entities: Entity[];
  networkables: number;
  fps: number;
  frameMs: number;
  aim: AimSolution;
}

export interface HackFlags {
  allowMemory: boolean;
  visCheckChams: boolean;
  adminEsp: boolean;
  interactiveCamera: boolean;
  adminFlag: boolean;
  shootWhileJumping: boolean;
  spiderman: boolean;
  brightNight: boolean;
  brightCaves: boolean;
  instantEoka: boolean;
}

export interface AimSettings {
  enabled: boolean;
  bone: Bone;
  smoothX: number;
  smoothY: number;
  lockon: boolean;
  recoilReduction: boolean;
  recoilIntensity: number;
  fov: number;
}

export interface AppSettings {
  loot: Record<LootFilterKey, boolean>;
  chams: ChamsMode;
  hacks: HackFlags;
  aim: AimSettings;
  showMenu: boolean;
  showLoot: boolean;
  showEsp: boolean;
  showStats: boolean;
  classicRadar: boolean;
  espRange: number;
}

export const FILTER_CATEGORY: Record<LootFilterKey, EntityCategory[]> = {
  collectibles: ["collectible", "dropped", "supply-drop"],
  ores: ["ore-stone", "ore-metal", "ore-sulfur", "ore-hqm"],
  food: ["food"],
  hemp: ["hemp"],
  berries: ["berry"],
  loot: ["loot-basic", "loot-military", "loot-elite", "loot-barrel"],
  base: ["base", "sleeping-bag"],
  misc: ["bradley", "helicopter"],
  animals: ["animal", "animal-bear", "animal-wolf"],
  vehicle: ["vehicle"],
};

export const PLAYER_CATEGORIES: EntityCategory[] = [
  "player",
  "player-sleeping",
  "player-npc",
  "player-admin",
];
