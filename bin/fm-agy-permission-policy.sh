#!/usr/bin/env bash
# fm-agy-permission-policy.sh - firstmate's permission decision layer for agy
# workers launched under --dangerously-skip-permissions. bin/fm-spawn.sh wires
# it through bin/fm-agy-hook.sh install-worker into the task-owned
# state/<id>.agy-hooks/.agents/hooks.json: an armed heartbeat on PreInvocation,
# the decision on PreToolUse after the log-only observer, and pending closure
# on Stop. It is only ever installed by an explicit opt-in spawn flag, and its
# per-task policy file lives outside the worktree.
#
# Usage: fm-agy-permission-policy.sh <event> <policy-file> [<key>]
#   events: armed | pre-tool-use | post-tool-use | stop | approve | decline |
#           retire | repin-grants | judge-probe
#        fm-agy-permission-policy.sh grants-digest <brief-file>
#        fm-agy-permission-policy.sh verified-versions
# The agy hook payload arrives as JSON on stdin; the management verbs
# (approve, decline, retire, repin-grants) and the two query verbs read none.
#
#   armed (PreInvocation)      the adapter's first hook call of a session
#                              writes one {event:"armed"} line to the observer
#                              log - the canary's proof the wiring is live.
#                              pre-tool-use and stop write it too, so a missed
#                              PreInvocation cannot fake a dead wiring.
#   pre-tool-use (every tool)  the decision contract below.
#   post-tool-use (every tool) closes a pending marker for the call that ran.
#   stop (Stop)                rewrites the armed heartbeat only. A pending
#                              marker deliberately survives turn end: unlike
#                              the Devin worker's native prompt, nothing in a
#                              bypassed agy session is still waiting, so the
#                              marker means "firstmate still owes this call a
#                              decision" and must stay resolvable until
#                              approve, decline, or retire.
#   approve <key>              firstmate's resolution of a held call: caches
#                              the verdict so the worker's retry runs. For a
#                              never-approve or credential call approval is a one-shot
#                              token consumed by one retry; a further retry
#                              escalates again.
#   decline <key>              firstmate's refusal of a held call: a retry of
#                              the same call is denied without re-escalating.
#   repin-grants               records the digest of a live brief's grants
#                              block after firstmate edits it.
#   grants-digest <file>       prints the digest of a brief's grants block.
#   retire                     closes every pending escalation as not-run and
#                              removes the pending directory.
#   verified-versions          prints the agy versions the live evidence in
#                              docs/verification/runtime-backends.md covers;
#                              fm-spawn refuses bypass mode on any other.
#   judge-probe                the measurement seam: runs the same static
#                              analysis and judge call as pre-tool-use on the
#                              payload given, prints one line naming the tier,
#                              model, static class, verdict, and reason, and
#                              writes NOTHING - no cache entry, no marker, no
#                              status line, no log record, no armed line. The
#                              judge disagrees with itself often enough that a
#                              tier has to be comparable on identical inputs
#                              before it is chosen; a harness replays captured
#                              payloads through it once per tier and diffs.
#
# Decisions: bin/fm-command-policy-lib.sh owns the command analysis - the
# refusal list, the read-and-build set, protected briefs and protected
# wiring, the never-approve outward-action class, fetch classification,
# recursive-rm roots, grants, the judge skeleton, and the verdict cache. This
# adapter owns the agy payload schema (.conversationId, .stepIdx,
# .toolCall.name and .toolCall.args camelCase fields), the agy tool-name
# mapping, the judge tier this adapter defaults to, and the agy decision
# surface (bin/fm-judge-tier-lib.sh owns each tier's invocation):
#   - the refusal list, a statically visible write or removal outside every
#     write root, and any write or removal of this adapter's own wiring - the
#     policy file, its pending and cache stores, the worker hook directory,
#     and the observer log - emit {"decision":"deny","reason":"..."}, which
#     agy enforces even under --dangerously-skip-permissions;
#   - the read-and-build set, read-only web lookups, task-local file
#     operations, a cached verdict, a consumed one-shot approval, and a
#     judge APPROVE emit NOTHING - the call abstains and runs;
#   - everything else - the never-approve class, a call touching credential
#     material, and every judge DECLINE, timeout, crash, or no-verdict -
#     emits {"decision":"deny","reason":"held for firstmate: ..."}, writes
#     the pending marker, and appends the needs-decision status line, so
#     firstmate can cache an approval and steer the worker to retry. A retry
#     of the same held call is denied against the existing marker BEFORE the
#     verdict cache or the judge is consulted, and a call firstmate declined
#     is denied against its declined cache entry - neither re-escalates. The
#     path never abstains: under a bypass launch, abstain is what runs a
#     call.
# Agy has no hook output that silently approves a call - {"decision":"allow"}
# still lands on a native prompt - so this adapter's approval IS abstention,
# which only means "run it" because the launch already skipped native review.
# Because abstain runs the call, every failure mode here fails closed: no jq,
# an unreadable payload, a call scoped to a foreign or missing workspace, or
# an unreadable policy file all deny rather than emit - there is no native
# prompt behind this layer to catch what it lets through.
#
# Tool mapping: run_command maps onto the shared exec analysis with
# CommandLine and Cwd; view_file, grep_search, and list_dir are the read
# class, and a view_file or list_dir of the worker's own agy brain directory
# (~/.gemini/antigravity-cli/brain/<conversationId>, its fetched-page store)
# or a view_file of a file the brief directs it to read stays approved under
# brief read exclusions, credential checks first; write_to_file and replace_file_content are the write class against
# the task worktree and scratch roots; search_web and read_url_content are
# read-only web lookups; manage_task kill requires firstmate approval until
# native ownership is verified; every other tool name is residue for the judge.
# The pending key is agy-permission-<conversationId>-s<stepIdx>, the only
# stable call identity agy provides.
#
# Credential-sensitive approvals also use one-shot exact-input tokens; no
# template suffix or .env wildcard bypasses that boundary.
#
# Policy file (written by bin/fm-spawn.sh): JSON object with string fields
# task, worktree, status, inbox, data, tasktmp, brief, log, agy (absolute
# judge executable), agy_version (the launch binary version), gen (the launch's busy generation, stamped onto the
# armed line so the canary can tell this launch's wiring from a stale record
# left by an earlier launch), judge_model (a model id for the judge tier below,
# read on every call, empty disables the judge), judge_timeout (seconds, the
# bound on ONE judge attempt), judge_tier and judge_bin (the judge tier this
# task runs and its executable - fm-spawn records what --agy-judge selected,
# an absent tier means this adapter's own agy tier on the `agy` field above,
# and a tier this build does not know denies rather than falling back), and
# grants_sha (the digest pin the shared library describes).
# Pending escalation markers live in <policy minus .json>-pending/ and the
# per-task verdict cache in <policy minus .json>-cache/; bin/fm-teardown.sh
# removes both with the policy file. With no readable policy file the
# refusal list still applies and every other call denies.
#
# Exit codes: 0 always for hook events - agy reads the decision from stdout
# and a non-zero exit blocks the tool without a reason the model can use.
# Management verbs exit 1 on a failed operation.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# The shared command policy (tokenizer, path helpers, segment and command
# analysis, refusal list, read-and-build set, fetch classification, grants,
# judge skeleton, verdict cache, pending markers).
# shellcheck source=bin/fm-command-policy-lib.sh
. "$SCRIPT_DIR/fm-command-policy-lib.sh"

