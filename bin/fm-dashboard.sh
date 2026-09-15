#!/usr/bin/env bash
# fm-dashboard.sh - render a local Firstmate dashboard for a Herdr-hosted pane.
#
# Usage:
#   fm-dashboard.sh [--json] [--watch <seconds>] [--refresh-external|--force-refresh]
#   fm-dashboard.sh --mark-seen <id>
#   fm-dashboard.sh --help
#
# The dashboard is terminal-first: it renders plain ANSI panels that work in any
# terminal, including a Herdr pane, and needs no Herdr plugin or TUI API today.
# A Herdr plugin launcher can come later without changing this projection.
#
# The dashboard collects the canonical fm-fleet-snapshot.sh document once per
# refresh and projects it twice: directly for the today summary, and through
# fm-bearings-snapshot.sh (FM_BEARINGS_SNAPSHOT_JSON) for the underway, gate, and
# landed panels, so every panel describes the same instant and one refresh costs one
# remote-ledger collection. That collection is itself reused from
# state/dashboard/cache/fleet.json while it is younger than the freshness window, so
# a --watch tick redraws from the cached snapshot instead of re-reading every remote
# home; the header reports the snapshot's age whenever a panel is drawn from cache.
# Collecting a fresh snapshot lets fm-fleet-snapshot.sh refresh its parent-side
# remote-ledger cache, which is the only fleet state any dashboard run writes.
# Microsoft 365 calendar and mail reads are optional and read-only: pass
# --refresh-external to refresh private cache files under state/dashboard/ through
# ~/.agents/skills/claude-connectors/query.py, which reuses a cached widget while it
# is younger than the freshness window (default 300s, FM_DASHBOARD_CACHE_TTL), so a
# --watch loop does not re-query the connector on every tick. --force-refresh
# bypasses that window. A failed refresh keeps the last good answer and reports the
# error alongside it, with the age of that answer. Any cached answer older than the
# freshness window reports its age whether or not the last refresh succeeded, so a
# plain run never presents a days-old agenda as current.
# Seen actions are local-only markers under state/dashboard/seen.jsonl.
# The script never mutates backlog, task state, calendar, mail, GitHub, Linear, or
# any Herdr session state.
# Panels disclose what the snapshot could not fully read: a bounded or partial
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
DASH_STATE="${FM_DASHBOARD_STATE_DIR:-$STATE/dashboard}"
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
      shift
      WATCH_SECONDS=${1:-}
      ;;
    --refresh-external) REFRESH_EXTERNAL=1 ;;
    --force-refresh) REFRESH_EXTERNAL=1; FORCE_REFRESH=1 ;;
    --mark-seen)
      shift
      MARK_SEEN_ID=${1:-}
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
  local tmpdir bearings fleet fleet_cache fleet_cached fleet_generated fleet_age calendar email seen out now today
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
  fleet_cached=0
  if [ "$FORCE_REFRESH" != 1 ] && cache_is_fresh "$fleet_cache"; then
    fleet_cached=1
    cat "$fleet_cache" > "$fleet" || { rm -rf "$tmpdir"; fail "cannot read cached fleet snapshot"; }
  else
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_SNAPSHOT_NOW="$now" \
      "$FLEET_CMD" --json > "$fleet" \
      || { rm -rf "$tmpdir"; fail "cannot read fleet snapshot"; }
    if ! { cp "$fleet" "$fleet_cache.tmp" && mv "$fleet_cache.tmp" "$fleet_cache"; }; then
      rm -f "$fleet_cache.tmp"
      rm -rf "$tmpdir"
      fail "cannot publish fleet cache"
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
      ((arr($f0.backlog.records)
          | map(select(landed_record and .completion.date == $today)
              | {id,title,kind,completion,owner:"(main)",artifact:(landed_artifact // "-")}))
        + (arr($f0.secondmate_landed.records)
          | map(select(.completion.date == $today)
              | {id,title,kind,completion,owner:(.home_id // "-"),artifact:(landed_artifact // "-")}))) as $done_today
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
            }
          }
        }
    ' > "$out" || { rm -rf "$tmpdir"; fail "cannot build dashboard model"; }
  cat "$out"
  rm -rf "$tmpdir"
}

panel() { # <title> <body>
  local title=$1 body=${2:-}
  printf '\n┌─ %s\n' "$title"
  if [ -n "$body" ]; then
    printf '%s\n' "$body" | sed 's/^/│ /'
  else
    printf '│ (none)\n'
  fi
  printf '└\n'
}

external_body() { # <json> <widget> <fallback>
  printf '%s' "$1" | jq -r --arg widget "$2" --arg fallback "$3" --argjson ttl "$CACHE_TTL_SECONDS" '
    def age_label($seconds):
      if $seconds < 3600 then "\($seconds / 60 | floor)m"
      elif $seconds < 86400 then "\($seconds / 3600 | floor)h"
      else "\($seconds / 86400 | floor)d"
      end;
    (.widgets[$widget] // {}) as $w
    | ($w.answer // "") as $answer
    | ($w.answer_age_seconds // null) as $age
    | if $answer == "" then ($w.message // $fallback)
      elif ($w.ok // false) then
        $answer
        + (if $age != null and $age > $ttl then "\n(collected " + age_label($age) + " ago)" else "" end)
      else $answer + "\n(stale"
           + (if $age == null then "" else " for " + age_label($age) end)
           + ": " + ($w.message // $fallback) + ")"
      end'
}

BOUNDED_NOTE_JQ='
  def bounded_note:
    (.omitted // [])[]
    | "\u2026 " + (.surface // "bounded") + " (reveal: " + (.reveal // "-") + ")";
'

render_dashboard() {
  local json=$1 header body
  header=$(printf '%s' "$json" | jq -r '
    "Firstmate dashboard " + .generated +
    (.fleet as $f
     | if ($f.cached // false) then " \u00b7 fleet \((($f.age_seconds // 0) / 60 | floor))m old (cached)" else "" end) +
    (if .herdr.detected then " · Herdr " + (.herdr.session // "session") else " · Herdr not detected" end)
  ')
  printf '%s\n' "$header"

  body=$(external_body "$json" calendar 'calendar unavailable')
  panel 'Next calendar events' "$body"

  body=$(external_body "$json" email 'email unavailable')
  panel 'Important emails' "$body"

  body=$(printf '%s' "$json" | jq -r "$BOUNDED_NOTE_JQ"'
    (.widgets.working.items[]? | "- \(.name // .id) [\(.repo // "-")] - \(.state // "unknown"): \(.doing // "")"),
    (.widgets.working | bounded_note)')
  panel 'Current working tasks' "$body"

  body=$(printf '%s' "$json" | jq -r "$BOUNDED_NOTE_JQ"'
    (.widgets.next.items[]? | "- \(.title // .id) [\(.owner // "-")] - \(.reason // "-")"),
    (.widgets.next | bounded_note)')
  panel 'Next tasks' "$body"

  body=$(printf '%s' "$json" | jq -r "$BOUNDED_NOTE_JQ"'
    (.widgets.done.items[]? | "- \(.what // .id) (\(.owner // "-"))"),
    (.widgets.done | bounded_note)')
  panel 'Done actions' "$body"

  body=$(printf '%s' "$json" | jq -r "$BOUNDED_NOTE_JQ"'
    (.widgets.seen.items[]? | "- \(.at): \(.id)"),
    (.widgets.seen | bounded_note)')
  panel 'Seen actions' "$body"

  body=$(printf '%s' "$json" | jq -r "$BOUNDED_NOTE_JQ"'
    .widgets.today.summary,
    (.widgets.today.items[]? | "- \(.title // .id) [\(.owner // "-")] \(.completion.verb // "done") \(.completion.date // "")"),
    (.widgets.today | bounded_note)')
  panel 'Today summary' "$body"
}

run_once() {
  local json
  json=$(gather_dashboard_json)
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
    run_once
    sleep "$WATCH_SECONDS"
  done
else
  run_once
fi
