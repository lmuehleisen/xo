#!/usr/bin/env bash
# fm-dispatch-history-lib.sh - best-effort private dispatch call history.
#
# fm_dispatch_history_router <home> <brief> <status> <reason> <result-json>
#                            <evidence-json> <lane> <latency-ms> <model> [<resolution-id>]
# fm_dispatch_history_spawn <home> <task-id> <harness> <model> <effort>
#                           <override-reason> <dispatch-record-json> [<relaunch 0|1>]
# fm_dispatch_history_outcome <home> <task-id> <task-kind> <result> [<pr-url>]
#
# Appends one compact JSON object per call to $home/state/dispatch-history.jsonl,
# independent of FM_STATE_OVERRIDE. Each entry has kind, time (Unix seconds),
# and task_id. Router task ids are the brief's parent-directory basename;
# brief_path points to the input without storing its text. Unavailable evidence
# is null or empty. Router fields whitelist scores, token counts, the suggested
# profile and compact candidates, never request bodies, response bodies or keys.
# spendMetric names the snapshot-wide formula (null before quota evaluation);
# each candidate score uses that metric as its key, with unmetered marking
# synthetic policy scores. Legacy snapshots retain their spendPriority key.
# Router entries also make each decision attributable: resolution_id (the id
# the task record carries to the launch), rule (the router's raw pick, or the
# --lane rule), rule_lane and rule_probability for that pick, floor (pass or
# fail on that pick's confidence floor, null for --lane), fallback_lane (the
# runner-up a failed floor fell to), intended_lane (the --lane given), lane
# (the final lane), lane_check ({ran, pick, reason, not_run, checker,
# latency_ms, cached, digest, from, action, keep_reason} from the top-lane check, or
# null when none is configured), and keep_lane_reason (the --keep-lane reason).
# Rows written before these fields existed simply lack them.
# Spawn entries record the final profile and resolver_exists, which means an
# earlier router entry for that task exists in this home's history (any status).
# override_reason is the explicit launch override, or null. Lane, class,
# confidence, and resolution_id come from the matching task's dispatch record,
# passed as the JSON text the caller validated the launch against (not reread),
# or are null. final_lane is null unless the launch matches the concrete
# profile axes of its clear lane resolution. relaunch is true for a --relaunch, false for a fresh launch, and
# null when the caller did not say.
# Only successful ship/scout launches call the spawn helper, including relaunch.
# Outcome entries come from a completed cleanup (bin/fm-teardown.sh) of a task
# this history holds a launch entry for, and carry task_kind,
# result (landed, delivered, discarded, or unknown without worktree proof), pr, relaunches (spawn entries for
# the task after its last fresh launch, or all but the first for older rows),
# and, for a PR, reviews and review_rounds (submitted reviews and the distinct
# commits they reviewed, from one gh call bounded at 10 seconds, else null).
# pr_state is the forge's OPEN, CLOSED, or MERGED verdict when available;
# landed records the cleanup worktree proof, which also accepts pushed work.
# No brief text, review text, or secret is stored.
# No retention or rotation is performed. All logging work runs in a silent
# subshell and callers ignore failure, preserving their output and exit status.

