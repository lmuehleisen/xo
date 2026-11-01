#!/usr/bin/env bash
# Fork-specific fm-supervision-host regression cases.
# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"

fm_test_run \
  test_acknowledged_host_recovery_settles \
  test_host_takeover_waits_full_stop_bound \
  test_host_takeover_accepts_decimal_stop_bound \
  test_host_takeover_accepts_prefixed_term_receipt \
  test_host_recovery_after_real_successor_downtime \
  test_activation_skips_the_lease_lock_when_no_branch_lease_is_held