FM_POLICY_EXEC_TOOL=run_command
FM_POLICY_COMMAND_FIELD=CommandLine
# This launch runs under agy's full bypass, so the shared analysis refuses
# statically visible writes and removals outside the task write roots
# outright rather than sending them to a judge with no native prompt behind
# it.
FM_POLICY_BYPASS=1
# The judge budget is pinned per adapter so an inherited JUDGE_BUDGET cannot
# stretch a hook invocation past the explicit timeout install-worker gives
# the PreToolUse handler.
JUDGE_BUDGET=100
# This adapter's identity in the shared judge: the scratch directory the judge
# runs from, the word the prompt uses for the worker it is supervising, and the
# judge tier a per-task policy that names none falls back to.
FM_POLICY_ADAPTER=agy
FM_POLICY_WORKER_LABEL=agy
FM_JUDGE_TIER_NATIVE=agy

EVENT=${1-}
POLICY=${2-}
KEY=${3-}
case "$EVENT" in
  armed|pre-tool-use|post-tool-use|stop|approve|decline|retire|repin-grants|grants-digest|verified-versions|judge-probe) ;;
  *)
    sed -n '9,11s/^# *//p' "${BASH_SOURCE[0]}" >&2
    exit 0
    ;;
esac

if [ "$EVENT" = verified-versions ]; then
  # The agy versions docs/verification/runtime-backends.md records live
  # evidence for; fm-spawn gates --agy-bypass launches on this set. Each
  # entry is admitted only after tests/fm-agy-bypass-live-e2e.test.sh passes
  # against that installed binary, because the hook contract this layer rests
  # on is version-sensitive. The live checks cover that deny blocks a
  # bypassed call with its reason, abstention runs the call, a timed-out judge
  # denies and holds, an invalid merged hooks.json is refused before launch,
  # force_ask stays inert, and a session that never loads the adapter logs no
  # armed line; a version without that evidence stays out. Keep this an
  # explicit list, never a minimum or a range: a range would admit the next
  # release unproven, which is the failure this gate exists to prevent.
  printf '1.2.4 1.2.5 1.2.6 1.2.7 1.2.11 1.3.1\n'
  exit 0
