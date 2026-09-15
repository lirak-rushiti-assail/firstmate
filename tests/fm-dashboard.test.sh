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
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
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
    {"id":"next-1","title":"Next task","blocked_by":"-","reason":"awaiting review","owner":"mate-a","filed":"2026-01-01"}
  ],
  "landed": [
    {"id":"done-1","what":"Merged finished work","owner":"(main)"}
  ],
  "omitted": [
    {"surface":"landed showing 1 of 14","reveal":"--all-landed"},
    {"surface":"in_flight showing 1 of 30","reveal":"--all-in-flight"},
    {"surface":"gates showing 1 of 25","reveal":"--all-queued"},
    {"surface":"secondmate home Done capped at the snapshot layer for 2 home(s)","reveal":"--all-landed"},
    {"surface":"secondmate registry unavailable: read failed","reveal":"inspect data/secondmates.md"},
    {"surface":"registered secondmates omitted by snapshot bound: 2","reveal":"raise FM_SNAPSHOT_SECONDMATES"},
    {"surface":"secondmate mate-b served from cached home ledger","reveal":"inspect the home ledger publication and remote route"},
    {"surface":"secondmates showing 5 of 20","reveal":"--all-secondmates"},
    {"surface":"secondmate parent activity evidence unavailable for 2 record(s)","reveal":"inspect the parent status logs"},
    {"surface":"main unstructured current backlog row(s): 2","reveal":"inspect main data/backlog.md In flight and Queued free-form rows"},
    {"surface":"secondmate mate-c active children omitted by snapshot bound: 3","reveal":"raise FM_SNAPSHOT_SECONDMATE_CHILDREN"},
    {"surface":"task paths","reveal":"--fields paths"}
  ]
}
JSON

cat > "$TMP_ROOT/fleet.json" <<JSON
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "$NOW",
  "backlog": {
    "records": [
      {"state":"done","structured":true,"id":"today-1","title":"Finished today","repo":"firstmate","kind":"ship","completion":{"verb":"merged","date":"$TODAY"},"pr_url":"https://example.invalid/pr/1"},
      {"state":"done","structured":true,"id":"old-1","title":"Finished earlier","repo":"firstmate","kind":"ship","completion":{"verb":"merged","date":"$YESTERDAY"},"pr_url":"https://example.invalid/pr/2"},
      {"state":"done","structured":true,"id":"cap-1","title":"Decide the rollout","repo":"firstmate","kind":"captain","completion":{"verb":"done","date":"$TODAY"},"local_note":"decided"}
    ]
  },
  "secondmate_landed": {
    "records": [
      {"id":"mate-today-1","title":"Mate landed today","kind":"ship","completion":{"verb":"merged","date":"$TODAY"},"pr_url":"https://example.invalid/pr/9","home":"/homes/mate-a","home_id":"mate-a"},
      {"id":"mate-old-1","title":"Mate landed earlier","kind":"ship","completion":{"verb":"merged","date":"$YESTERDAY"},"pr_url":"https://example.invalid/pr/8","home":"/homes/mate-a","home_id":"mate-a"}
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
[ -z "${FM_DASHBOARD_TEST_FLEET_FAIL:-}" ] || { echo "fleet: cannot read remote home ledger" >&2; exit 1; }
printf 'collect\n' >> "$FM_DASHBOARD_TEST_COLLECTIONS"
cat "$FM_DASHBOARD_TEST_FLEET"
SH
chmod +x "$FAKEBIN/fleet"

cat > "$FAKEBIN/m365" <<'SH'
printf 'call\n' >> "$FM_DASHBOARD_TEST_CALLS"
if [ -n "${FM_DASHBOARD_TEST_SILENT_FAIL:-}" ]; then
  exit 137
fi
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
  COLUMNS=100 \
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
assert_equals "2" "$(printf '%s' "$json" | jq -r '.widgets.today.count')" "today summary filters completion date"
# Today summary answers for the same fleet the Done actions panel describes, so a
# secondmate home's delivery landed today counts too.
assert_equals "mate-a" "$(printf '%s' "$json" | jq -r '.widgets.today.items[] | select(.id == "mate-today-1") | .owner')" "secondmate delivery landed today is attributed to its home"
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.today.items[] | select(.id == "mate-old-1")] | length')" "secondmate delivery landed earlier is not counted today"
# The today summary and the Done actions panel answer the same question, so the
# today widget uses the shared landed selector: a closed captain call is a
# decision, not a delivery, and must not be counted as work landed today.
assert_equals "today-1" "$(printf '%s' "$json" | jq -r '.widgets.today.items[0].id')" "today summary lists the landed delivery"
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.today.items[] | select(.id == "cap-1")] | length')" "closed captain call is not counted as landed today"
assert_equals "https://example.invalid/pr/1" "$(printf '%s' "$json" | jq -r '.widgets.today.items[0].artifact')" "today item carries the shared landed artifact"

