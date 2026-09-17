#!/usr/bin/env bash
# Behavior tests for bin/fm-dashboard.sh: today board projection, panel
# disclosures, saved task details, and fleet snapshot cache reuse.
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
      {"state":"queued","structured":true,"id":"todo-1","title":"Todo today","repo":"firstmate","kind":"ship","since":"$YESTERDAY","body_excerpt":"Todo details stay saved but hidden."},
      {"state":"in_flight","structured":true,"id":"ship-1","title":"Build dashboard","repo":"firstmate","kind":"ship"},
      {"state":"in_flight","structured":true,"id":"held-1","title":"Held task","repo":"firstmate","kind":"ship","current_role":"held","hold_reason":"waiting on the captain","body_excerpt":"Held details stay saved but hidden."},
      {"state":"in_flight","structured":true,"id":"prog-1","title":"Program task","repo":"firstmate","kind":"program","current_role":"program"},
      {"state":"done","structured":true,"id":"today-1","title":"Finished today","repo":"firstmate","kind":"ship","completion":{"verb":"merged","date":"$TODAY"},"pr_url":"https://example.invalid/pr/1","body_excerpt":"Done details stay saved but hidden."},
      {"state":"done","structured":true,"id":"old-1","title":"Finished earlier","repo":"firstmate","kind":"ship","completion":{"verb":"merged","date":"$YESTERDAY"},"pr_url":"https://example.invalid/pr/2"},
      {"state":"done","structured":true,"id":"cap-1","title":"Decide the rollout","repo":"firstmate","kind":"captain","completion":{"verb":"done","date":"$TODAY"},"local_note":"decided"}
    ]
  },
  "tasks": [
    {"id":"ship-1","backlog":{"body_excerpt":"In-progress details stay saved but hidden."}}
  ],
  "secondmate_current": {
    "records": [
      {"id":"mate-a","home":"/homes/mate-a","provenance":{"selected":"structured-home"},
       "queued":[
         {"id":"mate-todo-1","title":"Mate queued today","repo":"materepo","kind":"ship","since":"$TODAY","body_excerpt":"Mate todo details stay saved but hidden."}
       ]},
      {"id":"mate-z","home":"/homes/mate-z","provenance":{"selected":"parent-status"},
       "queued":[
         {"id":"mate-untrusted-1","title":"Untrusted queued row","kind":"ship","since":"$TODAY"}
       ]}
    ]
  },
  "secondmate_landed": {
    "records": [
      {"id":"mate-today-1","title":"Mate landed today","kind":"ship","completion":{"verb":"merged","date":"$TODAY"},"pr_url":"https://example.invalid/pr/9","body_excerpt":"Mate details stay saved but hidden.","home":"/homes/mate-a","home_id":"mate-a"},
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

run_dashboard() {
  COLUMNS=100 \
    FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_DASHBOARD_BEARINGS_CMD="$FAKEBIN/bearings" \
    FM_DASHBOARD_FLEET_CMD="$FAKEBIN/fleet" \
    FM_DASHBOARD_TEST_BEARINGS="$TMP_ROOT/bearings.json" \
    FM_DASHBOARD_TEST_FLEET="${FM_DASHBOARD_TEST_FLEET:-$TMP_ROOT/fleet.json}" \
    FM_DASHBOARD_TEST_COLLECTIONS="$COLLECTIONS" \
    "$DASHBOARD" "$@"
}

fleet_collections() { [ -s "$COLLECTIONS" ] && wc -l < "$COLLECTIONS" | tr -d ' ' || printf '0'; }

json=$(run_dashboard --json) || fail "dashboard JSON should render"
assert_equals "fm-dashboard.v1" "$(printf '%s' "$json" | jq -r '.schema')" "schema is reported"
# One render collects the canonical fleet snapshot once and hands that same
# collection to the bearings projection (the fake bearings fails otherwise).
assert_equals "1" "$(fleet_collections)" "one render collects the fleet snapshot once"

assert_equals "2" "$(printf '%s' "$json" | jq -r '.widgets.board.todo.items | length')" "today board lists queued tasks as todo"
assert_equals "3" "$(printf '%s' "$json" | jq -r '.widgets.board.in_progress.items | length')" "today board lists active tasks as in progress"
assert_equals "2" "$(printf '%s' "$json" | jq -r '.widgets.board.done.items | length')" "today board lists today's finished deliveries"
# The board answers "my tasks" for the whole fleet in every column, so a
# secondmate home's queued row is todo here before it shows up in progress.
assert_equals "mate-a" "$(printf '%s' "$json" | jq -r '.widgets.board.todo.items[] | select(.id == "mate-todo-1") | .owner')" "a secondmate queued row is todo and attributed to its home"
# A home whose structured state was not selected is not a trustworthy source of
# queued rows, so its rows stay out rather than being presented as fleet todo.
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.board.todo.items[] | select(.id == "mate-untrusted-1")] | length')" "an untrusted home contributes no todo rows"
# Bearings routes held rows and programs to its own decision and gate sections;
# the board would otherwise show them nowhere and report no live work at all.
assert_equals "waiting on the captain" "$(printf '%s' "$json" | jq -r '.widgets.board.in_progress.items[] | select(.id == "held-1") | .doing')" "a held in-flight row stays in progress with its hold reason"
assert_equals "1" "$(printf '%s' "$json" | jq -r '[.widgets.board.in_progress.items[] | select(.id == "prog-1")] | length')" "an in-flight program stays in progress"
assert_equals "1" "$(printf '%s' "$json" | jq -r '[.widgets.board.in_progress.items[] | select(.id == "ship-1")] | length')" "a row both projections carry is listed once"
assert_equals "coding" "$(printf '%s' "$json" | jq -r '.widgets.board.in_progress.items[] | select(.id == "ship-1") | .doing')" "a live row keeps the observed detail from the bearings projection"
# The board is the whole product surface: it must not carry a second spelling of
# the same columns for a caller nothing has.
assert_equals '["board"]' "$(printf '%s' "$json" | jq -c '.widgets | keys')" "the model defines the board and nothing else"

# Done is fleet-scoped, so a secondmate home's delivery landed today counts too,
# and a closed captain call is a decision rather than a delivery.
assert_equals "mate-a" "$(printf '%s' "$json" | jq -r '.widgets.board.done.items[] | select(.id == "mate-today-1") | .owner')" "secondmate delivery landed today is attributed to its home"
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.board.done.items[] | select(.id == "mate-old-1")] | length')" "secondmate delivery landed earlier is not counted today"
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.board.done.items[] | select(.id == "cap-1")] | length')" "closed captain call is not counted as landed today"
assert_equals "https://example.invalid/pr/1" "$(printf '%s' "$json" | jq -r '.widgets.board.done.items[0].artifact')" "done item carries the shared landed artifact"

