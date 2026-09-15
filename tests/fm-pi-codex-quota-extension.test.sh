#!/usr/bin/env bash
# Tests for the Firstmate Pi Codex quota status extension.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-codex-quota.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# A stub quota-axi that records every invocation, so the shared-cache assertion
# below measures real subprocess fanout rather than the extension's own bookkeeping.
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/cache"
cat > "$TMP_ROOT/bin/quota-axi" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_QUOTA_AXI_CALLS"
printf '{"schemaVersion":5,"providers":[]}\n'
STUB
chmod +x "$TMP_ROOT/bin/quota-axi"

out=$(EXT="$ROOT/.pi/extensions/lib/fm-codex-quota.ts" \
  PATH="$TMP_ROOT/bin:$PATH" \
  FM_CODEX_QUOTA_CACHE_DIR="$TMP_ROOT/cache" \
  FM_QUOTA_AXI_CALLS="$TMP_ROOT/calls" \
  node --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const quota = await import(pathToFileURL(process.env.EXT).href);
const now = new Date("2026-09-15T10:00:00.000Z");

assert.equal(quota.isCodexPiModel({ provider: "openai-codex", id: "gpt-5.3-codex" }), true);
assert.equal(quota.isCodexPiModel({ provider: "codex-native", id: "gpt-6-astra" }), true);
assert.equal(quota.isCodexPiModel({ provider: "openai", id: "openai-codex/gpt-5.3-codex" }), true);
assert.equal(quota.isCodexPiModel("codex-native/gpt-6-astra"), true);
assert.equal(quota.isCodexPiModel({ provider: "openai", id: "gpt-5.5" }), false);
// "codex" is not a Pi provider id, and a bare id never names a Codex model on its own.
assert.equal(quota.isCodexPiModel({ provider: "codex", id: "gpt-5.3-codex" }), false);
assert.equal(quota.isCodexPiModel({ provider: "openai", id: "codex" }), false);
assert.equal(quota.codexQuotaStatusText({ provider: "openai", id: "gpt-5.5" }, undefined, now), undefined);

// The shapes quota-axi actually emits: per-model windows plus an account-wide one,
// and the models join that says which windows bound each model.
const quotaPayload = {
  schemaVersion: 5,
  providers: [{
    provider: "codex",
    state: { status: "fresh", stale: false },
    windows: [
      { id: "weekly", label: "week", kind: "weekly", resetsAt: "2026-09-20T12:20:26.000Z", percentRemaining: 86 },
      { id: "model:codex_bengalfox:5h", label: "GPT-5.3-Codex session", kind: "model", resetsAt: "2026-09-15T15:31:42.000Z", percentRemaining: 75 },
      { id: "model:codex_bengalfox:7d", label: "GPT-5.3-Codex week", kind: "model", resetsAt: "2026-09-22T10:31:42.000Z", percentUsed: 3 },
      { id: "model:base_model_inference:7d", label: "gpt-reserve week", kind: "model", resetsAt: "2026-09-17T18:26:52.000Z", percentUsed: 99 },
    ],
  }],
};
const modelsPayload = {
  models: [
    {
      provider: "codex",
      id: "gpt-5.3-codex",
      effective: { boundedBy: ["weekly", "model:codex_bengalfox:5h", "model:codex_bengalfox:7d"] },
    },
    { provider: "codex", id: "gpt-5.1-codex", effective: { boundedBy: ["weekly"] } },
    { provider: "claude", id: "claude-opus-4-5", quotaScopes: [] },
  ],
};

const scoped = quota.resolveCodexQuota(quotaPayload, modelsPayload, { provider: "openai-codex", id: "gpt-5.3-codex" });
assert.ok(scoped);
assert.equal(scoped.fiveHour.usedPercent, 25);
assert.equal(
  quota.formatCodexQuota(scoped, now),
  "Codex 5h 25% used reset 15:31Z | 1w 14% used reset 2026-09-20 12:20Z",
);
// The gpt-reserve week is 99% used but does not bound this model, so it must not
// be reported as the session's one-week limit.
assert.equal(scoped.oneWeek.resetsAt, "2026-09-20T12:20:26.000Z");

// A model bounded only by the account-wide weekly window has no five-hour window.
const weeklyOnly = quota.resolveCodexQuota(quotaPayload, modelsPayload, { provider: "openai-codex", id: "gpt-5.1-codex" });
assert.ok(weeklyOnly);
assert.equal(weeklyOnly.fiveHour, undefined);
assert.equal(
  quota.formatCodexQuota(weeklyOnly, now),
  "Codex 5h no window | 1w 14% used reset 2026-09-20 12:20Z",
);

// A model the catalog does not describe reports unavailable instead of borrowing
// another model's windows.
assert.equal(quota.resolveCodexQuota(quotaPayload, modelsPayload, { provider: "openai-codex", id: "gpt-9-unknown" }), undefined);
assert.equal(
  quota.codexQuotaStatusText({ provider: "openai-codex", id: "gpt-9-unknown" }, undefined, now),
  "Codex quota unavailable",
);

// A prefixed Pi model id resolves to the same catalog entry as the bare one.
assert.equal(quota.codexModelId("openai-codex/gpt-5.3-codex"), "gpt-5.3-codex");
assert.deepEqual(
  quota.codexScopeWindowIds(modelsPayload, { provider: "openai", id: "openai-codex/gpt-5.1-codex" }),
  ["weekly"],
);

// Stale provider state and unparseable payloads fail closed.
assert.equal(quota.resolveCodexQuota({ providers: [{ provider: "codex", state: { status: "auth_required" }, windows: [] }] }, modelsPayload, { provider: "openai-codex", id: "gpt-5.3-codex" }), undefined);
assert.equal(quota.resolveCodexQuota({ providers: [{ provider: "codex", state: { status: "fresh", stale: true }, windows: [] }] }, modelsPayload, { provider: "openai-codex", id: "gpt-5.3-codex" }), undefined);

assert.equal(quota.formatPercent(12.34), "12.3%");
assert.equal(quota.formatResetTime("2026-09-15T12:00:00.000Z", now), "12:00Z");
assert.equal(quota.formatResetTime("not-a-time", now), "unknown");
assert.equal(
  quota.formatCodexQuota(scoped, now, 600_000),
  "Codex 5h 25% used reset 15:31Z | 1w 14% used reset 2026-09-20 12:20Z (stale 10m)",
);

// Every session shares one host-local snapshot: a second read inside the TTL
// must not spawn quota-axi again.
const first = await quota.cachedQuotaAxiJson("codex-quota.json", 60_000, ["--provider", "codex", "--json"]);
const second = await quota.cachedQuotaAxiJson("codex-quota.json", 60_000, ["--provider", "codex", "--json"]);
assert.equal(first.text, second.text);
assert.equal(second.ageMs < 60_000, true);
assert.equal(readFileSync(process.env.FM_QUOTA_AXI_CALLS, "utf8").trim().split("\n").length, 1);

// An expired entry refreshes, and a concurrent pair still spawns only once more
// because the loser of the refresh lock serves the previous snapshot.
const [a, b] = await Promise.all([
  quota.cachedQuotaAxiJson("codex-quota.json", -1, ["--provider", "codex", "--json"]),
  quota.cachedQuotaAxiJson("codex-quota.json", -1, ["--provider", "codex", "--json"]),
]);
assert.ok(a.text);
assert.ok(b.text);
assert.equal(readFileSync(process.env.FM_QUOTA_AXI_CALLS, "utf8").trim().split("\n").length, 2);
JS
)
status=$?
expect_code 0 "$status" "Codex quota extension parsing/gating failed: $out"
[ -z "$out" ] || fail "Codex quota extension test printed output: $out"
pass "Pi Codex quota extension scopes windows to the active model and shares one host snapshot"
