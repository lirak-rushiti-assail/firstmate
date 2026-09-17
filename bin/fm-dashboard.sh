#!/usr/bin/env bash
# fm-dashboard.sh - render a local Firstmate today board for a Herdr-hosted pane.
#
# Usage:
#   fm-dashboard.sh [--json] [--watch <seconds>] [--refresh-external|--force-refresh]
#   fm-dashboard.sh --mark-seen <id>
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
# state/dashboard/cache/fleet.json while it is younger than the freshness window, so
# a --watch tick redraws from the cached snapshot instead of re-reading every remote
# home; the header reports the snapshot's age whenever a panel is drawn from cache.
# That reuse is keyed on the FM_SNAPSHOT_* collection settings as well as age, so
# raising a bound a panel's disclosure names re-collects instead of replaying a
# snapshot collected under the old bound.
# Collecting a fresh snapshot lets fm-fleet-snapshot.sh refresh its parent-side
# remote-ledger cache, which is the only fleet state any dashboard run writes.
# Microsoft 365 calendar and mail reads are optional and read-only cache refreshes:
# pass --refresh-external to refresh private cache files under state/dashboard/
# through ~/.agents/skills/claude-connectors/query.py. The terminal board no longer
# renders those widgets, but JSON keeps them for callers that still inspect the
# cached data. The cache is reused while younger than the freshness window (default
# 300s, FM_DASHBOARD_CACHE_TTL), and --force-refresh bypasses that window. A failed
# refresh keeps the last good answer and reports the error alongside it, with the
# age of that answer.
# Seen actions are local-only markers under state/dashboard/seen.jsonl and remain in
# JSON, but the terminal board does not render them.
# Saved task details come from backlog body text and stay in JSON; the terminal
# board intentionally hides them.
# The script never mutates backlog, task state, calendar, mail, GitHub, Linear, or
# any Herdr session state.
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
M365_HELPER="${FM_DASHBOARD_M365_HELPER:-$HOME/.agents/skills/claude-connectors/query.py}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
CACHE_TTL_SECONDS="${FM_DASHBOARD_CACHE_TTL:-300}"
SEEN_LIMIT=12
SEEN_READABLE=1

FORMAT=terminal
WATCH_SECONDS=
REFRESH_EXTERNAL=0
FORCE_REFRESH=0
MARK_SEEN_ID=

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
    --watch)
      [ $# -ge 2 ] || fail "--watch requires a positive integer"
      shift
      [ -n "$1" ] || fail "--watch requires a positive integer"
      WATCH_SECONDS=$1
      ;;
    --refresh-external) REFRESH_EXTERNAL=1 ;;
    --force-refresh) REFRESH_EXTERNAL=1; FORCE_REFRESH=1 ;;
    --mark-seen)
      [ $# -ge 2 ] || fail "--mark-seen requires an id"
      shift
      [ -n "$1" ] || fail "--mark-seen requires an id"
      MARK_SEEN_ID=$1
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

case "$WATCH_SECONDS" in
  ''|*[!0-9]*) [ -z "$WATCH_SECONDS" ] || fail "--watch requires a positive integer" ;;
  0) fail "--watch requires a positive integer" ;;
esac

case "$CACHE_TTL_SECONDS" in
  ''|*[!0-9]*) fail "FM_DASHBOARD_CACHE_TTL requires a non-negative integer" ;;
esac

command -v jq >/dev/null 2>&1 || fail "jq is required"

ensure_state() {
  (umask 077; mkdir -p "$DASH_STATE/cache") || fail "cannot create dashboard state: $DASH_STATE"
}

mark_seen() {
  [ -n "$MARK_SEEN_ID" ] || fail "--mark-seen requires an id"
  ensure_state
  local tmp at
  tmp=$(mktemp "$DASH_STATE/.seen.XXXXXX") || fail "cannot create seen marker"
  at=$(now_utc)
  jq -nc --arg at "$at" --arg id "$MARK_SEEN_ID" \
    '{at:$at,id:$id}' > "$tmp" || { rm -f "$tmp"; fail "cannot encode seen marker"; }
  cat "$tmp" >> "$DASH_STATE/seen.jsonl" || { rm -f "$tmp"; fail "cannot append seen marker"; }
  rm -f "$tmp"
  printf 'seen: %s\n' "$MARK_SEEN_ID"
}

cache_placeholder() { # <message>
  jq -nc --arg generated "$(now_utc)" --arg message "$1" \
    '{generated:$generated,ok:false,answer:null,message:$message}'
}

