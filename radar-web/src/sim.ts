import { applyAim, selectAimTarget } from "./aim";
import {
  generateTerrain,
  isLandAt,
  lineOfSight,
  randomLandPoint,
  sampleHeight,
  type Terrain,
} from "./mapgen";
import { clamp, mulberry32, wrapDeg } from "./rng";
import {
  FILTER_CATEGORY,
  type AppSettings,
  type Entity,
  type EntityCategory,
  type LocalPlayer,
  type LootFilterKey,
  type WorldSnapshot,
} from "./types";

const NAMES = [
  "A7H2K9", "Wolfpack", "EWE6W2K", "MaxxAsh", "Rostov", "Natter",
  "Baited", "SulfurKid", "BagLeft", "Roofcam", "AKMami", "OilRig",
  "ZergOne", "SoloLife", "BowKid", "DoorCamp", "HqmRat", "CaveOwl",
  "AdminWatch", "ModCam", "NpcSci", "Heavy", "Dweller",
];

const WEAPONS = [
  "rifle.ak", "rifle.lr300", "smg.mp5", "bow.hunting", "pistol.python",
  "shotgun.pump", "rifle.bolt", "smg.thompson", "pistol.eoka", "lmg.m249",
];

interface Actor extends Entity {
  vx: number;
  vz: number;
  wander: number;
}

function catLabel(c: EntityCategory, amount?: number): string {
  switch (c) {
    case "ore-sulfur":
      return amount ? `Sulfur (${amount})` : "Sulfur";
    case "ore-metal":
      return amount ? `Metal (${amount})` : "Metal";
    case "ore-stone":
      return amount ? `Stone (${amount})` : "Stone";
    case "ore-hqm":
      return "HQM";
    case "hemp":
      return "Hemp";
    case "berry":
      return "Berries";
    case "food":
      return "Food";
    case "vehicle":
      return amount ? `Car ${amount}` : "Car";
    case "sleeping-bag":
      return "Sleeping Bag";
    case "loot-basic":
      return "Loot";
    case "loot-military":
      return "Military Crate";
    case "loot-elite":
      return "Elite Crate";
    case "dropped":
      return "Hunting Bow";
    default:
      return c;
  }
}

export class WorldSim {
  readonly seed: number;
  readonly size: number;
  readonly terrain: Terrain;
  private rand: () => number;
  private actors: Actor[] = [];
  private statics: Entity[] = [];
  local: LocalPlayer;
  dmaConnected = false;
  provider: WorldSnapshot["provider"] = "sim";
  private lastAim = selectAimTarget(
    {
      position: { x: 0, y: 0, z: 0 },
      health: 100,
      yaw: 0,
      pitch: 0,
      name: "local",
      airborne: false,
      recoilPitch: 0,
      recoilYaw: 0,
    },
    [],
    {
      enabled: false,
      bone: "neck",
      smoothX: 0.69,
      smoothY: 0.69,
      lockon: true,
      recoilReduction: true,
      recoilIntensity: 9,
      fov: 12,
    },
    true,
  );
  private time = 0;

  constructor(seed = 1337, size = 4000) {
    this.seed = seed;
    this.size = size;
    this.rand = mulberry32(seed);
    this.terrain = generateTerrain(size, seed, 256);
    this.local = this.spawnLocal();
    this.seedWorld();
  }

  private spawnLocal(): LocalPlayer {
    const preferred = { x: this.size * 0.47, z: this.size * 0.44 };
    const p = isLandAt(this.terrain, preferred.x, preferred.z)
      ? preferred
      : randomLandPoint(this.terrain, this.rand, 200) ?? preferred;
    return {
      position: { x: p.x, y: sampleHeight(this.terrain, p.x, p.z) * 80, z: p.z },
      health: 86,
      yaw: 210,
      pitch: 4,
      name: "local",
      airborne: false,
      recoilPitch: -1.4,
      recoilYaw: 0.35,
    };
  }

  private landOrRetry(): { x: number; z: number } {
    return randomLandPoint(this.terrain, this.rand) ?? {
      x: this.size * 0.5,
      z: this.size * 0.45,
    };
  }