# Bearings bounds each section and discloses the gap in omitted[]; the panels
# that render a bounded section must not present it as the complete set.
assert_equals "1" "$(printf '%s' "$json" | jq -r '[.widgets.done.omitted[] | select(.surface | startswith("landed showing"))] | length')" "done widget keeps its own truncation disclosure"
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.done.omitted[] | select(.surface == "task paths")] | length')" "unrelated omitted surfaces stay out of the done widget"
# A capped secondmate Done set bounds the landed panel even though its surface
# text does not start with "landed", and an unavailable registry bounds every
# fleet panel because it explains a short or empty one.
assert_equals "1" "$(printf '%s' "$json" | jq -r '[.widgets.done.omitted[] | select(.surface | startswith("secondmate home Done capped"))] | length')" "capped secondmate Done set is disclosed on the done panel"
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.working.omitted[] | select(.surface | startswith("secondmate home Done capped"))] | length')" "a landed-only bound stays off the working panel"
for w in "done" "working" "next"; do
  assert_equals "1" "$(printf '%s' "$json" | jq -r --arg w "$w" '[.widgets[$w].omitted[] | select(.surface | startswith("secondmate registry unavailable"))] | length')" "unavailable registry is disclosed on the $w panel"
done

# A home dropped by the snapshot bound contributes no underway, gate, or landed
# rows, so every panel is short and every panel must say so. The same holds for a
# home served from its cached ledger: its rows are present but stale.
for w in "done" "working" "next"; do
  assert_equals "1" "$(printf '%s' "$json" | jq -r --arg w "$w" '[.widgets[$w].omitted[] | select(.surface | startswith("registered secondmates omitted"))] | length')" "snapshot-bound home drop is disclosed on the $w panel"
  assert_equals "1" "$(printf '%s' "$json" | jq -r --arg w "$w" '[.widgets[$w].omitted[] | select(.surface | endswith("served from cached home ledger"))] | length')" "cached home ledger is disclosed on the $w panel"
done

# FM_BEARINGS_SECONDMATES caps only the bearings "secondmates" section, which this
# dashboard never renders, so it must not warn that complete panels are short.
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets[] | objects | .omitted // [] | .[] | select(.surface | startswith("secondmates showing"))] | length')" "a cap on an unrendered section warns on no panel"
assert_equals "1" "$(printf '%s' "$json" | jq -r '[.widgets.working.omitted[] | select(.surface | test("active children omitted"))] | length')" "omitted active children bound only the working panel"

# Today is fleet-scoped like Done actions, so a gap that hides landed rows must be
# disclosed there too rather than letting the count read as the whole day. Today
# builds from the canonical snapshot, not the bearings landed array, so only bounds
# that really drop rows from the snapshot reach it.
for w in "done" "today"; do
  assert_equals "1" "$(printf '%s' "$json" | jq -r --arg w "$w" '[.widgets[$w].omitted[] | select(.surface | startswith("secondmate home Done capped"))] | length')" "a snapshot-layer Done cap is disclosed on the $w panel"
  assert_equals "1" "$(printf '%s' "$json" | jq -r --arg w "$w" '[.widgets[$w].omitted[] | select(.surface | startswith("secondmate registry unavailable"))] | length')" "unavailable registry is disclosed on the $w panel"
done

# "landed showing N of M" caps only the bearings landed array that Done actions
# renders; it can drop no Today row, so it must not mark a complete day partial.
assert_equals "1" "$(printf '%s' "$json" | jq -r '[.widgets.done.omitted[] | select(.surface | startswith("landed showing"))] | length')" "a bearings display cap is disclosed on the done panel"
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.today.omitted[] | select(.surface | startswith("landed"))] | length')" "a bearings display cap does not mark the today panel short"

# Parent activity evidence feeds no rendered panel, and an unstructured main row can
# never have been dropped from the landed set, so neither may mark a full list short.
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets[] | objects | .omitted // [] | .[] | select(.surface | startswith("secondmate parent activity evidence"))] | length')" "parent activity evidence warns on no panel"
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.done.omitted[] | select(.surface | startswith("main unstructured current backlog"))] | length')" "unstructured main rows do not bound the done panel"
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.today.omitted[] | select(.surface | startswith("main unstructured current backlog"))] | length')" "unstructured main rows do not bound the today panel"
for w in "working" "next"; do
  assert_equals "1" "$(printf '%s' "$json" | jq -r --arg w "$w" '[.widgets[$w].omitted[] | select(.surface | startswith("main unstructured current backlog"))] | length')" "unstructured main rows bound the $w panel"
