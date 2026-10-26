#!/usr/bin/env bash
# fm-agy-permission-policy.sh - deterministic agy worker policy and decisions.
#
# Usage: fm-agy-permission-policy.sh <event> <policy.json> [<decision-key>]
# Events: armed | pre-tool-use | post-tool-use | stop | native-poll |
#         approve | decline | resume | retire | repin-grants |
#         register-credentials | judge-probe
# Queries: grants-digest <brief> | verified-versions | --help
#
# A policy with posture=native-auto retains physical write-root, protected
# wiring/instruction, metadata-only credential, force/publication and brief
# scope constraints. Refusals emit deny. Firstmate-specific questions deny
# with a durable held-call decision; only an exact one-shot approval permits
# their retry. Ordinary residue abstains to native Auto without a Firstmate
# judge or reusable judge approval. Native execution remains independently
# reviewed by the vendor. This static layer is not an OS security boundary.
#
# native-poll inspects only the recorded worker's live viewport and binds an
# answerable command panel to exactly one outstanding native hook input.
# It writes an agy-permission-<conversationId>-s<stepIdx> keyed needs-decision
# marker, or an unbound decision when identity/shape cannot be proven.
# approve selects option 1 once and confirms the same invocation's PostToolUse.
# decline selects option 4, then submits a tool-free reconciliation turn;
# only its accepted generation/main-conversation Stop settles cancellation.
# A sent but unconfirmed action stays open and cannot be sent again. resume
# finishes that reconciliation without repeating a sent action or message.
# Never select a conversation-wide or persistent approval. Unbound prompts
# require inspection or guarded relaunch rather than guessed keys.
# fm-agy-native-lib.sh owns the backend mechanics and activation contract.
#
# Policies without posture=native-auto are legacy bypass tasks. Their prior
# judge selection, caches, held-call exact retry tokens, declined-retry
# suppression and management verbs remain supported until they finish.
# A held marker survives Stop and closes only on approval, decline, an
# authorized completion, or retire. No version string admits a binary;
# fm-agy-admission.sh owns executable/context verification.
#
# Hook JSON uses conversationId, stepIdx, workspacePaths and toolCall.name/args.
# run_command uses CommandLine/Cwd; read_file, write_file and edit_file use
# absolute Path. Legacy file names remain mapped too. Observer/log input
# excludes file contents. A conversation's own brain outputs and explicitly
# directed skill reads retain their existing read-scope exception, after
# credential checks. fm-command-policy-lib.sh owns command analysis and grant
# pinning; fm-credential-access.mjs owns credential metadata and use grants.
#
# The firstmate-owned policy declares task, worktree, status, inbox, data,
# tasktmp, brief, log, gen, config and optional agy_version/credential fields.
# Legacy policies additionally declare agy, judge_tier/bin/model/timeout.
# <policy-without-.json>-pending/ holds exact pending calls and native decline
# records; -cache/ is retained for legacy judge verdicts and exact one-shot
# Firstmate constraints. Both are protected wiring and retire with the task.
# Armed records are generation-bound; missing policy, malformed input or
# foreign workspace denies. Hook events exit 0 with deny JSON or silence;
# failed management verbs exit nonzero. Management/query verbs read no stdin.

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
# Use the shared conservative static write refusals in both routes. Native
# review must not widen Firstmate's authorized task write roots.
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

if [ "${1:-}" = --help ]; then
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 0
fi
EVENT=${1-}
POLICY=${2-}
KEY=${3-}
case "$EVENT" in
  armed|pre-tool-use|post-tool-use|stop|approve|decline|retire|repin-grants|register-credentials|grants-digest|verified-versions|judge-probe|native-poll|resume) ;;
  *)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}" >&2
    exit 0
    ;;
esac

