import { clamp, lerp, shortestDeg, wrapDeg } from "./rng";
import type { AimSettings, AimSolution, Bone, Entity, LocalPlayer } from "./types";

const BONE_Z: Record<Bone, number> = {
  head: 1.72,
  neck: 1.48,
  body: 1.02,
};

export function boneWorld(entity: Entity, bone: Bone) {
  if (bone === "head" && entity.boneHead) return entity.boneHead;
  if (bone === "neck" && entity.boneNeck) return entity.boneNeck;
  if (bone === "body" && entity.boneBody) return entity.boneBody;
  return {
    x: entity.position.x,
    y: entity.position.y + BONE_Z[bone],
    z: entity.position.z,
  };
}

export function lookAngles(from: { x: number; y: number; z: number }, to: { x: number; y: number; z: number }) {
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  const dz = to.z - from.z;
  const horiz = Math.hypot(dx, dz);
  const yaw = (Math.atan2(dx, dz) * 180) / Math.PI;
  const pitch = (-Math.atan2(dy, horiz) * 180) / Math.PI;
  return { pitch, yaw, distance: Math.hypot(dx, dy, dz) };
}

export function angularFov(
  viewPitch: number,
  viewYaw: number,
  targetPitch: number,
  targetYaw: number,
): number {
  return Math.hypot(shortestDeg(viewPitch, targetPitch), shortestDeg(viewYaw, targetYaw));
}

export function selectAimTarget(
  local: LocalPlayer,
  entities: Entity[],
  settings: AimSettings,
  airborneOk: boolean,
): AimSolution {
  const t0 = performance.now();
  const empty: AimSolution = {
    targetId: null,
    bone: settings.bone,
    world: null,
    pitch: local.pitch,
    yaw: local.yaw,
    deltaPitch: 0,
    deltaYaw: 0,
    fov: 0,
    distance: 0,
    locked: false,
    elapsedMs: 0,
  };
  if (!settings.enabled) {
    empty.elapsedMs = performance.now() - t0;
    return empty;
  }
  if (local.airborne && !airborneOk) {
    empty.elapsedMs = performance.now() - t0;
    return empty;
  }

  const eye = {
    x: local.position.x,
    y: local.position.y + 1.62,
    z: local.position.z,
  };

  let best: { e: Entity; fov: number; dist: number; world: { x: number; y: number; z: number }; pitch: number; yaw: number } | null = null;

  for (const e of entities) {
    if (e.local) continue;
    if (e.category !== "player" && e.category !== "player-admin" && e.category !== "player-npc") continue;
    if (e.sleeping || e.health === 0) continue;
    if (e.visible === false) continue;
    const world = boneWorld(e, settings.bone);
    const look = lookAngles(eye, world);
    const fov = angularFov(local.pitch, local.yaw, look.pitch, look.yaw);
    if (fov > settings.fov) continue;
    if (!best || fov < best.fov || (Math.abs(fov - best.fov) < 0.4 && look.distance < best.dist)) {
      best = { e, fov, dist: look.distance, world, pitch: look.pitch, yaw: look.yaw };
    }
  }

  if (!best) {
    empty.elapsedMs = performance.now() - t0;
    return empty;
  }

  let targetPitch = best.pitch;
  let targetYaw = best.yaw;
  if (settings.recoilReduction) {
    const k = clamp(settings.recoilIntensity / 12, 0, 1);
    targetPitch += local.recoilPitch * k;
    targetYaw += local.recoilYaw * k;
  }

  const dp = shortestDeg(local.pitch, targetPitch);
  const dy = shortestDeg(local.yaw, targetYaw);
  const sx = clamp(settings.smoothX, 0.05, 1);
  const sy = clamp(settings.smoothY, 0.05, 1);
  const outPitch = wrapDeg(local.pitch + dp * sx);
  const outYaw = wrapDeg(local.yaw + dy * sy);
  const locked = settings.lockon && best.fov < 4.5;

  return {
    targetId: best.e.id,
    bone: settings.bone,
    world: best.world,
    pitch: outPitch,
    yaw: outYaw,
    deltaPitch: shortestDeg(local.pitch, outPitch),
    deltaYaw: shortestDeg(local.yaw, outYaw),
    fov: best.fov,
    distance: best.dist,
    locked,
    elapsedMs: performance.now() - t0,
  };
}

export function applyAim(local: LocalPlayer, aim: AimSolution, settings: AimSettings): void {
  if (!settings.enabled || !aim.targetId) return;
  local.pitch = lerp(local.pitch, aim.pitch, 1);
  local.yaw = lerp(local.yaw, aim.yaw, 1);
}
