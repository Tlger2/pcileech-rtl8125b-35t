import type { WorldSnapshot } from "./types";

export interface DmaStatus {
  connected: boolean;
  provider: WorldSnapshot["provider"];
  detail: string;
}

const SNAPSHOT_URLS = [
  "/api/state",
  "http://127.0.0.1:8080/state",
  "http://127.0.0.1:1738/state",
];

export async function probeDma(): Promise<DmaStatus> {
  for (const url of SNAPSHOT_URLS) {
    try {
      const r = await fetch(url, { signal: AbortSignal.timeout(400) });
      if (!r.ok) continue;
      const j = (await r.json()) as { entities?: unknown[]; provider?: string };
      if (Array.isArray(j.entities)) {
        return {
          connected: true,
          provider: (j.provider as DmaStatus["provider"]) ?? "snapshot",
          detail: url,
        };
      }
    } catch {
      /* next */
    }
  }
  return { connected: false, provider: "sim", detail: "sim world — no DMA bridge" };
}

export async function pullSnapshot(): Promise<Record<string, unknown> | null> {
  for (const url of SNAPSHOT_URLS) {
    try {
      const r = await fetch(url, { signal: AbortSignal.timeout(400) });
      if (!r.ok) continue;
      return (await r.json()) as Record<string, unknown>;
    } catch {
      /* next */
    }
  }
  return null;
}
