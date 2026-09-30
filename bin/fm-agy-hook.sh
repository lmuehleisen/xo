#!/usr/bin/env bash
# Agy native-hook transport and worker installation.
# Usage: fm-agy-hook.sh install-worker <state> <id> <gen> <worktree> [<policy-file>]
#        fm-agy-hook.sh retire-worker <state> <id>
#        fm-agy-hook.sh worker <PreInvocation|PreToolUse|PostToolUse|Stop> <state> <id> <gen> <worktree>
#        fm-agy-hook.sh primary <PreInvocation|PreToolUse|Stop>
#
# Hook calls consume Agy's camelCase JSON on stdin and exit 0, returning one
# JSON object for an action or no stdout when inert. Invalid payloads are inert.
# Primary scope, startup nudges,
# turn-end predicates, and pre-tool decisions remain with their existing owners.
# Stop executionNum > 0 maps to the shared one-continuation loop guard.
# Agy's Stop does not fire on manual interruption; neither a key nor a rendered
# footer manufactures idle. PreInvocation opens busy and fullyIdle Stop closes.
#
# install-worker writes ONLY state/<id>.agy-hooks/.agents/hooks.json and an
# ownership marker. Spawn grants that directory separately, so the project's
# own .agents/hooks.json is never rewritten. Each generation latches the first
# PreInvocation conversation id; subagent callbacks cannot settle its parent.
# A retired generation can write only its own session binding and is refused by
# fm-busy-event.sh before publishing state or a turn-ended wake.
# retire-worker removes only that marked, non-symlink adapter directory.
#
# install-worker also registers the log-only tool observer: matcher groups on
# the same worker command append one JSON line per tool call to
# state/agy-permission-log.jsonl. Fields mirror devin-permission-log.jsonl
# naming where the concept is shared - ts, task, event (pre-tool-use or
# post-tool-use), tool, session_id (Agy conversationId), input (the command
# line, the file path, or the url/query), plus step_idx, model, cwd, and for
# PostToolUse error. File contents, tool output, and environment are never
# logged. The observer ALWAYS exits 0 with empty stdout - every parse,
# extraction, or append failure lands inert - because Agy blocks the tool on
# any non-zero exit or any stdout. install-worker validates the merged
# hooks.json before installing it, so every hook it writes, including the
# turn-end pair, is one agy will load.
#
# With a <policy-file> argument install-worker also wires the bypass-mode
# permission adapter bin/fm-agy-permission-policy.sh beside the observer: an
# armed heartbeat on PreInvocation and Stop, and the decision as a second
# PreToolUse hook (after the observer, with a timeout above the judge
# budget). The merge is validated the same way, so the busy-state groups
# always load beside the adapter's entries.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MODE=${1:-}
shift || exit 2

usage() {
  sed -n '3,6s/^# *//p' "$SCRIPT_DIR/fm-agy-hook.sh" >&2
  exit 2
}
token_valid() {
  case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}
shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}
bad_args() {
  # agy pipes the payload on stdin for every hook call, so a terminal
  # stdin means a human ran the script by hand and gets usage. A piped
  # worker PreToolUse/PostToolUse call with a bad argument count -
  # reachable only through a malformed installed command - still exits 0
  # with empty stdout, because agy blocks the tool on any non-zero exit.
  [ -t 0 ] && usage
  case "$MODE:$event" in
    worker:PreToolUse|worker:PostToolUse) exit 0 ;;
    *) usage ;;
  esac
}

