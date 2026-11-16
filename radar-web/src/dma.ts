import type { WorldSnapshot } from "./types";

export interface DmaStatus {
  connected: boolean;
  provider: WorldSnapshot["provider"];
  detail: string;
}

export const DEFAULT_DMA_URL = "http://127.0.0.1:1738/state";
const DMA_URL_KEY = "never-banned-dma-url";

export function loadDmaSourceUrl(): string {
  try {
    const raw = localStorage.getItem(DMA_URL_KEY);
    if (raw && raw.trim()) return raw.trim();
  } catch {
    /* ignore */
  }
  return DEFAULT_DMA_URL;
}

export function saveDmaSourceUrl(url: string): void {
  try {
    localStorage.setItem(DMA_URL_KEY, (url.trim() || DEFAULT_DMA_URL));
  } catch {
    /* ignore */
  }
}

/** Accept `http://127.0.0.1:1738` and append `/state`. */
export function normalizeDmaUrl(raw: string): string {
  const text = raw.trim() || DEFAULT_DMA_URL;
  if (text.startsWith("/")) {
    return text.endsWith("/state") || text.endsWith("/state/") ? text.replace(/\/$/, "") : `${text.replace(/\/$/, "")}/state`;
  }
  try {
    const u = new URL(text);
    if (!u.pathname || u.pathname === "/") u.pathname = "/state";
    return u.toString();
  } catch {
    return text;
  }
}

export function mapUrlFromStateUrl(stateUrl: string): string | null {
  const url = normalizeDmaUrl(stateUrl);
  if (url.startsWith("/")) {
    return url.replace(/\/state\/?$/, "/map");
  }
  try {
    const u = new URL(url);
    const host = (u.hostname || "").toLowerCase();
    if (u.protocol !== "http:" || (host !== "127.0.0.1" && host !== "localhost")) return null;
    u.pathname = u.pathname.replace(/\/state\/?$/, "/map");
    if (!u.pathname.endsWith("/map")) u.pathname = `${u.pathname.replace(/\/$/, "")}/map`;
    u.search = "";
    u.hash = "";
    return u.toString();
  } catch {
    return null;
  }
}

function isLiveSnapshot(j: Record<string, unknown>): boolean {
  if (!Array.isArray(j.entities)) return false;
  if (j.dmaConnected === true) return true;
  const provider = j.provider;
  if (provider === "memprocfs" || provider === "ft601" || provider === "snapshot") return true;
  if (j.local_player && typeof j.local_player === "object") return true;
  return j.entities.length > 0;
}

export async function probeDma(sourceUrl: string): Promise<DmaStatus> {
  const url = normalizeDmaUrl(sourceUrl);
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(800) });
    if (!r.ok) {
      return { connected: false, provider: "sim", detail: `SIM — ${url} HTTP ${r.status}` };
    }
    const j = (await r.json()) as Record<string, unknown>;
    if (isLiveSnapshot(j)) {
      return {
        connected: true,
        provider: (j.provider as DmaStatus["provider"]) ?? "snapshot",
        detail: url,
      };
    }
    const ft = j.ft601 as { usb?: boolean; magic_ok?: boolean } | undefined;
    if (ft?.magic_ok) {
      return { connected: false, provider: "sim", detail: `SIM — MAGIC ok, no snapshot at ${url}` };
    }
    if (ft?.usb) {
      return { connected: false, provider: "sim", detail: `SIM — FT601 USB, no snapshot at ${url}` };
    }
    return { connected: false, provider: "sim", detail: `SIM — no live snapshot at ${url}` };
  } catch {
    return { connected: false, provider: "sim", detail: `SIM — no bridge at ${url}` };
  }
}

export async function pullSnapshot(sourceUrl: string): Promise<Record<string, unknown> | null> {
  const url = normalizeDmaUrl(sourceUrl);
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(800) });
    if (!r.ok) return null;
    const j = (await r.json()) as Record<string, unknown>;
    return Array.isArray(j.entities) ? j : null;
  } catch {
    return null;
  }
}