done
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.next.omitted[] | select(.surface | test("active children omitted"))] | length')" "omitted active children do not bound the next panel"
assert_contains "$(printf '%s' "$json" | jq -r '.widgets.calendar.message')" "--refresh-external" "calendar widget starts with refresh hint"

rendered=$(run_dashboard) || fail "dashboard terminal view should render"
assert_contains "$rendered" "Work 1  ·  Next 1  ·  Done today 2  ·  Seen 0" "terminal view starts with compact dashboard counts"
assert_contains "$rendered" "╭ Next calendar events" "calendar panel uses a dashboard box"
assert_contains "$rendered" "Next calendar events" "calendar panel rendered"
assert_contains "$rendered" "Important emails" "email panel rendered"
assert_contains "$rendered" "● Build dashboard" "working task rendered as a compact status row"
assert_contains "$rendered" "Finished today" "today summary rendered"
assert_contains "$rendered" "landed showing 1 of 14" "done panel discloses its truncation"
assert_contains "$rendered" "--all-landed" "done panel names how to reveal the rest"
assert_contains "$rendered" "in_flight showing 1 of 30" "working panel discloses its truncation"
assert_contains "$rendered" "gates showing 1 of 25" "next panel discloses its truncation"
assert_contains "$rendered" "secondmate registry unavailable: read failed" "partial fleet data is visible in the panels it bounds"
assert_contains "$rendered" "Next task [mate-a]" "next panel names the home that owns the gate"
assert_contains "$rendered" "awaiting review" "next panel renders the gate reason"
assert_not_contains "$rendered" "task paths" "unrelated omitted surfaces are not rendered as panel truncation"

seen_out=$(run_dashboard --mark-seen email-123) || fail "mark seen should succeed"
assert_contains "$seen_out" "seen: email-123" "mark seen reports id"
json=$(run_dashboard --json) || fail "dashboard JSON after seen marker should render"
assert_equals "email-123" "$(printf '%s' "$json" | jq -r '.widgets.seen.items[0].id')" "seen marker appears in dashboard"
assert_equals "0" "$(printf '%s' "$json" | jq -r '.widgets.seen.omitted | length')" "an unbounded seen ledger discloses nothing"

# The Seen panel keeps the most recent 12 markers; past that it must say so rather
# than read as the complete set of what the operator has marked seen.
for i in 2 3 4 5 6 7 8 9 10 11 12 13 14; do
  run_dashboard --mark-seen "email-$i" >/dev/null || fail "mark seen $i should succeed"
done
json=$(run_dashboard --json) || fail "dashboard JSON with a bounded seen ledger should render"
assert_equals "12" "$(printf '%s' "$json" | jq -r '.widgets.seen.items | length')" "seen panel keeps the most recent 12 markers"
assert_equals "email-14" "$(printf '%s' "$json" | jq -r '.widgets.seen.items[0].id')" "newest seen marker stays at the top"
assert_equals "seen showing 12 of 14" "$(printf '%s' "$json" | jq -r '.widgets.seen.omitted[0].surface')" "seen panel discloses the markers it dropped"
assert_contains "$(printf '%s' "$json" | jq -r '.widgets.seen.omitted[0].reveal')" "seen.jsonl" "seen disclosure names the local ledger"
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.seen.items[] | select(.id == "email-123")] | length')" "the oldest markers are the ones dropped"
rendered=$(run_dashboard) || fail "terminal view with a bounded seen ledger should render"
assert_contains "$rendered" "seen showing 12 of 14" "seen panel renders its truncation note"

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

# The answer a failed refresh carried forward is itself the last good answer for the
# next failure, so an outage lasting more than one refresh does not erase the agenda.
json=$(run_dashboard --json --force-refresh) || fail "second failed refresh should still render"
assert_contains "$(printf '%s' "$json" | jq -r '.widgets.calendar.answer')" "Standup" "a repeated failure keeps the last good calendar answer"
assert_contains "$(printf '%s' "$json" | jq -r '.widgets.email.answer')" "Please review" "a repeated failure keeps the last good email answer"
assert_contains "$(printf '%s' "$json" | jq -r '.widgets.calendar.message')" "connector refused" "a repeated failure still reports the current error"
json=$(run_dashboard --json --force-refresh) || fail "third failed refresh should still render"
assert_contains "$(printf '%s' "$json" | jq -r '.widgets.calendar.answer')" "Standup" "the last good answer survives a prolonged outage"

