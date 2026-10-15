# shellcheck shell=bash
# Shared Codex model-catalog lookup for reasoning-effort support.
# Usage: . bin/fm-codex-catalog-lib.sh
#
# The installed Codex catalog (${CODEX_HOME:-$HOME/.codex}/models_cache.json)
# owns which models accept the `max` and `ultra` reasoning efforts.
# bin/fm-spawn.sh uses it to decide the launch flag; bin/fm-bootstrap.sh and
# bin/fm-dispatch-resolve.sh use it so a dispatch profile is valid exactly when
# the launch would honor it. For `max`, an unavailable or invalid catalog
# preserves the historical Luna-only fallback rather than guessing from the
# model name. For `ultra` there is no name-based fallback: ultra is accepted
# only when an explicit model's catalog entry advertises it, matching the
# launch-time rule bin/fm-harness.sh validate-native-effort enforces for a
# direct Codex task worker.
#
# fm_codex_max_support <model>
#   Prints true when the catalog advertises max for <model>, false when the
#   catalog is valid and does not, and unknown when it is unreadable, malformed,
#   carries a non-array reasoning-level list for <model>, or neither CODEX_HOME
#   nor HOME names a catalog root. Requires jq.
#
# fm_codex_max_allowed <model>
#   Exits 0 when max is accepted for <model>: the catalog advertises it, or the
#   catalog is unknown and <model> is gpt-5.6-luna.
#
# fm_codex_max_allowed_json
#   Reads one model per line on stdin and prints a JSON array of the distinct
#   models fm_codex_max_allowed accepts, for a jq --argjson consumer.
#
# fm_codex_ultra_support <model>
#   As fm_codex_max_support, but for the ultra reasoning effort.
#
# fm_codex_ultra_allowed <model>
#   Exits 0 when ultra is accepted for <model>: a non-empty explicit model
#   whose catalog entry advertises ultra. Unlike max there is no name-based
#   fallback, so an unknown catalog refuses ultra.
#
# fm_codex_ultra_allowed_json
#   Reads one model per line on stdin and prints a JSON array of the distinct
#   models fm_codex_ultra_allowed accepts, for a jq --argjson consumer.

# fm_codex_effort_support <model> <effort>
#   Shared catalog probe. Prints true/false/unknown as documented above.
fm_codex_effort_support() {
  local model=$1 effort=$2 root catalog result
  root=${CODEX_HOME:-}
  [ -n "$root" ] || [ -z "${HOME:-}" ] || root=$HOME/.codex
  catalog=$root/models_cache.json
  result=
  if [ -n "$root" ] && [ -f "$catalog" ] && [ -r "$catalog" ]; then
    result=$(jq -r --arg model "$model" --arg effort "$effort" '
      if (.models | type) != "array" then error("invalid model catalog")
      else [.models[] | select(.slug == $model)] |
        if any(.[]; (.supported_reasoning_levels | type) != "array")
        then error("invalid model reasoning levels")
        else any(.[]; any(.supported_reasoning_levels[]; .effort == $effort)) end
      end
    ' "$catalog" 2>/dev/null) || result=
  fi
  case "$result" in
  true | false) printf '%s\n' "$result" ;;
  *) printf 'unknown\n' ;;
  esac
}

fm_codex_max_support() {
  fm_codex_effort_support "$1" max
}

fm_codex_max_allowed() {
  case "$(fm_codex_max_support "$1")" in
  true) return 0 ;;
  false) return 1 ;;
  *) [ "$1" = gpt-5.6-luna ] ;;
  esac
}

fm_codex_max_allowed_json() {
  local model
  while IFS= read -r model; do
    [ -n "$model" ] || continue
    fm_codex_max_allowed "$model" && printf '%s\n' "$model"
  done | jq -Rsc 'split("\n") | map(select(length > 0)) | unique'
}

fm_codex_ultra_support() {
  fm_codex_effort_support "$1" ultra
}

fm_codex_ultra_allowed() {
  [ -n "$1" ] || return 1
  [ "$1" = default ] && return 1
  case "$(fm_codex_ultra_support "$1")" in
  true) return 0 ;;
  *) return 1 ;;
  esac
}

fm_codex_ultra_allowed_json() {
  local model
  while IFS= read -r model; do
    [ -n "$model" ] || continue
    fm_codex_ultra_allowed "$model" && printf '%s\n' "$model"
  done | jq -Rsc 'split("\n") | map(select(length > 0)) | unique'
}