if [ "$EVENT" = verified-versions ]; then
  # Migration history, not authority for an arbitrary same-version executable.
  # The bounded admission owner retains the explicit manual-baseline refresh
  # path without requiring a tracked list edit for eligible patch candidates.
  printf '1.2.4 1.2.5 1.2.6 1.2.7 1.2.11 1.3.1 1.3.5 1.3.6 1.4.0 1.4.4\n'
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
  [ "$EVENT" != post-tool-use ] || set -- "$@" "$PENDING_DIR"/*.candidate
  [ "$EVENT" != post-tool-use ] || set -- "$@" "$CACHE_DIR"/*.once-spent
  for m in "$@"; do [ ! -f "$m" ] || break; done
  [ -f "$m" ] || { cat >/dev/null; exit 0; }
fi
if [ "$EVENT" = retire ]; then
  [ -n "$PENDING_DIR" ] && [ -d "$PENDING_DIR" ] || { rm -rf "$PENDING_DIR" 2>/dev/null; exit 0; }
fi

PAYLOAD=
case "$EVENT" in retire|repin-grants|register-credentials|approve|decline|native-poll|resume) ;; *) PAYLOAD=$(cat) ;; esac

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
NATIVE_AUTO=0
if jq -e '.posture == "native-auto"' "$POLICY" >/dev/null 2>&1; then
  NATIVE_AUTO=1
  JUDGE_TIER=native JUDGE_MODEL=''
  if [ "$EVENT" = judge-probe ]; then
    echo 'fm-agy-permission-policy: native Auto policies have no Firstmate model judge' >&2
    exit 1
  fi
else
  fm_judge_tier_bind "$FM_JUDGE_TIER_NATIVE" "$AGY"
fi

TOOL='' TOOL_USE_ID='' SESSION_ID='' CMD='' AGY_CWD='' FILE_PATH='' INPUT_JSON='' CACHE_INPUT=''
case "$EVENT" in
  native-poll|resume|approve|decline)
    # Native command panels are answered through the existing policy verbs.
    # Hook-held deterministic decisions keep their original exact-token path.
    native_action=$EVENT
    [ "$native_action" != native-poll ] || native_action=poll
    native_marker="$PENDING_DIR/${KEY#agy-permission-}.pending"
    if [ "$NATIVE_AUTO" = 1 ] && { [ "$EVENT" = native-poll ] || [ "$EVENT" = resume ] \
      || [ "$(sed -n '4p' "$native_marker" 2>/dev/null)" = native ]; }; then
      # shellcheck source=bin/fm-backend.sh
      . "$SCRIPT_DIR/fm-backend.sh"
      # shellcheck source=bin/fm-busy-lib.sh
      . "$SCRIPT_DIR/fm-busy-lib.sh"
      # shellcheck source=bin/fm-agy-native-lib.sh
      . "$SCRIPT_DIR/fm-agy-native-lib.sh"
      fm_agy_native_decision "$native_action" "$POLICY" "$KEY"
      exit $?
    fi
    [ "$EVENT" != native-poll ] && [ "$EVENT" != resume ] || exit 1
    ;;
esac

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
if [ "$NATIVE_AUTO" = 1 ] && [ -n "$WORKTREE" ]; then
  # Shell writers must preserve the same agent/Git wiring boundary as native
  # file tools, including a hooks file that does not exist at launch yet.
  POLICY_PROTECTED="$POLICY_PROTECTED"$'\n'"$WORKTREE/.agents"$'\n'"$WORKTREE/.git"
fi
credential_policy

{
  IFS= read -r -d '' TOOL
  IFS= read -r -d '' TOOL_USE_ID
  IFS= read -r -d '' SESSION_ID
  IFS= read -r -d '' _
  IFS= read -r -d '' CMD
  IFS= read -r -d '' AGY_CWD
  IFS= read -r -d '' FILE_PATH
  IFS= read -r -d '' INPUT_JSON
  IFS= read -r -d '' CACHE_INPUT
} < <(printf '%s' "$PAYLOAD" | jq -j '
  def s: (. // "") | tostring | gsub("\u0000"; "");
  (.conversationId | s) as $conv
  | (.stepIdx | if type == "number" then . else "" end | tostring) as $step
  | (.toolCall.args // {}) as $a
  | ($a | del(.Content?, .NewContent?, .OldString?, .NewString?, .Text?,
             .CodeContent?, .Contents?, .Target?, .Replacement?)) as $cacheargs
  | [ (.toolCall.name | s),
      (if $conv != "" and $step != "" then "\($conv)-s\($step)" else "" end | s),
      ($conv | s),
      ($step | s),
      ($a.CommandLine | s),
      ($a.Cwd | s),
      (if .toolCall.name == "read_file" or .toolCall.name == "write_file" or .toolCall.name == "edit_file"
       then $a.Path | s
       else [$a.TargetFile, $a.AbsolutePath, $a.FilePath, $a.File]
         | map(select(type == "string" and . != "")) | .[0] // "" | s
       end),
      (($a) | tojson | .[0:2000] | s),
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

native_abstain() {
  # Record full, exact inputs only for calls that actually reach native review.
  # Candidates are private and protected by the same policy as pending holds.
  # Multiple concurrent calls remain distinct; an ambiguous panel is never
  # answered. File prompts with no supported exact binding remain unbound.
  local slug candidate
  [ "$NATIVE_AUTO" = 1 ] && [ "$TOOL" = run_command ] || return 0
  slug=$(tool_slug) || return 1
  case "$slug" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  candidate="$PENDING_DIR/$slug.candidate"
  mkdir -p "$PENDING_DIR" || return 1
  printf '%s' "$PAYLOAD" | jq -c --arg gen "$GEN" \
    '{gen:$gen, session:.conversationId, step:.stepIdx, tool:.toolCall.name, args:.toolCall.args}' \
    > "$candidate" || return 1
}

native_control_boundary() {
  # Known Firstmate state/decision writers are supervisor-only. A literal
  # invocation must not become ordinary vendor-reviewed residue. Plain
  # read-and-build inspection of these public scripts stays allowed.
  local i path leaf
  [ "$NATIVE_AUTO" = 1 ] && [ "$TOOL" = run_command ] && [ -n "$NOT_APPROVABLE" ] || return 0
  tokenize "$CMD"
  for ((i=0; i<${#T_TXT[@]}; i++)); do
    [ "${T_KIND[i]}" = w ] || continue
    leaf=${T_TXT[i]##*/}
    case "$leaf" in
      fm-agy-permission-policy.sh|fm-agy-native-lib.sh|fm-agy-hook.sh|fm-busy-event.sh|fm-control.sh) ;;
      *) continue ;;
    esac
    path=$(physical_target "${T_TXT[i]}" "${AGY_CWD:-$WORKTREE}" 0 2>/dev/null) || continue
    [ "$path" = "$(norm_abs "$SCRIPT_DIR/$leaf")" ] || continue
    refuse 'invoking Firstmate permission, lifecycle or busy-state control is reserved to the supervisor'
    return 0
  done
}