# A carried-forward answer keeps the instant it was actually good, so a prolonged
# outage cannot present a stale agenda as current.
assert_equals "false" "$(printf '%s' "$json" | jq -r '.widgets.calendar.answer_generated == .widgets.calendar.generated')" "a failed refresh does not restamp the answer as freshly collected"
assert_equals "true" "$(printf '%s' "$json" | jq -r '(.widgets.calendar.answer_age_seconds // -1) >= 0')" "a carried-forward answer reports its age"
rendered=$(run_dashboard) || fail "terminal view during an outage should render"
assert_contains "$rendered" "stale for " "the stale answer names how old it is"
unset FM_DASHBOARD_TEST_FAIL
rendered=$(run_dashboard) || fail "terminal view should render after a failed refresh"
assert_contains "$rendered" "Standup" "stale answer still rendered"
assert_contains "$rendered" "(stale" "stale answer is marked stale"

# The fleet collection obeys the same freshness window as the connector, so a
# --watch tick redraws from the cached snapshot instead of re-reading every
# registered home once per tick.
collected=$(fleet_collections)
json=$(run_dashboard --json) || fail "cached fleet render should succeed"
assert_equals "$collected" "$(fleet_collections)" "render inside the freshness window reuses the collected snapshot"
assert_equals "true" "$(printf '%s' "$json" | jq -r '.fleet.cached')" "a reused snapshot is reported as cached"
assert_equals "1" "$(printf '%s' "$json" | jq -r '.widgets.working.items | length')" "a cached snapshot still fills the panels"
rendered=$(run_dashboard) || fail "cached terminal view should render"
assert_contains "$rendered" "(cached)" "header discloses that the fleet snapshot came from cache"

json=$(run_dashboard --json --force-refresh) || fail "forced fleet refresh should render"
assert_equals "$((collected + 1))" "$(fleet_collections)" "force refresh re-collects the fleet snapshot"
assert_equals "false" "$(printf '%s' "$json" | jq -r '.fleet.cached')" "a freshly collected snapshot is not reported as cached"

# A panel disclosure tells the operator to raise an FM_SNAPSHOT_* bound, so a run
# that raises one must re-collect rather than replay a snapshot collected under
# the old bound.
collected=$(fleet_collections)
FM_SNAPSHOT_SECONDMATES=50 run_dashboard --json > /dev/null || fail "raised-bound render should succeed"
assert_equals "$((collected + 1))" "$(fleet_collections)" "a changed snapshot bound re-collects the fleet snapshot"
json=$(FM_SNAPSHOT_SECONDMATES=50 run_dashboard --json) || fail "repeated raised-bound render should succeed"
assert_equals "$((collected + 1))" "$(fleet_collections)" "an unchanged snapshot bound still reuses the cached snapshot"
assert_equals "true" "$(printf '%s' "$json" | jq -r '.fleet.cached')" "the reused snapshot is reported as cached"
json=$(run_dashboard --json) || fail "restored-bound render should succeed"
assert_equals "$((collected + 2))" "$(fleet_collections)" "restoring the default bound re-collects the fleet snapshot"

collected=$(fleet_collections)
export FM_DASHBOARD_CACHE_TTL=0
json=$(run_dashboard --json) || fail "zero-ttl fleet render should succeed"
assert_equals "$((collected + 1))" "$(fleet_collections)" "zero freshness window always re-collects the fleet snapshot"
unset FM_DASHBOARD_CACHE_TTL

# A plain run serves the cached answer without re-querying, so a successful answer
# that has aged past the freshness window must report how old it is rather than
# reading as today's agenda.
OLD_AT=$(date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)
jq -nc --arg at "$OLD_AT" \
  '{generated:$at,answer_generated:$at,ok:true,answer:"- 09:00 Standup",message:null}' \
  > "$HOME_DIR/state/dashboard/cache/calendar.json"
json=$(run_dashboard --json) || fail "dashboard with an aged calendar cache should render"
assert_equals "true" "$(printf '%s' "$json" | jq -r '.widgets.calendar.ok')" "an aged answer is still a good answer"
assert_equals "true" "$(printf '%s' "$json" | jq -r '.widgets.calendar.answer_age_seconds > 86400')" "an aged answer reports its age"
rendered=$(run_dashboard) || fail "terminal view with an aged calendar cache should render"
assert_contains "$rendered" "Standup" "an aged answer is still shown"
assert_contains "$rendered" "collected 3d ago" "an aged answer names how old it is"

