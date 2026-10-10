#!/usr/bin/env bash
# fm-dispatch-history-lib.sh - best-effort private dispatch call history.
#
# fm_dispatch_history_router <home> <brief> <status> <reason> <result-json>
#                            <evidence-json> <lane> <latency-ms> <model>
# fm_dispatch_history_spawn <home> <task-id> <harness> <model> <effort>
#
# Appends one compact JSON object per call to $home/state/dispatch-history.jsonl,
# independent of FM_STATE_OVERRIDE. Each entry has kind, time (Unix seconds),
# and task_id. Router task ids are the brief's parent-directory basename;
# brief_path points to the input without storing its text. Unavailable evidence
# is null or empty. Router fields whitelist scores, token counts, the suggested
# profile and compact candidates, never request bodies, response bodies or keys.
# Spawn entries record the final profile and resolver_exists, which means an
# earlier router entry for that task exists in this home's history (any status).
# Only successful ship/scout launches call the spawn helper, including relaunch.
# No retention or rotation is performed. All logging work runs in a silent
# subshell and callers ignore failure, preserving their output and exit status.

fm_dispatch_history_router() (
  local home=$1 brief=$2 status=$3 reason=$4 result=$5 evidence=$6
  local lane=$7 latency=$8 model=$9 parent id='' line
  if [[ "$brief" == */* ]]; then
    parent=${brief%/*}
    id=${parent##*/}
  fi
  line=$(jq -cn --argjson time "$(date +%s)" --arg id "$id" --arg brief "$brief" \
    --arg status "$status" --arg reason "$reason" --arg lane "$lane" \
    --arg model "$model" --argjson latency "$latency" \
    --argjson evidence "$evidence" --argjson result "$result" '
    ({status: $status, reason: $reason, lane: $lane, model: $model,
      latency_ms: $latency} + $evidence + $result) as $r |
    {kind: "router", time: $time, task_id: $id, brief_path: $brief,
     status: $r.status, model: ($r.model | select(. != "") // null),
     latency_ms: $r.latency_ms,
     tokens: (if $r.tokens then $r.tokens | {input_tokens, output_tokens} else null end),
     rule: ($r.rule // null), confidence: ($r.confidence // null),
     probabilities: ($r.probabilities // {}), lane: ($r.lane | select(. != "") // null),
     reason: ($r.reason | select(. != "") // $r.note // null),
     suggested_profile: (if $r.status == "clear" then
       $r.chosen.profile | {harness, model, effort} else null end),
     candidates: [$r.candidates[]? |
       {route: (.profile.harness + ":" + (.profile.model // "default")),
        provider: (.provider // null), class: (.class // null),
        eligibility: (if .unranked then "eligible, unranked"
          elif .eligible then "eligible" else "not eligible" end),
        spendPriority: (.spendPriority // null)}]}
  ') || return 0
  umask 077
  mkdir -p "$home/state" || return 0
  printf '%s\n' "$line" >> "$home/state/dispatch-history.jsonl"
) >/dev/null 2>&1

fm_dispatch_history_spawn() (
  local home=$1 id=$2 harness=$3 model=$4 effort=$5 exists=false line
  local log="$home/state/dispatch-history.jsonl"
  if [ -f "$log" ] && jq -en --arg id "$id" \
      'any(inputs; .kind == "router" and .task_id == $id)' "$log" >/dev/null; then
    exists=true
  fi
  line=$(jq -cn --argjson time "$(date +%s)" --arg id "$id" \
    --arg harness "$harness" --arg model "${model:-default}" \
    --arg effort "${effort:-default}" --argjson exists "$exists" '
    {kind: "spawn", time: $time, task_id: $id, harness: $harness,
     model: $model, effort: $effort, resolver_exists: $exists}
  ') || return 0
  umask 077
  mkdir -p "$home/state" || return 0
  printf '%s\n' "$line" >> "$log"
) >/dev/null 2>&1
