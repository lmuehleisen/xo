#!/usr/bin/env bash
# fm-dispatch-history.sh - report private routing decisions without writing state.
#
# Usage: fm-dispatch-history.sh report [--home <dir>] [--since <YYYY-MM-DD>] [--task <id>] [--json]
#
# Read state/dispatch-history.jsonl under --home, else FM_HOME, else the code root
# (honoring FM_ROOT_OVERRIDE). A missing log is empty. FM_STATE_OVERRIDE does
# not apply. --since is inclusive from midnight UTC and filters spawns, not the
# earlier router calls they can join. --task matches an exact task id.
#
# Count and show each spawn, including relaunches, in log order. Use the latest
# preceding router call for that task, ignoring bare probes with no brief.
# Outcomes: followed, overridden, router_not_clear, or no_router_call. A clear
# recommendation is overridden by an explicit override or a difference on any
# profile axis the router set. Reason is the override reason when recorded,
# otherwise the router's reason for a non-clear decision.
#
# The default output is a summary and a TSV table with UTC times and
# harness/model/effort profiles. --json emits {summary, spawns} with Unix
# timestamps and structured profiles. Malformed lines are skipped with a
# line-number warning on stderr; their contents are not printed.

set -euo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() { printf 'fm-dispatch-history: %s\n' "$1" >&2; exit 2; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  report) shift ;;
  *) die "expected report (see --help)" ;;
esac

home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
since='' task='' json=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home|--since|--task)
      [ "$#" -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || die "$1 needs a value"
      case "$1" in
        --home) home=$2 ;;
        --since) since=$2 ;;
        --task) task=$2 ;;
      esac
      shift 2 ;;
    --json) json=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq required"
start=null
if [ -n "$since" ]; then
  start=$(jq -en --arg date "$since" '
    select($date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) |
    ($date + "T00:00:00Z" | fromdateiso8601) |
    select(strftime("%Y-%m-%d") == $date)' 2>/dev/null) || die "--since needs a valid UTC date (YYYY-MM-DD)"
fi

log="$home/state/dispatch-history.jsonl"
if [ -e "$log" ] || [ -L "$log" ]; then
  [ -f "$log" ] && [ -r "$log" ] || die "log is not a readable regular file: $log"
else
  log=/dev/null
fi

jq -nRr --arg task "$task" --argjson start "$start" --argjson json "$json" '
  def nonempty: type == "string" and length > 0;
  def profile: {harness, model: (.model | strings // null), effort: (.effort | strings // null)};
  def valid:
    if type != "object" then false
    elif (.time | type) != "number" or (.task_id | type) != "string" then false
    elif .kind == "spawn" then (.task_id | nonempty) and (.harness | nonempty)
    elif .kind == "router" then
      if .status == "clear" then (.suggested_profile | objects | .harness | nonempty) // false
      else (.status | IN("ambiguous", "escalate", "error", "off")) end
    else false end;
  def decision($router):
    (if $router.status == "clear" then $router.suggested_profile | profile else null end) as $recommended |
    profile as $used |
    ((.override_reason | strings | select(length > 0)) // null) as $override |
    (if $router == null then "no_router_call"
     elif $router.status != "clear" then "router_not_clear"
     elif $override != null or $recommended.harness != $used.harness
       or ($recommended.model != null and $recommended.model != $used.model)
       or ($recommended.effort != null and $recommended.effort != $used.effort)
     then "overridden"
     else "followed" end) as $outcome |
    {time, task_id, lane: ($router.lane | strings // null),
     confidence: ($router.confidence | numbers // null), router_status: $router.status,
     recommended_profile: $recommended, used_profile: $used, outcome: $outcome,
     reason: ($override // if $outcome == "router_not_clear" then ($router.reason | strings // null) else null end)};
  def show_profile:
    if . == null then "-" else [.harness, (.model // "-"), (.effort // "-")] | join("/") end;

  reduce inputs as $line (
    {routers: {}, spawns: [], summary: {followed: 0, overridden: 0, router_not_clear: 0, no_router_call: 0}};
    ($line | try fromjson catch null) as $row |
    if ($row | valid | not) then
      ("fm-dispatch-history: skipping malformed line \(input_line_number)\n" | stderr) as $_ | .
    elif $task != "" and $row.task_id != $task then .
    elif $row.kind == "router" then
      if $row.task_id == "" or ($row.brief_path | IN("", "/dev/null")) then .
      else .routers[$row.task_id] = $row end
    elif $start != null and $row.time < $start then .
    else
      .routers[$row.task_id] as $router |
      ($row | decision($router)) as $spawn |
      .spawns += [$spawn] | .summary[$spawn.outcome] += 1
    end
  ) | del(.routers) |
  if $json then . else
    "Spawns: \(.spawns | length) (followed: \(.summary.followed), overridden: \(.summary.overridden), router not clear: \(.summary.router_not_clear), no router call: \(.summary.no_router_call))",
    (["TIME (UTC)", "TASK", "LANE", "CONFIDENCE", "RECOMMENDED", "USED", "OUTCOME", "REASON"] | @tsv),
    (.spawns[] |
      [(try (.time | todateiso8601) catch null) // (.time | tostring),
       .task_id, (.lane // "-"), (.confidence // "-"), (.recommended_profile | show_profile),
       (.used_profile | show_profile), .outcome, (.reason // "-")] | @tsv)
  end' "$log"
