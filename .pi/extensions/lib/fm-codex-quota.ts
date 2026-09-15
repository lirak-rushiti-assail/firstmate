import { spawn, type ChildProcess } from "node:child_process";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const STATUS_KEY = "firstmate-codex-quota";
const UNAVAILABLE = "Codex quota unavailable";
const REFRESH_MS = 60_000;
const TIMEOUT_MS = 8_000;
const MAX_OUTPUT_BYTES = 1024 * 1024;
const INSTALL_KEY = "__firstmateCodexQuotaIndicatorInstalled";

type PiModelLike = {
  provider?: unknown;
  id?: unknown;
};

type RawQuotaWindow = {
  id?: unknown;
  label?: unknown;
  kind?: unknown;
  resetsAt?: unknown;
  percentUsed?: unknown;
  percentRemaining?: unknown;
  windowSeconds?: unknown;
};

type RawCodexProvider = {
  provider?: unknown;
  state?: { status?: unknown; stale?: unknown };
  windows?: unknown;
};

export type CodexQuotaWindow = {
  label: "5h" | "1w";
  usedPercent: number;
  resetsAt: string;
};

export type CodexQuotaReading = {
  fiveHour: CodexQuotaWindow;
  oneWeek: CodexQuotaWindow;
};

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function asNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function clampPercent(value: number): number {
  return Math.max(0, Math.min(100, value));
}

function usedPercent(window: RawQuotaWindow): number | undefined {
  const used = asNumber(window.percentUsed);
  if (used !== undefined) return clampPercent(used);
  const remaining = asNumber(window.percentRemaining);
  if (remaining === undefined) return undefined;
  return clampPercent(100 - remaining);
}

function resetTime(window: RawQuotaWindow): string | undefined {
  const resetsAt = asString(window.resetsAt);
  if (!resetsAt || Number.isNaN(Date.parse(resetsAt))) return undefined;
  return resetsAt;
}

function scoreFiveHour(window: RawQuotaWindow): number {
  const id = asString(window.id).toLowerCase();
  const label = asString(window.label).toLowerCase();
  const seconds = asNumber(window.windowSeconds);
  let score = 0;
  if (seconds === 18_000) score += 100;
  if (/(^|:)5h$/.test(id)) score += 80;
  if (label.includes("session")) score += 10;
  return score;
}

function scoreOneWeek(window: RawQuotaWindow): number {
  const id = asString(window.id).toLowerCase();
  const label = asString(window.label).toLowerCase();
  const kind = asString(window.kind).toLowerCase();
  const seconds = asNumber(window.windowSeconds);
  let score = 0;
  if (id === "weekly") score += 500;
  if (kind === "weekly") score += 300;
  if (seconds === 604_800) score += 100;
  if (/(^|:)(7d|week|weekly)$/.test(id)) score += 50;
  if (label.includes("week")) score += 10;
  return score;
}

function selectWindow(
  windows: RawQuotaWindow[],
  score: (window: RawQuotaWindow) => number,
): RawQuotaWindow | undefined {
  let selected: RawQuotaWindow | undefined;
  let selectedScore = 0;
  for (const window of windows) {
    if (usedPercent(window) === undefined || resetTime(window) === undefined) continue;
    const currentScore = score(window);
    if (currentScore > selectedScore) {
      selected = window;
      selectedScore = currentScore;
    }
  }
  return selected;
}

function quotaWindow(label: "5h" | "1w", window: RawQuotaWindow): CodexQuotaWindow | undefined {
  const used = usedPercent(window);
  const reset = resetTime(window);
  if (used === undefined || reset === undefined) return undefined;
  return { label, usedPercent: used, resetsAt: reset };
}

export function isCodexPiModel(model: unknown): boolean {
  if (typeof model === "string") {
    const name = model.toLowerCase();
    return name.startsWith("openai-codex/") || name.startsWith("codex-native/");
  }
  if (!model || typeof model !== "object") return false;
  const candidate = model as PiModelLike;
  const provider = asString(candidate.provider).toLowerCase();
  const id = asString(candidate.id).toLowerCase();
  if (provider === "codex" || provider === "openai-codex" || provider === "codex-native") return true;
  if (id.startsWith("openai-codex/") || id.startsWith("codex-native/")) return true;
  return `${provider}/${id}`.startsWith("openai-codex/") || `${provider}/${id}`.startsWith("codex-native/");
}

export function parseCodexQuota(payload: unknown): CodexQuotaReading | undefined {
  const root = typeof payload === "string" ? JSON.parse(payload) : payload;
  if (!root || typeof root !== "object") return undefined;
  const providers = (root as { providers?: unknown }).providers;
  if (!Array.isArray(providers)) return undefined;
  const provider = providers.find((item): item is RawCodexProvider =>
    Boolean(item) && typeof item === "object" && (item as RawCodexProvider).provider === "codex",
  );
  if (!provider || !Array.isArray(provider.windows)) return undefined;
  if (provider.state?.status !== undefined && provider.state.status !== "fresh") return undefined;
  if (provider.state?.stale === true) return undefined;

  const windows = provider.windows.filter((item): item is RawQuotaWindow =>
    Boolean(item) && typeof item === "object",
  );
  const fiveHour = selectWindow(windows, scoreFiveHour);
  const oneWeek = selectWindow(windows, scoreOneWeek);
  if (!fiveHour || !oneWeek) return undefined;
  const fiveHourQuota = quotaWindow("5h", fiveHour);
  const oneWeekQuota = quotaWindow("1w", oneWeek);
  if (!fiveHourQuota || !oneWeekQuota) return undefined;
  return { fiveHour: fiveHourQuota, oneWeek: oneWeekQuota };
}

