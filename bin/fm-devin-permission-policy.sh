#!/usr/bin/env bash
# fm-devin-permission-policy.sh - firstmate's permission decision layer for
# Devin CLI workers. bin/fm-devin-lib.sh installs it as native Devin lifecycle
# hooks in the worker's private config (state/<id>.devin-config.json); it and its
# per-task policy file (state/<id>.devin-permission.json) live outside the
# worktree, and Devin reads hooks once at session start, so a worker cannot
# rewrite the policy mid-session.
#
# Usage: fm-devin-permission-policy.sh <event> <policy-file>
#   events: pre-tool-use | permission-request | post-tool-use | stop | retire |
#           repin-grants | judge-probe
#        fm-devin-permission-policy.sh grants-digest <brief-file>
# The Devin hook payload arrives as JSON on stdin (the last three read none).
#
#   pre-tool-use (matcher ^exec$)
#       Refuses the hard-line list for the whole command string, including
#       every && / ; / | segment, $(...) and backtick bodies, bash -c / sh -c /
#       eval strings, find -exec commands, and env / xargs / nohup / timeout
#       wrappers: sudo, launchctl, a git push force in any argument position
#       (--force, --force-with-lease, --force-if-includes, a short-flag
#       cluster containing f, a +refspec, or any push option not on the exact
#       list of known non-force spellings, since git accepts abbreviated long
#       options), a recursive rm whose target, with its existing directory
#       components resolved physically through symlinks, is not strictly
#       inside the worktree or cannot be resolved, any gh repo
#       command, and gh pr create without an explicit --repo / -R, plus
#       everything the shared publish policy refuses (bin/fm-gh-publish-policy.mjs,
#       reached through bin/fm-command-policy-lib.sh).
#       This is the only step a call admitted by one of the private config's
#       Exec(...) pre-allow prefixes reaches, so it also refuses the git forms
#       such a prefix could admit that review would otherwise catch: a
#       mutating git remote subcommand, a git checkout or git switch form that
#       can discard uncommitted work, a push that deletes, mirrors, or
#       publishes beyond the task branch, a fetch naming its own upload-pack
#       program, and an option that writes a file or runs a program
#       (FM_POLICY_PREALLOW_GUARD in the shared library). Each refusal names
#       its fix.
#       A refusal prints {"decision":"block"} and exits 2; anything else exits
#       0 silently so Devin's own permission layer decides.
#
#   permission-request (every tool)
#       Fires only when Devin would otherwise prompt. Refused commands are
#       blocked here too. A command whose every segment is in the read-and-build
#       set below is approved with {"decision":"approve"}, silently. The
#       residue goes to a cheap first judge on the policy's judge TIER, which
#       for this adapter is the Devin tier unless the policy names another:
#       a headless `devin -p` call on the policy's judge model (SWE-2 High by
#       default), run from an empty directory under the task temp root with the
#       task instructions excerpt and the tool call as data, bounded by the
#       policy's judge timeout. A
#       judge line starting APPROVE approves silently. Anything the judge
#       declines, or a judge that fails, times out, or is disabled, is
#       escalated: a pending marker is written and one needs-decision line
#       naming the exact command and the judge's reason (key
#       devin-permission-<tool-use-slug>) is appended to the task status file,
#       then the hook exits 0 with no output so Devin shows its normal prompt.
#
#   post-tool-use (every tool)
#       When the finished tool call has a pending escalation marker, the call
#       was approved at the prompt: the marker is retired, the outcome logged,
#       and a resolved line closes the decision key.
#
#   stop (Stop, SessionEnd, and UserPromptSubmit)
#       Any escalation still pending when the turn or session ends, or when a
#       new prompt arrives, was not run (declined at the prompt, or cancelled by
#       an interrupt, which fires no Stop): each is logged and closed.
#
#   repin-grants / grants-digest (not Devin hooks)
#       Both belong to the digest pin described under Task grants below.
#       grants-digest prints the digest of a brief's grants block, which
#       bin/fm-spawn.sh records in the policy file at launch. repin-grants
#       rewrites that recorded digest from the brief's current block, which is
#       how FIRSTMATE re-pins grants after editing them on purpose; nothing a
#       worker can reach runs it. Each exits 1 when it cannot do its job.
#
#   judge-probe (not a Devin hook)
#       The measurement seam. Reads the same payload and runs the same static
#       analysis and judge call as permission-request, then prints one line -
#       tier, model, static class, verdict, reason - and writes NOTHING: no
#       verdict cache entry, no pending marker, no status line, no log record.
#       It exists because the judge disagrees with itself often enough that a
#       tier has to be comparable on identical inputs before it is chosen; a
#       harness replays captured payloads through it once per tier and diffs.
#
#   retire (not a Devin hook)
#       bin/fm-spawn.sh runs this when a relaunch retires the Devin wiring, so
#       an escalation left by a worker that died at the prompt is logged and
#       closed as not-run and the pending directory removed while the policy
#       file still names the status file; no later hook could close it.
#       Exits 1 when the pending directory cannot be retired.
#
# The command-policy contract this layer enforces - the hard-refusal list,
# the read-and-build approval set, the protected task briefs, the
# never-approve outward-action class, fetch classification, the recursive-rm
# roots, task grants and their digest pin, the judge retry skeleton, and the
# per-task verdict cache - is owned by bin/fm-command-policy-lib.sh, which
# this adapter sources below; its header holds the shared prose. The judge
# prompt, budget, retry, and verdict parser live there too, and
# bin/fm-judge-tier-lib.sh owns the `devin -p` invocation itself. This file
# owns only the Devin payload schema, the Devin tool-name mapping, the judge
# tier this adapter defaults to, and the Devin decision surface: a refusal
# prints {"decision":"block"} and exits 2, an approval prints
# {"decision":"approve"}, and everything else exits 0 with no output so
# Devin's own permission prompt decides.
#
# Own-PR review writes. One narrow carve-out from the shared never-approve
# class, owned here rather than in the shared library so it reaches Devin
# workers only and never widens what the agy adapter's bypass launch or any
# judge approves. permission-request approves, uncached, a call whose only
# objection was that outward action and whose whole command is one `gh api`
# invocation, or a && chain of them each qualifying on its own - no other
# operator, redirection, substitution, expansion, glob, or ANSI-C quoting,
# and no flag beyond -X/--method POST, the output filters --jq/-q and
# --silent, and --hostname github.com - of exactly one of these shapes:
#   - repos/<owner>/<name>/pulls/<n>/comments with exactly the fields
#     in_reply_to (a number) and body (a -F body must not start with @, which
#     would read a file): a reply to an existing review comment;
#   - repos/<owner>/<name>/issues/<n>/comments with exactly one raw -f body
#     field whose value is `@codex review`: a Codex re-review request;
#   - graphql with exactly one raw -f query field holding one
#     resolveReviewThread mutation with a literal threadId and a plain field
#     selection, where a read-only graphql lookup confirms the thread belongs
#     to the task's own PR;
#   - graphql whose one query document, a raw inline -f query, opens with
#     query, fragment, or {, and never spells mutation or subscription
#     anywhere in any case; it may add literal variable fields (no @file) and
#     --paginate, and names any repo, since it cannot write. A query read
#     from a file (-F query=@<file>) is never approved here, because the
#     approved text must be the text that runs.
# The first three must target the task's own PR on github.com.
# The task's own PR is the pr= line in state/<task>.meta, beside the status
# file; before one is recorded it is the single open PR whose head is the
# worktree's branch, owned by the origin repository's owner. Owner, name, and
# number must all match (case-insensitively for owner and name, as GitHub
# does). A command naming no host is approved only while gh's default host in
# the hook's environment is github.com (GH_HOST unset or github.com, and a
# github.com credential present), and every lookup names github.com itself. An unprovable PR, a failed or timed-out lookup, or any other forge
# write keeps the never-approve escalation.
#
# Non-exec tools: read / grep / glob / notebook_read are approved unless an
# argument names credential material; write / edit / notebook_edit are
# approved for a file strictly inside the worktree (outside .git/, .devin/,
# and .claude/), the task data directory, the task temp root, a granted write
# directory, or /tmp / $TMPDIR scratch space, measured where the path
# physically resolves (directory components and a final symlink chain
# followed). Every other tool escalates.
#
# Policy file (written by bin/fm-spawn.sh): JSON object with string fields
# task, worktree, status, inbox, data, tasktmp, brief, log, devin (absolute
# judge executable), judge_model (a `devin models list` id, which encodes the
# effort level, e.g. swe-2-high or swe-2-medium; read on every call, so
# editing it retargets a running worker's judge; empty disables the judge),
# judge_timeout (seconds, the bound on ONE judge attempt), optional judge_tier
# and judge_bin (the judge tier this task runs and its executable; absent
# means this adapter's own Devin tier on the `devin` field above, and a tier
# this build does not know denies rather than falling back), and grants_sha
# (the digest pin the shared library describes). Pending escalation
# markers live in the sibling directory <policy-file minus .json>-pending/,
# and the per-task verdict cache in <policy-file minus .json>-cache/.
# bin/fm-teardown.sh removes both with the policy file.
# With no readable policy file the refusal list still applies (every
# recursive rm is then unresolvable and refused), and permission-request
# falls through to Devin's prompt. Without jq the hook is inert; fm-spawn
# refuses to launch a devin worker when jq is missing.
#
# Exit codes: 0 no objection / approved / recorded; 2 refused (Devin blocks
# the tool call). Any other failure is swallowed so the harness lifecycle
# continues.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