# Saved details stay in JSON for every column, including secondmate rows, whose
# excerpt has to survive the home-summary boundary to get here.
assert_equals "Todo details stay saved but hidden." "$(printf '%s' "$json" | jq -r '.widgets.board.todo.items[] | select(.id == "todo-1") | .details')" "todo details stay persisted in JSON"
assert_equals "Mate todo details stay saved but hidden." "$(printf '%s' "$json" | jq -r '.widgets.board.todo.items[] | select(.id == "mate-todo-1") | .details')" "secondmate todo details stay persisted in JSON"
assert_equals "Held details stay saved but hidden." "$(printf '%s' "$json" | jq -r '.widgets.board.in_progress.items[] | select(.id == "held-1") | .details')" "held task details stay persisted in JSON"
assert_equals "In-progress details stay saved but hidden." "$(printf '%s' "$json" | jq -r '.widgets.board.in_progress.items[] | select(.id == "ship-1") | .details')" "in-progress details stay persisted in JSON"
assert_equals "Done details stay saved but hidden." "$(printf '%s' "$json" | jq -r '.widgets.board.done.items[] | select(.id == "today-1") | .details')" "done details stay persisted in JSON"
assert_equals "Mate details stay saved but hidden." "$(printf '%s' "$json" | jq -r '.widgets.board.done.items[] | select(.id == "mate-today-1") | .details')" "secondmate done details stay persisted in JSON"

# Bearings bounds each section and discloses the gap in omitted[]; a column must
# disclose only the bounds that can really drop one of its own rows.
assert_equals "1" "$(printf '%s' "$json" | jq -r '[.widgets.board.in_progress.omitted[] | select(.surface | startswith("in_flight showing"))] | length')" "the in-progress bound is disclosed on the in-progress column"
assert_equals "1" "$(printf '%s' "$json" | jq -r '[.widgets.board.in_progress.omitted[] | select(.surface | test("active children omitted"))] | length')" "omitted active children bound the in-progress column"
assert_equals "1" "$(printf '%s' "$json" | jq -r '[.widgets.board.done.omitted[] | select(.surface | startswith("secondmate home Done capped"))] | length')" "a capped secondmate Done set is disclosed on the done column"
for c in "todo" "in_progress"; do
  assert_equals "1" "$(printf '%s' "$json" | jq -r --arg c "$c" '[.widgets.board[$c].omitted[] | select(.surface | startswith("main unstructured current backlog"))] | length')" "unstructured main rows bound the $c column"
