#!/usr/bin/env bash
# Stable PreToolUse transport for the watcher-arm command policy.
#
# A firstmate primary must arm the watcher or run a Codex checkpoint as a
# standalone verified harness call.
# bin/fm-arm-command-policy.mjs is the sole owner of shell classification,
# protected execution identity, the blessed setup tree, and deny reason codes.
# The same transport also carries the publish policy
# (bin/fm-gh-publish-policy.mjs: the gh publish guard and the git identity and
# hook-bypass refusals), so every harness registration below enforces both.
# This wrapper only acquires the harness payload, discovers the active roots,
# invokes the policies, and renders the established harness-specific responses.
# It never executes, sources, evaluates, or expands the submitted command.
# See docs/arm-pretool-check.md for the complete contract and validation record.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-arm-pretool-check.sh
#   bin/fm-arm-pretool-check.sh --command '<cmd>' [--background true|false]
#   ... --publish-only   evaluate only the publish policy (worker registrations
#                        written by bin/fm-spawn.sh and the Devin and agy
#                        permission layers)
#
# Stdin mode extracts .toolInput.command for Grok or .tool_input.command for
# Claude and Codex. Cursor delivers the same .tool_input.command shape with
# tool_name "Shell" (verified live, cursor-agent 2026.08.11-e8db854), so it needs
# no new extraction - only --cursor, which selects Cursor's own deny rendering
# and marks this invocation as the Cursor registration rather than the
# Claude-settings duplicate Cursor also loads.
# CLI mode is used by OpenCode and Pi after their adapters extract the exact
# command string.
# --background remains accepted for compatibility, but harness-native tracked
# background execution is not itself a policy signal.
#
# Exit/output contract:
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   DENY, --cursor - exit 0 and Cursor's own decision object on stdout. Cursor
#          reads the returned object rather than the exit status, and only that
#          rendering is verified to block the command and surface the reason.
#   FAIL OPEN - for the watcher policy only: malformed or empty stdin, missing
#               jq for stdin transport, missing Node or policy owner, or an
#               invalid policy response.
#   FAIL CLOSED - a command the publish prefilter selects (a gh command word,
#               a git command word with a refused flag or key spelling, or the
#               publish judge's name or its overrides file) is
#               denied with code publish-engine-unavailable when the publish
#               policy cannot decide it: stdin that jq is missing for or cannot
#               parse, missing Node, a missing policy file, a policy that
#               exits nonzero, or output that is neither allow nor a valid
#               deny. Stdin mode checks the raw payload against the same
#               prefilter when it cannot extract the command.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
# Cursor consumes the stdout decision object.
set -u

CMD=""
CMD_SET=0
BACKGROUND=""
CLAUDE_MODE=0
CURSOR_MODE=0
PUBLISH_ONLY=0
CMD_CWD=""

usage() {
  cat <<'EOF'
Usage: fm-arm-pretool-check.sh [--command <cmd>] [--background true|false] [--claude|--cursor] [--publish-only]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex/Cursor tool_input.command).
Exits 0 to allow and 2 to deny.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
With --cursor, a deny is Cursor's own decision object on stdout and exit 0,
because Cursor reads the returned object rather than the exit status.
Malformed transport and an unavailable classifier runtime fail open for the
watcher policy; a command the publish policy must see is denied instead.
EOF
}