function twoDigits(value: number): string {
  return String(value).padStart(2, "0");
}

export function formatResetTime(resetsAt: string, now = new Date()): string {
  const reset = new Date(resetsAt);
  if (Number.isNaN(reset.getTime())) return "unknown";
  const resetDate = `${reset.getUTCFullYear()}-${twoDigits(reset.getUTCMonth() + 1)}-${twoDigits(reset.getUTCDate())}`;
  const nowDate = `${now.getUTCFullYear()}-${twoDigits(now.getUTCMonth() + 1)}-${twoDigits(now.getUTCDate())}`;
  const time = `${twoDigits(reset.getUTCHours())}:${twoDigits(reset.getUTCMinutes())}Z`;
  return resetDate === nowDate ? time : `${resetDate} ${time}`;
}

export function formatPercent(value: number): string {
  const rounded = Math.round(clampPercent(value) * 10) / 10;
  return Number.isInteger(rounded) ? `${rounded}%` : `${rounded.toFixed(1)}%`;
}

export function formatCodexQuota(reading: CodexQuotaReading, now = new Date()): string {
  return `Codex 5h ${formatPercent(reading.fiveHour.usedPercent)} used reset ${formatResetTime(reading.fiveHour.resetsAt, now)} | 1w ${formatPercent(reading.oneWeek.usedPercent)} used reset ${formatResetTime(reading.oneWeek.resetsAt, now)}`;
}

export function codexQuotaStatusText(model: unknown, reading: CodexQuotaReading | undefined, now = new Date()): string | undefined {
  if (!isCodexPiModel(model)) return undefined;
  return reading ? formatCodexQuota(reading, now) : UNAVAILABLE;
}

function readQuotaAxiJson(): Promise<string> {
  return new Promise((resolve, reject) => {
    let child: ChildProcess;
    try {
      child = spawn("quota-axi", ["--provider", "codex", "--json"], {
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      reject(error);
      return;
    }

    let stdout = "";
    let stderr = "";
    let bytes = 0;
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const finish = (error?: Error): void => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      if (error) reject(error);
      else resolve(stdout);
    };
    timer = setTimeout(() => {
      child.kill("SIGTERM");
      finish(new Error("quota-axi timed out"));
    }, TIMEOUT_MS);
    timer.unref();

    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => {
      bytes += Buffer.byteLength(chunk, "utf8");
      if (bytes > MAX_OUTPUT_BYTES) {
        child.kill("SIGTERM");
        finish(new Error("quota-axi output exceeded limit"));
        return;
      }
      stdout += chunk;
    });
    child.stderr?.setEncoding("utf8");
    child.stderr?.on("data", (chunk: string) => {
      stderr += chunk;
    });
    child.on("error", (error) => finish(error));
    child.on("close", (code) => {
      if (code === 0) finish();
      else finish(new Error(stderr.trim() || `quota-axi exited ${code ?? "without status"}`));
    });
  });
}

function modelFromContext(ctx: ExtensionContext): PiModelLike | undefined {
  return (ctx.model as PiModelLike | undefined) ?? {
    provider: process.env.PI_PROVIDER,
    id: process.env.PI_MODEL,
  };
}

export function installCodexQuotaIndicator(pi: ExtensionAPI): void {
  const globalState = globalThis as typeof globalThis & Record<string, boolean | undefined>;
  if (globalState[INSTALL_KEY]) return;
  globalState[INSTALL_KEY] = true;

  let ctx: ExtensionContext | undefined;
  let timer: ReturnType<typeof setInterval> | undefined;
  let refreshing = false;
  let generation = 0;

  const clear = (target: ExtensionContext): void => target.ui.setStatus(STATUS_KEY, undefined);

  const publish = (target: ExtensionContext, text: string, unavailable = false): void => {
    if (target !== ctx || !target.hasUI || !isCodexPiModel(modelFromContext(target))) return;
    target.ui.setStatus(STATUS_KEY, target.ui.theme.fg(unavailable ? "warning" : "dim", text));
  };

  const refresh = async (target: ExtensionContext, refreshGeneration: number): Promise<void> => {
    if (refreshing || refreshGeneration !== generation || !target.hasUI || !isCodexPiModel(modelFromContext(target))) return;
    refreshing = true;
    try {
      const reading = parseCodexQuota(await readQuotaAxiJson());
      if (refreshGeneration === generation) {
        publish(target, codexQuotaStatusText(modelFromContext(target), reading) ?? UNAVAILABLE, !reading);
      }
    } catch {
      if (refreshGeneration === generation) publish(target, UNAVAILABLE, true);
    } finally {
      refreshing = false;
      if (refreshGeneration !== generation && ctx && isCodexPiModel(modelFromContext(ctx))) {
        void refresh(ctx, generation);
      }
    }
  };

  const stopTimer = (): void => {
    if (timer) clearInterval(timer);
    timer = undefined;
  };

  const startTimer = (): void => {
    if (timer) return;
    timer = setInterval(() => {
      if (ctx) void refresh(ctx, generation);
    }, REFRESH_MS);
    timer.unref();
  };

  const apply = (target: ExtensionContext): void => {
    ctx = target;
    generation += 1;
    if (!target.hasUI || !isCodexPiModel(modelFromContext(target))) {
      stopTimer();
      clear(target);
      return;
    }
    publish(target, "Codex quota …");
    startTimer();
    void refresh(target, generation);
  };

  pi.on("session_start", (_event, target) => apply(target));
  pi.on("model_select", (_event, target) => apply(target));
  pi.on("session_shutdown", (_event, target) => {
    stopTimer();
    clear(target);
    ctx = undefined;
    globalState[INSTALL_KEY] = undefined;
  });
}