  private addStatic(
    category: EntityCategory,
    n: number,
    extra?: (i: number, pos: { x: number; z: number }) => Partial<Entity>,
  ): void {
    for (let i = 0; i < n; i++) {
      const pos = this.landOrRetry();
      const amount = extra ? undefined : Math.floor(this.rand() * 24) + 1;
      const e: Entity = {
        id: `${category}-${i}`,
        category,
        position: { x: pos.x, y: sampleHeight(this.terrain, pos.x, pos.z) * 80, z: pos.z },
        label: catLabel(category, amount),
        amount,
        visible: true,
        ...extra?.(i, pos),
      };
      if (extra) e.label = extra(i, pos).label ?? e.label;
      this.statics.push(e);
    }
  }

  private seedWorld(): void {
    const cluster = { x: this.size * 0.47, z: this.size * 0.44 };
    const scatter = (spread: number) => {
      for (let k = 0; k < 12; k++) {
        const p = this.landOrRetry();
        if (Math.hypot(p.x - cluster.x, p.z - cluster.z) < spread) return p;
      }
      return {
        x: cluster.x + (this.rand() - 0.5) * spread,
        z: cluster.z + (this.rand() - 0.5) * spread,
      };
    };

    const drop = (
      category: EntityCategory,
      n: number,
      spread: number,
      labeler?: (i: number) => Partial<Entity>,
    ) => {
      for (let i = 0; i < n; i++) {
        const pos = scatter(spread);
        if (!isLandAt(this.terrain, pos.x, pos.z)) continue;
        const amount = 4 + Math.floor(this.rand() * 22);
        this.statics.push({
          id: `${category}-c${i}`,
          category,
          position: {
            x: pos.x,
            y: sampleHeight(this.terrain, pos.x, pos.z) * 80,
            z: pos.z,
          },
          label: catLabel(category, amount),
          amount,
          visible: true,
          ...labeler?.(i),
        });
      }
    };

    drop("ore-sulfur", 18, 420);
    drop("ore-metal", 14, 480);
    drop("hemp", 10, 380);
    drop("berry", 8, 360);
    drop("sleeping-bag", 4, 280, () => ({ label: "Sleeping Bag" }));
    drop("vehicle", 5, 500, (i) => ({ label: `Car ${i + 1}`, amount: i + 1 }));
    drop("dropped", 6, 300, (i) => ({
      label: i % 2 ? "Hunting Bow" : "Salvaged Sword",
    }));
    drop("loot-military", 4, 340, () => ({ label: "Semi Automatic Rifle" }));

    this.addStatic("ore-stone", 40);
    this.addStatic("ore-hqm", 8);
    this.addStatic("food", 16);
    this.addStatic("collectible", 22, (i) => ({
      label: i % 3 ? "Cloth" : "Diesel",
    }));
    this.addStatic("loot-basic", 18);
    this.addStatic("loot-elite", 3);
    this.addStatic("base", 7, () => ({ label: "Tool Cupboard" }));
    this.addStatic("animal", 9, () => ({ label: "Boar", health: 40 }));
    this.addStatic("animal-wolf", 5, () => ({ label: "Wolf", health: 50 }));
    this.addStatic("animal-bear", 2, () => ({ label: "Bear", health: 220 }));
    this.addStatic("bradley", 1, () => ({ label: "Bradley", health: 1000 }));
    this.addStatic("helicopter", 1, () => ({ label: "Patrol Heli", health: 10000 }));

    const makePlayer = (
      i: number,
      kind: "human" | "sleep" | "npc" | "admin",
    ): Actor => {
      const pos =
        kind === "human" || kind === "admin" ? scatter(520) : this.landOrRetry();
      const yaw = this.rand() * 360;
      const name =
        kind === "npc"
          ? `Scientist ${i}`
          : kind === "admin"
            ? "AdminWatch"
            : NAMES[i % NAMES.length] + (kind === "sleep" ? "" : "");
      const category: EntityCategory =
        kind === "sleep"
          ? "player-sleeping"
          : kind === "npc"
            ? "player-npc"
            : kind === "admin"
              ? "player-admin"
              : "player";
      return {
        id: `p-${kind}-${i}`,
        category,
        position: {
          x: pos.x,
          y: sampleHeight(this.terrain, pos.x, pos.z) * 80,
          z: pos.z,
        },
        label: name,
        health: kind === "sleep" ? 32 : 55 + Math.floor(this.rand() * 45),
        maxHealth: 100,
        held: kind === "sleep" ? null : WEAPONS[i % WEAPONS.length],
        yaw,
        sleeping: kind === "sleep",
        npc: kind === "npc",
        admin: kind === "admin",
        visible: true,
        vx: (this.rand() - 0.5) * 18,
        vz: (this.rand() - 0.5) * 18,
        wander: this.rand() * Math.PI * 2,
        boneHead: { x: pos.x, y: sampleHeight(this.terrain, pos.x, pos.z) * 80 + 1.72, z: pos.z },
        boneNeck: { x: pos.x, y: sampleHeight(this.terrain, pos.x, pos.z) * 80 + 1.48, z: pos.z },
        boneBody: { x: pos.x, y: sampleHeight(this.terrain, pos.x, pos.z) * 80 + 1.02, z: pos.z },
      };
    };

    for (let i = 0; i < 15; i++) this.actors.push(makePlayer(i, "human"));
    for (let i = 0; i < 21; i++) this.actors.push(makePlayer(i, "sleep"));
    for (let i = 0; i < 8; i++) this.actors.push(makePlayer(i, "npc"));
    this.actors.push(makePlayer(0, "admin"));
    this.actors.push(makePlayer(1, "admin"));
  }