# publish_needed <text>: exit 0 when the publish policy must see <text>. This
# prefilter is a strict superset: the publish policy can deny only a command
# with a gh command word, a git command word plus one of the refused flag or
# key spellings, or the publish judge's name or its overrides file, so
# anything lacking all of them is fast-allowed. A quoting-decoder marker
# ($'...' or $"...") can rebuild any of them, so it always delegates.
# Quotes and escape backslashes are dropped, and newlines become spaces (not
# deleted) so a command word on its own line keeps its word boundary.
publish_needed() {
  local text=$1
  local gh_word='(^|[^A-Za-z0-9_.-])gh([^A-Za-z0-9_-]|$)'
  local git_word='(^|[^A-Za-z0-9_.-])git([^A-Za-z0-9_-]|$)'
  local git_mark='(no-verify|[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]|author|committer|user\.name|user\.email|GIT_AUTHOR|GIT_COMMITTER|commit.*[[:space:]]-[A-Za-z]*n)'
  case "$text" in
    *"\$'"*|*'$"'*) return 0 ;;
  esac
  text=${text//\\/}
  text=${text//\"/}
  text=${text//\'/}
  text=${text//$'\n'/ }
  text=${text//$'\r'/ }
  [[ "$text" =~ $gh_word ]] && return 0
  case "$text" in
    *fm-publish-judge*|*judge-overrides*) return 0 ;;
  esac
  [[ "$text" =~ $git_word ]] && [[ "$text" =~ $git_mark ]] && return 0
  return 1
}

# Deny because the publish policy cannot decide a command it must see.
publish_unavailable() {
  render_deny "$(printf 'deny\tpublish-engine-unavailable\tthe publish policy could not run (%s), so this gh or git command is refused until it can. Fix: install Node and jq, and restore the policy file (git checkout -- bin/fm-gh-publish-policy.mjs).' "$1")"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --background)
      [ "$#" -gt 1 ] || { echo "error: --background requires a value" >&2; exit 2; }
      BACKGROUND=$2
      shift 2
      ;;
    --background=*)
      BACKGROUND=${1#--background=}
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    --cursor)
      CURSOR_MODE=1
      shift
      ;;
    --publish-only)
      PUBLISH_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

# Render a "deny<TAB>code<TAB>reason" policy line; return 1 when it is not a
# valid deny.
render_deny() {
  local output=$1 tab decision rest code reason detail escaped
  [ -n "$output" ] || return 1
  tab=$(printf '\t')
  decision=${output%%"$tab"*}
  [ "$decision" = "deny" ] || return 1
  rest=${output#*"$tab"}
  [ "$rest" != "$output" ] || return 1
  code=${rest%%"$tab"*}
  reason=${rest#*"$tab"}
  [ -n "$code" ] && [ -n "$reason" ] && [ "$reason" != "$rest" ] || return 1
  detail="[$code] $reason"
  escaped=$(json_escape "$detail")
  if [ "$CURSOR_MODE" -eq 1 ]; then
    printf '{"permission":"deny","user_message":"%s"}\n' "$escaped"
    exit 0
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  # When the command cannot be extracted, the raw payload stands in for it in
  # the publish prefilter, with its JSON newline, tab, and CR escapes as spaces.
  RAW_PAYLOAD=${PAYLOAD//\\n/ }
  RAW_PAYLOAD=${RAW_PAYLOAD//\\t/ }
  RAW_PAYLOAD=${RAW_PAYLOAD//\\r/ }
  if ! command -v jq >/dev/null 2>&1; then
    ! publish_needed "$RAW_PAYLOAD" || publish_unavailable "jq is not installed to read the hook payload"
    exit 0
  fi
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fm-hook-host-lib.sh"
  # Cursor's own registration passes --cursor. Without it a Cursor-delivered
  # payload is the Claude-settings duplicate Cursor also loads, already
  # evaluated by that registration, so this copy allows without re-classifying.
  if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  if ! CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null); then
    ! publish_needed "$RAW_PAYLOAD" || publish_unavailable "the hook payload is not valid JSON"
    exit 0
  fi
  [ -n "$CMD" ] || exit 0
  # Kept for transport parity only.
  # shellcheck disable=SC2034
  BACKGROUND=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.background // .tool_input.background // false)' 2>/dev/null) || BACKGROUND=false
  CMD_CWD=$(printf '%s' "$PAYLOAD" | jq -r '(.cwd // empty) | select(type == "string")' 2>/dev/null) || CMD_CWD=""
fi

[ -n "$CMD" ] || exit 0

# Strict-superset prefilter (transport only; owns zero classification semantics).
# Every protected watcher execution and every broad watcher kill resolves to the
# fm-watch byte sequence AFTER the classifier's byte normalization, so a command
# that cannot contain fm-watch even after that normalization can never be a
# deniable watcher command and is fast-allowed without the Node policy owner.
# We mirror the classifier's cheapest byte transforms here (drop line-
# continuation and escape backslashes, quotes, and newlines) so obfuscated
# protected paths such as fm-watc\<newline>h-arm.sh or fm-"watch"-arm.sh still
# delegate. Stripping only these non-alphanumeric bytes can never destroy an
# existing fm-watch run.
#
# The fast path may allow ONLY when BOTH hold: (a) the stripped/normalized text
# lacks the fm-watch watcher substring, AND (b) the raw command carries no
# quoting-decoder marker - a $ immediately followed by a single quote (ANSI-C
# $'...') or a double quote (bash locale $"..."), both of which the classifier
# decodes and can therefore reconstruct fm-watch from bytes this cheap byte
# strip cannot. This marker set is COUPLED to the classifier's decoder set in
# bin/fm-arm-command-policy.mjs: adding any new quote/expansion form the
# classifier decodes REQUIRES extending this marker set in the same change, or
# the prefilter stops being a strict superset. Otherwise the command always
# delegates to the classifier - the single owner of every decision. Any deeper
# decode-required obfuscation stays the classifier's and the post-arm liveness
# guards' responsibility.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/}
PREFILTER=${PREFILTER//$'\r'/}
WATCH_NEEDED=0
case "$CMD" in
  *"\$'"*|*'$"'*)
    WATCH_NEEDED=1
    ;;
  *)
    case "$PREFILTER" in
      *fm-watch*) WATCH_NEEDED=1 ;;
    esac
    ;;
esac
PUBLISH_NEEDED=0
! publish_needed "$CMD" || PUBLISH_NEEDED=1
[ "$PUBLISH_ONLY" -eq 0 ] || WATCH_NEEDED=0
[ "$WATCH_NEEDED" -eq 1 ] || [ "$PUBLISH_NEEDED" -eq 1 ] || exit 0

# From here the watcher policy still fails open, while a command the publish
# policy must see is denied whenever that policy cannot decide it.
if ! SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) ||
  ! ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P); then
  [ "$PUBLISH_NEEDED" -eq 0 ] || publish_unavailable "the policy directory cannot be resolved"
  exit 0
fi
ACTIVE_HOME=${FM_HOME:-$ROOT}
POLICY="$ROOT/bin/fm-arm-command-policy.mjs"
PUBLISH_POLICY="$ROOT/bin/fm-gh-publish-policy.mjs"

if ! command -v node >/dev/null 2>&1; then
  [ "$PUBLISH_NEEDED" -eq 0 ] || publish_unavailable "Node is not installed"
  exit 0
fi

if [ "$WATCH_NEEDED" -eq 1 ] && [ -f "$POLICY" ]; then
  POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" --root "$ROOT" --home "$ACTIVE_HOME" 2>/dev/null) || POLICY_OUTPUT=""
  render_deny "$POLICY_OUTPUT"
fi
if [ "$PUBLISH_NEEDED" -eq 1 ]; then
  [ -f "$PUBLISH_POLICY" ] || publish_unavailable "bin/fm-gh-publish-policy.mjs is missing"
  [ -n "$CMD_CWD" ] && [ -d "$CMD_CWD" ] || CMD_CWD=$PWD
  POLICY_OUTPUT=$(node "$PUBLISH_POLICY" --command "$CMD" --cwd "$CMD_CWD" 2>/dev/null) ||
    publish_unavailable "the publish policy exited with an error"
  [ "$POLICY_OUTPUT" != allow ] || exit 0
  render_deny "$POLICY_OUTPUT"
  publish_unavailable "the publish policy printed neither allow nor a valid deny"
fi
exit 0
