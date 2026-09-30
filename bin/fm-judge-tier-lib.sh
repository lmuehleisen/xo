#!/usr/bin/env bash
# fm-judge-tier-lib.sh - the judge TIER interface: the single owner of which
# model runs firstmate's first-line permission judge, what it costs, and how it
# is invoked. Sourced, never executed.
#
# A tier is the (executable, default model, invocation shape) triple one judge
# runs under. Every worker permission adapter
# (bin/fm-devin-permission-policy.sh, bin/fm-agy-permission-policy.sh) shares
# the prompt, the budget, the retry, and the verdict parser in
# bin/fm-command-policy-lib.sh, and differs only in the tier bound to the task.
# Adding a judge means adding a case here, not a second copy of the judge.
# The publish judge (bin/fm-publish-judge.sh) is not a permission judge: it
# takes no task policy, answers in JSON, and owns its own judge invocations.
#
#   fm_judge_tier_known <tier>          0 when the tier exists
#   fm_judge_tiers                      prints every known tier id
#   fm_judge_tier_model <tier>          the tier's default model id
#   fm_judge_tier_command <tier>        the executable name the tier needs
#   fm_judge_tier_bind <native-tier> <native-executable>
#                                       sets JUDGE_TIER and JUDGE_BIN for a call
#   fm_judge_tier_run <tier> <bin> <model> <seconds> <prompt-file>
#                                       ONE bounded judge call; prints its raw
#                                       output, returns its exit status (124
#                                       when the bound was hit)
#
# EACH ADAPTER JUDGES ITSELF BY DEFAULT: agy judges agy, Devin judges Devin.
# That default is automatic, not opt-in, and nothing here resolves a tier the
# caller did not name - an adapter whose policy names no tier keeps its OWN
# native tier rather than reaching for another's. Selecting a different tier is
# a deliberate act, and the selection is recorded in the task's posture and
# printed at launch so a reader of the decision log afterwards can tell WHICH
# judge adjudicated a given call, long after the per-task policy file is gone.
#
# THE TIER IS A CORRECTNESS VARIABLE. A model judge can disagree with itself
# when the same input is resampled, so tiers have to be comparable on
# identical inputs, not merely swappable. The `judge-probe` verb each adapter
# exposes is that seam: it runs the static analysis and one judge call on a
# real hook payload and prints the verdict WITHOUT touching the verdict cache,
# the pending markers, the status file, or the observer log, so the same
# captured payloads can be replayed across tiers and diffed.
set -u

# The known tiers. Each adapter's native tier shares its name. Keep this an
# explicit list: an unknown tier must refuse at bin/fm-spawn.sh and deny at
# decision time, never resolve to whatever binary happens to answer to that
# name on PATH.
FM_JUDGE_TIERS='agy devin'

fm_judge_tier_known() {  # <tier>
  [ -n "${1-}" ] || return 1
  case " $FM_JUDGE_TIERS " in *" $1 "*) return 0 ;; esac
  return 1
}

fm_judge_tiers() { printf '%s\n' "$FM_JUDGE_TIERS"; }

# fm_judge_attribution: the bound tier and model as one token, written into
# every judge-decided log record so the append-only log still says which judge
# adjudicated a call after the per-task policy file has been torn down.
fm_judge_attribution() {
  printf '%s/%s' "${JUDGE_TIER:-(none)}" "${JUDGE_MODEL:-(none)}"
}

# The model a tier runs when the caller names no model. Each is a low-cost
# catalog entry, and each is a DEFAULT, not a pin: the per-task policy's
# judge_model retargets a running worker's judge without touching this file.
fm_judge_tier_model() {  # <tier>
  case "${1-}" in
    agy) printf 'gemini-3.6-flash-low\n' ;;
    devin) printf 'swe-2-high\n' ;;
    *) return 1 ;;
  esac
}

# The executable a tier needs. bin/fm-spawn.sh resolves it once at launch and
# writes the absolute path into the per-task policy file, so the hook never
# searches a PATH it does not control.
fm_judge_tier_command() {  # <tier>
  case "${1-}" in
    agy) printf 'agy\n' ;;
    devin) printf 'devin\n' ;;
    *) return 1 ;;
  esac
}

# fm_judge_tier_bind <native-tier> <native-executable>: binds JUDGE_TIER and
# JUDGE_BIN for this call from the per-task policy's judge_tier and judge_bin
# fields, which the adapter has already read into FM_POLICY_JUDGE_TIER and
# FM_POLICY_JUDGE_BIN.
#
# A policy that names no tier keeps the adapter's own native tier: the
# default, self-judging. A policy that names a NON-native tier must also carry
# that tier's executable: nothing here searches for one, because a judge
# resolved from PATH would leave the recorded tier and the judge that actually
# answered free to disagree, which is exactly what the record exists to pin. An
# unresolved executable leaves JUDGE_BIN empty, and run_judge turns that into a
# decline that firstmate answers - never an approval.
fm_judge_tier_bind() {  # <native-tier> <native-executable>
  JUDGE_TIER=${FM_POLICY_JUDGE_TIER:-}
  [ -n "$JUDGE_TIER" ] || JUDGE_TIER=${1-}
  JUDGE_BIN=${FM_POLICY_JUDGE_BIN:-}
  if [ -z "$JUDGE_BIN" ] && [ "$JUDGE_TIER" = "${1-}" ]; then JUDGE_BIN=${2-}; fi
}

# fm_judge_tier_run <tier> <bin> <model> <seconds> <prompt-file>: ONE bounded
# judge call, run by the caller from the task temp root so it loads no
# workspace configuration. Prints the judge's raw output; the shared parser
# owns what counts as a verdict. Requires bin/fm-timeout-lib.sh's fm_run_timed,
# whose 124 means the bound was hit.
#
# Each tier's argv is the one verified against that CLI: agy print mode reads
# no stdin, so the prompt rides on -p's value, while the Devin CLI takes
# --prompt-file and needs the worker's own harness environment scrubbed so the
# judge cannot inherit the session it is judging.
fm_judge_tier_run() {  # <tier> <bin> <model> <seconds> <prompt-file>
  local tier=${1-} bin=${2-} model=${3-} seconds=${4-} prompt=${5-}
  case "$tier" in
    agy)
      fm_run_timed "$seconds" \
        "$bin" -p "$(cat "$prompt")" --model "$model" \
        --disable-slash-commands --sandbox 2>/dev/null </dev/null
      ;;
    devin)
      fm_run_timed "$seconds" env -u FM_DEVIN_HARNESS -u DEVIN_PROJECT_DIR \
        -u DEVIN_PERMISSION_MODE -u DEVIN_SANDBOX -u DEVIN_MODEL \
        "$bin" --model "$model" --permission-mode normal \
        --respect-workspace-trust=false --prompt-file "$prompt" -p 2>/dev/null </dev/null
      ;;
    *)
      # Unreachable through run_judge, which refuses an unknown tier before
      # any attempt; a direct caller gets "command not found" semantics rather
      # than a silent success.
      return 127
      ;;
  esac
}
