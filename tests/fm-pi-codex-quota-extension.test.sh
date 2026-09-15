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
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/cache-home"
cat > "$TMP_ROOT/bin/quota-axi" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_QUOTA_AXI_CALLS"
printf '{"schemaVersion":5,"providers":[]}\n'
STUB
chmod +x "$TMP_ROOT/bin/quota-axi"

out=$(EXT="$ROOT/.pi/extensions/lib/fm-codex-quota.ts" \
  PATH="$TMP_ROOT/bin:$PATH" \
  XDG_CACHE_HOME="$TMP_ROOT/cache-home" \
  FM_QUOTA_AXI_CALLS="$TMP_ROOT/calls" \
  node --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const quota = await import(pathToFileURL(process.env.EXT).href);
const now = new Date("2026-09-15T10:00:00.000Z");

assert.equal(quota.isCodexPiModel({ provider: "openai-codex", id: "gpt-5.3-codex-spark" }), true);
assert.equal(quota.isCodexPiModel({ provider: "codex-native", id: "gpt-6-astra" }), true);
assert.equal(quota.isCodexPiModel({ provider: "openai", id: "gpt-5.5" }), false);
// Pi hands the extension a Model with a bare id and a separate provider, so the
// provider alone decides. "codex" is not a Pi provider id, and a Codex-looking id
// under another provider never counts.
assert.equal(quota.isCodexPiModel({ provider: "codex", id: "gpt-5.3-codex" }), false);
assert.equal(quota.isCodexPiModel({ provider: "openai", id: "openai-codex/gpt-5.6-terra" }), false);
assert.equal(quota.isCodexPiModel(undefined), false);
assert.equal(quota.codexQuotaStatusText({ provider: "openai", id: "gpt-5.5" }, undefined, now), undefined);

// The exact shape `quota-axi --provider codex --json` emits at schemaVersion 5:
// percentRemaining only, no percentUsed and no windowSeconds, with the
// account-wide scope carried in quotaSemantics.effectiveAvailability.
const payload = {
  schemaVersion: 5,
  providers: [{
    provider: "codex",
    plan: "prolite",
    state: { status: "fresh", stale: false },
    windows: [
      { id: "weekly", label: "week", kind: "weekly", resetsAt: "2026-09-20T12:20:26.000Z", percentRemaining: 86 },
      { id: "model:codex_bengalfox:5h", label: "GPT-5.3-Codex-Spark session", kind: "model", resetsAt: "2026-09-15T15:31:42.000Z", percentRemaining: 75 },
      { id: "model:codex_bengalfox:7d", label: "GPT-5.3-Codex-Spark week", kind: "model", resetsAt: "2026-09-22T10:31:42.000Z", percentRemaining: 97 },
      { id: "model:base_model_inference:7d", label: "gpt-reserve week", kind: "model", resetsAt: "2026-09-17T18:26:52.000Z", percentRemaining: 1 },
    ],
    quotaSemantics: {
      status: "known",
      effectiveAvailability: [
        { scope: "all_models", status: "known", boundedBy: ["weekly"], limitingWindowIds: ["weekly"] },
        { scope: "model:codex_bengalfox", status: "known", boundedBy: ["weekly", "model:codex_bengalfox:5h", "model:codex_bengalfox:7d"] },
        { scope: "model:base_model_inference", status: "known", boundedBy: ["weekly", "model:base_model_inference:7d"] },
      ],
    },
  }],
};

// A Pi model that owns a model-level window shows its own five-hour limit. The
// quota-axi curated catalog has no `gpt-5.3-codex-spark` entry, so this is the
// regression: keying on that catalog rendered every real session unavailable.
const spark = quota.resolveCodexQuota(JSON.stringify(payload), { provider: "openai-codex", id: "gpt-5.3-codex-spark" });
assert.ok(spark);
assert.equal(spark.fiveHour.usedPercent, 25);
assert.equal(
  quota.formatCodexQuota(spark, now),
  "Codex 5h 25% used reset 15:31Z | 1w 14% used reset 2026-09-20 12:20Z",
);

// A Pi model with no model-level window still shows the account-wide weekly limit
// (docs/verification/dispatch-auth.md: the Codex all_models scope covers every
// model in the family), and reports the five-hour window as missing rather than
// borrowing another model's session budget.
for (const id of ["gpt-5.6-terra", "gpt-5.4", "gpt-6-astra"]) {
  const reading = quota.resolveCodexQuota(JSON.stringify(payload), { provider: "openai-codex", id });
  assert.ok(reading, "expected a reading for " + id);
  assert.equal(reading.fiveHour, undefined, id + " must not borrow another model 5h window");
  assert.equal(
    quota.formatCodexQuota(reading, now),
    "Codex 5h no window | 1w 14% used reset 2026-09-20 12:20Z",
  );
}

// The 1% remaining gpt-reserve week belongs to another model, so it never becomes
// any Pi session's one-week limit.
for (const id of ["gpt-5.3-codex-spark", "gpt-5.6-terra"]) {
  const reading = quota.resolveCodexQuota(JSON.stringify(payload), { provider: "openai-codex", id });
  assert.equal(reading.oneWeek.resetsAt, "2026-09-20T12:20:26.000Z");
  assert.equal(reading.oneWeek.usedPercent, 14);
}

// The Pi Model carries a bare id, which is the form window labels name.
assert.equal(quota.codexModelId({ provider: "openai-codex", id: "GPT-5.3-Codex-Spark" }), "gpt-5.3-codex-spark");

// Stale or unauthenticated provider state fails closed.
const unusable = { providers: [{ provider: "codex", state: { status: "auth_required" }, windows: [] }] };
assert.equal(quota.resolveCodexQuota(JSON.stringify(unusable), { provider: "openai-codex", id: "gpt-5.5" }), undefined);
assert.equal(
  quota.resolveCodexQuota(JSON.stringify({ providers: [{ provider: "codex", state: { status: "fresh", stale: true }, windows: [] }] }), { provider: "openai-codex", id: "gpt-5.5" }),
  undefined,
);
// A payload with no account scope and no matching model window has nothing to show.
assert.equal(
  quota.resolveCodexQuota(JSON.stringify({ providers: [{ provider: "codex", state: { status: "fresh" }, windows: payload.providers[0].windows }] }), { provider: "openai-codex", id: "gpt-5.4" }),
  undefined,
);
assert.equal(
  quota.codexQuotaStatusText({ provider: "openai-codex", id: "gpt-5.4" }, undefined, now),
  "Codex quota unavailable",
);

assert.equal(quota.formatPercent(12.35), "12.4%");
assert.equal(quota.formatResetTime("2026-09-15T12:00:00.000Z", now), "12:00Z");
assert.equal(quota.formatResetTime("not-a-time", now), "unknown");
assert.equal(
  quota.formatCodexQuota(spark, now, 600_000),
  "Codex 5h 25% used reset 15:31Z | 1w 14% used reset 2026-09-20 12:20Z (stale 10m)",
);

// Every session shares one host-local snapshot: a second read inside the TTL
// must not spawn quota-axi again.
const READ_ONLY_ARGS = ["--provider", "codex", "--json", "--no-credential-refresh"];
const first = await quota.cachedQuotaAxiJson("codex-quota.json", 60_000, READ_ONLY_ARGS);
const second = await quota.cachedQuotaAxiJson("codex-quota.json", 60_000, READ_ONLY_ARGS);
assert.equal(quota.codexQuotaCacheDir(), join(process.env.XDG_CACHE_HOME, "firstmate"));
assert.ok(existsSync(join(quota.codexQuotaCacheDir(), "codex-quota.json")), "snapshot must land under XDG_CACHE_HOME");
assert.equal(first.text, second.text);
assert.equal(second.ageMs < 60_000, true);
assert.equal(readFileSync(process.env.FM_QUOTA_AXI_CALLS, "utf8").trim().split("\n").length, 1);

// An expired entry refreshes, and a concurrent pair still spawns only once more
// because the loser of the refresh lock serves the previous snapshot.
const [a, b] = await Promise.all([
  quota.cachedQuotaAxiJson("codex-quota.json", -1, READ_ONLY_ARGS),
  quota.cachedQuotaAxiJson("codex-quota.json", -1, READ_ONLY_ARGS),
]);
assert.ok(a.text);
assert.ok(b.text);
const calls = readFileSync(process.env.FM_QUOTA_AXI_CALLS, "utf8").trim().split("\n");
assert.equal(calls.length, 2);
// The indicator never triggers a multi-provider read, and stays strictly
// read-only so a passive status tick cannot delegate credential renewal to the
// Codex vendor CLI (quota-axi --help: --no-credential-refresh keeps a read
// strictly read-only).
for (const call of calls) assert.equal(call, "--provider codex --json --no-credential-refresh");
JS
)
status=$?
expect_code 0 "$status" "Codex quota extension parsing/gating failed: $out"
[ -z "$out" ] || fail "Codex quota extension test printed output: $out"
pass "Pi Codex quota extension scopes windows to the active model and shares one host snapshot"
