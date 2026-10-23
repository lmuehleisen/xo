#!/usr/bin/env bash
# Shared context/completion transport for the existing agy live guards.
# Admission requires an end-of-guard artifact in addition to exit status.
# A narrowed or skipped guard never reaches agy_live_complete.
agy_live_context() {
  # shellcheck disable=SC2034 # read by the sourcing live guards
  AGY_BIN=${FM_AGY_LIVE_BIN:-$(command -v agy 2>/dev/null || true)}
  MODEL=${FM_AGY_LIVE_MODEL:-${FM_AGY_BYPASS_LIVE_MODEL:-gemini-3.8-flash-low}}
  MODEL_FLAGS=(--model "$MODEL")
  [ -z "${FM_AGY_LIVE_EFFORT:-}" ] || MODEL_FLAGS+=(--effort "$FM_AGY_LIVE_EFFORT")
  export AGY_CLI_DISABLE_AUTO_UPDATE=1
  AGY_LIVE_STARTED=$SECONDS
}

agy_live_complete() {  # <guard> <observer-logs...>
  local guard=$1
  shift
  [ -n "${FM_AGY_ADMISSION_PROOF_DIR:-}" ] || return 0
  python3 "$ROOT/bin/fm-agy-admission.py" complete \
    "$FM_AGY_ADMISSION_PROOF_DIR" "$guard" "$((SECONDS - AGY_LIVE_STARTED))" "$@"
}