done
for c in "todo" "in_progress" "done"; do
  assert_equals "1" "$(printf '%s' "$json" | jq -r --arg c "$c" '[.widgets.board[$c].omitted[] | select(.surface | startswith("secondmate registry unavailable"))] | length')" "an unavailable registry is disclosed on the $c column"
  assert_equals "1" "$(printf '%s' "$json" | jq -r --arg c "$c" '[.widgets.board[$c].omitted[] | select(.surface | startswith("registered secondmates omitted"))] | length')" "a snapshot-bound home drop is disclosed on the $c column"
  assert_equals "1" "$(printf '%s' "$json" | jq -r --arg c "$c" '[.widgets.board[$c].omitted[] | select(.surface | endswith("served from cached home ledger"))] | length')" "a cached home ledger is disclosed on the $c column"
done

# Bounds that describe a bearings display array can drop no row from a column the
# dashboard projects itself, so they must not tell the operator it is short.
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.board.todo.omitted[] | select(.surface | startswith("gates showing"))] | length')" "a bearings gates cap does not mark the todo column short"
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.board.todo.omitted[] | select(.surface | startswith("secondmate home Done capped"))] | length')" "a landed-only bound does not mark the todo column short"
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.board.done.omitted[] | select(.surface | startswith("landed showing"))] | length')" "a bearings landed display cap does not mark the done column short"
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.board.done.omitted[] | select(.surface | startswith("main unstructured current backlog"))] | length')" "unstructured main rows do not bound the done column"
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.board[] | .omitted[] | select(.surface | startswith("secondmates showing") or startswith("secondmate parent activity evidence") or (. == "task paths"))] | length')" "a bound on an unrendered section warns on no column"

rendered=$(run_dashboard) || fail "dashboard terminal view should render"
assert_contains "$rendered" "Todo 2 | In Progress 3 | Done 2" "terminal view starts with today board counts"
assert_contains "$rendered" "TODO" "todo section rendered"
assert_contains "$rendered" "IN PROGRESS" "in-progress section rendered"
assert_contains "$rendered" "DONE" "done section rendered"
assert_contains "$rendered" "[ ] Todo today [firstmate]" "todo task rendered"
assert_contains "$rendered" "[>] Build dashboard [firstmate]" "active task rendered"
assert_contains "$rendered" "[>] Held task [firstmate]" "held in-flight task rendered"
assert_contains "$rendered" "[ ] Mate queued today [materepo]" "secondmate queued task rendered"
assert_contains "$rendered" "[x] Finished today [firstmate]" "done task rendered"
assert_contains "$rendered" "[x] Mate landed today [mate-a]" "secondmate done task rendered"
assert_contains "$rendered" "in_flight showing 1 of 30" "the in-progress column discloses its truncation"
assert_contains "$rendered" "secondmate registry unavailable: read failed" "partial fleet data is visible in the sections it bounds"
assert_not_contains "$rendered" "gates showing 1 of 25" "a bound on no rendered column is not printed"
assert_not_contains "$rendered" "╭" "terminal board uses no box drawing"
assert_not_contains "$rendered" "●" "terminal board uses ascii markers"
assert_not_contains "$rendered" "Todo details stay saved" "terminal board hides saved details"
assert_not_contains "$rendered" "task paths" "unrelated omitted surfaces are not rendered as panel truncation"

# The Todo column is bounded like the others. The backlog is written in append
# order, so slicing it as read would hide exactly the rows filed most recently -
# the ones a today board exists to surface. Past the bound the column keeps the
# newest rows by filing date, undated last, and says how many it dropped.
cat > "$TMP_ROOT/fleet-many.json" <<JSON
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "$NOW",
  "backlog": {
    "records": [
$(for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    printf '      {"state":"queued","structured":true,"id":"todo-%s","title":"Queued %s","repo":"firstmate","kind":"ship","since":"2026-01-%02d"},\n' "$i" "$i" "$i"
  done)
      {"state":"queued","structured":true,"id":"todo-undated","title":"Queued undated","repo":"firstmate","kind":"ship"}
    ]
  },
  "tasks": [],
  "secondmate_landed": {"records": []}
}
JSON
json=$(FM_DASHBOARD_TEST_FLEET="$TMP_ROOT/fleet-many.json" \
  run_dashboard --json --force-refresh) || fail "bounded todo render should succeed"
