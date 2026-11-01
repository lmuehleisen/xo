#!/usr/bin/env bash
# Antigravity CLI (agy) session-open adapter: the RUN tier transport for agy.
#
# Registered in tracked .agents/hooks.json for Antigravity's SessionStart step.
# It is a thin transport around bin/fm-sessionstart-run.sh, which remains the
# single owner of source routing, eligibility, and the digest itself.
#
# Antigravity injects a hook's `injectSteps[].systemMessage.systemMessage`
# straight into model context before the first turn. In a linked crewmate
# worktree without .fm-secondmate-home, fm-sessionstart-run.sh stands down
# silently and this wrapper prints empty JSON ({}).
#
# Every path exits 0 and prints valid JSON.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE=
while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE=${2:-}
      if [ $# -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*) SOURCE=${1#--source=}; shift ;;
    *) shift ;;
  esac
done

if [ -z "$SOURCE" ] && [ ! -t 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  # Read the top-level field: nested metadata may also carry a source key.
  SOURCE=$(printf '%s' "$PAYLOAD" | jq -r '.source | select(type == "string")' 2>/dev/null || true)
fi

DIGEST=$("$SCRIPT_DIR/fm-sessionstart-run.sh" --source "${SOURCE:-startup}" </dev/null 2>/dev/null || true)
if [ -z "$DIGEST" ] || ! command -v jq >/dev/null 2>&1; then
  printf '{}\n'
  exit 0
fi

printf '%s' "$DIGEST" | jq -Rsc '{injectSteps:[{systemMessage:{systemMessage:.}}]}'
exit 0