EVENT=${1-}
POLICY=${2-}
case "$EVENT" in
  pre-tool-use|permission-request|post-tool-use|stop|retire|repin-grants|grants-digest|judge-probe) ;;
  *)
    sed -n '9,11s/^# *//p' "${BASH_SOURCE[0]}" >&2
    exit 0
    ;;
esac

# The shared command policy (tokenizer, path helpers, segment and command
# analysis, refusal list, read-and-build set, fetch classification, grants,
# judge skeleton, verdict cache, pending markers).
# shellcheck source=bin/fm-command-policy-lib.sh
. "$SCRIPT_DIR/fm-command-policy-lib.sh"
FM_POLICY_COMMAND_FIELD='command'
# The judge budget is pinned per adapter so an inherited JUDGE_BUDGET cannot
# stretch a hook invocation past the timeout the harness grants it; 100s fits
# inside this adapter's 120s permission-hook timeout.
JUDGE_BUDGET=100
# This adapter's identity in the shared judge: the scratch directory the judge
# runs from, the word the prompt uses for the worker it is supervising, and the
# judge tier a per-task policy that names none falls back to.
FM_POLICY_ADAPTER=devin
FM_POLICY_WORKER_LABEL=Devin
FM_JUDGE_TIER_NATIVE=devin

if [ "$EVENT" = grants-digest ]; then
  # fm-spawn asks for the digest of a brief's grants block at launch.
  fm_grants_digest_of_file "$POLICY"
  exit 0
