#!/usr/bin/env bash
# fm-agy-admission.sh - bounded, synthetic agy worker compatibility admission.
#
# Usage: fm-agy-admission.sh ensure|ensure-native|manual-baseline <absolute-agy> <model>
#          <effective-effort-or-empty> <judge-tier> <judge-model> <absolute-judge>
# Native form: ensure-native <absolute-agy> <model> <effort-or-empty>
#              native-tmux|native-herdr '' ''
#
# ensure admits candidates >=1.4.4,<1.5.0 only after the complete existing
# bypass, observer and interactive-signals guards. The historical
# fm-agy-permission-policy.sh verified-versions list remains a manual migration
# baseline: manual-baseline can explicitly run those same checks on a listed
# release outside the candidate family. Neither path certifies version text.
# Matching exact receipts, including manually verified baselines, are reused.
# A mutable default model is not a tested context: select --model explicitly.
# ensure-native admits >=1.4.7,<1.5.0 with native Auto, observer and signals
# guards bound to the selected backend. Ordinary safe native approvals need
# not prompt. Receipts explicitly record whether live approval and decline
# were observed; deterministic native-control fixtures cover the cancellation
# protocol when harmless live canaries auto-approve. They are not live proof.
#
# The stdout result is the receipt path. Progress and failures go to stderr.
# Private receipts live at $FM_HOME/state/agy-compatibility (FM_STATE_OVERRIDE
# selects the state directory). fm-agy-admission.py owns their format, identity,
# integration revision, context and completeness checks and atomic publication.
# The existing portable lock owner serializes only one exact binding's cold
# proof; readers never accept partial proof. Each guard has a hard 360-second
# budget (observer: 150), and lock contention has a 900-second bound.
# Native processes suppress only their own updater. Identity is compared around
# proof and again by the staged worker launch, before it receives the real brief.
# No global settings, updater, daemon, or alternate permission policy is used.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
EVIDENCE="$SCRIPT_DIR/fm-agy-admission.py"
mode=${1:-}
shift || exit 2
if [ "$#" -ne 6 ] || { [ "$mode" != ensure ] && [ "$mode" != ensure-native ] && [ "$mode" != manual-baseline ]; }; then
  sed -n '4,5s/^# *//p' "${BASH_SOURCE[0]}" >&2
  exit 2
fi
if [ "$mode" = ensure-native ]; then
  case "$4:$5:$6" in native-tmux::|native-herdr::) ;; *)
    echo 'agy compatibility: native admission requires a verified backend context and cannot carry a judge' >&2; exit 1 ;;
  esac
elif [[ "$4" == native-* ]]; then
  echo 'agy compatibility: native context requires ensure-native' >&2
  exit 1
fi
umask 077
mkdir -p "$STATE"
STATE=$(cd "$STATE" && pwd -P)
cache="$STATE/agy-compatibility"
if [ ! -e "$cache" ] && [ ! -L "$cache" ]; then
  mkdir -m 700 "$cache" 2>/dev/null || [ -d "$cache" ]
fi
python3 "$EVIDENCE" directory "$cache"
work=$(mktemp -d "$cache/.admission.XXXXXX")
lock=
cleanup() {
  [ -z "$lock" ] || fm_lock_release "$lock"
  # Only this invocation's freshly minted scratch directory is removed.
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 143' TERM HUP
trap 'exit 130' INT
python3 "$EVIDENCE" snapshot "$@" > "$work/binding.json"
key=$(python3 "$EVIDENCE" key "$work/binding.json")
receipt="$cache/$key.json"
if python3 "$EVIDENCE" match "$receipt" "$work/binding.json" 2>/dev/null; then
  printf 'agy compatibility: reusing matching executable/model receipt\n' >&2
  printf '%s\n' "$receipt"
  exit 0
fi
version=$(jq -r .version "$work/binding.json")
first_guard=bypass
if [ "$mode" = ensure-native ]; then
  first_guard=native
  case "$version" in 1.4.[7-9]|1.4.[1-9][0-9]*) ;; *)
    echo "agy compatibility: native Auto candidate $version is outside >=1.4.7,<1.5.0" >&2
    exit 1 ;;
  esac
fi
eligible=$(python3 - "$version" <<'PY'
import sys
v = tuple(map(int, sys.argv[1].split(".")))
print("yes" if (1, 4, 4) <= v < (1, 5, 0) else "no")
PY
)
origin=patch-verification
if [ "$mode" = manual-baseline ]; then
  historical=$("$SCRIPT_DIR/fm-agy-permission-policy.sh" verified-versions)
  case " $historical " in
    *" $version "*) origin=manual-baseline ;;
    *) echo "agy compatibility: $version has no historical manual baseline" >&2; exit 1 ;;
  esac
elif [ "$eligible" != yes ]; then
  echo "agy compatibility: $version is outside candidate family >=1.4.4,<1.5.0; an unchanged manually certified baseline needs its exact receipt" >&2
  exit 1
fi

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
lock="$cache/$key.lock"
echo "agy compatibility: task is waiting for synthetic verification of $version ($2); no real brief is sent yet" >&2
fm_lock_acquire_wait_bounded "$lock" 900 || {
  echo "agy compatibility: another admission still holds this executable/context lock; retry after it completes" >&2
  exit 1
}
if python3 "$EVIDENCE" match "$receipt" "$work/binding.json" 2>/dev/null; then
  printf 'agy compatibility: reused the completed concurrent proof\n' >&2
  printf '%s\n' "$receipt"
  exit 0
fi
export AGY_CLI_DISABLE_AUTO_UPDATE=1 FM_AGY_LIVE_BIN="$1"
export FM_AGY_LIVE_MODEL="$2" FM_AGY_LIVE_EFFORT="$3"
export FM_AGY_LIVE_JUDGE_TIER="$4" FM_AGY_LIVE_JUDGE_MODEL="$5" FM_AGY_LIVE_JUDGE_BIN="$6"
if [ "$first_guard" = native ]; then export FM_AGY_NATIVE_LIVE_BACKEND="${4#native-}"; fi
export FM_AGY_ADMISSION_PROOF_DIR="$work" FM_AGY_ADMISSION_BINDING="$work/binding.json"
for guard in "$first_guard" observer signals; do
  limit=360
  [ "$guard" != observer ] || limit=150
  if [ "${FM_TEST_SEAM:-0}" = 1 ]; then limit=${FM_TEST_AGY_GUARD_SECONDS:-$limit}; fi
  echo "agy compatibility: checking $guard (bounded ${limit}s); attempts, side effects and completion are required" >&2
  if ! fm_run_timed "$limit" env -u FM_CREDENTIAL_HOOK_ONLY \
      FM_AGY_NATIVE_LIVE=1 FM_AGY_BYPASS_LIVE=1 FM_AGY_OBSERVER_LIVE=1 FM_AGY_SIGNALS_LIVE=1 \
      bash "$FM_ROOT/tests/fm-agy-$guard-live-e2e.test.sh" >&2; then
    echo "agy compatibility: $guard failed or timed out; no receipt published, worker not launched" >&2
    exit 1
  fi
done
python3 "$EVIDENCE" publish "$receipt" "$work/binding.json" "$work" "$origin" "$@"
python3 "$EVIDENCE" assert "$receipt" "$@"
echo "agy compatibility: all focused checks completed; private executable-bound receipt published" >&2
printf '%s\n' "$receipt"
