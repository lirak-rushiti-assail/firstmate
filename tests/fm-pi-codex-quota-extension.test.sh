#!/usr/bin/env bash
# Tests for the Firstmate Pi Codex quota status extension.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

out=$(EXT="$ROOT/.pi/extensions/lib/fm-codex-quota.ts" node --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

const quota = await import(pathToFileURL(process.env.EXT).href);
const now = new Date("2026-09-15T10:00:00.000Z");

assert.equal(quota.isCodexPiModel({ provider: "openai-codex", id: "gpt-5.5" }), true);
assert.equal(quota.isCodexPiModel({ provider: "codex-native", id: "gpt-6-astra" }), true);
assert.equal(quota.isCodexPiModel({ provider: "openai", id: "openai-codex/gpt-5.5" }), true);
assert.equal(quota.isCodexPiModel("codex-native/gpt-6-astra"), true);
assert.equal(quota.isCodexPiModel({ provider: "openai", id: "gpt-5.5" }), false);
assert.equal(quota.codexQuotaStatusText({ provider: "openai", id: "gpt-5.5" }, undefined, now), undefined);

const parsed = quota.parseCodexQuota({
  providers: [{
    provider: "codex",
    state: { status: "fresh", stale: false },
    windows: [
      {
        id: "model:codex_bengalfox:5h",
        label: "GPT-5.3-Codex-Spark session",
        resetsAt: "2026-09-15T15:31:42.000Z",
        percentRemaining: 75,
      },
      {
        id: "weekly",
        label: "week",
        kind: "weekly",
        resetsAt: "2026-09-20T12:20:26.000Z",
        percentRemaining: 86,
      },
      {
        id: "model:codex_bengalfox:7d",
        label: "GPT-5.3-Codex-Spark week",
        resetsAt: "2026-09-22T10:31:42.000Z",
        percentUsed: 0,
      },
    ],
  }],
});

assert.ok(parsed);
assert.equal(parsed.fiveHour.usedPercent, 25);
assert.equal(parsed.oneWeek.usedPercent, 14);
assert.equal(
  quota.formatCodexQuota(parsed, now),
  "Codex 5h 25% used reset 15:31Z | 1w 14% used reset 2026-09-20 12:20Z",
);
assert.equal(
  quota.codexQuotaStatusText({ provider: "openai-codex", id: "gpt-5.5" }, parsed, now),
  "Codex 5h 25% used reset 15:31Z | 1w 14% used reset 2026-09-20 12:20Z",
);

const usedParsed = quota.parseCodexQuota({
  providers: [{
    provider: "codex",
    state: { status: "fresh" },
    windows: [
      { id: "spark:5h", resetsAt: "2026-09-15T11:00:00.000Z", percentUsed: 12.34 },
      { id: "weekly", resetsAt: "2026-09-15T12:00:00.000Z", percentUsed: 50 },
    ],
  }],
});
assert.ok(usedParsed);
assert.equal(quota.formatPercent(usedParsed.fiveHour.usedPercent), "12.3%");
assert.equal(quota.formatResetTime(usedParsed.oneWeek.resetsAt, now), "12:00Z");

assert.equal(quota.parseCodexQuota({ providers: [{ provider: "codex", state: { status: "auth_required" }, windows: [] }] }), undefined);
assert.equal(quota.parseCodexQuota({ providers: [{ provider: "codex", state: { status: "fresh" }, windows: [
  { id: "weekly", resetsAt: "2026-09-15T12:00:00.000Z", percentRemaining: 50 },
] }] }), undefined);
assert.equal(quota.codexQuotaStatusText({ provider: "openai-codex", id: "gpt-5.5" }, undefined, now), "Codex quota unavailable");
JS
)
status=$?
expect_code 0 "$status" "Codex quota extension parsing/gating failed: $out"
[ -z "$out" ] || fail "Codex quota extension test printed output: $out"
pass "Pi Codex quota extension gates providers, parses quota windows, and renders failures"