fi
PENDING_DIR='' CACHE_DIR=''
case "$POLICY" in
  *.json) PENDING_DIR="${POLICY%.json}-pending" CACHE_DIR="${POLICY%.json}-cache" ;;
esac
if ! command -v jq >/dev/null 2>&1; then
  # retire cannot close a pending escalation without jq, so it must not
  # report the wiring retired while one is still open.
  [ "$EVENT" = retire ] && [ -n "$PENDING_DIR" ] && [ -d "$PENDING_DIR" ] && exit 1
  exit 0
fi
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

# post-tool-use fires for every tool call; stay cheap when nothing is pending.
if [ "$EVENT" = post-tool-use ] || [ "$EVENT" = stop ]; then
  [ -n "$PENDING_DIR" ] && [ -d "$PENDING_DIR" ] || { cat >/dev/null; exit 0; }
  set -- "$PENDING_DIR"/*.pending
  [ -e "${1-}" ] || { cat >/dev/null; exit 0; }
fi
if [ "$EVENT" = retire ]; then
  [ -n "$PENDING_DIR" ] && [ -d "$PENDING_DIR" ] || exit 0
fi

PAYLOAD=
case "$EVENT" in retire|repin-grants) ;; *) PAYLOAD=$(cat) ;; esac

TASK='' WORKTREE='' STATUS='' INBOX='' DATA_DIR='' TASKTMP='' BRIEF='' LOG='' DEVIN='' JUDGE_MODEL='' JUDGE_TIMEOUT='' GRANTS_SHA='' CONFIG_DIR='' FM_POLICY_JUDGE_TIER='' FM_POLICY_JUDGE_BIN=''
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
    IFS= read -r -d '' DEVIN
    IFS= read -r -d '' JUDGE_MODEL
    IFS= read -r -d '' JUDGE_TIMEOUT
    IFS= read -r -d '' GRANTS_SHA
    IFS= read -r -d '' CONFIG_DIR
    IFS= read -r -d '' FM_POLICY_JUDGE_TIER
    IFS= read -r -d '' FM_POLICY_JUDGE_BIN
  } < <(jq -j '[.task, .worktree, .status, .inbox, .data, .tasktmp, .brief, .log, .devin, .judge_model, .judge_timeout, .grants_sha, .config, .judge_tier, .judge_bin]
    | map((. // "") | tostring | gsub("\u0000"; "")) | join("\u0000") + "\u0000"' "$POLICY" 2>/dev/null)
fi
# Which judge answers this task, and the executable it runs. Devin judges Devin
# by default: a policy that names no tier keeps this adapter's own tier on the
# binary above, which is the posture every Devin task has always had.
fm_judge_tier_bind "$FM_JUDGE_TIER_NATIVE" "$DEVIN"

TOOL='' TOOL_USE_ID='' SESSION_ID='' CMD='' FILE_PATH='' INPUT_JSON='' INPUT_STRINGS='' CACHE_INPUT=''
{
  IFS= read -r -d '' TOOL
  IFS= read -r -d '' TOOL_USE_ID
  IFS= read -r -d '' SESSION_ID
  IFS= read -r -d '' CMD
  IFS= read -r -d '' FILE_PATH
  IFS= read -r -d '' INPUT_JSON
  IFS= read -r -d '' INPUT_STRINGS
  IFS= read -r -d '' CACHE_INPUT
} < <(printf '%s' "$PAYLOAD" | jq -j '
  def s: (. // "") | tostring | gsub("\u0000"; "");
  [ (.tool_name | s), (.tool_use_id | s), (.session_id | s),
    (.tool_input.command | s),
    ((.tool_input.file_path // .tool_input.path // .tool_input.notebook_path) | s),
    ((.tool_input // {}) | del(.content?, .new_string?, .old_string?) | tojson | .[0:2000] | s),
    ([(.tool_input // {}) | del(.content?, .new_string?, .old_string?) | .. | strings] | join("\n") | s),
    ((.tool_input // {}) | tojson | s)
  ] | join("\u0000") + "\u0000"' 2>/dev/null)

evaluate_tool() {  # non-exec tools: sets NOT_APPROVABLE
  REFUSE_REASON='' NOT_APPROVABLE='' NEVER_APPROVE=''
  case "$TOOL" in
    read|grep|glob|notebook_read)
      sensitive_text "$INPUT_STRINGS" && no_approve "$TOOL of credential material"
      granted_env_file_text "$INPUT_STRINGS" \
        && no_approve "$TOOL of a credential file this task may only source"
      ;;
    write|edit|notebook_edit)
      local abs rel wt_abs
      [ -n "$FILE_PATH" ] || { no_approve "$TOOL without a file path"; return 0; }
      wt_abs=$(CWD=$WORKTREE write_target_path "$FILE_PATH" 0 2>/dev/null) || wt_abs=''
      if [ -n "$wt_abs" ] && brief_protected "$wt_abs"; then
        refuse "writing this task's own instructions ($FILE_PATH) is refused by firstmate policy"
        return 0
      fi
      sensitive_text "$FILE_PATH" && { no_approve "$TOOL of credential material"; return 0; }
      granted_env_file_text "$FILE_PATH" \
        && { no_approve "$TOOL of a credential file this task may only source"; return 0; }
      # The write root check resolves the path PHYSICALLY, as the agy adapter
      # does: a symlink inside the worktree that points outside the roots must
      # not carry the write with it, and an unresolvable target asks first.
      abs=$wt_abs
      [ -n "$abs" ] || { no_approve "$TOOL path unresolvable"; return 0; }
      if strictly_inside "$abs" "$WORKTREE"; then
        rel=${abs#"$(norm_abs "$WORKTREE")"/}
        case "$rel" in
          .git|.git/*|.devin|.devin/*|.claude|.claude/*) no_approve "$TOOL of agent or git configuration" ;;
        esac
      elif ! inside_scratch_write_roots "$abs"; then
        no_approve "$TOOL outside the task write roots"
      fi
      ;;
    *) no_approve "$TOOL is not auto-approved" ;;
  esac
}

# --- review-round writes on the task's own PR (see the header) ---------------

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# own_pr: sets OWN_PR_REPO (lowercase owner/name) and OWN_PR_NUMBER from the
# task's recorded pr=, or, when none is recorded yet, from the one open PR
# whose head is the worktree's branch in the origin repository. 1 when neither
# proves a PR; an unparseable or non-GitHub pr= never falls back.
own_pr() {
  local meta branch remote repo out line n=0 pattern
  OWN_PR_REPO='' OWN_PR_NUMBER=''
  fm_pr_task_id_valid "$TASK" && [ -n "$STATUS" ] || return 1
  meta="${STATUS%/*}/$TASK.meta"
  if grep -q '^pr=' "$meta" 2>/dev/null; then
    fm_pr_metadata_identity_parse "$meta" && [ "$FM_PR_META_PROVIDER" = github ] || return 1
    OWN_PR_REPO=$(lower "$FM_PR_META_PATH") OWN_PR_NUMBER=$FM_PR_META_NUMBER
    return 0
  fi
  [ -n "$WORKTREE" ] || return 1
  branch=$(git -C "$WORKTREE" symbolic-ref --short -q HEAD 2>/dev/null) || return 1
  case "$branch" in ''|main|master|-*) return 1 ;; esac
  remote=$(git -C "$WORKTREE" remote get-url origin 2>/dev/null) || return 1
  pattern='^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)$'
  [[ ${remote%.git} =~ $pattern ]] || return 1
  repo="${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
  out=$(fm_run_timed 15 gh pr list -R "github.com/$repo" --head "$branch" --state open \
    --json number,headRepositoryOwner --jq '.[] | "\(.number) \(.headRepositoryOwner.login)"' 2>/dev/null) || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(lower "${line#* }")" = "$(lower "${repo%%/*}")" ] || continue
    n=$((n + 1)) OWN_PR_NUMBER=${line%% *}
  done <<< "$out"
  [ "$n" = 1 ] && [[ $OWN_PR_NUMBER =~ ^[1-9][0-9]*$ ]] || { OWN_PR_NUMBER=''; return 1; }
  OWN_PR_REPO=$(lower "$repo")
}

# github_default_host: 0 when a gh call naming no host reaches github.com, as
# the approved command would from this same environment - GH_HOST is unset or
# github.com, and github.com holds a credential, so gh never falls back to
# another authenticated host. The token itself is discarded.
github_default_host() {
  case "${GH_HOST:-github.com}" in github.com) ;; *) return 1 ;; esac
  fm_run_timed 10 gh auth token --hostname github.com >/dev/null 2>&1
}

# review_thread_query_id <query>: prints the thread id when <query> is exactly
# one resolveReviewThread mutation with a literal threadId and a selection of
# plain field names, so no second mutation can ride along.
review_thread_query_id() {
  local q depth=0 k c sel pattern
  q=$(printf '%s' "$1" | tr '\t\n\r' '   ' | tr -s ' ')
  q=${q# } q=${q% }
  pattern='^mutation( [A-Za-z_][A-Za-z0-9_]*)? ?\{ ?resolveReviewThread ?\( ?input ?: ?\{ ?threadId ?: ?"([A-Za-z0-9_=-]+)" ?\} ?\) ?(\{[A-Za-z0-9_ {}]*\}) ?\}$'
  [[ $q =~ $pattern ]] || return 1
  sel=${BASH_REMATCH[3]}
  for ((k = 0; k < ${#sel}; k++)); do
    c=${sel:k:1}
    case "$c" in
      '{') depth=$((depth + 1)) ;;
      '}') depth=$((depth - 1)); [ "$depth" -gt 0 ] || [ "$k" = $((${#sel} - 1)) ] || return 1 ;;
    esac
  done
  [ "$depth" = 0 ] || return 1
  printf '%s\n' "${BASH_REMATCH[2]}"
}

# graphql_read_only <document>: 0 when <document> can only read. GraphQL has
# three operation types, so a document that never spells mutation or
# subscription anywhere, in any case and even inside a string or comment,
# holds no write; it must also open as a query, a fragment, or the { query
# shorthand. Anything else is treated as a possible write.
graphql_read_only() {
  local q
  q=$(lower "$1" | tr '\t\n\r' '   ')
  case "$q" in *mutation*|*subscription*) return 1 ;; esac
  q=${q#"${q%%[! ]*}"}
  case "$q" in '{'*|query|query[' ({']*|fragment' '*) return 0 ;; esac
  return 1
}

# own_pr_review_write <command>: 0, with OWN_PR_SHAPE naming the writes, when
# the whole command is one review-round call, or a && chain of them, each of
# which qualifies on its own (see review_segment). Any other shell construct
# returns 1 and the call keeps its never-approve escalation.
own_pr_review_write() {
  local cmd=$1 k n start=0 shapes=''
  OWN_PR_SHAPE=''
  # The tokenizer approximates ANSI-C quoting, so its words are not trusted.
  case "$cmd" in *"\$'"*) return 1 ;; esac
  P_INNER=()
  tokenize "$cmd"
  [ "$P_SUBST" -eq 0 ] && [ "$P_HEREDOC_EXPANDING" -eq 0 ] || return 1
  n=${#T_TXT[@]}
  for ((k = 0; k <= n; k++)); do
    if [ "$k" -lt "$n" ] && [ "${T_KIND[k]}" = w ]; then
      [ "${T_VAR[k]}" = 0 ] && [ "${T_GLOB[k]}" = 0 ] || return 1
      continue
    fi
    if [ "$k" -lt "$n" ]; then
      [ "${T_KIND[k]}" = o ] && [ "${T_TXT[k]}" = '&&' ] || return 1
    fi
    review_segment "$start" "$k" || return 1
    case ", $shapes, " in *", $OWN_PR_SHAPE, "*) ;; *) shapes=${shapes:+$shapes, }$OWN_PR_SHAPE ;; esac
    # Newlines after && tokenize as ';'; Bash rejects a literal one there.
    while [ $((k + 1)) -lt "$n" ] && [ "${T_KIND[k + 1]}" = o ] && [ "${T_TXT[k + 1]}" = ';' ]; do
      k=$((k + 1))
    done
    start=$((k + 1))
  done
  OWN_PR_SHAPE=$shapes
}

# review_segment <first> <end>: 0, with OWN_PR_SHAPE set, when tokens
# [first, end) are one gh api call of these shapes: a reply to a review
# comment, a Codex re-review request, or resolving a review thread, each on
# this task's own PR; or a read-only graphql query. Output filters (--jq, -q,
# --silent) change only what gh prints.
review_segment() {
  local s=$1 n=$2 k w endpoint='' pattern repo num kind tid got host=''
  local text='' text_raw=0 nbody=0 reply='' nreply=0 query='' nquery=0 nfield=0
  local fileread=0 paginate=0
  OWN_PR_SHAPE=''
  [ $((n - s)) -ge 3 ] && [ "${T_TXT[s]}" = gh ] && [ "${T_TXT[s + 1]}" = api ] || return 1
  _field() {  # <raw-flag> <key=value>
    nfield=$((nfield + 1))
    case "$2" in
      body=*) nbody=$((nbody + 1)) text=${2#body=} text_raw=$1 ;;
      in_reply_to=*) nreply=$((nreply + 1)) reply=${2#in_reply_to=} ;;
      # Only a raw inline query qualifies, so the approved text is the text
      # that runs.
      query=*)
        nquery=$((nquery + 1))
        if [ "$1" = 1 ]; then query=${2#query=}; else nquery=2; fi ;;
      *=@*) [ "$1" = 1 ] || fileread=1 ;;
    esac
  }
  for ((k = s + 2; k < n; k++)); do
    w=${T_TXT[k]}
    case "$w" in
      -X|--method) k=$((k + 1)); [ "$k" -lt "$n" ] && [ "${T_TXT[k]}" = POST ] || return 1 ;;
      -XPOST|--method=POST|--silent|--jq=*) ;;
      --paginate) paginate=1 ;;
      --hostname) k=$((k + 1)); [ "$k" -lt "$n" ] && [ "${T_TXT[k]}" = github.com ] || return 1; host=github.com ;;
      --hostname=github.com) host=github.com ;;
      --jq|-q) k=$((k + 1)); [ "$k" -lt "$n" ] || return 1 ;;
      -f|--raw-field|-F|--field)
        k=$((k + 1)); [ "$k" -lt "$n" ] || return 1
        case "$w" in -f|--raw-field) _field 1 "${T_TXT[k]}" ;; *) _field 0 "${T_TXT[k]}" ;; esac ;;
      --raw-field=*) _field 1 "${w#--raw-field=}" ;;
      --field=*) _field 0 "${w#--field=}" ;;
      -f?*) _field 1 "${w#-f}" ;;
      -F?*) _field 0 "${w#-F}" ;;
      -*) return 1 ;;
      *) [ -z "$endpoint" ] || return 1; endpoint=$w ;;
    esac
  done
  [ "$fileread" = 0 ] || return 1
  endpoint=${endpoint#/}
  pattern='^repos/([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)/(pulls|issues)/([1-9][0-9]*)/comments$'
  if [[ $endpoint =~ $pattern ]]; then
    [ "$paginate" = 0 ] && [ "$nquery" = 0 ] || return 1
    repo=$(lower "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}") kind=${BASH_REMATCH[3]} num=${BASH_REMATCH[4]}
    if [ "$kind" = pulls ]; then
      # -F reads a file for an @value, so a typed body must not start with @.
      [ "$nfield" = 2 ] && [ "$nbody" = 1 ] && [ "$nreply" = 1 ] && [ -n "$text" ] \
        && [[ $reply =~ ^[1-9][0-9]*$ ]] || return 1
      [ "$text_raw" = 1 ] || [ "${text#@}" = "$text" ] || return 1
      OWN_PR_SHAPE='a reply to a review comment'
    else
      [ "$nfield" = 1 ] && [ "$nbody" = 1 ] && [ "$text_raw" = 1 ] && [ "$text" = '@codex review' ] || return 1
      OWN_PR_SHAPE='a Codex re-review request'
    fi
    { [ -n "$host" ] || github_default_host; } && own_pr \
      && [ "$repo" = "$OWN_PR_REPO" ] && [ "$num" = "$OWN_PR_NUMBER" ] || { OWN_PR_SHAPE=''; return 1; }
    return 0
  fi
  [ "$endpoint" = graphql ] && [ "$nquery" = 1 ] || return 1
  # A read-only query may carry variables and page; it needs no PR proof.
  if graphql_read_only "$query"; then
    OWN_PR_SHAPE='a read-only GraphQL query'
    return 0
  fi
  [ "$nfield" = 1 ] && [ "$paginate" = 0 ] || return 1
  tid=$(review_thread_query_id "$query") || return 1
  { [ -n "$host" ] || github_default_host; } && own_pr || return 1
  # Ownership is read back from the forge: the thread must sit on this PR.
  # shellcheck disable=SC2016  # $id is a GraphQL variable, not a shell one.
  got=$(fm_run_timed 15 gh api --hostname github.com graphql \
    -f query='query($id: ID!) { node(id: $id) { ... on PullRequestReviewThread { pullRequest { number repository { nameWithOwner } } } } }' \
    -f id="$tid" --jq '.data.node.pullRequest | "\(.repository.nameWithOwner) \(.number)"' 2>/dev/null) || return 1
  [ "$(lower "$got")" = "$OWN_PR_REPO $OWN_PR_NUMBER" ] || return 1
  OWN_PR_SHAPE='resolving a review thread'
}

case "$EVENT" in
  judge-probe)
    # The measurement seam (not a Devin hook). Same payload, same static
    # analysis, same prompt as a real permission-request - but nothing is
    # written, so a tier comparison leaves no trace in the task's cache,
    # markers, status file, or observer log.
    if [ "$TOOL" = exec ]; then
      evaluate_exec "$CMD"
    else
      evaluate_tool
    fi
    if [ -n "$REFUSE_REASON" ]; then judge_probe refuse
    elif [ -z "$NOT_APPROVABLE" ]; then judge_probe read-and-build
    elif [ -n "$NEVER_APPROVE" ]; then judge_probe never-approve
    else judge_probe residue
    fi
    exit 0
    ;;
  pre-tool-use)
    [ "$TOOL" = exec ] || exit 0
    # A pre-allowed call reaches no later step, so the forms review would
    # have caught are refused here (see the header).
    FM_POLICY_PREALLOW_GUARD=1
    evaluate_exec "$CMD"
    if [ -n "$REFUSE_REASON" ]; then
      log_record refuse policy "$REFUSE_REASON"
      json_reason block "Blocked by firstmate policy: $REFUSE_REASON"
      exit 2
    fi
    exit 0
    ;;
  permission-request)
    if [ "$TOOL" = exec ]; then
      evaluate_exec "$CMD"
    else
      evaluate_tool
    fi
    if [ -n "$REFUSE_REASON" ]; then
      log_record refuse policy "$REFUSE_REASON"
      json_reason block "Blocked by firstmate policy: $REFUSE_REASON"
      exit 2
    fi
    [ -n "$POLICY" ] && [ -r "$POLICY" ] || exit 0
    if [ -z "$NOT_APPROVABLE" ]; then
      log_record approve policy "read-and-build set"
      json_reason approve "Approved by firstmate policy: read-and-build set"
      exit 0
    fi
    escalate_reason='' escalate_source='first judge'
    # The one carve-out from the never-approve class: only when the outward
    # action was the call's sole objection, and never cached.
    if [ "$TOOL" = exec ] && [ -n "$NEVER_APPROVE" ] && [ "$NOT_APPROVABLE" = "$NEVER_APPROVE" ] \
      && [ -z "$SENSITIVE_HIT" ] && own_pr_review_write "$CMD"; then
      log_record approve policy "own-PR review round: $OWN_PR_SHAPE"
      json_reason approve "Approved by firstmate policy: own-PR review round: $OWN_PR_SHAPE"
      exit 0
    fi
    if [ -n "$NEVER_APPROVE" ]; then
      # Outward actions skip the judge and the cache entirely, and are never
      # cached at the prompt either, so approving one stays a one-off.
      escalate_reason=$NEVER_APPROVE escalate_source='firstmate policy'
      log_record escalate policy "$NEVER_APPROVE"
    elif cache_lookup; then
      log_record approve cache "$CACHE_REASON (static: $NOT_APPROVABLE)"
      json_reason approve "Approved by firstmate policy cache: $CACHE_REASON"
      exit 0
    else
      run_judge
      if [ "$JUDGE_VERDICT" = approve ]; then
        cache_store "first judge: $JUDGE_REASON"
        log_record approve judge "$JUDGE_REASON (judge: $(fm_judge_attribution), static: $NOT_APPROVABLE)"
        json_reason approve "Approved by firstmate first judge: $JUDGE_REASON"
        exit 0
      fi
      escalate_reason=$JUDGE_REASON
      log_record escalate judge "$JUDGE_REASON (judge: $(fm_judge_attribution), static: $NOT_APPROVABLE)"
    fi
    slug=$(tool_slug)
    key="devin-permission-$slug"
    if [ -n "$PENDING_DIR" ] && mkdir -p "$PENDING_DIR" 2>/dev/null; then
      marker="$PENDING_DIR/$slug.pending"
      if [ ! -e "$marker" ]; then
        ckey=''
        [ -n "$NEVER_APPROVE" ] || ckey=$(cache_key 2>/dev/null || true)
        printf '%s\n%s\n%s\n' "$key" "$(one_line "$(input_summary)" 2000)" "$ckey" \
          > "$marker" 2>/dev/null || true
        status_append "needs-decision [key=$key]: Devin is waiting at a permission prompt for $TOOL ($escalate_source: $(one_line "$escalate_reason" 160)): $(one_line "$(input_summary)" 300)"
      fi
    fi
    exit 0
    ;;
  post-tool-use)
    marker="$PENDING_DIR/$(tool_slug).pending"
    [ -n "$TOOL_USE_ID" ] && [ -f "$marker" ] || exit 0
    close_pending "$marker" approved-at-prompt "the escalated $TOOL call was approved at the prompt and ran"
    exit 0
    ;;
  stop)
    for marker in "$PENDING_DIR"/*.pending; do
      [ -f "$marker" ] || continue
      close_pending "$marker" not-run "the escalated call did not run (declined or cancelled at the prompt)"
    done
    exit 0
    ;;
  repin-grants)
    # Firstmate edits a live brief's grants on purpose; this records the new
    # digest so the block is honored again. Nothing a worker can reach runs it.
    [ -n "$POLICY" ] && [ -r "$POLICY" ] && [ -w "$POLICY" ] || {
      echo "fm-devin-permission-policy: cannot repin grants: $POLICY is not writable" >&2
      exit 1
    }
    new_sha=$(grants_digest "$(grants_block)" 2>/dev/null || true)
    if ! jq --arg sha "$new_sha" '.grants_sha = $sha' "$POLICY" > "$POLICY.repin" 2>/dev/null \
      || ! mv "$POLICY.repin" "$POLICY"; then
      rm -f "$POLICY.repin"
      echo "fm-devin-permission-policy: cannot repin grants: $POLICY could not be rewritten" >&2
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
