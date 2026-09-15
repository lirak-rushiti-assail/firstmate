#!/usr/bin/env bash
# Behavior tests for bin/fm-dashboard.sh: dashboard projection, terminal panels,
# local seen markers, and read-only M365 cache refresh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASHBOARD="$ROOT/bin/fm-dashboard.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TODAY=$(date -u +%Y-%m-%d)
YESTERDAY=$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u -d 'yesterday' +%Y-%m-%d)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$FAKEBIN"
CALLS="$TMP_ROOT/m365-calls"
: > "$CALLS"
COLLECTIONS="$TMP_ROOT/fleet-collections"
: > "$COLLECTIONS"

cat > "$TMP_ROOT/bearings.json" <<JSON
{
  "schema": "fm-bearings.v1",
  "home": "$HOME_DIR",
  "generated": "2026-01-02T03:04:05Z",
  "in_flight": [
    {"id":"ship-1","kind":"ship","state":"working","repo":"firstmate","name":"Build dashboard","doing":"coding"}
  ],
  "gates": [
    {"id":"next-1","title":"Next task","repo":"firstmate","reason":"ready"}
  ],
  "landed": [
    {"id":"done-1","what":"Merged finished work","owner":"(main)"}
  ]
}
JSON

cat > "$TMP_ROOT/fleet.json" <<JSON
{
  "schema": "fm-fleet-snapshot.v1",
  "backlog": {
    "records": [
      {"state":"done","id":"today-1","title":"Finished today","repo":"firstmate","kind":"ship","completion":{"verb":"done","date":"$TODAY"},"report_path":"data/today.md"},
      {"state":"done","id":"old-1","title":"Finished earlier","repo":"firstmate","kind":"ship","completion":{"verb":"done","date":"$YESTERDAY"},"report_path":"data/old.md"}
    ]
  }
}
JSON

cat > "$FAKEBIN/bearings" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --json ] || exit 2
[ -n "${FM_BEARINGS_SNAPSHOT_JSON:-}" ] \
  || { echo "bearings: dashboard collected no snapshot to project" >&2; exit 3; }
cmp -s "$FM_BEARINGS_SNAPSHOT_JSON" "$FM_DASHBOARD_TEST_FLEET" \
  || { echo "bearings: injected snapshot differs from the collected one" >&2; exit 4; }
cat "$FM_DASHBOARD_TEST_BEARINGS"
SH
chmod +x "$FAKEBIN/bearings"

cat > "$FAKEBIN/fleet" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --json ] || exit 2
printf 'collect\n' >> "$FM_DASHBOARD_TEST_COLLECTIONS"
cat "$FM_DASHBOARD_TEST_FLEET"
SH
chmod +x "$FAKEBIN/fleet"

cat > "$FAKEBIN/m365" <<'SH'
printf 'call\n' >> "$FM_DASHBOARD_TEST_CALLS"
if [ -n "${FM_DASHBOARD_TEST_FAIL:-}" ]; then
  printf 'connector refused\n'
  exit 1
fi
case "${2:-}" in
  *calendar*) printf '{"ok":true,"answer":"- 09:00 Standup\\n- 13:00 Review","reads":[{"is_error":false}]}\n' ;;
  *emails*|*email*) printf '{"ok":true,"answer":"- Ada: Please review","reads":[{"is_error":false}]}\n' ;;
  *) printf '{"ok":false,"error":"unexpected prompt"}\n'; exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/m365"

run_dashboard() {
  FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_DASHBOARD_BEARINGS_CMD="$FAKEBIN/bearings" \
    FM_DASHBOARD_FLEET_CMD="$FAKEBIN/fleet" \
    FM_DASHBOARD_M365_HELPER="$FAKEBIN/m365" \
    FM_DASHBOARD_TEST_BEARINGS="$TMP_ROOT/bearings.json" \
    FM_DASHBOARD_TEST_FLEET="$TMP_ROOT/fleet.json" \
    FM_DASHBOARD_TEST_CALLS="$CALLS" \
    FM_DASHBOARD_TEST_COLLECTIONS="$COLLECTIONS" \
    PYTHON_BIN=bash \
    "$DASHBOARD" "$@"
}

