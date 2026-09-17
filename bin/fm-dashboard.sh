#!/usr/bin/env bash
# fm-dashboard.sh - render a local Firstmate today board for a Herdr-hosted pane.
#
# Usage:
#   fm-dashboard.sh [--json] [--force-refresh]
#   fm-dashboard.sh --help
#
# The dashboard is terminal-first: it renders plain ANSI Todo, In Progress, and
# Done panels that work in any terminal, including a Herdr pane, and needs no Herdr
# plugin or TUI API today.
# A Herdr plugin launcher can come later without changing this projection.
#
# The dashboard collects the canonical fm-fleet-snapshot.sh document once per
# refresh and projects it twice: directly for today's Todo and Done board columns,
# and through fm-bearings-snapshot.sh (FM_BEARINGS_SNAPSHOT_JSON) for the active
# In Progress column, so every column describes the same instant and one refresh
# costs one remote-ledger collection. That collection is itself reused from
# state/dashboard/cache/fleet.json while it is younger than the freshness window
# (default 300s, FM_DASHBOARD_CACHE_TTL), so a re-run redraws from the cached
# snapshot instead of re-reading every remote home; the header reports the
# snapshot's age whenever a panel is drawn from cache. That reuse is keyed on the
# FM_SNAPSHOT_* collection settings as well as age, so raising a bound a panel's
# disclosure names re-collects instead of replaying a snapshot collected under the
# old bound. --force-refresh bypasses the freshness window for one run.
# Collecting a fresh snapshot lets fm-fleet-snapshot.sh refresh its parent-side
# remote-ledger cache, which is the only fleet state any dashboard run writes.
# All three columns are fleet-scoped: each unions this home's backlog rows with the
# registered secondmate homes' own structured rows, so a task is visible as todo
# before it shows up in progress and again once it lands. In Progress keeps every
# live in-flight row, including held rows and programs that the bearings projection
# routes to its own decision and gate sections. A secondmate home publishes one
# captain-actionable inventory that mixes queued and held in-flight rows, so the
# board splits it on the row's own state rather than reading all of it as todo, and
# namespaces those rows as <home>/<id> so a row both projections carry is listed once.
# The Todo column shows the newest FM_DASHBOARD_TODO queued rows by filing date
# (default 10, undated last) and discloses the rest rather than printing the whole
# backlog.
# Saved task details come from backlog body text and stay in JSON; the terminal
# board intentionally hides them.
# The script never mutates backlog, task state, GitHub, Linear, or any Herdr
# session state.
# Columns disclose what the snapshot could not fully read: a bounded or partial
# section prints a concise trailing line naming the gap and how to reveal it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-landed-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-landed-lib.sh"  # FM_LANDED_JQ_DEFS: the shared landed selector
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DASH_STATE="$STATE/dashboard"
BEARINGS_CMD="${FM_DASHBOARD_BEARINGS_CMD:-$SCRIPT_DIR/fm-bearings-snapshot.sh}"
FLEET_CMD="${FM_DASHBOARD_FLEET_CMD:-$SCRIPT_DIR/fm-fleet-snapshot.sh}"
CACHE_TTL_SECONDS="${FM_DASHBOARD_CACHE_TTL:-300}"
TODO_LIMIT="${FM_DASHBOARD_TODO:-10}"

FORMAT=terminal
FORCE_REFRESH=0

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-dashboard: %s\n' "$*" >&2
  exit 1
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
today_utc() { date -u +%Y-%m-%d; }

while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --force-refresh) FORCE_REFRESH=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

case "$CACHE_TTL_SECONDS" in
  ''|*[!0-9]*) fail "FM_DASHBOARD_CACHE_TTL requires a non-negative integer" ;;
esac

case "$TODO_LIMIT" in
  ''|*[!0-9]*|0) fail "FM_DASHBOARD_TODO requires a positive integer" ;;
esac

command -v jq >/dev/null 2>&1 || fail "jq is required"

ensure_state() {
  (umask 077; mkdir -p "$DASH_STATE/cache") || fail "cannot create dashboard state: $DASH_STATE"
}