# Inside the freshness window a good answer carries no age note.
NOW_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -nc --arg at "$NOW_AT" \
  '{generated:$at,answer_generated:$at,ok:true,answer:"- 09:00 Standup",message:null}' \
  > "$HOME_DIR/state/dashboard/cache/calendar.json"
rendered=$(run_dashboard) || fail "terminal view with a fresh calendar cache should render"
assert_not_contains "$rendered" "collected" "a fresh answer is not labelled old"

# A seen ledger that cannot be parsed must not read as "nothing marked seen".
printf 'not json at all\n' >> "$HOME_DIR/state/dashboard/seen.jsonl"
json=$(run_dashboard --json) || fail "dashboard with an unreadable seen ledger should render"
assert_equals "0" "$(printf '%s' "$json" | jq -r '.widgets.seen.items | length')" "an unreadable seen ledger yields no items"
assert_equals "1" "$(printf '%s' "$json" | jq -r '[.widgets.seen.omitted[] | select(.surface == "seen ledger unreadable")] | length')" "an unreadable seen ledger is disclosed"
assert_contains "$(printf '%s' "$json" | jq -r '.widgets.seen.omitted[] | select(.surface == "seen ledger unreadable") | .reveal')" "seen.jsonl" "the seen disclosure names the local ledger"
rendered=$(run_dashboard) || fail "terminal view with an unreadable seen ledger should render"
assert_contains "$rendered" "seen ledger unreadable" "the seen panel discloses that it could not be read"
assert_contains "$rendered" "Seen ?" "the stats row does not assert a seen count it could not read"
assert_not_contains "$rendered" "Seen 0" "an unreadable ledger is not summarised as nothing seen"

# A connector that dies without writing anything must not read as an empty agenda.
export FM_DASHBOARD_TEST_SILENT_FAIL=1
json=$(run_dashboard --json --force-refresh --refresh-external) || fail "dashboard with a silent connector failure should render"
assert_equals "false" "$(printf '%s' "$json" | jq -r '.widgets.calendar.ok')" "a silent connector failure is not a good answer"
assert_not_equals "" "$(printf '%s' "$json" | jq -r '.widgets.calendar.message')" "a silent connector failure still carries an error message"
rendered=$(run_dashboard) || fail "terminal view after a silent connector failure should render"
assert_contains "$rendered" "connector failed" "the calendar panel names the connector failure"
unset FM_DASHBOARD_TEST_SILENT_FAIL

# A failed fleet collection must stop rather than draw empty panels as fleet state.
if FM_DASHBOARD_TEST_FLEET_FAIL=1 run_dashboard --force-refresh >"$TMP_ROOT/failed.out" 2>"$TMP_ROOT/failed.err"; then
  fail "a failed fleet collection should not exit 0"
fi
assert_not_contains "$(cat "$TMP_ROOT/failed.out")" "(none)" "a failed fleet collection draws no empty panels"
assert_contains "$(cat "$TMP_ROOT/failed.err")" "fleet snapshot" "a failed fleet collection names the failure"
if FM_DASHBOARD_TEST_FLEET_FAIL=1 run_dashboard --json --force-refresh >"$TMP_ROOT/failed.json" 2>/dev/null; then
  fail "a failed fleet collection should not exit 0 in JSON mode"
fi
assert_equals "" "$(cat "$TMP_ROOT/failed.json")" "a failed fleet collection emits no JSON document"

# A watch loop must survive a transient collection failure and keep refreshing.
set -m
FM_DASHBOARD_TEST_FLEET_FAIL=1 run_dashboard --watch 1 --force-refresh \
  >"$TMP_ROOT/watch.out" 2>"$TMP_ROOT/watch.err" &
watch_pid=$!
set +m
sleep 3
watch_children=$(pgrep -P "$watch_pid" | tr '\n' ' ')
kill -- -"$watch_pid" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true
assert_not_equals "" "$watch_children" "a transient collection failure should not kill the watch loop"
watch_survivors=
for watch_child in $watch_children; do
  for _ in 1 2 3 4 5; do
    kill -0 "$watch_child" 2>/dev/null || break
    sleep 0.2
  done
  kill -0 "$watch_child" 2>/dev/null && watch_survivors="$watch_survivors $watch_child"
done
assert_equals "" "${watch_survivors# }" "the watch loop leaves no orphaned dashboard behind"
assert_equals "true" \
  "$([ "$(grep -c 'retrying' "$TMP_ROOT/watch.err")" -ge 2 ] && printf 'true' || printf 'false')" \
  "each failed watch tick reports the failure and retries"

pass "fm-dashboard"
