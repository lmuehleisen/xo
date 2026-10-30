#!/usr/bin/env bash
# fm-watch-triage behavior cases with shared fixtures.
# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

fm_test_run \
  test_wedge_threshold_defers_to_a_declared_wait_under_a_working_verdict \
  test_wedge_threshold_keeps_a_wait_past_a_default_key_answer \
  test_wedge_threshold_recheck_names_the_captain_for_a_held_lane \
  test_wedge_threshold_defers_to_a_backlog_captain_hold \
  test_wedge_threshold_defers_to_a_parked_gate_awaiting_a_human \
  test_wedge_threshold_parked_gate_needs_an_unanswered_decision \
  test_wedge_threshold_parked_gate_is_off_until_armed \
  test_wedge_threshold_defers_to_a_worker_blocker \
  test_wedge_threshold_worker_wait_is_off_until_armed \
  test_wedge_defer_refuses_a_half_filled_wait_record \
  test_wedge_threshold_defers_to_an_executing_validation_run \
  test_wedge_threshold_escalates_when_no_run_is_executing \
  test_wedge_threshold_validating_run_is_off_until_armed