fm_dispatch_history_router() (
  local home=$1 brief=$2 status=$3 reason=$4 result=$5 evidence=$6
  local lane=$7 latency=$8 model=$9 resolution=${10:-} parent id='' line
  if [[ "$brief" == */* ]]; then
    parent=${brief%/*}
    id=${parent##*/}
  fi
  line=$(jq -cn --argjson time "$(date +%s)" --arg id "$id" --arg brief "$brief" \
    --arg status "$status" --arg reason "$reason" --arg lane "$lane" \
    --arg model "$model" --argjson latency "$latency" --arg resolution "$resolution" \
    --argjson evidence "$evidence" --argjson result "$result" '
    ({status: $status, reason: $reason, lane: $lane, model: $model,
      latency_ms: $latency} + $evidence + $result) as $r |
    {kind: "router", time: $time, task_id: $id, brief_path: $brief,
     resolution_id: ($resolution | select(. != "") // null),
     status: $r.status, model: ($r.model | select(. != "") // null),
     latency_ms: $r.latency_ms, spendMetric: ($r.spendMetric // null),
     tokens: (if $r.tokens then $r.tokens | {input_tokens, output_tokens} else null end),
     rule: ($r.rule // null), confidence: ($r.confidence // null),
     probabilities: ($r.probabilities // {}),
     rule_lane: ($r.rule_lane // null), rule_probability: ($r.rule_probability // null),
     floor: ($r.floor // null), fallback_lane: ($r.fallback_lane // null),
     intended_lane: ($lane | select(. != "") // null),
     lane: ($r.lane | select(. != "") // null),
     lane_check: (if ($r.lane_check | type) == "object" then $r.lane_check
       | {ran, pick, reason, not_run, checker, latency_ms, cached, digest, from, action, keep_reason} else null end),
     keep_lane_reason: ($r.keep_lane_reason // null),
     reason: ($r.reason | select(. != "") // $r.note // null),
     suggested_profile: (if $r.status == "clear" then
       $r.chosen.profile | {harness, model, effort} else null end),
     candidates: [$r.candidates[]? |
       {route: (.profile.harness + ":" + (.profile.model // "default")),
        provider: (.provider // null), class: (.class // null),
        eligibility: (if .unranked then "eligible, unranked"
          elif .eligible then "eligible" else "not eligible" end),
        unmetered: (.unmetered // false),
        ($r.spendMetric // "spendPriority"): (.spendScore // null)}]}
  ') || return 0
  umask 077
  mkdir -p "$home/state" || return 0
  printf '%s\n' "$line" >> "$home/state/dispatch-history.jsonl"
) >/dev/null 2>&1

fm_dispatch_history_spawn() (
  local home=$1 id=$2 harness=$3 model=$4 effort=$5 exists=false line
  local override=$6 record=$7 relaunch=${8:-} routing=''
  local log="$home/state/dispatch-history.jsonl"
  if [ -f "$log" ] && jq -en --arg id "$id" \
      'any(inputs; .kind == "router" and .task_id == $id)' "$log" >/dev/null; then
    exists=true
  fi
  if [ -n "$record" ]; then
    routing=$(jq -cs --arg id "$id" --arg harness "$harness" --arg model "$model" --arg effort "$effort" '
      select(length == 1) | .[0] | objects |
      select(.task == $id and (.status | IN("clear", "ambiguous", "escalate", "error", "off"))) |
      {lane: (.lane | strings // null), class: (.class | strings // null),
       confidence: (.confidence | numbers // null),
       resolution_id: (.resolution_id | strings // null),
       final_lane: (if .status == "clear" and .profile.harness == $harness
         and (.profile.model == null or .profile.model == $model)
         and (.profile.effort == null or .profile.effort == $effort) then .lane else null end)}' <<<"$record") || routing=''
  fi
  line=$(jq -cn --argjson time "$(date +%s)" --arg id "$id" \
    --arg harness "$harness" --arg model "${model:-default}" \
    --arg effort "${effort:-default}" --argjson exists "$exists" \
    --arg override "$override" --argjson routing "${routing:-null}" --arg relaunch "$relaunch" '
    {kind: "spawn", time: $time, task_id: $id, harness: $harness,
     model: $model, effort: $effort, resolver_exists: $exists,
     override_reason: ($override | select(. != "") // null),
     lane: $routing.lane, final_lane: $routing.final_lane, class: $routing.class, confidence: $routing.confidence,
     resolution_id: $routing.resolution_id,
     relaunch: (if $relaunch == "1" then true elif $relaunch == "0" then false else null end)}
  ') || return 0
  umask 077
  mkdir -p "$home/state" || return 0
  printf '%s\n' "$line" >> "$log"
) >/dev/null 2>&1

fm_dispatch_history_outcome() (
  local home=$1 id=$2 kind=$3 result=$4 pr=${5:-} relaunches=null reviews=null rounds=null counts line pr_state=''
  local log="$home/state/dispatch-history.jsonl"
  # Only a task this history recorded a launch for gets an outcome to join.
  [ -f "$log" ] || return 0
  relaunches=$(jq -nRc --arg id "$id" '
    reduce (inputs | fromjson? | objects | select(.task_id == $id)) as $row (null;
      if $row.kind == "outcome" then null
      elif $row.kind != "spawn" then .
      elif $row.relaunch == false or . == null then 0 else . + 1 end)
    | select(. != null)' "$log" 2>/dev/null) || return 0
  [ -n "$relaunches" ] || return 0
  if ! declare -F fm_pr_url_parse >/dev/null || ! fm_pr_url_parse "$pr"; then
    pr=''
  elif [ "$FM_PR_PROVIDER" = github ] && command -v gh >/dev/null 2>&1 && declare -F fm_run_timed >/dev/null 2>&1; then
    counts=$(fm_run_timed 10 gh pr view "$pr" --json state,reviews \
      --jq '[.state, (.reviews | length), ([.reviews[] | .commit.oid // empty] | unique | length)] | @tsv' 2>/dev/null) || counts=''
    if [[ "$counts" =~ ^(OPEN|CLOSED|MERGED)$'\t'([0-9]+)$'\t'([0-9]+)$ ]]; then
      pr_state=${BASH_REMATCH[1]}
      reviews=${BASH_REMATCH[2]}
      rounds=${BASH_REMATCH[3]}
    fi
  fi
  line=$(jq -cn --argjson time "$(date +%s)" --arg id "$id" --arg kind "$kind" --arg result "$result" \
    --arg pr "$pr" --arg pr_state "$pr_state" --argjson relaunches "$relaunches" --argjson reviews "$reviews" --argjson rounds "$rounds" '
    {kind: "outcome", time: $time, task_id: $id, task_kind: $kind, result: $result,
     pr: ($pr | select(. != "") // null), pr_state: ($pr_state | select(. != "") // null), relaunches: $relaunches,
     reviews: $reviews, review_rounds: $rounds}') || return 0
  umask 077
  mkdir -p "$home/state" || return 0
  printf '%s\n' "$line" >> "$log"
) >/dev/null 2>&1
