#!/usr/bin/env bash
# The claim sweep must preserve the former numeric-name eligibility rules.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job-claim-retention)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
export FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/state"
. "$ROOT/bin/fm-remote-job-lib.sh"
mkdir -p "$TMP_ROOT/account"
fm_remote_job_prepare_state "$TMP_ROOT/account" || fail "$FM_REMOTE_JOB_ERROR"
for name in 0 notes 1x .private 1 00 01; do
  mkdir "$FM_REMOTE_JOB_SEQ_CLAIMS/$name"
  fm_touch_epoch 946684800 "$FM_REMOTE_JOB_SEQ_CLAIMS/$name"
done
mkdir "$FM_REMOTE_JOB_SEQ_CLAIMS/2"
# An expired token-bearing claim must still be reaped: unlinking its .owner
# inside the sweep bumps the claim's own mtime, so selecting claims and
# removing tokens in one pass is what keeps it eligible.
mkdir "$FM_REMOTE_JOB_SEQ_CLAIMS/7" "$FM_REMOTE_JOB_SEQ_CLAIMS/8"
printf 'x\n' > "$FM_REMOTE_JOB_SEQ_CLAIMS/7/.owner"
printf 'x\n' > "$FM_REMOTE_JOB_SEQ_CLAIMS/8/.owner"
fm_touch_epoch 946684800 "$FM_REMOTE_JOB_SEQ_CLAIMS/7" \
  "$FM_REMOTE_JOB_SEQ_CLAIMS/7/.owner" "$FM_REMOTE_JOB_SEQ_CLAIMS/8" \
  "$FM_REMOTE_JOB_SEQ_CLAIMS/8/.owner"
# An expired-looking claim whose token is fresh is an in-flight reclaim;
# the sweep must leave it (and its token) alone.
mkdir "$FM_REMOTE_JOB_SEQ_CLAIMS/9"
printf 'x\n' > "$FM_REMOTE_JOB_SEQ_CLAIMS/9/.owner"
fm_touch_epoch 946684800 "$FM_REMOTE_JOB_SEQ_CLAIMS/9"
# Pin the sweep clock so claims can sit on either side of the whole-second
# cutoff without racing a real second boundary.
NOW=$(command date +%s)
date() {
  if [ "$*" = '+%s' ]; then printf '%s\n' "$NOW"; else command date "$@"; fi
}
touch_frac() { # <epoch> <fraction> <path>
  local stamp
  stamp=$(TZ=UTC0 command date -d "@$1" +%Y-%m-%dT%H:%M:%S 2>/dev/null) \
    || stamp=$(TZ=UTC0 command date -r "$1" +%Y-%m-%dT%H:%M:%S 2>/dev/null) \
    || fail "touch_frac: date(1) accepted neither -d @<epoch> nor -r <epoch>"
  touch -d "$stamp.$2Z" "$3" || fail "touch_frac: touch -d $stamp.$2Z failed"
}
CUTOFF=$((NOW - FM_REMOTE_JOB_SEQ_CLAIM_REAP_SECONDS))
for spec in 3:$CUTOFF:0 4:$CUTOFF:5 5:$((CUTOFF + 1)):0 6:$((CUTOFF + 1)):5; do
  IFS=: read -r name epoch frac <<< "$spec"
  mkdir "$FM_REMOTE_JOB_SEQ_CLAIMS/$name"
  touch_frac "$epoch" "$frac" "$FM_REMOTE_JOB_SEQ_CLAIMS/$name"
done
fm_remote_job_reap_stale "$TMP_ROOT/account" || fail "claim sweep failed"
for name in 0 notes 1x .private 2 5 6 9; do
  assert_present "$FM_REMOTE_JOB_SEQ_CLAIMS/$name" "ineligible or fresh claim $name was reaped"
done
for name in 1 00 01 3 4 7 8; do
  assert_absent "$FM_REMOTE_JOB_SEQ_CLAIMS/$name" "expired eligible claim $name survived"
done
assert_present "$FM_REMOTE_JOB_SEQ_CLAIMS/9/.owner" "in-flight reclaim token was removed"
pass "claim sweep preserves numeric-name eligibility, whole-second expiry, and token-bearing claims"