  reloadMap(seed = this.seed): void {
    Object.assign(this, new WorldSim(seed, this.size));
  }

  ingestSnapshot(raw: {
    world_size?: number;
    local_player?: { position: { x: number; y: number; z: number }; health: number } | null;
    entities?: Array<{
      category: string;
      position: { x: number; y: number; z: number };
      meta?: Record<string, unknown>;
    }>;
  }): void {
    this.provider = "snapshot";
    this.dmaConnected = true;
    if (raw.local_player) {
      this.local.position = raw.local_player.position;
      this.local.health = raw.local_player.health;
    }
    const ents: Actor[] = [];
    for (let i = 0; i < (raw.entities?.length ?? 0); i++) {
      const e = raw.entities![i];
      const meta = e.meta ?? {};
      const cat = (e.category === "player-sleeping" ? "player-sleeping" : e.category) as EntityCategory;
      ents.push({
        id: `live-${i}`,
        category: cat,
        position: e.position,
        label: String(meta.name ?? e.category),
        health: typeof meta.health === "number" ? meta.health : undefined,
        held: typeof meta.held === "string" ? meta.held : null,
        sleeping: e.category === "player-sleeping",
        npc: e.category === "player-npc",
        admin: Boolean(meta.admin),
        visible: true,
        vx: 0,
        vz: 0,
        wander: 0,
      });
    }
    this.actors = ents.filter((e) => e.category.startsWith("player") || e.category.startsWith("animal") || e.category === "vehicle" || e.category === "bradley" || e.category === "helicopter");
    this.statics = ents.filter((e) => !this.actors.includes(e));
  }