connector_calls() { [ -s "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || printf '0'; }
fleet_collections() { [ -s "$COLLECTIONS" ] && wc -l < "$COLLECTIONS" | tr -d ' ' || printf '0'; }

json=$(run_dashboard --json) || fail "dashboard JSON should render"
assert_equals "fm-dashboard.v1" "$(printf '%s' "$json" | jq -r '.schema')" "schema is reported"
# One render collects the canonical fleet snapshot once and hands that same
# collection to the bearings projection (the fake bearings fails otherwise).
assert_equals "1" "$(fleet_collections)" "one render collects the fleet snapshot once"
assert_equals "1" "$(printf '%s' "$json" | jq -r '.widgets.working.items | length')" "working widget uses bearings snapshot"
assert_equals "1" "$(printf '%s' "$json" | jq -r '.widgets.next.items | length')" "next widget uses bearings gates"
assert_equals "1" "$(printf '%s' "$json" | jq -r '.widgets.done.items | length')" "done widget uses landed rows"
assert_equals "1" "$(printf '%s' "$json" | jq -r '.widgets.today.count')" "today summary filters completion date"
assert_contains "$(printf '%s' "$json" | jq -r '.widgets.calendar.message')" "--refresh-external" "calendar widget starts with refresh hint"

rendered=$(run_dashboard) || fail "dashboard terminal view should render"
assert_contains "$rendered" "Next calendar events" "calendar panel rendered"
assert_contains "$rendered" "Important emails" "email panel rendered"
assert_contains "$rendered" "Build dashboard" "working task rendered"
assert_contains "$rendered" "Finished today" "today summary rendered"

seen_out=$(run_dashboard --mark-seen email-123 --note 'handled locally') || fail "mark seen should succeed"
assert_contains "$seen_out" "seen: email-123" "mark seen reports id"
json=$(run_dashboard --json) || fail "dashboard JSON after seen marker should render"
assert_equals "email-123" "$(printf '%s' "$json" | jq -r '.widgets.seen.items[0].id')" "seen marker appears in dashboard"
assert_equals "handled locally" "$(printf '%s' "$json" | jq -r '.widgets.seen.items[0].note')" "seen marker note appears in dashboard"

json=$(run_dashboard --json --refresh-external) || fail "external refresh should render"
assert_equals "true" "$(printf '%s' "$json" | jq -r '.widgets.calendar.ok')" "calendar cache refreshed"
assert_contains "$(printf '%s' "$json" | jq -r '.widgets.calendar.answer')" "Standup" "calendar answer cached"
assert_contains "$(printf '%s' "$json" | jq -r '.widgets.email.answer')" "Please review" "email answer cached"
assert_no_grep "reads" "$HOME_DIR/state/dashboard/cache/calendar.json" "cache does not persist connector evidence payload"
assert_equals "2" "$(connector_calls)" "first external refresh queries both widgets once"

# A repeated refresh inside the freshness window reuses the cache instead of
# re-querying the connector, so a --watch tick cannot spin the connector.
json=$(run_dashboard --json --refresh-external) || fail "cached external refresh should render"
assert_equals "2" "$(connector_calls)" "refresh within freshness window reuses cache"
assert_contains "$(printf '%s' "$json" | jq -r '.widgets.calendar.answer')" "Standup" "cached calendar answer still served"

json=$(run_dashboard --json --force-refresh) || fail "forced refresh should render"
assert_equals "4" "$(connector_calls)" "force refresh bypasses the freshness window"

export FM_DASHBOARD_CACHE_TTL=0
json=$(run_dashboard --json --refresh-external) || fail "zero-ttl refresh should render"
assert_equals "6" "$(connector_calls)" "zero freshness window always refreshes"
unset FM_DASHBOARD_CACHE_TTL

# A failed refresh keeps the last good answer and reports the error with it.
export FM_DASHBOARD_TEST_FAIL=1
json=$(run_dashboard --json --force-refresh) || fail "failed refresh should still render"
assert_equals "false" "$(printf '%s' "$json" | jq -r '.widgets.calendar.ok')" "failed refresh marks widget not ok"
assert_contains "$(printf '%s' "$json" | jq -r '.widgets.calendar.answer')" "Standup" "failed refresh keeps last good answer"
assert_contains "$(printf '%s' "$json" | jq -r '.widgets.calendar.message')" "connector refused" "failed refresh records the error"
unset FM_DASHBOARD_TEST_FAIL
rendered=$(run_dashboard) || fail "terminal view should render after a failed refresh"
assert_contains "$rendered" "Standup" "stale answer still rendered"
assert_contains "$rendered" "stale:" "stale answer is marked stale"

pass "fm-dashboard"