utc_to_epoch() { # <timestamp>
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z) ;;
    *) return 1 ;;
  esac
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null \
    || return 1
}

cache_is_fresh() { # <path>
  [ "$CACHE_TTL_SECONDS" -gt 0 ] || return 1
  [ -s "$1" ] || return 1
  local generated epoch now
  generated=$(jq -r '.generated // ""' "$1" 2>/dev/null) || return 1
  epoch=$(utc_to_epoch "$generated") || return 1
  now=$(date -u +%s)
  [ "$((now - epoch))" -lt "$CACHE_TTL_SECONDS" ]
}

fleet_collection_settings() {
  env | sed -n 's/^\(FM_SNAPSHOT_[A-Z0-9_]*=.*\)$/\1/p' \
    | grep -v '^FM_SNAPSHOT_NOW' \
    | LC_ALL=C sort
}

gather_dashboard_json() {
  local tmpdir bearings fleet fleet_cache fleet_settings fleet_cached fleet_generated fleet_age out now today cache_tmp
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-dashboard.XXXXXX") || fail "cannot create temp dir"
  bearings="$tmpdir/bearings.json"
  fleet="$tmpdir/fleet.json"
  out="$tmpdir/dashboard.json"
  now=$(now_utc)
  today=$(today_utc)

  ensure_state
  fleet_cache="$DASH_STATE/cache/fleet.json"
  fleet_settings=$(fleet_collection_settings)
  fleet_cached=0
  if [ "$FORCE_REFRESH" != 1 ] && cache_is_fresh "$fleet_cache" \
    && [ "$fleet_settings" = "$(cat "$fleet_cache.settings" 2>/dev/null)" ]; then
    fleet_cached=1
    cat "$fleet_cache" > "$fleet" || { rm -rf "$tmpdir"; fail "cannot read cached fleet snapshot"; }
  else
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_SNAPSHOT_NOW="$now" \
      "$FLEET_CMD" --json > "$fleet" \
      || { rm -rf "$tmpdir"; fail "cannot read fleet snapshot"; }
    cache_tmp=$(mktemp "$DASH_STATE/cache/.fleet.XXXXXX") \
      || { rm -rf "$tmpdir"; fail "cannot create fleet cache temp file"; }
    if ! { cp "$fleet" "$cache_tmp" && mv "$cache_tmp" "$fleet_cache"; }; then
      rm -f "$cache_tmp"
      rm -rf "$tmpdir"
      fail "cannot publish fleet cache"
    fi
    cache_tmp=$(mktemp "$DASH_STATE/cache/.fleet-settings.XXXXXX") \
      || { rm -rf "$tmpdir"; fail "cannot create fleet cache settings temp file"; }
    if ! { printf '%s\n' "$fleet_settings" > "$cache_tmp" \
      && mv "$cache_tmp" "$fleet_cache.settings"; }; then
      rm -f "$cache_tmp"
      rm -rf "$tmpdir"
      fail "cannot publish fleet cache settings"
    fi
  fi
  fleet_generated=$(jq -r '.generated // ""' "$fleet") \
    || { rm -rf "$tmpdir"; fail "cannot read fleet snapshot instant"; }
  [ -n "$fleet_generated" ] || fleet_generated=$now
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_BEARINGS_NOW="$fleet_generated" \
    FM_BEARINGS_SNAPSHOT_JSON="$fleet" "$BEARINGS_CMD" --json > "$bearings" \
    || { rm -rf "$tmpdir"; fail "cannot read bearings snapshot"; }

  fleet_age=$(( $(date -u +%s) - $(utc_to_epoch "$fleet_generated" || date -u +%s) ))
  [ "$fleet_age" -ge 0 ] || fleet_age=0

  jq -n \
    --slurpfile b "$bearings" \
    --slurpfile f "$fleet" \
    --arg generated "$now" \
    --arg fleet_generated "$fleet_generated" \
    --argjson fleet_age "$fleet_age" \
    --argjson fleet_cached "$fleet_cached" \
    --argjson todo_limit "$TODO_LIMIT" \
    --arg today "$today" \
    --arg fm_home "$FM_HOME" "$FM_LANDED_JQ_DEFS"'
      def arr($x): if ($x | type) == "array" then $x else [] end;
      ($b[0] // {}) as $b0
      | ($f[0] // {}) as $f0
      | (arr($b0.omitted)) as $omitted
      | def panels_bounded:
          if startswith("secondmate home Done capped") then ["done"]
          elif startswith("in_flight") or startswith("main in-flight")
            or test("^secondmate .+ active children omitted") then ["in_progress"]
          elif test("^secondmate .+ queued rows omitted") then ["todo","in_progress"]
          elif startswith("main unstructured current backlog") then ["todo","in_progress"]
          elif startswith("secondmate registry")
            or startswith("registered secondmates omitted")
            or startswith("secondmate home(s) with unreadable structured state")
            or test(" served from cached home ledger$") then ["todo","in_progress","done"]
          else [] end;
      def omitted_for($panel):
          [ $omitted[] | select((((.surface // "") | panels_bounded) | index($panel)) != null) ];
      def structured_homes:
          arr($f0.secondmate_current.records)
          | map(select(.provenance.selected == "structured-home"));
      def task_detail($id):
          ([arr($f0.tasks)[]? | select(.id == $id) | .backlog.body_excerpt // empty][0]
           // [structured_homes[] as $m
               | arr($m.active_children)[]
               | select(($m.id + "/" + .id) == $id)
               | .body_excerpt // empty][0]
           // null);
      def task_state($id):
          ([arr($f0.tasks)[]? | select(.id == $id) | .current_state // empty][0] // null);
      def since_epoch:
          (.since // null) as $s
          | if ($s | type) != "string" then null
            elif ($s | test("T")) then (try ($s | fromdateiso8601) catch null)
            else (try (($s + "T00:00:00Z") | fromdateiso8601) catch null) end;
      def newest_since_first:
          to_entries
          | sort_by((.value | since_epoch) as $epoch
              | if $epoch == null then [1, 0, .key] else [0, -$epoch, .key] end)
          | map(.value);
      (structured_homes
        | map(. as $m
            | arr($m.queued)
            | map({id:($m.id + "/" + .id),title,kind,repo,owner:$m.id,
                   state:(.state // "queued"),
                   reason:(.blocked_reason // .hold_reason // null),
                   since:(.since // null),details:(.body_excerpt // null)}))
        | add // []) as $secondmate_inventory
      | ((arr($f0.backlog.records)
        | map(select(.state == "queued" and .structured == true)
            | {id,title,kind,repo,owner:"(main)",reason:(.blocked_reason // null),
               since:(.since // null),details:(.body_excerpt // null)}))
       + ($secondmate_inventory
          | map(select(.state != "in_flight") | del(.state)))
       | newest_since_first) as $todo_all
      | ($todo_all[:$todo_limit]) as $todo_today
      | (arr($b0.in_flight) | map(.id)) as $in_flight_ids
      | ((arr($b0.in_flight)
          | map({id,title:(.name // .id),kind,repo,state,doing:(.doing // .state // null),
                 owner:((.id | split("/")) as $parts
                        | if ($parts | length) > 1 then $parts[0] else "(main)" end),
                 details:task_detail(.id)}))
        + (arr($f0.backlog.records)
          | map(select(.structured == true and .state == "in_flight")
              | . as $r
              | select(($in_flight_ids | index($r.id)) == null)
              | task_state($r.id) as $t
              | {id,title,kind,repo,
                 state:($t.state // .current_role // "held"),
                 doing:(.hold_reason // $t.detail // .current_role // null),
                 owner:"(main)",details:(.body_excerpt // null)}))
        + ($secondmate_inventory
          | map(. as $r
              | select($r.state == "in_flight")
              | select(($in_flight_ids | index($r.id)) == null)
              | {id,title,kind,repo,state,
                 doing:(.reason // .state),
                 owner,details}))) as $in_progress_today
      | ((arr($f0.backlog.records)
          | map(select(landed_record and .completion.date == $today)
              | {id,title,kind,repo,completion,owner:"(main)",details:(.body_excerpt // null),
                 artifact:(landed_artifact // "-")}))
        + (arr($f0.secondmate_landed.records)
          | map(select(.completion.date == $today)
              | {id,title,kind,completion,owner:(.home_id // "-"),details:(.body_excerpt // null),
                 artifact:(landed_artifact // "-")}))) as $done_today
      | {
          schema:"fm-dashboard.v1",
          generated:$generated,
          home:$fm_home,
          today:$today,
          fleet:{generated:$fleet_generated,age_seconds:$fleet_age,cached:($fleet_cached == 1)},
          widgets:{
            board:{
              todo:{
                items:$todo_today,
                count:($todo_all | length),
                omitted:(omitted_for("todo")
                  + (if ($todo_all | length) > $todo_limit
                     then [{surface:"todo showing \($todo_limit) of \($todo_all | length)",
                            reveal:"raise FM_DASHBOARD_TODO"}]
                     else [] end))
              },
              in_progress:{items:$in_progress_today,omitted:omitted_for("in_progress")},
              done:{items:$done_today,omitted:omitted_for("done")}
            }
          }
        }
    ' > "$out" || { rm -rf "$tmpdir"; fail "cannot build dashboard model"; }
  cat "$out"
  rm -rf "$tmpdir"
}

terminal_columns() {
  local cols=${COLUMNS:-}
  [ -n "$cols" ] || cols=$({ stty size </dev/tty; } 2>/dev/null | cut -d' ' -f2)
  case "$cols" in
    ''|*[!0-9]*) cols=100 ;;
  esac
  [ "$cols" -gt 120 ] && cols=120
  [ "$cols" -lt 60 ] && cols=60
  printf '%s\n' "$cols"
}

clip_ascii_lines() { # <width>
  local width=$1
  awk -v width="$width" '
    length($0) > width { print substr($0, 1, width - 3) "..."; next }
    { print }
  '
}

render_dashboard() {
  local json=$1 header stats cols rule_width rule
  cols=$(terminal_columns)
  rule_width=$((cols - 1))
  rule=$(printf '%*s' "$rule_width" '' | tr ' ' '-')
  header=$(printf '%s' "$json" | jq -r '
    "Firstmate today board " + .generated +
    (.fleet as $f
     | if ($f.cached // false) then " | fleet \((($f.age_seconds // 0) / 60 | floor))m old cached" else "" end)
  ')
  stats=$(printf '%s' "$json" | jq -r '
    "Todo \((.widgets.board.todo.items // []) | length)" +
    " | In Progress \((.widgets.board.in_progress.items // []) | length)" +
    " | Done \((.widgets.board.done.items // []) | length)"
  ')
  {
    printf '%s
%s
%s
' "$header" "$stats" "$rule"
    printf '%s' "$json" | jq -r '
      def owner($x):
        ($x.repo // $x.owner // "") as $owner
        | if $owner == "" then "" else " [" + ($owner | tostring) + "]" end;
      def line($mark; $x):
        "  " + $mark + " " + (($x.title // $x.name // $x.id) | tostring) + owner($x);
      def note($w):
        ($w.omitted // [])[]? | "  ! " + (.surface // "bounded") + " (reveal: " + (.reveal // "-") + ")";
      def section($name; $mark; $w):
        $name,
        (($name | gsub("."; "-"))),
        (if (($w.items // []) | length) == 0 then "  - none"
         else ($w.items[] | line($mark; .)) end),
        note($w),
        "";
      section("TODO"; "[ ]"; .widgets.board.todo),
      section("IN PROGRESS"; "[>]"; .widgets.board.in_progress),
      section("DONE"; "[x]"; .widgets.board.done)
    '
  } | clip_ascii_lines "$rule_width"
}

json=$(gather_dashboard_json) || exit 1
if [ "$FORMAT" = json ]; then
  printf '%s\n' "$json"
else
  render_dashboard "$json"
fi
