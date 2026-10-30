#!/usr/bin/env bash
# fm-watch-triage behavior cases with shared fixtures.
# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

fm_test_run \
  test_required_captain_hold_tests_fail_without_tasks_axi \
  test_nonterminal_stale_not_working_surfaced \
  test_nonterminal_stale_paused_absorbed_then_resurfaced \
  test_exited_declared_pause_is_bounded_but_live_gate_surfaces \
  test_own_work_wait_keeps_first_alert_then_long_cadence \
  test_absorbed_replacement_wait_does_not_inherit_the_old_throttle \
  test_live_declared_wait_churn_honors_the_resurface_throttle \
  test_live_paused_until_controls_recheck_time \
  test_open_captain_call_bounds_stale_churn \
  test_stale_churn_without_a_captain_call_still_alarms \
  test_failed_wake_append_does_not_arm_the_captain_hold_throttle \
  test_reheld_captain_call_starts_its_own_resurface_window \
  test_secondmate_paused_resurfaces_in_normal_mode \
  test_secondmate_captain_held_resurfaces_in_normal_mode \
  test_secondmate_nonpaused_stale_remains_suppressed \
  test_secondmate_unpause_clears_pause_tracking \
  test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash \
  test_nonterminal_paused_rechecks_authoritative_state \
  test_paused_authoritative_working_preserves_wedge_timer \
  test_captain_held_never_rechecked_while_away_record_exists \
  test_live_captain_held_first_sight_silenced_by_away_record \
  test_backlog_hold_never_rechecked_while_away_record_exists \
  test_afk_one_shot_never_hands_off_captain_held_under_away_record \
  test_captain_held_rechecked_under_a_quiet_record \
  test_paused_until_near_future_is_quiet_before_the_cadence \
  test_paused_until_wrong_year_is_bounded_by_the_cadence \
  test_paused_until_that_passed_is_rechecked_before_the_cadence \
  test_paused_bg_job_without_until_stays_silent_after_the_job_ends \
  test_paused_bg_job_until_timeout_rechecks_after_the_job_ends