fi
if [ "$EVENT" = grants-digest ]; then
  # fm-spawn asks for the digest of a brief's grants block at launch.
  fm_grants_digest_of_file "$POLICY"
  exit 0
fi

PENDING_DIR='' CACHE_DIR=''
case "$POLICY" in
  *.json) PENDING_DIR="${POLICY%.json}-pending" CACHE_DIR="${POLICY%.json}-cache" ;;
esac

deny() {  # <reason> - the only blocking verdict agy honors under bypass.
  jq -n --arg r "$1" '{decision:"deny",reason:$r}' 2>/dev/null \
    || printf '{"decision":"deny","reason":"%s"}\n' "firstmate agy permission policy"
  exit 0
}

if ! command -v jq >/dev/null 2>&1; then
  # Every hook path fails closed: without jq the payload cannot be read, so a
  # tool call is denied rather than abstained into a bypassed run. retire is
  # the exception - it must not report the wiring retired while a pending
  # escalation is still open.
  [ "$EVENT" = pre-tool-use ] && { printf '{"decision":"deny","reason":"firstmate agy permission policy: jq unavailable"}\n'; exit 0; }
  [ "$EVENT" = retire ] && [ -n "$PENDING_DIR" ] && [ -d "$PENDING_DIR" ] && exit 1
  exit 0
fi
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

