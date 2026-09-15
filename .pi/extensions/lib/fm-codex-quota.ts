import { spawn, type ChildProcess } from "node:child_process";
import { mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const STATUS_KEY = "firstmate-codex-quota";
const UNAVAILABLE = "Codex quota unavailable";
const MISSING_WINDOW = "no window";
const REFRESH_MS = 60_000;
const QUOTA_TTL_MS = 60_000;
const STALE_AFTER_MS = 2 * QUOTA_TTL_MS;
const LOCK_STALE_MS = 30_000;
const TIMEOUT_MS = 8_000;
const MAX_OUTPUT_BYTES = 1024 * 1024;
const INSTALL_KEY = "__firstmateCodexQuotaIndicatorInstalled";
const CODEX_PROVIDERS = ["openai-codex", "codex-native"];

type PiModelLike = {
  provider?: unknown;
  id?: unknown;
};

type RawQuotaWindow = {
  id?: unknown;
  label?: unknown;
  kind?: unknown;
  resetsAt?: unknown;
  percentRemaining?: unknown;
};

type RawScope = {
  scope?: unknown;
  boundedBy?: unknown;
};

type RawCodexProvider = {
  provider?: unknown;
  state?: { status?: unknown; stale?: unknown };
  windows?: unknown;
  quotaSemantics?: { effectiveAvailability?: unknown };
};

export type CodexQuotaWindow = {
  label: "5h" | "1w";
  usedPercent: number;
  resetsAt: string;
};

export type CodexQuotaReading = {
  fiveHour?: CodexQuotaWindow;
  oneWeek?: CodexQuotaWindow;
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
  const remaining = asNumber(window.percentRemaining);
  if (remaining === undefined) return undefined;
  return clampPercent(100 - remaining);
}

function resetTime(window: RawQuotaWindow): string | undefined {
  const resetsAt = asString(window.resetsAt);
  if (!resetsAt || Number.isNaN(Date.parse(resetsAt))) return undefined;
  return resetsAt;
}

function isFiveHourWindow(window: RawQuotaWindow): boolean {
  return /(^|:)5h$/.test(asString(window.id).toLowerCase());
}

function isOneWeekWindow(window: RawQuotaWindow): boolean {
  if (asString(window.kind).toLowerCase() === "weekly") return true;
  return /(^|:)(7d|weekly)$/.test(asString(window.id).toLowerCase());
}

function mostConstraining(
  windows: RawQuotaWindow[],
  matches: (window: RawQuotaWindow) => boolean,
): RawQuotaWindow | undefined {
  const candidates = windows
    .filter((window) => matches(window) && usedPercent(window) !== undefined && resetTime(window) !== undefined)
    .sort((left, right) => {
      const byUsed = (usedPercent(right) ?? 0) - (usedPercent(left) ?? 0);
      if (byUsed !== 0) return byUsed;
      const byReset = Date.parse(resetTime(left) ?? "") - Date.parse(resetTime(right) ?? "");
      if (byReset !== 0) return byReset;
      return asString(left.id).localeCompare(asString(right.id));
    });
  return candidates[0];
}

function quotaWindow(label: "5h" | "1w", window: RawQuotaWindow | undefined): CodexQuotaWindow | undefined {
  if (!window) return undefined;
  const used = usedPercent(window);
  const reset = resetTime(window);
  if (used === undefined || reset === undefined) return undefined;
  return { label, usedPercent: used, resetsAt: reset };
}

export function isCodexPiModel(model: unknown): boolean {
  if (!model || typeof model !== "object") return false;
  return CODEX_PROVIDERS.includes(asString((model as PiModelLike).provider).toLowerCase());
}

export function codexModelId(model: unknown): string {
  return asString((model as PiModelLike | null | undefined)?.id).toLowerCase();
}

function parseJson(payload: unknown): unknown {
  return typeof payload === "string" ? JSON.parse(payload) : payload;
}

function codexProvider(quotaPayload: unknown): RawCodexProvider | undefined {
  const root = parseJson(quotaPayload);
  if (!root || typeof root !== "object") return undefined;
  const providers = (root as { providers?: unknown }).providers;
  if (!Array.isArray(providers)) return undefined;
  const provider = providers.find((item): item is RawCodexProvider =>
    Boolean(item) && typeof item === "object" && (item as RawCodexProvider).provider === "codex",
  );
  if (!provider || !Array.isArray(provider.windows)) return undefined;
  if (provider.state?.status !== undefined && provider.state.status !== "fresh") return undefined;
  if (provider.state?.stale === true) return undefined;
  return provider;
}

/**
 * Window ids of the account-wide `all_models` scope. Every model in the Codex
 * family is bound by these, which is what lets the weekly limit render for a Pi
 * model that owns no model-level window of its own.
 */
function accountWindowIds(provider: RawCodexProvider): string[] {
  const scopes = provider.quotaSemantics?.effectiveAvailability;
  if (!Array.isArray(scopes)) return [];
  const account = scopes.find((item): item is RawScope =>
    Boolean(item) && typeof item === "object" && asString((item as RawScope).scope) === "all_models",
  );
  const boundedBy = account?.boundedBy;
  if (!Array.isArray(boundedBy)) return [];
  return boundedBy.filter((id): id is string => typeof id === "string");
}

/**
 * The Pi model id a model-level window names in its own label, so a window is
 * only ever attributed to the model quota-axi itself says it belongs to.
 * "GPT-5.3-Codex-Spark session" names gpt-5.3-codex-spark.
 */
function windowModelId(window: RawQuotaWindow): string {
  return asString(window.label)
    .toLowerCase()
    .replace(/\s+(session|week|weekly)$/, "")
    .trim()
    .replace(/[\s_]+/g, "-");
}

export function resolveCodexQuota(quotaPayload: unknown, model: unknown): CodexQuotaReading | undefined {
  const provider = codexProvider(quotaPayload);
  if (!provider) return undefined;
  const windows = (provider.windows as unknown[]).filter(
    (item): item is RawQuotaWindow => Boolean(item) && typeof item === "object",
  );
  const accountIds = accountWindowIds(provider);
  const activeId = codexModelId(model);
  const applicable = windows.filter(
    (window) =>
      accountIds.includes(asString(window.id)) || (activeId !== "" && windowModelId(window) === activeId),
  );
  const fiveHour = quotaWindow("5h", mostConstraining(applicable, isFiveHourWindow));
  const oneWeek = quotaWindow("1w", mostConstraining(applicable, isOneWeekWindow));
  if (!fiveHour && !oneWeek) return undefined;
  return { fiveHour, oneWeek };
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

export function formatAge(ageMs: number): string {
  const seconds = Math.max(0, Math.round(ageMs / 1000));
  if (seconds < 90) return `${seconds}s`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 90) return `${minutes}m`;
  return `${Math.round(minutes / 60)}h`;
}

function formatWindow(label: "5h" | "1w", window: CodexQuotaWindow | undefined, now: Date): string {
  if (!window) return `${label} ${MISSING_WINDOW}`;
  return `${label} ${formatPercent(window.usedPercent)} used reset ${formatResetTime(window.resetsAt, now)}`;
}

export function formatCodexQuota(reading: CodexQuotaReading, now = new Date(), ageMs = 0): string {
  const text = `Codex ${formatWindow("5h", reading.fiveHour, now)} | ${formatWindow("1w", reading.oneWeek, now)}`;
  return ageMs >= STALE_AFTER_MS ? `${text} (stale ${formatAge(ageMs)})` : text;
}

export function codexQuotaStatusText(
  model: unknown,
  reading: CodexQuotaReading | undefined,
  now = new Date(),
  ageMs = 0,
): string | undefined {
  if (!isCodexPiModel(model)) return undefined;
  return reading ? formatCodexQuota(reading, now, ageMs) : UNAVAILABLE;
}

function readQuotaAxiJson(args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    let child: ChildProcess;
    try {
      child = spawn("quota-axi", args, {
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

type CacheEntry = { text: string; ageMs: number };

export function codexQuotaCacheDir(): string {
  const base = asString(process.env.XDG_CACHE_HOME) || join(homedir(), ".cache");
  return join(base, "firstmate");
}

function readCache(file: string): CacheEntry | undefined {
  try {
    const age = Date.now() - statSync(file).mtimeMs;
    return { text: readFileSync(file, "utf8"), ageMs: Math.max(0, age) };
  } catch {
    return undefined;
  }
}

function writeCache(file: string, text: string): void {
  const tmp = `${file}.${process.pid}.tmp`;
  try {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(tmp, text);
    renameSync(tmp, file);
  } catch {
    try {
      rmSync(tmp, { force: true });
    } catch {
      /* the temp file is best-effort cleanup only */
    }
  }
}

function acquireLock(file: string): boolean {
  const lock = `${file}.lock`;
  try {
    mkdirSync(lock);
    return true;
  } catch {
    try {
      if (Date.now() - statSync(lock).mtimeMs <= LOCK_STALE_MS) return false;
      rmSync(lock, { recursive: true, force: true });
      mkdirSync(lock);
      return true;
    } catch {
      return false;
    }
  }
}

function releaseLock(file: string): void {
  try {
    rmSync(`${file}.lock`, { recursive: true, force: true });
  } catch {
    /* a leaked lock expires on its own after LOCK_STALE_MS */
  }
}

/**
 * One bounded refresh path shared by every Pi session on this host: a fresh
 * cache entry is reused as is, and only the lock holder spawns quota-axi while
 * the others read the last snapshot and report its age.
 */
export async function cachedQuotaAxiJson(name: string, ttlMs: number, args: string[]): Promise<CacheEntry> {
  const file = join(codexQuotaCacheDir(), name);
  const cached = readCache(file);
  if (cached && cached.ageMs <= ttlMs) return cached;
  try {
    mkdirSync(dirname(file), { recursive: true });
  } catch {
    /* an unwritable cache directory still allows a direct read below */
  }
  if (!acquireLock(file)) {
    if (cached) return cached;
    throw new Error("quota-axi refresh is already in flight");
  }
  try {
    const text = await readQuotaAxiJson(args);
    writeCache(file, text);
    return { text, ageMs: 0 };
  } catch (error) {
    if (cached) return cached;
    throw error;
  } finally {
    releaseLock(file);
  }
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
    if (target !== ctx || !target.hasUI || !isCodexPiModel(target.model)) return;
    target.ui.setStatus(STATUS_KEY, target.ui.theme.fg(unavailable ? "warning" : "dim", text));
  };

  const refresh = async (target: ExtensionContext, refreshGeneration: number): Promise<void> => {
    if (refreshing || refreshGeneration !== generation || !target.hasUI || !isCodexPiModel(target.model)) return;
    refreshing = true;
    try {
      const quota = await cachedQuotaAxiJson("codex-quota.json", QUOTA_TTL_MS, ["--provider", "codex", "--json", "--no-credential-refresh"]);
      const reading = resolveCodexQuota(quota.text, target.model);
      if (refreshGeneration === generation) {
        publish(target, codexQuotaStatusText(target.model, reading, new Date(), quota.ageMs) ?? UNAVAILABLE, !reading);
      }
    } catch {
      if (refreshGeneration === generation) publish(target, UNAVAILABLE, true);
    } finally {
      refreshing = false;
      if (refreshGeneration !== generation && ctx && isCodexPiModel(ctx.model)) {
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
    if (!target.hasUI || !isCodexPiModel(target.model)) {
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