cache_file_or_placeholder() { # <path> <message>
  if [ -s "$1" ]; then
    cat "$1"
  else
    cache_placeholder "$2"
  fi
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

cache_last_good_answer() { # <path>
  [ -s "$1" ] || return 0
  jq -r '.answer // "" | if type == "string" then . else "" end' "$1" 2>/dev/null
}

cache_answer_generated() { # <path>
  [ -s "$1" ] || return 0
  jq -r '(.answer_generated // .generated // "") | if type == "string" then . else "" end' "$1" 2>/dev/null
}

refresh_m365_cache() { # <kind> <prompt> <dest>
  local kind=$1 prompt=$2 dest=$3 out rc tmp last_good last_good_at
  ensure_state
  if [ "$FORCE_REFRESH" != 1 ] && cache_is_fresh "$dest"; then
    return 0
  fi
  tmp=$(mktemp "$DASH_STATE/cache/.${kind}.XXXXXX") || fail "cannot create cache file"
  last_good=$(cache_last_good_answer "$dest")
  last_good_at=$(cache_answer_generated "$dest")
  if [ ! -f "$M365_HELPER" ]; then
    out="M365 helper not found: $M365_HELPER"
    rc=1
  else
    out=$("$PYTHON_BIN" "$M365_HELPER" m365 "$prompt" --max-turns 8 --timeout 120 2>&1)
    rc=$?
  fi
  [ -n "$out" ] || out="$kind connector failed (exit $rc) with no output"
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '.ok == true' >/dev/null 2>&1; then
    printf '%s' "$out" | jq -c --arg generated "$(now_utc)" \
      '{generated:$generated,answer_generated:$generated,ok:(.ok == true),answer:(.answer // ""),message:null}' > "$tmp" \
      || { rm -f "$tmp"; fail "cannot parse $kind connector output"; }
  else
    jq -nc --arg generated "$(now_utc)" --arg message "$out" --arg answer "$last_good" \
      --arg answer_generated "$last_good_at" \
      '{generated:$generated,
        answer_generated:(if $answer == "" or $answer_generated == "" then null else $answer_generated end),
        ok:false,answer:(if $answer == "" then null else $answer end),message:$message}' > "$tmp" \
      || { rm -f "$tmp"; fail "cannot write $kind connector error"; }
  fi
  mv "$tmp" "$dest" || fail "cannot publish $kind cache"
}

refresh_external() {
  refresh_m365_cache calendar \
    'List my next five calendar events from now, with start/end times, timezone, title, and meeting link presence. Return concise plain text bullets only.' \
    "$DASH_STATE/cache/calendar.json"
  refresh_m365_cache email \
    'List up to five important emails needing attention from the last seven days: unread, high-importance, directly addressed, or from key people. Include sender, subject, age, and why it matters. Return concise plain text bullets only.' \
    "$DASH_STATE/cache/email.json"
}

make_seen_json() { # <dest>
  local dest=$1
  SEEN_READABLE=1
  [ -s "$DASH_STATE/seen.jsonl" ] || { printf '[]\n' > "$dest"; return 0; }
  jq -s 'map(select(type == "object")) | reverse' "$DASH_STATE/seen.jsonl" > "$dest" 2>/dev/null \
    && return 0
  SEEN_READABLE=0
  printf '[]\n' > "$dest"
}

