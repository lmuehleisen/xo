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
# Count and show each spawn, including relaunches, in log order. Pair it with
# the router call whose resolution_id it carries. Only older spawns without
# that field use the preceding router call for the task, ignoring bare probes.
# Outcomes: followed, overridden, router_not_clear, or no_router_call. A clear
# recommendation is overridden by an explicit override or a difference on any
# profile axis the router set. Reason is the override reason when recorded,
# otherwise the router's reason for a non-clear decision.
# Each spawn also shows lane (the resolved lane), final_lane (the lane bound
# to the launched profile, null for an unattributable override), router_lane (the lane of the
# router model's raw pick for that resolution, or a prior call on the same
# task and checker input for a supervisor's --lane follow-up),
# shadow_lane and check_action (the top-lane check's pick and action), and,
# from the first cleanup outcome entry after it, result, relaunches, and
# review_rounds. Rows older than these fields leave them null.
# The summary adds lane_check action counts and agreement counts
# ({compared, same}) for router vs shadow, shadow vs final, and router vs final
# lanes over launches that are not relaunches, plus outcomes per final lane
# counted once per task. --since and --task filter spawns; router and outcome
# entries they join are read from the whole log.
#
# The default output is the summary lines and a TSV table with UTC times and
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
  if ! start=$(jq -en --arg date "$since" '
    select($date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) |
    ($date + "T00:00:00Z" | fromdateiso8601) |
    select(strftime("%Y-%m-%d") == $date)' 2>/dev/null) || [ -z "$start" ]; then
    die "--since needs a valid UTC date (YYYY-MM-DD)"
  fi
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
    elif .kind == "outcome" then (.task_id | nonempty) and (.result | nonempty)
    elif .kind == "router" then
      if .status == "clear" then (.suggested_profile | objects | .harness | nonempty) // false
      else (.status | IN("ambiguous", "escalate", "error", "off")) end
    else false end;
  def decision($router):
    (if $router.status == "clear" then $router.suggested_profile | profile else null end) as $recommended |
    profile as $used |
    ((.override_reason | strings | select(length > 0)) // null) as $override |
    ($recommended != null and $recommended.harness == $used.harness and
      ($recommended.model == null or $recommended.model == $used.model) and
      ($recommended.effort == null or $recommended.effort == $used.effort)) as $matches |
    (if $router == null then "no_router_call"
     elif $router.status != "clear" then "router_not_clear"
     elif $override != null or ($matches | not) then "overridden"
     else "followed" end) as $outcome |
    {time, task_id, lane: ($router.lane | strings // null),
     final_lane: (if has("final_lane") then .final_lane elif $matches then $router.lane else null end),
     confidence: ($router.confidence | numbers // null), router_status: $router.status,
     recommended_profile: $recommended, used_profile: $used, outcome: $outcome,
     reason: ($override // if $outcome == "router_not_clear" then ($router.reason | strings // null) else null end),
     resolution_id: (.resolution_id | strings // null), relaunch: (if (.relaunch | type) == "boolean" then .relaunch else null end),
     router_lane: $router.router_lane,
     shadow_lane: ($router.lane_check.pick | strings // null),
     check_action: ($router.lane_check.action | strings // null),
     keep_lane_reason: ($router.lane_check.keep_reason | strings // null)};
  def show_profile:
    if . == null then "-" else [.harness, (.model // "-"), (.effort // "-")] | join("/") end;
  def same($a; $b): [.[] | select(.[$a] != null and .[$b] != null)] | {compared: length, same: (map(select(.[$a] == .[$b])) | length)};
  def show(v): if v == null then "-" else v | tostring end;

  reduce inputs as $line (
    {routers: {}, by_id: {}, jev: {}, spawns: [], pending: {},
     summary: {followed: 0, overridden: 0, router_not_clear: 0, no_router_call: 0}};
    ($line | try fromjson catch null) as $row |
    if ($row | valid | not) then
      ("fm-dispatch-history: skipping malformed line \(input_line_number)\n" | stderr) as $_ | .
    elif $task != "" and $row.task_id != $task then .
    elif $row.kind == "router" then
      if $row.task_id == "" or ($row.brief_path | IN("", "/dev/null")) then .
      else
        $row.lane_check.digest as $digest |
        (if $row.model != null then
           .jev[$row.task_id] = {digest: $digest, lane: $row.rule_lane}
         else . end) |
        ($row + {router_lane:
          (if $row.model != null then $row.rule_lane
           elif $row.intended_lane != null and $digest != null and $digest == .jev[$row.task_id].digest
           then .jev[$row.task_id].lane else null end)}) as $decision |
        .routers[$row.task_id] = $decision |
        if ($row.resolution_id | type) == "string" then .by_id[$row.task_id][$row.resolution_id] = $decision else . end
      end
    elif $row.kind == "outcome" then
      reduce .pending[$row.task_id][]? as $i (.;
        .spawns[$i] += {cleanup: input_line_number, result: $row.result, pr_state: $row.pr_state,
          relaunches: $row.relaunches, review_rounds: $row.review_rounds})
      | del(.pending[$row.task_id], .routers[$row.task_id], .jev[$row.task_id], .by_id[$row.task_id])
    else
      (if $row.relaunch == false then del(.pending[$row.task_id]) else . end) |
      if $start != null and $row.time < $start then . else
      (if ($row.resolution_id | type) == "string" then .by_id[$row.task_id][$row.resolution_id]
       else .routers[$row.task_id] end) as $router |
      ($row | decision($router) + {result: null, pr_state: null, relaunches: null, review_rounds: null}) as $spawn |
      .pending[$row.task_id] += [(.spawns | length)] |
      .spawns += [$spawn] | .summary[$spawn.outcome] += 1
      end
    end
  ) |
  ([.spawns[] | select(.relaunch != true)]) as $dispatches |
  .summary.lane_check = ([$dispatches[] | .check_action | strings] | group_by(.) | map({key: .[0], value: length}) | from_entries) |
  .summary.agreement = {
    router_vs_shadow: ($dispatches | same("router_lane"; "shadow_lane")),
    shadow_vs_final: ($dispatches | same("shadow_lane"; "final_lane")),
    router_vs_final: ($dispatches | same("router_lane"; "final_lane"))} |
  .summary.outcomes = ([.spawns[] | select(.result != null)] | group_by(.cleanup) | map(last)
    | group_by(.final_lane // "-") | map({key: (.[0].final_lane // "-"), value: {
        tasks: length,
        landed: (map(select(.result == "landed")) | length),
        delivered: (map(select(.result == "delivered")) | length),
        discarded: (map(select(.result == "discarded")) | length),
        relaunches: ([.[].relaunches | numbers] | add // 0),
        review_rounds: ([.[].review_rounds | numbers] | add // 0)}}) | from_entries) |
  del(.routers, .by_id, .jev, .pending, .spawns[].cleanup) |
  if $json then . else
    "Spawns: \(.spawns | length) (followed: \(.summary.followed), overridden: \(.summary.overridden), router not clear: \(.summary.router_not_clear), no router call: \(.summary.no_router_call))",
    (if (.summary.lane_check | length) > 0 then
       "Lane check: " + ([.summary.lane_check | to_entries[] | "\(.key) \(.value)"] | join(", "))
     else empty end),
    (.summary.agreement | if .router_vs_shadow.compared + .shadow_vs_final.compared + .router_vs_final.compared > 0 then
       "Agreement: router vs shadow \(.router_vs_shadow.same)/\(.router_vs_shadow.compared), shadow vs final \(.shadow_vs_final.same)/\(.shadow_vs_final.compared), router vs final \(.router_vs_final.same)/\(.router_vs_final.compared)"
     else empty end),
    (.summary.outcomes | to_entries[] |
       "Outcomes \(.key): tasks \(.value.tasks) (landed \(.value.landed), delivered \(.value.delivered), discarded \(.value.discarded)), relaunches \(.value.relaunches), review rounds \(.value.review_rounds)"),
    (["TIME (UTC)", "TASK", "LANE", "CONFIDENCE", "RECOMMENDED", "USED", "OUTCOME", "REASON",
      "ROUTER LANE", "SHADOW", "CHECK", "RESULT", "RELAUNCHES", "REVIEW ROUNDS", "FINAL LANE", "PR STATE"] | @tsv),
    (.spawns[] |
      [(try (.time | todateiso8601) catch null) // (.time | tostring),
       .task_id, (.lane // "-"), (.confidence // "-"), (.recommended_profile | show_profile),
       (.used_profile | show_profile), .outcome, (.reason // "-"),
       (.router_lane // "-"), (.shadow_lane // "-"), (.check_action // "-"), (.result // "-"),
       show(.relaunches), show(.review_rounds), show(.final_lane), show(.pr_state)] | @tsv)
  end' "$log"
