#!/usr/bin/env bash
# Read quota-axi with this home's optional provider scope.
# Usage: fm-quota-read.sh [quota-axi read arguments...]
# Pass no arguments for default TOON, --json for the defensive snapshot,
# or auth --json for credential-source evidence. Compatibility/version calls
# use quota-axi directly. docs/configuration.md owns config/quota-providers.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FILE="$CONFIG/quota-providers"

invalid() {
  printf 'error: malformed config/quota-providers: %s\n' "$1" >&2
  exit 1
}

args=()
if [ -e "$FILE" ] || [ -L "$FILE" ]; then
  [ -f "$FILE" ] && [ -r "$FILE" ] || invalid 'expected a readable regular file'
  list='' line='' lines=0
  while IFS= read -r line || [ -n "$line" ]; do
    lines=$((lines + 1))
    [ "$lines" -eq 1 ] || invalid 'expected exactly one nonempty comma-separated line'
    list=$line
  done < "$FILE"
  [ -n "$list" ] || invalid 'expected exactly one nonempty comma-separated line'
  [[ "$list" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]] || invalid 'use provider ids separated by commas without whitespace or empty entries'
  IFS=',' read -r -a providers <<< "$list"
  seen=,
  for provider in "${providers[@]}"; do
    # quota-axi 0.1.55 PROVIDER_IDS; new ids require an explicit update.
    case "$provider" in
      claude|codex|cursor|copilot|grok|kimi|zai|agy|alibaba|opencode-go|commandcode|minimax|mimo|deepseek|openrouter|elevenlabs|devin|muse) ;;
      *) invalid "unsupported provider id: $provider" ;;
    esac
    case "$seen" in *",$provider,"*) invalid "duplicate provider id: $provider" ;; esac
    seen+="$provider,"
  done
  args=(--provider "$list")
fi

# Keep existing callers' quiet tool failures while leaving config diagnostics
# visible. An invalid file never reaches quota-axi or widens discovery.
exec quota-axi "$@" ${args[@]+"${args[@]}"} 2>/dev/null