case "$MODE" in
  install-worker|retire-worker)
    [ "$#" -ge 2 ] || usage
    state=$1 id=$2
    token_valid "$id" && [ -d "$state" ] || usage
    state=$(cd "$state" && pwd -P) || exit 1
    dir="$state/$id.agy-hooks"
    if [ -e "$dir" ] || [ -L "$dir" ]; then
      [ ! -L "$dir" ] && [ -d "$dir" ] && [ ! -L "$dir/.firstmate-owned" ] \
        && [ "$(cat "$dir/.firstmate-owned" 2>/dev/null)" = "$id" ] || {
        echo "error: refusing unowned agy hook directory: $dir" >&2
        exit 1
      }
    fi
    if [ "$MODE" = retire-worker ]; then
      [ "$#" -eq 2 ] || usage
      rm -rf -- "$dir"
      exit
    fi
    [ "$#" -eq 4 ] || [ "$#" -eq 5 ] || usage
    gen=$3 wt=$4 policy=${5-}
    token_valid "$gen" && [ -d "$wt" ] || usage
    command -v jq >/dev/null 2>&1 || { echo 'error: agy hooks require jq' >&2; exit 1; }
    if [ -n "$policy" ]; then
      [ -f "$policy" ] && [ ! -L "$policy" ] || {
        echo "error: agy permission policy file missing or a link: $policy" >&2
        exit 1
      }
      policy=$(cd "$(dirname "$policy")" && pwd -P)/$(basename "$policy") || exit 1
    fi
    wt=$(cd "$wt" && pwd -P) || exit 1
    [ ! -L "$dir/.agents" ] && [ ! -L "$dir/.agents/hooks.json" ] || exit 1
    mkdir -p "$dir/.agents" || exit 1
    printf '%s\n' "$id" > "$dir/.firstmate-owned" || exit 1
    prefix="$(shell_quote "$SCRIPT_DIR/fm-agy-hook.sh") worker"
    suffix="$(shell_quote "$state") $(shell_quote "$id") $(shell_quote "$gen") $(shell_quote "$wt")"
    tmp=$(mktemp "$dir/.agents/.hooks.XXXXXX") || exit 1
    if [ -n "$policy" ]; then
      # The permission layer rides beside the observer: its armed heartbeat
      # joins PreInvocation, its decision runs second on PreToolUse after the
      # observer has logged the call, and its pending closure joins Stop.
      # The decision hook's timeout must sit above the library's JUDGE_BUDGET
      # (100s) or agy kills the hook mid-judge and blocks the tool anyway.
      polprefix="$(shell_quote "$SCRIPT_DIR/fm-agy-permission-policy.sh")"
      polpath="$(shell_quote "$policy")"
      if ! jq -n --arg open "$prefix PreInvocation $suffix" --arg close "$prefix Stop $suffix" \
        --arg pre "$prefix PreToolUse $suffix" --arg post "$prefix PostToolUse $suffix" \
        --arg armed "$polprefix armed $polpath" --arg decide "$polprefix pre-tool-use $polpath" \
        --arg pstop "$polprefix stop $polpath" --arg ppost "$polprefix post-tool-use $polpath" \
        '{"firstmate-worker":{
          PreInvocation:[{command:$open},{command:$armed}],
          Stop:[{command:$close},{command:$pstop}],
          PreToolUse:[{matcher:"*",hooks:[{type:"command",command:$pre,timeout:10},
                                        {type:"command",command:$decide,timeout:130}]}],
          PostToolUse:[{matcher:"*",hooks:[{type:"command",command:$post,timeout:10},
                                         {type:"command",command:$ppost,timeout:10}]}]}}' > "$tmp"; then
        rm -f "$tmp"; exit 1
      fi
      want_cmds=8
    else
      if ! jq -n --arg open "$prefix PreInvocation $suffix" --arg close "$prefix Stop $suffix" \
        --arg pre "$prefix PreToolUse $suffix" --arg post "$prefix PostToolUse $suffix" \
        '{"firstmate-worker":{
          PreInvocation:[{command:$open}],
          Stop:[{command:$close}],
          PreToolUse:[{matcher:"*",hooks:[{type:"command",command:$pre,timeout:10}]}],
          PostToolUse:[{matcher:"*",hooks:[{type:"command",command:$post,timeout:10}]}]}}' > "$tmp"; then
        rm -f "$tmp"; exit 1
      fi
      want_cmds=4
    fi
    # Refuse to install anything that does not carry all four groups with
    # non-empty commands - and, for a policy install, the adapter's own
    # entries beside them - so the shipped turn-end pair always loads.
    if ! jq -e --argjson want "$want_cmds" '
      ."firstmate-worker" as $h
      | ([$h | .. | objects | select(has("command")) | .command]) as $cmds
      | ($h | has("PreInvocation") and has("Stop") and has("PreToolUse") and has("PostToolUse"))
        and ($h.PreToolUse[0] | has("matcher") and (.hooks | type == "array" and length >= 1))
        and ($h.PostToolUse[0] | has("matcher") and (.hooks | type == "array" and length >= 1))
        and ($cmds | length) == $want
        and ($cmds | all(type == "string" and length > 0))' "$tmp" >/dev/null; then
      echo "error: refusing to install malformed agy hooks for $id" >&2
      rm -f "$tmp"; exit 1
    fi
    mv -- "$tmp" "$dir/.agents/hooks.json" || { rm -f "$tmp"; exit 1; }
    exit 0
    ;;
  worker|primary) ;;
  -h|--help) sed -n '3,6s/^# *//p' "$SCRIPT_DIR/fm-agy-hook.sh"; exit 0 ;;
  *) usage ;;