evaluate_tool() {  # non-exec agy tools: sets NOT_APPROVABLE
  REFUSE_REASON='' NOT_APPROVABLE='' NEVER_APPROVE='' SENSITIVE_HIT=''
  local fields credential_tool=$TOOL native_tool=$TOOL
  case "$TOOL" in
    read_file|write_file|edit_file)
      # Current agy file tools use Path, not the legacy CamelCase fields.
      # Granted hook directories are also workspaces, so a relative target
      # has no proven task-root base. Require the actual absolute operand.
      case "$FILE_PATH" in
        /*) ;;
        *) refuse "$TOOL requires an absolute Path"; return 0 ;;
      esac
      fields=$(printf '%s' "$PAYLOAD" | jq -c '{AbsolutePath:.toolCall.args.Path}')
      case "$TOOL" in
        read_file) credential_tool=view_file ;;
        write_file) credential_tool=write_to_file ;;
        edit_file) credential_tool=replace_file_content ;;
      esac
      ;;
    *) fields=$(printf '%s' "$PAYLOAD" | jq -c '.toolCall.args // {} | {TargetFile,AbsolutePath,FilePath,File,SearchPath,DirectoryPath,RootDirectory,Input,Recursive,Url,URL,Query}') ;;
  esac
  TOOL=$credential_tool
  credential_native "$fields" "$WORKTREE"
  TOOL=$native_tool
  case "$TOOL" in
    read_file|view_file|grep_search|list_dir|search_web|read_url_content)
      ;;
    write_file|edit_file|write_to_file|replace_file_content)
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
      [ -z "$CREDENTIAL_HOLD" ] || return 0
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
    read_file|view_file) target=$FILE_PATH ;;
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
  case "$TOOL" in read_file|view_file) ;; *) return 1 ;; esac
  while IFS= read -r d; do
    [ -n "$d" ] && [ "$d" = "$abs" ] && return 0
  done <<<"$(brief_directed_reads)"
  return 1
}

native_activation_call() {
  # The fixed nonce printf reads no source. Brief read exclusions must not
  # prevent the pre-brief activation proof itself from running.
  [ "$NATIVE_AUTO" = 1 ] && [ "$TOOL" = run_command ] && [ -z "$NOT_APPROVABLE" ] || return 1
  tokenize "$CMD"
  [ "${#T_TXT[@]}" = 4 ] && [ "${T_KIND[*]}" = 'w w r w' ] \
    && [ "${T_TXT[0]}" = /usr/bin/printf ] && [ "${T_TXT[2]}" = '>' ] || return 1
  local i nonce=${T_TXT[1]}
  case "$nonce" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#nonce}" = 48 ] && [ "${T_TXT[3]}" = "$TASKTMP/agy-activation-$GEN-$nonce" ] || return 1
  for i in 0 1 2 3; do
    [ "${T_VAR[i]}${T_GLOB[i]}${T_SUBS[i]}" = 000 ] || return 1
  done
}

apply_read_constraints() {
  READ_CONSTRAINTS=$(brief_read_constraints)
  [ -n "$READ_CONSTRAINTS" ] || return 0
  own_read && return 0
  native_activation_call && return 0
  case "$TOOL" in
    run_command|read_file|view_file|grep_search|list_dir|search_web|read_url_content)
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
    native_control_boundary
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
    if [ "$NATIVE_AUTO" = 1 ]; then
      case "$GEN" in ''|*[!A-Za-z0-9._-]*) deny 'firstmate agy native policy has no valid generation' ;; esac
      [ "$(cat "${POLICY%/*}/$TASK.busy-gen" 2>/dev/null)" = "$GEN" ] \
        || deny 'firstmate agy native policy generation is stale or unavailable'
    fi
    if [ "$NATIVE_AUTO" = 1 ] && [ "$TOOL" = run_command ]; then
      for declined in "$PENDING_DIR"/*.native-declined; do
        [ -f "$declined" ] || continue
        if jq -e --arg gen "$GEN" --arg cmd "$CMD" --arg cwd "${AGY_CWD:-$WORKTREE}" --arg wt "$WORKTREE" \
          '.gen == $gen and .args.CommandLine == $cmd and ((.args.Cwd // $wt) == $cwd)' "$declined" >/dev/null; then
          deny 'firstmate declined this native call; do not retry it'
        fi
      done
    fi
    if [ -z "$NOT_APPROVABLE" ]; then
      native_abstain || deny 'firstmate agy native policy could not retain exact call identity'
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
    if { [ "$NATIVE_AUTO" = 1 ] || [ -n "$NEVER_APPROVE" ] || [ -n "$SENSITIVE_HIT" ] || [ "$JUDGE_SCRIPT_UNCACHEABLE" = 1 ]; } && [ -n "$CACHE_DIR" ] \
      && once_key=$(cache_key 2>/dev/null) && [ -n "$once_key" ] \
      && [ -f "$CACHE_DIR/$once_key.once" ]; then
      # Firstmate's one-shot approval of an uncached call: the token is
      # consumed by this retry, so a further retry escalates again. It is
      # bound to this invocation so a later denied retry cannot borrow proof
      # from an earlier authorized run, even if its post hook never arrived.
      if mv -f "$CACHE_DIR/$once_key.once" "$CACHE_DIR/$once_key.once-spent" 2>/dev/null \
        && tool_slug > "$CACHE_DIR/$once_key.once-spent"; then
        log_record approve firstmate "one-shot approval consumed"
        native_abstain || deny 'firstmate agy native policy could not retain exact call identity'
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
    elif [ "$NATIVE_AUTO" = 1 ] && [ -z "$READ_CONSTRAINTS" ]; then
      native_abstain || deny 'firstmate agy native policy could not retain exact call identity'
      log_record native-review native "ordinary command review delegated to native Auto"
      exit 0
    elif [ "$NATIVE_AUTO" = 1 ]; then
      escalate_reason=$NOT_APPROVABLE escalate_source='firstmate scope policy'
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
        if [ "$NATIVE_AUTO" = 1 ] || [ -n "$NEVER_APPROVE" ] || [ -n "$SENSITIVE_HIT" ] || [ "$JUDGE_SCRIPT_UNCACHEABLE" = 1 ]; then mclass=never; fi
        printf '%s\n%s\n%s\n%s\n' "$key" "$summary" "$ckey" "$mclass" \
          > "$marker" 2>/dev/null || true
        status_append "needs-decision [key=$key]: agy worker held a tool call for firstmate - $TOOL ($escalate_source: $(one_line "$escalate_reason" 160)): $(one_line "$summary" 300)"
      fi
    fi
    deny "held for firstmate: $(one_line "$escalate_reason" 200). Do not retry unless firstmate approves it."
    ;;
  post-tool-use)
    if [ "$NATIVE_AUTO" = 1 ]; then
      slug=$(tool_slug)
      case "$slug" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
      marker="$PENDING_DIR/$slug.pending"
      if [ -f "$marker" ] && [ "$(sed -n '4p' "$marker")" = native ]; then
        # The exact native invocation completed after a one-shot selection.
        # It never creates the legacy reusable approval cache.
        if [ "$(cat "$PENDING_DIR/$slug.native.sent" 2>/dev/null)" = approve ]; then
          if [ "$(jq -cS .args "$PENDING_DIR/$slug.candidate" 2>/dev/null)" != \
            "$(printf '%s' "$PAYLOAD" | jq -cS .toolCall.args)" ]; then
            log_record anomaly native 'native completion did not match the approved exact input'
            status_append "needs-decision [at=$(date +%s)] [key=agy-permission-$slug]: native completion differs from the exact approved input; inspect the worker before resuming"
            exit 0
          fi
          printf '%s\n' "$GEN" > "$PENDING_DIR/$slug.native.completed" || exit 1
          close_pending "$marker" approved "native one-shot approval completed the exact invocation" firstmate
          rm -f "$PENDING_DIR/$slug.native" "$PENDING_DIR/$slug.native.sent"
        else
          close_pending "$marker" anomaly "native held call completed without a recorded one-shot approval; inspect the worker" policy
        fi
      fi
      rm -f "$PENDING_DIR/$slug.candidate"
    fi
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
      case "$mclass" in native|native-unbound) continue ;; esac
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
        # An uncached call cannot be cache-approved: the next identical
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
  register-credentials)
    credential_record_grants && credential_pin_registry || exit 1
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
    credential_record_grants "$new_sha" || exit 1
    if ! jq --arg sha "$new_sha" '.grants_sha = $sha' "$POLICY" > "$POLICY.repin" 2>/dev/null \
      || ! mv "$POLICY.repin" "$POLICY"; then
      rm -f "$POLICY.repin"
      echo "fm-agy-permission-policy: cannot repin grants: $POLICY could not be rewritten" >&2
      exit 1
    fi
    echo "repinned grants digest for ${TASK:-this task}: ${new_sha:-(no grants block)}"
    credential_pin_registry || exit 1
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