assert_equals "10" "$(printf '%s' "$json" | jq -r '.widgets.board.todo.items | length')" "the todo column keeps its bound"
assert_equals "13" "$(printf '%s' "$json" | jq -r '.widgets.board.todo.count')" "the todo column reports the full queued count"
assert_equals "todo-12" "$(printf '%s' "$json" | jq -r '.widgets.board.todo.items[0].id')" "the newest queued row leads the todo column"
assert_equals "todo-3" "$(printf '%s' "$json" | jq -r '.widgets.board.todo.items[-1].id')" "the bound cuts from the oldest end"
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.board.todo.items[] | select(.id == "todo-1" or .id == "todo-2")] | length')" "the oldest queued rows are the ones dropped"
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.board.todo.items[] | select(.id == "todo-undated")] | length')" "an undated queued row sorts behind every dated one"
assert_equals "todo showing 10 of 13" "$(printf '%s' "$json" | jq -r '[.widgets.board.todo.omitted[] | select(.surface | startswith("todo showing"))] | .[0].surface')" "the todo column discloses the rows it dropped"
assert_contains "$(printf '%s' "$json" | jq -r '.widgets.board.todo.omitted[] | select(.surface | startswith("todo showing")) | .reveal')" "FM_DASHBOARD_TODO" "the todo disclosure names how to reveal the rest"
json=$(FM_DASHBOARD_TODO=20 FM_DASHBOARD_TEST_FLEET="$TMP_ROOT/fleet-many.json" \
  run_dashboard --json --force-refresh) || fail "raised todo bound render should succeed"
assert_equals "13" "$(printf '%s' "$json" | jq -r '.widgets.board.todo.items | length')" "raising the todo bound reveals the rest"
assert_equals "todo-undated" "$(printf '%s' "$json" | jq -r '.widgets.board.todo.items[-1].id')" "an undated queued row stays at the end"
assert_equals "0" "$(printf '%s' "$json" | jq -r '[.widgets.board.todo.omitted[] | select(.surface | startswith("todo showing"))] | length')" "a complete todo column discloses no drop"
if FM_DASHBOARD_TODO=0 run_dashboard --json >/dev/null 2>"$TMP_ROOT/todo.err"; then
  fail "a zero todo bound should not exit 0"
fi
assert_contains "$(cat "$TMP_ROOT/todo.err")" "FM_DASHBOARD_TODO requires a positive integer" "an unusable todo bound says so"
run_dashboard --json --force-refresh >/dev/null || fail "restored fleet render should succeed"

# The fleet collection obeys a freshness window, so a repeated render redraws from
# the cached snapshot instead of re-reading every registered home.
collected=$(fleet_collections)
json=$(run_dashboard --json) || fail "cached fleet render should succeed"
assert_equals "$collected" "$(fleet_collections)" "render inside the freshness window reuses the collected snapshot"
assert_equals "true" "$(printf '%s' "$json" | jq -r '.fleet.cached')" "a reused snapshot is reported as cached"
assert_equals "3" "$(printf '%s' "$json" | jq -r '.widgets.board.in_progress.items | length')" "a cached snapshot still fills the columns"
rendered=$(run_dashboard) || fail "cached terminal view should render"
assert_contains "$rendered" "old cached" "header discloses that the fleet snapshot came from cache"

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

# A failed fleet collection must stop rather than draw empty task sections as fleet state.
if FM_DASHBOARD_TEST_FLEET_FAIL=1 run_dashboard --force-refresh >"$TMP_ROOT/failed.out" 2>"$TMP_ROOT/failed.err"; then
  fail "a failed fleet collection should not exit 0"
fi
assert_equals "" "$(cat "$TMP_ROOT/failed.out")" "a failed fleet collection draws no board"
assert_contains "$(cat "$TMP_ROOT/failed.err")" "fleet snapshot" "a failed fleet collection names the failure"
if FM_DASHBOARD_TEST_FLEET_FAIL=1 run_dashboard --json --force-refresh >"$TMP_ROOT/failed.json" 2>/dev/null; then
  fail "a failed fleet collection should not exit 0 in JSON mode"
fi
assert_equals "" "$(cat "$TMP_ROOT/failed.json")" "a failed fleet collection emits no JSON document"

# Refresh is re-invocation, so the removed flags must be rejected rather than
# silently ignored by the parser.
for removed in "--watch" "--mark-seen" "--refresh-external"; do
  if run_dashboard "$removed" 1 >/dev/null 2>&1; then
    fail "$removed should not be accepted"
  fi
done

pass "fm-dashboard"