# Post-tool-use also retires spent invocation proofs after approval closed
# the hold. Otherwise post-tool-use and stop stay cheap with no pending work.
if [ "$EVENT" = post-tool-use ] || [ "$EVENT" = stop ]; then
  [ -n "$PENDING_DIR" ] || { cat >/dev/null; exit 0; }
  set -- "$PENDING_DIR"/*.pending
  [ "$EVENT" != post-tool-use ] || set -- "$@" "$CACHE_DIR"/*.once-spent
  for m in "$@"; do [ ! -f "$m" ] || break; done
  [ -f "$m" ] || { cat >/dev/null; exit 0; }
fi
if [ "$EVENT" = retire ]; then
  [ -n "$PENDING_DIR" ] && [ -d "$PENDING_DIR" ] || { rm -rf "$PENDING_DIR" 2>/dev/null; exit 0; }
fi

PAYLOAD=
case "$EVENT" in retire|repin-grants|approve|decline) ;; *) PAYLOAD=$(cat) ;; esac

TASK='' WORKTREE='' STATUS='' INBOX='' DATA_DIR='' TASKTMP='' BRIEF='' LOG='' AGY='' JUDGE_BIN='' JUDGE_MODEL='' JUDGE_TIMEOUT='' GRANTS_SHA='' CONFIG_DIR='' GEN='' FM_POLICY_JUDGE_TIER='' FM_POLICY_JUDGE_BIN=''
if [ -n "$POLICY" ] && [ -r "$POLICY" ]; then
  {
    IFS= read -r -d '' TASK
    IFS= read -r -d '' WORKTREE
    IFS= read -r -d '' STATUS
    IFS= read -r -d '' INBOX
    IFS= read -r -d '' DATA_DIR
    IFS= read -r -d '' TASKTMP
    IFS= read -r -d '' BRIEF
    IFS= read -r -d '' LOG
    IFS= read -r -d '' AGY
    IFS= read -r -d '' JUDGE_MODEL
    IFS= read -r -d '' JUDGE_TIMEOUT
    IFS= read -r -d '' GRANTS_SHA
    IFS= read -r -d '' CONFIG_DIR
    IFS= read -r -d '' GEN
    IFS= read -r -d '' FM_POLICY_JUDGE_TIER
    IFS= read -r -d '' FM_POLICY_JUDGE_BIN
  } < <(jq -j '[.task, .worktree, .status, .inbox, .data, .tasktmp, .brief, .log, .agy, .judge_model, .judge_timeout, .grants_sha, .config, .gen, .judge_tier, .judge_bin]
    | map((. // "") | tostring | gsub("\u0000"; "")) | join("\u0000") + "\u0000"' "$POLICY" 2>/dev/null)
fi
# Which judge answers this task, and the executable it runs. agy judges agy by
# default: a policy that names no tier keeps this adapter's own tier on the agy
# binary above. The tier fm-spawn recorded is the one that runs; an unknown
# one, or one whose executable is not there, denies and holds the call for
# firstmate rather than quietly running some other judge.
fm_judge_tier_bind "$FM_JUDGE_TIER_NATIVE" "$AGY"

# The adapter's own firstmate-owned wiring, declared to the shared policy so
# any statically visible write or removal of it is refused: the policy file
# itself, its pending and cache stores, the worker hook directory beside the
# policy file, and the observer log that carries the armed line and the
# decision record. A worker rewriting any of these would disarm the only
# check its bypassed launch has left.
POLICY_PROTECTED=''
if [ -n "$POLICY" ]; then
  POLICY_PROTECTED=$POLICY
  [ -n "$PENDING_DIR" ] && POLICY_PROTECTED="$POLICY_PROTECTED"$'\n'"$PENDING_DIR"
  [ -n "$CACHE_DIR" ] && POLICY_PROTECTED="$POLICY_PROTECTED"$'\n'"$CACHE_DIR"
  [ -n "$TASK" ] && POLICY_PROTECTED="$POLICY_PROTECTED"$'\n'"${POLICY%/*}/$TASK.agy-hooks"
  [ -n "$LOG" ] && POLICY_PROTECTED="$POLICY_PROTECTED"$'\n'"$LOG"
fi

TOOL='' TOOL_USE_ID='' SESSION_ID='' CMD='' AGY_CWD='' FILE_PATH='' INPUT_JSON='' INPUT_STRINGS='' CACHE_INPUT=''
{
  IFS= read -r -d '' TOOL
  IFS= read -r -d '' TOOL_USE_ID
  IFS= read -r -d '' SESSION_ID
  IFS= read -r -d '' _
  IFS= read -r -d '' CMD
  IFS= read -r -d '' AGY_CWD
  IFS= read -r -d '' FILE_PATH
  IFS= read -r -d '' INPUT_JSON
  IFS= read -r -d '' INPUT_STRINGS
  IFS= read -r -d '' CACHE_INPUT
} < <(printf '%s' "$PAYLOAD" | jq -j '
  def s: (. // "") | tostring | gsub("\u0000"; "");
  (.conversationId | s) as $conv
  | (.stepIdx | if type == "number" then . else "" end | tostring) as $step
  | (.toolCall.args // {}) as $a
  | ($a | del(.Content?, .NewContent?, .OldString?, .NewString?, .Text?,
             .CodeContent?, .Contents?)) as $cacheargs
  | [ (.toolCall.name | s),
      (if $conv != "" and $step != "" then "\($conv)-s\($step)" else "" end | s),
      ($conv | s),
      ($step | s),
      ($a.CommandLine | s),
      ($a.Cwd | s),
      ([$a.TargetFile, $a.AbsolutePath, $a.FilePath, $a.File]
       | map(select(type == "string" and . != "")) | .[0] // "" | s),
      (($a) | tojson | .[0:2000] | s),
      ([$a | .. | strings] | join("\n") | s),
      (($cacheargs) | tojson | s)
    ] | join("\u0000") + "\u0000"' 2>/dev/null)

# The worker's own agy brain directory, where agy keeps what this
# conversation's own tools fetched (.system_generated/steps/<n>/content.md).
# Only this conversation id's directory is named: a subagent's calls arrive
# under the subagent's own id, and no other conversation's directory counts.
FM_POLICY_OWN_OUTPUT_DIR=''
case "$SESSION_ID" in
  ''|*[!A-Za-z0-9-]*) ;;
  *)
    [ -z "${HOME:-}" ] \
      || FM_POLICY_OWN_OUTPUT_DIR=$(physical_target "$HOME/.gemini/antigravity-cli/brain/$SESSION_ID" '' 1 2>/dev/null) \
      || FM_POLICY_OWN_OUTPUT_DIR=''
    ;;
esac

# A hook call that cannot be read cannot be judged; under a bypass launch
# abstaining would run it, so an unparseable payload denies.
if [ "$EVENT" = pre-tool-use ] && [ -z "$TOOL" ]; then
  deny "firstmate agy permission policy: unparseable tool call"
fi

write_armed() {
  # The canary's heartbeat: one armed line on the observer log proves the
  # hook wiring fired at least once this generation. It carries the launch's
  # busy generation from the policy file, so the canary can tell it from a
  # stale line an earlier launch or a reused task id left in the append-only
  # log. The flag file dedupes; retire removes it with the pending directory
  # so a relaunch re-arms.
  local flag="$PENDING_DIR/.armed" conv='' model='' version=''
  [ -n "$PENDING_DIR" ] && [ -n "$LOG" ] || return 0
  [ -e "$flag" ] && return 0
  mkdir -p "$PENDING_DIR" 2>/dev/null || return 0
  (set -C; : > "$flag") 2>/dev/null || return 0
  conv=${SESSION_ID:-$(printf '%s' "$PAYLOAD" | jq -r '.conversationId // ""' 2>/dev/null)}
  model=$(printf '%s' "$PAYLOAD" | jq -r '.modelName // ""' 2>/dev/null)
  version=$(jq -r ' .agy_version // ""' "$POLICY" 2>/dev/null)
  jq -c -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg task "$TASK" \
    --arg version "$version" --arg tier "$JUDGE_TIER" --arg judge_model "$JUDGE_MODEL" \
    --arg conv "$conv" --arg model "$model" --arg gen "$GEN" '{
      ts: $ts, task: $task, event: "armed",
      tool: "fm-agy-permission-policy", session_id: $conv, gen: $gen,
      agy_version: $version, judge_tier: $tier, judge_model: $judge_model,
      step_idx: null, model: $model, input: "", cwd: "", error: ""
    }' >> "$LOG" 2>/dev/null || true
}

evaluate_tool() {  # non-exec agy tools: sets NOT_APPROVABLE
  REFUSE_REASON='' NOT_APPROVABLE='' NEVER_APPROVE='' SENSITIVE_HIT=''
  case "$TOOL" in
    view_file|grep_search|list_dir|search_web|read_url_content)
      sensitive_text "$INPUT_STRINGS" \
        && { SENSITIVE_HIT=1; no_approve "$TOOL of credential material"; }
      granted_env_file_text "$INPUT_STRINGS" \
        && { SENSITIVE_HIT=1; no_approve "$TOOL of a credential file this task may only source"; }
      ;;
    write_to_file|replace_file_content)
      local abs rel
      [ -n "$FILE_PATH" ] || { no_approve "$TOOL without a file path"; return 0; }
      # Whether agy's file tools expand a leading ~ is unverified; under
      # bypass an ambiguous write target is refused rather than trusted to
      # land inside the worktree as a literal '~' directory.
      case "$FILE_PATH" in
        '~'*)
          refuse "$TOOL of a ~ path ($FILE_PATH) is refused by firstmate policy"
          return 0 ;;
      esac
      # The write root check resolves the path PHYSICALLY - a symlink inside
      # the worktree pointing outside the roots must not carry the write with
      # it, and an unresolvable target is refused rather than judged.
      abs=$(CWD=$WORKTREE write_target_path "$FILE_PATH" 0 2>/dev/null) || abs=''
      [ -n "$abs" ] || {
        refuse "$TOOL of an unresolvable path ($FILE_PATH) is refused by firstmate policy"
        return 0
      }
      if brief_protected "$abs"; then
        refuse "writing this task's own instructions ($FILE_PATH) is refused by firstmate policy"
        return 0
      fi
      if protected_target "$abs"; then
        refuse "$TOOL of firstmate's own permission wiring ($FILE_PATH) is refused by firstmate policy"
        return 0
      fi
      sensitive_text "$FILE_PATH" \
        && { SENSITIVE_HIT=1; no_approve "$TOOL of credential material"; return 0; }
      granted_env_file_text "$FILE_PATH" \
        && { SENSITIVE_HIT=1; no_approve "$TOOL of a credential file this task may only source"; return 0; }
      if strictly_inside "$abs" "$WORKTREE"; then
        rel=${abs#"$(norm_abs "$WORKTREE")"/}
        case "$rel" in
          # A write into the worktree's hook or git state can disarm this
          # layer or the repository's own controls, so it is refused outright
          # rather than judged.
          .git|.git/*|.agents|.agents/*)
            refuse "$TOOL of agent or git configuration ($rel) is refused by firstmate policy" ;;
          .devin|.devin/*|.claude|.claude/*)
            no_approve "$TOOL of agent or git configuration" ;;
        esac
      elif ! inside_scratch_write_roots "$abs"; then
        # Under bypass there is no native prompt to catch an out-of-root
        # write, so the layer refuses it outright instead of judging.
        refuse "$TOOL outside the task write roots ($FILE_PATH) is refused by firstmate policy"
      fi
      ;;
    manage_task)
      # Native TaskId ownership has no verified binding in this adapter yet.
      # A model label or a guessed session prefix is not cancellation proof.
      if [ "$(printf '%s' "$PAYLOAD" | jq -r '.toolCall.args.Action // ""')" = kill ]; then
        never_approve "native task cancellation requires verified ownership and firstmate approval"
      else
        no_approve "$TOOL is not auto-approved"
      fi
      ;;
    *) no_approve "$TOOL is not auto-approved" ;;
  esac
}

marker_path() {  # <key> -> pending marker path for a decision key
  local k=${1#agy-permission-}
  case "$k" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s/%s.pending' "$PENDING_DIR" "$k"
}

declined_key_file() {  # cache entry marking a call firstmate declined
  local k
  k=$(cache_key) || return 1
  printf '%s/%s.declined' "$CACHE_DIR" "$k"
}

# 0 when this file-tool read targets only the worker's own brain directory or
# a file the brief directs it to read. Neither can be an excluded source: the
# brain directory holds only what this conversation's own reviewed calls
# fetched, and a directed file is part of the instructions. The target is
# resolved physically, so a symlink out of either cannot carry the read with
# it; the credential checks in evaluate_tool still run first.
own_read() {
  local target abs d
  case "$TOOL" in
    view_file) target=$FILE_PATH ;;
    list_dir) target=$(printf '%s' "$PAYLOAD" | jq -r '.toolCall.args.DirectoryPath // ""' 2>/dev/null) ;;
    *) return 1 ;;
  esac
  case "$target" in /*) ;; *) return 1 ;; esac
  abs=$(physical_target "$target" '' 0 2>/dev/null) || return 1
  abs=$(resolve_symlink_chain "$abs") || return 1
  if [ -n "$FM_POLICY_OWN_OUTPUT_DIR" ]; then
    [ "$abs" = "$FM_POLICY_OWN_OUTPUT_DIR" ] && return 0
    strictly_inside "$abs" "$FM_POLICY_OWN_OUTPUT_DIR" && return 0
  fi
  [ "$TOOL" = view_file ] || return 1
  while IFS= read -r d; do
    [ -n "$d" ] && [ "$d" = "$abs" ] && return 0
  done <<<"$(brief_directed_reads)"
  return 1
}

apply_read_constraints() {
  READ_CONSTRAINTS=$(brief_read_constraints)
  [ -n "$READ_CONSTRAINTS" ] || return 0
  own_read && return 0
  case "$TOOL" in
    run_command|view_file|grep_search|list_dir|search_web|read_url_content)
      no_approve "brief read exclusions require scope review"
      # Never reuse an approval from before an exclusion was added/changed.
      CACHE_INPUT="$CACHE_INPUT"$'\n'"$READ_CONSTRAINTS"
      ;;
  esac
}

case "$EVENT" in
  armed)
    write_armed
    exit 0
    ;;
  judge-probe)
    # The measurement seam (not an agy hook). Same payload, same static
    # analysis, same prompt as a real pre-tool-use - but nothing is written,
    # so a tier comparison leaves no trace in the task's cache, markers,
    # status file, or observer log, and never arms the canary either.
    if [ "$TOOL" = "$FM_POLICY_EXEC_TOOL" ]; then
      evaluate_exec "$CMD" "${AGY_CWD:-$WORKTREE}"
    else
      evaluate_tool
    fi
    apply_read_constraints
    if [ -n "$REFUSE_REASON" ]; then judge_probe refuse
    elif [ -z "$NOT_APPROVABLE" ]; then judge_probe read-and-build
    elif [ -n "$NEVER_APPROVE" ]; then judge_probe never-approve
    elif [ -n "$SENSITIVE_HIT" ]; then judge_probe credential
    else judge_probe residue
    fi
    exit 0
    ;;
  pre-tool-use)
    if [ "$TOOL" = "$FM_POLICY_EXEC_TOOL" ]; then
      evaluate_exec "$CMD" "${AGY_CWD:-$WORKTREE}"
    else
      evaluate_tool
    fi
    apply_read_constraints
    # The armed line is written even for a call about to be denied: any hook
    # invocation proves this launch's wiring is live, and the canary watches
    # the observer log only.
    write_armed
    # The refusal list speaks before every scope check: a refused command is
    # refused no matter whose workspace or policy state the call arrived
    # under.
    if [ -n "$REFUSE_REASON" ]; then
      log_record refuse policy "$REFUSE_REASON"
      deny "Blocked by firstmate policy: $REFUSE_REASON"
    fi
    # A call scoped to a foreign or missing workspace, or arriving with no
    # readable policy behind it, cannot be judged here - and under a bypass
    # launch abstaining would run it, so both deny.
    if [ -n "$WORKTREE" ]; then
      printf '%s' "$PAYLOAD" | jq -e --arg wt "$WORKTREE" \
        '.workspacePaths | type == "array" and index($wt) != null' >/dev/null 2>&1 \
        || { log_record refuse policy "tool call is not scoped to this task's workspace"
             deny "firstmate agy permission policy: tool call is not scoped to this task's workspace"; }
    fi
    [ -n "$POLICY" ] && [ -r "$POLICY" ] \
      || deny "firstmate agy permission policy: per-task policy file is missing or unreadable"
    if [ -z "$NOT_APPROVABLE" ]; then
      log_record approve policy "read-and-build set"
      exit 0
    fi
    summary=$(one_line "$(input_summary)" 2000)
    # A call already held for firstmate stays held: the open marker is
    # consulted BEFORE the verdict cache and before the judge so a retried
    # hold can never re-roll a nondeterministic judge into running it anyway.
    # Only firstmate's approve verb closes the marker and lands the cache
    # entry that lets the retry through.
    if [ -d "$PENDING_DIR" ]; then
      for m in "$PENDING_DIR"/*.pending; do
        [ -f "$m" ] || continue
        [ "$(sed -n '2p' "$m" 2>/dev/null)" = "$summary" ] || continue
        IFS= read -r held_key < "$m" 2>/dev/null || held_key=''
        log_record refuse policy "retried a call still held for firstmate as ${held_key:-held}"
        deny "still held for firstmate as ${held_key:-held}: $(one_line "$NOT_APPROVABLE" 160). Do not retry unless firstmate approves it."
      done
    fi
    if declined_file=$(declined_key_file 2>/dev/null) && [ -n "$declined_file" ] && [ -f "$declined_file" ]; then
      # Firstmate already declined this exact call; a retry is denied without
      # a second escalation so a looping worker cannot spam the status file.
      log_record refuse policy "firstmate declined this call earlier in this task"
      deny "firstmate declined this call; do not retry it"
    fi
    escalate_reason='' escalate_source='first judge'
    if { [ -n "$NEVER_APPROVE" ] || [ -n "$SENSITIVE_HIT" ]; } && [ -n "$CACHE_DIR" ] \
      && once_key=$(cache_key 2>/dev/null) && [ -n "$once_key" ] \
      && [ -f "$CACHE_DIR/$once_key.once" ]; then
      # Firstmate's one-shot approval of a never-approve call: the token is
      # consumed by this retry, so a further retry escalates again. It is
      # bound to this invocation so a later denied retry cannot borrow proof
      # from an earlier authorized run, even if its post hook never arrived.
      if mv -f "$CACHE_DIR/$once_key.once" "$CACHE_DIR/$once_key.once-spent" 2>/dev/null \
        && tool_slug > "$CACHE_DIR/$once_key.once-spent"; then
        log_record approve firstmate "one-shot approval consumed"
        exit 0
      fi
      deny "firstmate agy permission policy: could not consume the one-shot approval"
    elif [ -n "$NEVER_APPROVE" ]; then
      # Outward actions skip the judge and the cache entirely; a firstmate
      # approval is a one-off, so a retry escalates again.
      escalate_reason=$NEVER_APPROVE escalate_source='firstmate policy'
      log_record escalate policy "$NEVER_APPROVE"
    elif [ -n "$SENSITIVE_HIT" ]; then
      # Credential material never reaches the judge under bypass: there is no
      # native prompt behind it, so the call is held for firstmate directly.
      # Only the exact one-shot token above authorizes this retry; a reusable
      # cache entry from an older policy must not authorize credential reads.
      escalate_reason=$NOT_APPROVABLE escalate_source='firstmate policy'
      log_record escalate policy "$NOT_APPROVABLE"
    elif cache_lookup; then
      log_record approve cache "$CACHE_REASON (static: $NOT_APPROVABLE)"
      exit 0
    else
      run_judge
      if [ "$JUDGE_VERDICT" = approve ]; then
        cache_store "first judge: $JUDGE_REASON"
        log_record approve judge "$JUDGE_REASON (judge: $(fm_judge_attribution), static: $NOT_APPROVABLE)"
        exit 0
      fi
      escalate_reason=$JUDGE_REASON
      log_record escalate judge "$JUDGE_REASON (judge: $(fm_judge_attribution), static: $NOT_APPROVABLE)"
    fi
    slug=$(tool_slug)
    key="agy-permission-$slug"
    if [ -n "$PENDING_DIR" ] && mkdir -p "$PENDING_DIR" 2>/dev/null; then
      marker="$PENDING_DIR/$slug.pending"
      if [ ! -e "$marker" ]; then
        ckey=$(cache_key 2>/dev/null || true)
        mclass=judge
        if [ -n "$NEVER_APPROVE" ] || [ -n "$SENSITIVE_HIT" ]; then mclass=never; fi
        printf '%s\n%s\n%s\n%s\n' "$key" "$summary" "$ckey" "$mclass" \
          > "$marker" 2>/dev/null || true
        status_append "needs-decision [key=$key]: agy worker held a tool call for firstmate - $TOOL ($escalate_source: $(one_line "$escalate_reason" 160)): $(one_line "$summary" 300)"
      fi
    fi
    deny "held for firstmate: $(one_line "$escalate_reason" 200). Do not retry unless firstmate approves it."
    ;;
  post-tool-use)
    # A held call that later ran is matched by the same deterministic input
    # summary the escalation writes, not by the call's key - the retry
    # arrives at a new stepIdx. Only a firstmate approval authorizes the run:
    # a matching call with no approval cache entry ran DESPITE its deny,
    # which is an anomaly with its own status line rather than an approval.
    summary=$(one_line "$(input_summary)" 2000)
    for m in "$PENDING_DIR"/*.pending; do
      [ -f "$m" ] || continue
      [ "$(sed -n '2p' "$m" 2>/dev/null)" = "$summary" ] || continue
      mckey=$(sed -n '3p' "$m" 2>/dev/null)
      mclass=$(sed -n '4p' "$m" 2>/dev/null)
      # An earlier authorized invocation completing cannot close a later
      # one-shot hold merely because its command is identical.
      [ "$mclass" != never ] || [ "${m##*/}" = "$(tool_slug).pending" ] || continue
      if [ -n "$mckey" ] && { { [ "$mclass" != never ] && [ -f "$CACHE_DIR/$mckey" ]; } \
        || { [ -f "$CACHE_DIR/$mckey.once-spent" ] \
          && [ "$(cat "$CACHE_DIR/$mckey.once-spent")" = "$(tool_slug)" ]; }; }; then
        close_pending "$m" approved "the escalated $TOOL call was approved and ran" policy
      else
        close_pending "$m" anomaly "the held $TOOL call ran WITHOUT a firstmate approval - the deny was not honored; audit this worker's pane" policy
      fi
    done
    # A completed invocation no longer needs its consumed approval proof.
    for spent in "$CACHE_DIR"/*.once-spent; do
      [ -f "$spent" ] || continue
      [ "$(cat "$spent")" != "$(tool_slug)" ] || rm -f "$spent"
    done
    exit 0
    ;;
  stop)
    # Markers survive the turn: a held call is a decision firstmate still
    # owes, not a call still in flight, so only approve, decline, a
    # post-tool-use run, or retire closes one.
    write_armed
    exit 0
    ;;
  approve|decline)
    marker=$(marker_path "$KEY") || {
      echo "fm-agy-permission-policy: no pending escalation for key: $KEY" >&2
      exit 1
    }
    [ -f "$marker" ] || {
      echo "fm-agy-permission-policy: no pending escalation for key: $KEY" >&2
      exit 1
    }
    { IFS= read -r _; IFS= read -r _; IFS= read -r pckey; IFS= read -r pclass; } < "$marker" 2>/dev/null
    if [ "$EVENT" = approve ]; then
      [ -n "$pckey" ] && rm -f "$CACHE_DIR/$pckey.declined" 2>/dev/null || true
      if [ "$pclass" = never ]; then
        # A never-approve call cannot be cache-approved: the next identical
        # call would run forever. The approval is a one-shot token the retry
        # consumes, so a further retry escalates again.
        if [ -n "$pckey" ] && mkdir -p "$CACHE_DIR" 2>/dev/null \
          && printf 'one-shot\n' > "$CACHE_DIR/$pckey.once" 2>/dev/null; then
          close_pending "$marker" approved "firstmate approved ONE run of the held call; the worker must retry the identical command or batch once - a changed call or further retry escalates again" firstmate
        else
          close_pending "$marker" not-run "firstmate approved it, but this call cannot be honored without a verdict cache - run it manually" firstmate
        fi
      elif [ -n "$pckey" ]; then
        cache_store "firstmate approved earlier in this task" "$pckey"
        close_pending "$marker" approved "firstmate approved the held call; the worker must retry the identical command or batch; changed inputs need a new decision" firstmate
      else
        close_pending "$marker" approved "firstmate approved the held call; the worker must retry the identical command or batch; changed inputs need a new decision" firstmate
      fi
    else
      if [ -n "$pckey" ]; then
        mkdir -p "$CACHE_DIR" 2>/dev/null \
          && printf '%s\n' "declined by firstmate" > "$CACHE_DIR/$pckey.declined" 2>/dev/null || true
      fi
      close_pending "$marker" declined "firstmate declined the held call" firstmate
    fi
    exit 0
    ;;
  repin-grants)
    # Firstmate edits a live brief's grants on purpose; this records the new
    # digest so the block is honored again. Nothing a worker can reach runs it.
    [ -n "$POLICY" ] && [ -r "$POLICY" ] && [ -w "$POLICY" ] || {
      echo "fm-agy-permission-policy: cannot repin grants: $POLICY is not writable" >&2
      exit 1
    }
    new_sha=$(grants_digest "$(grants_block)" 2>/dev/null || true)
    if ! jq --arg sha "$new_sha" '.grants_sha = $sha' "$POLICY" > "$POLICY.repin" 2>/dev/null \
      || ! mv "$POLICY.repin" "$POLICY"; then
      rm -f "$POLICY.repin"
      echo "fm-agy-permission-policy: cannot repin grants: $POLICY could not be rewritten" >&2
      exit 1
    fi
    echo "repinned grants digest for ${TASK:-this task}: ${new_sha:-(no grants block)}"
    exit 0
    ;;
  retire)
    for marker in "$PENDING_DIR"/*.pending; do
      [ -f "$marker" ] || continue
      close_pending "$marker" not-run "the escalated call did not run (the worker was relaunched)"
    done
    rm -rf -- "$PENDING_DIR" || exit 1
    exit 0
    ;;
esac
exit 0
