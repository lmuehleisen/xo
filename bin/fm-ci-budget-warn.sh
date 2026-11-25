#!/usr/bin/env bash
# fm-ci-budget-warn.sh - emit a warning when a CI lane's measured command time
# crosses the healthy ~20-minute budget. Never fails the job.
#
# The timing-aggregate CI job runs this after combining per-lane timing JSON
# and any lint telemetry sidecars. duration_ms and lint wall_seconds are the
# test or lint command's own elapsed time, not the GitHub Actions job wall.
# A value at or above 20 minutes prints a GitHub warning annotation (and a
# plain warning line for local tests). Shorter lanes stay silent. Missing
# inputs print a warning and still exit 0.
#
# Usage:
#   fm-ci-budget-warn.sh <aggregate.json> [lint-telemetry-dir]
#   fm-ci-budget-warn.sh --help
#
# Exit status: 0 always except usage errors (2).
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-ci-budget-warn: %s\n' "$*" >&2
  exit 2
}

BUDGET_MS=1200000
AGGREGATE=
LINT_DIR=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown argument: $1"
      ;;
    *)
      if [ -z "$AGGREGATE" ]; then
        AGGREGATE=$1
      elif [ -z "$LINT_DIR" ]; then
        LINT_DIR=$1
      else
        die "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[ -n "$AGGREGATE" ] || die "need an aggregate timing JSON (see --help)"

warn() {
  local message=$1
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    printf '::warning title=CI budget::%s\n' "$message"
  fi
  printf 'fm-ci-budget-warn: warning: %s\n' "$message" >&2
}

minutes() {  # <ms>
  awk -v ms="$1" 'BEGIN { printf "%.1f", ms / 60000 }'
}

warn_on_behavior_budget() {
  local rows selection duration
  if [ ! -f "$AGGREGATE" ]; then
    warn "no aggregate timing JSON at $AGGREGATE; skipped behavior budget check"
    return 0
  fi

  if ! rows=$(python3 - "$AGGREGATE" "$BUDGET_MS" 2>/dev/null <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
budget = int(sys.argv[2])
doc = json.loads(path.read_text(encoding="utf-8"))
for lane in doc.get("lanes") or []:
    summary = lane.get("summary") or {}
    try:
        duration = int(summary.get("duration_ms") or 0)
    except (TypeError, ValueError):
        continue
    if duration < budget:
        continue
    selection = lane.get("selection") or lane.get("path") or "unknown lane"
    print("%s\t%s" % (selection, duration))
PY
  ); then
    warn "could not parse $AGGREGATE; skipped behavior budget check"
    return 0
  fi

  while IFS=$'\t' read -r selection duration; do
    [ -n "$duration" ] || continue
    selection=${selection#lane=}
    selection=${selection%%;*}
    warn "lane ${selection} command time was $(minutes "$duration") minutes, above the 20-minute healthy budget"
  done <<<"$rows"
}

warn_on_behavior_budget

if [ -n "$LINT_DIR" ] && [ -d "$LINT_DIR" ]; then
  while IFS= read -r telemetry; do
    [ -n "$telemetry" ] || continue
    wall=$(awk -F '\t' '$1 == "wall_seconds" { print $2; exit }' "$telemetry")
    partition=$(awk -F '\t' '$1 == "partition" { print $2; exit }' "$telemetry")
    case "$wall" in
      ''|*[!0-9.]*) continue ;;
    esac
    wall_ms=$(awk -v s="$wall" 'BEGIN { printf "%d", s * 1000 }')
    if [ "$wall_ms" -ge "$BUDGET_MS" ]; then
      warn "lint partition ${partition:-unknown} command time was $(minutes "$wall_ms") minutes, above the 20-minute healthy budget"
    fi
  done < <(find "$LINT_DIR" -type f -name '*.tsv' ! -name '*.roots.tsv' | LC_ALL=C sort)
fi

exit 0