gather_dashboard_json() {
  local tmpdir bearings fleet fleet_cache fleet_settings fleet_cached fleet_generated fleet_age calendar email seen out now today cache_tmp
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-dashboard.XXXXXX") || fail "cannot create temp dir"
  bearings="$tmpdir/bearings.json"
  fleet="$tmpdir/fleet.json"
  calendar="$tmpdir/calendar.json"
  email="$tmpdir/email.json"
  seen="$tmpdir/seen.json"
  out="$tmpdir/dashboard.json"
  now=$(now_utc)
  today=$(today_utc)

  if [ "$REFRESH_EXTERNAL" = 1 ]; then
    refresh_external
  fi

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
  cache_file_or_placeholder "$DASH_STATE/cache/calendar.json" "Run fm-dashboard.sh --refresh-external to populate calendar events." > "$calendar"
  cache_file_or_placeholder "$DASH_STATE/cache/email.json" "Run fm-dashboard.sh --refresh-external to populate important emails." > "$email"
  make_seen_json "$seen"

  fleet_age=$(( $(date -u +%s) - $(utc_to_epoch "$fleet_generated" || date -u +%s) ))
  [ "$fleet_age" -ge 0 ] || fleet_age=0

  jq -n \
    --slurpfile b "$bearings" \
    --slurpfile f "$fleet" \
    --slurpfile calendar "$calendar" \
    --slurpfile email "$email" \
    --slurpfile seen "$seen" \
    --arg generated "$now" \
    --arg fleet_generated "$fleet_generated" \
    --arg seen_path "$DASH_STATE/seen.jsonl" \
    --argjson seen_readable "$SEEN_READABLE" \
    --arg now_epoch "$(date -u +%s)" \
    --argjson seen_limit "$SEEN_LIMIT" \
    --argjson fleet_age "$fleet_age" \
    --argjson fleet_cached "$fleet_cached" \
    --arg today "$today" \
    --arg fm_home "$FM_HOME" \
    --arg herdr_env "${HERDR_ENV:-}" \
    --arg herdr_session "${HERDR_SESSION:-}" "$FM_LANDED_JQ_DEFS"'
      def arr($x): if ($x | type) == "array" then $x else [] end;
      ($b[0] // {}) as $b0
      | ($f[0] // {}) as $f0
      | (arr($b0.omitted)) as $omitted
      | def panels_bounded:
          if startswith("secondmate home Done capped") then ["done","today"]
          elif startswith("landed") then ["done"]
          elif startswith("in_flight") or startswith("main in-flight")
            or test("^secondmate .+ active children omitted") then ["working"]
          elif startswith("gates") then ["next"]
          elif startswith("main unstructured current backlog") then ["working","next"]
          elif startswith("secondmate registry")
            or startswith("registered secondmates omitted")
            or startswith("secondmate home(s) with unreadable structured state")
            or test(" served from cached home ledger$") then ["done","working","next","today"]
          else [] end;
      def with_answer_age:
          ($now_epoch | tonumber) as $now
          | . + {answer_age_seconds:
              ((.answer_generated // null) as $t
               | if ($t | type) != "string" then null
                 else (try ($t | fromdateiso8601) catch null) as $at
                      | if $at == null then null else ($now - $at) end
                 end)};
      def omitted_for($panel):
          [ $omitted[] | select((((.surface // "") | panels_bounded) | index($panel)) != null) ];
      def task_detail($id):
          ([arr($f0.tasks)[]? | select(.id == $id) | .backlog.body_excerpt // empty][0] // null);
      (arr($f0.backlog.records)
        | map(select(.state == "queued" and .structured == true)
            | {id,title,kind,repo,owner:"(main)",reason:(.blocked_reason // null),
               since:(.since // null),details:(.body_excerpt // null)})) as $todo_today
      | (arr($b0.in_flight)
        | map({id,title:(.name // .id),kind,repo,state,doing:(.doing // .state // null),
               owner:(.owner // "(main)"),details:task_detail(.id)})) as $in_progress_today
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
          herdr:{
            detected:($herdr_env != ""),
            session:(if $herdr_session != "" then $herdr_session else null end)
          },
          widgets:{
            calendar:(($calendar[0] // {}) | with_answer_age),
            email:(($email[0] // {}) | with_answer_age),
            seen:{
              items:(($seen[0] // [])[:$seen_limit]),
              count:(($seen[0] // []) | length),
              readable:($seen_readable == 1),
              omitted:(($seen[0] // []) | length as $n
                | (if $n > $seen_limit
                   then [{surface:"seen showing \($seen_limit) of \($n)",reveal:("inspect " + $seen_path)}]
                   else [] end)
                + (if $seen_readable == 1 then []
                   else [{surface:"seen ledger unreadable",reveal:("inspect " + $seen_path)}] end))
            },
            done:{items:arr($b0.landed),omitted:omitted_for("done")},
            working:{items:arr($b0.in_flight),omitted:omitted_for("working")},
            next:{items:arr($b0.gates),omitted:omitted_for("next")},
            today:{
              items:$done_today,
              count:($done_today | length),
              omitted:omitted_for("today"),
              summary:(if ($done_today | length) == 0 then "Nothing landed today." else "\(($done_today | length)) landed today." end)
            },
            board:{
              todo:{items:$todo_today,omitted:omitted_for("next")},
              in_progress:{items:$in_progress_today,omitted:omitted_for("working")},
              done:{items:$done_today,omitted:omitted_for("today")}
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
     | if ($f.cached // false) then " | fleet \((($f.age_seconds // 0) / 60 | floor))m old cached" else "" end) +
    (if .herdr.detected then " | Herdr " + (.herdr.session // "session") else " | Herdr not detected" end)
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

run_once() {
  local json
  json=$(gather_dashboard_json) || return 1
  if [ "$FORMAT" = json ]; then
    printf '%s\n' "$json"
  else
    render_dashboard "$json"
  fi
}

if [ -n "$MARK_SEEN_ID" ]; then
  mark_seen
  exit 0
fi

if [ -n "$WATCH_SECONDS" ]; then
  while :; do
    printf '\033[H\033[2J'
    run_once || printf 'fm-dashboard: refresh failed; retrying in %ss\n' "$WATCH_SECONDS" >&2
    sleep "$WATCH_SECONDS"
  done
else
  run_once
fi