  tick(dt: number, settings: AppSettings): WorldSnapshot {
    const t0 = performance.now();
    this.time += dt;
    const hacks = settings.hacks;

    this.local.airborne = hacks.spiderman ? false : Math.sin(this.time * 0.7) > 0.92;
    this.local.recoilPitch = -1.1 - Math.sin(this.time * 9) * 0.45;
    this.local.recoilYaw = Math.cos(this.time * 7) * 0.4;
    const speed = hacks.spiderman ? 28 : 16;
    this.local.position.x = clamp(
      this.local.position.x + Math.sin((this.local.yaw * Math.PI) / 180) * speed * dt * 0.15,
      0,
      this.size,
    );
    this.local.position.z = clamp(
      this.local.position.z + Math.cos((this.local.yaw * Math.PI) / 180) * speed * dt * 0.15,
      0,
      this.size,
    );
    if (!isLandAt(this.terrain, this.local.position.x, this.local.position.z)) {
      this.local.yaw = wrapDeg(this.local.yaw + 140);
    }
    this.local.position.y = sampleHeight(this.terrain, this.local.position.x, this.local.position.z) * 80;

    if (this.provider === "sim") {
      for (const a of this.actors) {
        if (a.sleeping) continue;
        a.wander += dt * (0.4 + (a.id.length % 5) * 0.05);
        a.vx = Math.cos(a.wander) * (a.npc ? 8 : 14);
        a.vz = Math.sin(a.wander) * (a.npc ? 8 : 14);
        a.position.x += a.vx * dt;
        a.position.z += a.vz * dt;
        if (!isLandAt(this.terrain, a.position.x, a.position.z)) {
          a.wander += Math.PI;
          a.position.x = clamp(a.position.x, 80, this.size - 80);
          a.position.z = clamp(a.position.z, 80, this.size - 80);
        }
        a.position.y = sampleHeight(this.terrain, a.position.x, a.position.z) * 80;
        a.yaw = (Math.atan2(a.vx, a.vz) * 180) / Math.PI;
        a.boneHead = { x: a.position.x, y: a.position.y + 1.72, z: a.position.z };
        a.boneNeck = { x: a.position.x, y: a.position.y + 1.48, z: a.position.z };
        a.boneBody = { x: a.position.x, y: a.position.y + 1.02, z: a.position.z };
        if (hacks.instantEoka && a.held === "pistol.eoka") a.held = "pistol.eoka*";
      }
    }

    const visOn = hacks.visCheckChams;
    for (const a of this.actors) {
      a.visible = visOn
        ? lineOfSight(
            this.terrain,
            this.local.position.x,
            this.local.position.z,
            a.position.x,
            a.position.z,
          )
        : true;
    }

    const entities = [...this.statics, ...this.actors];
    this.lastAim = selectAimTarget(
      this.local,
      entities,
      settings.aim,
      hacks.shootWhileJumping,
    );
    applyAim(this.local, this.lastAim, settings.aim);

    const frameMs = performance.now() - t0;
    return {
      ts: Date.now() / 1000,
      worldSize: this.size,
      seed: this.seed,
      provider: this.provider,
      dmaConnected: this.dmaConnected,
      localPlayer: this.local,
      entities,
      networkables: 4100 + (entities.length % 400),
      fps: 0,
      frameMs,
      aim: this.lastAim,
    };
  }
}

export function defaultSettings(): AppSettings {
  const loot = {
    collectibles: true,
    ores: true,
    food: true,
    hemp: true,
    berries: true,
    loot: true,
    base: true,
    misc: true,
    animals: true,
    vehicle: true,
  };
  return {
    loot,
    chams: "full-pink",
    hacks: {
      allowMemory: false,
      visCheckChams: true,
      adminEsp: true,
      interactiveCamera: true,
      adminFlag: false,
      shootWhileJumping: false,
      spiderman: false,
      brightNight: false,
      brightCaves: true,
      instantEoka: false,
    },
    aim: {
      enabled: true,
      bone: "neck",
      smoothX: 0.69,
      smoothY: 0.69,
      lockon: true,
      recoilReduction: true,
      recoilIntensity: 9,
      fov: 12,
    },
    showMenu: true,
    showLoot: true,
    showEsp: true,
    showStats: true,
    classicRadar: false,
    espRange: 250,
  };
}

export function loadSettings(): AppSettings {
  const base = defaultSettings();
  try {
    const raw = localStorage.getItem("atomicdma-settings");
    if (!raw) return base;
    const parsed = JSON.parse(raw) as Partial<AppSettings>;
    return {
      ...base,
      ...parsed,
      loot: { ...base.loot, ...parsed.loot },
      hacks: { ...base.hacks, ...parsed.hacks },
      aim: { ...base.aim, ...parsed.aim },
    };
  } catch {
    return base;
  }
}

export function saveSettings(s: AppSettings): void {
  localStorage.setItem("atomicdma-settings", JSON.stringify(s));
}

export function passesFilter(e: Entity, settings: AppSettings): boolean {
  if (e.category.startsWith("player")) return true;
  for (const key of Object.keys(FILTER_CATEGORY) as LootFilterKey[]) {
    if (FILTER_CATEGORY[key].includes(e.category)) return settings.loot[key];
  }
  return true;
}