esac

event=${1:-}
shift || bad_args
# A bad worker argument count is gated before stdin is read so a hand-run
# call still reaches usage instead of hanging on the payload read.
if [ "$MODE" = worker ] && [ "$#" -ne 4 ]; then bad_args; fi
payload=$(cat 2>/dev/null || true)
inert() {
  # Agy requires a decision when PreToolUse emits JSON; {} denies the call.
  # No output leaves the native permission policy in control.
  exit 0
}
observe_tool_call() {
  # Log-only observer. One JSONL append, then abstain: any failure anywhere
  # leaves the log incomplete but never blocks the worker's tool. Field names
  # mirror devin-permission-log.jsonl where the concept is the same; input
  # carries the command line, the file path, or the url/query and every
  # field is length-capped so contents, output, and env never reach the log.
  local line
  line=$(printf '%s' "$payload" | jq -c \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg task "$id" --arg event "$event" '
    def s(n): (. // "") | tostring | .[0:n];
    (.toolCall.args // {}) as $a
    | ([$a.CommandLine, $a.TargetFile, $a.AbsolutePath, $a.FilePath, $a.File,
        $a.DirectoryPath, $a.Url, $a.Query, $a.SearchPath, $a.query, $a.url]
       | map(select(type == "string" and . != "")) | .[0] // "") as $input
    | {
        ts: ($ts | s(32)),
        task: ($task | s(128)),
        event: (if $event == "PostToolUse" then "post-tool-use" else "pre-tool-use" end),
        tool: (.toolCall.name | s(128)),
        session_id: (.conversationId | s(128)),
        step_idx: (.stepIdx | if type == "number" then . else null end),
        model: (.modelName | s(128)),
        input: ($input | s(4000)),
        cwd: ($a.Cwd | s(512)),
        error: (.error | s(512))
      }' 2>>"$dir/diag.log") || line=
  [ -z "$line" ] \
    || printf '%s\n' "$line" >> "$state/agy-permission-log.jsonl" 2>>"$dir/diag.log" || true
}
command -v jq >/dev/null 2>&1 || inert
conversation=$(printf '%s' "$payload" | jq -er '.conversationId | select(type == "string")' 2>/dev/null) || inert
token_valid "$conversation" || inert

if [ "$MODE" = worker ]; then
  state=$1 id=$2 gen=$3 wt=$4
  token_valid "$id" || inert
  token_valid "$gen" || inert
  dir="$state/$id.agy-hooks"
  [ ! -L "$dir" ] && [ -d "$dir" ] || inert
  [ "$(cat "$dir/.firstmate-owned" 2>/dev/null)" = "$id" ] || inert
  [ "$(cat "$state/$id.busy-gen" 2>/dev/null)" = "$gen" ] || inert
  printf '%s' "$payload" | jq -e --arg wt "$wt" \
    '.workspacePaths | type == "array" and index($wt) != null' >/dev/null 2>&1 || inert
  case "$event" in
    # The observer records every tool call this generation makes, including
    # ones a subagent conversation fires; the main-conversation binding below
    # stays reserved for the parent's lifecycle events.
    PreToolUse|PostToolUse) observe_tool_call ;;
  esac
  binding="$dir/$gen.session"
  [ ! -L "$binding" ] || inert
  if [ "$event" = PreInvocation ] && [ ! -e "$binding" ]; then
    (set -C; printf '%s\n' "$conversation" > "$binding") 2>/dev/null || true
  fi
  [ "$(cat "$binding" 2>/dev/null)" = "$conversation" ] || inert
  case "$event" in
    PreInvocation)
      "$SCRIPT_DIR/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
        --source agy-hook --event pre-invocation >/dev/null 2>&1 || true
      ;;
    Stop)
      printf '%s' "$payload" | jq -e '.fullyIdle == true' >/dev/null 2>&1 || inert
      if "$SCRIPT_DIR/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
        --source agy-hook --event stop >/dev/null 2>&1; then
        touch "$state/$id.turn-ended" 2>/dev/null || true
      fi
      ;;
  esac
  inert
fi

[ "$#" -eq 0 ] || usage
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || inert
printf '%s' "$payload" | jq -e --arg root "$(cd "$FM_ROOT" && pwd -P)" \
  '.workspacePaths | type == "array" and index($root) != null' >/dev/null 2>&1 || inert

case "$event" in
  PreInvocation)
    # Injecting on later model invocations continually preempts pending tools.
    # Nudge only the opening invocation of a user/background execution cycle.
    printf '%s' "$payload" | jq -e '.invocationNum == 0' >/dev/null 2>&1 || inert
    nudge=$("$SCRIPT_DIR/fm-sessionstart-nudge.sh" 2>/dev/null || true)
    [ -n "$nudge" ] || inert
    jq -n --arg text "$nudge" '{injectSteps:[{ephemeralMessage:$text}]}'
    ;;
  Stop)
    mapped=$(printf '%s' "$payload" | jq -ec '
      select((.executionNum | type) == "number" and .executionNum >= 0
        and .executionNum == (.executionNum | floor) and (.fullyIdle | type) == "boolean")
      | {session_id:.conversationId, stop_hook_active:(.executionNum > 0)}' 2>/dev/null) || inert
    result=$(printf '%s' "$mapped" | "$SCRIPT_DIR/fm-turnend-guard.sh" 2>&1)
    rc=$?
    [ "$rc" -eq 2 ] || inert
    jq -n --arg reason "$result" '{decision:"continue",reason:$reason}'
    ;;
  PreToolUse)
    tool=$(printf '%s' "$payload" | jq -er '.toolCall.name | select(type == "string")' 2>/dev/null) || inert
    result=$("$SCRIPT_DIR/fm-subagent-pretool-check.sh" --tool "$tool" --claude 2>&1)
    rc=$?
    if [ "$rc" -ne 2 ] && [ "$tool" = run_command ]; then
      cmd=$(printf '%s' "$payload" | jq -er '.toolCall.args.CommandLine | select(type == "string")' 2>/dev/null) || inert
      result=$("$SCRIPT_DIR/fm-arm-pretool-check.sh" --command "$cmd" --claude 2>&1)
      rc=$?
      if [ "$rc" -ne 2 ]; then
        result=$("$SCRIPT_DIR/fm-cd-pretool-check.sh" --command "$cmd" --claude 2>&1)
        rc=$?
      fi
    fi
    if [ "$rc" -eq 2 ]; then
      jq -n --arg reason "$result" '{decision:"deny",reason:$reason}'
    else
      # The required ask decision preserves review and existing user grants.
      # Never emit decision=allow: that would bypass Agy's ordinary review.
      printf '{"decision":"ask"}\n'
    fi
    ;;
  *) inert ;;
esac
exit 0
