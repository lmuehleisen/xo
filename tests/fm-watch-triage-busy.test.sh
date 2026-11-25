#!/usr/bin/env bash
# Behavior tests for watcher busy-pane age, TERM cleanup, write-deferral,
# procevent, heartbeat/afk, and exit-picker paths (bin/fm-watch.sh). Shared
# fixtures live in tests/watch-triage-helpers.sh.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

fm_test_run \
  test_term_stops_a_watcher_blocked_inside_a_poll \
  test_term_stops_a_watcher_whose_cleanup_marker_lock_is_held \
  test_cleanup_marker_lock_bound_is_decimal_with_zero_default \
  test_busy_pane_below_turn_age_bound_is_absorbed \
  test_busy_pane_stable_hash_escalates_past_turn_age_bound \
  test_busy_pane_changing_hash_escalates_past_turn_age_bound \
  test_busy_pane_turn_end_touch_resets_age \
  test_busy_pane_native_progress_resets_age \
  test_busy_pane_repeated_escalation_reaches_demand_deep_inspection \
  test_busy_pane_default_turn_age_bound_is_3600s \
  test_busy_declared_pause_is_rechecked_not_wedge_escalated \
  test_afk_busy_declared_pause_hands_off_plain_stale \
  test_afk_busy_declared_pause_ticking_pane_hands_off_once \
  test_nonterminal_stale_repairs_missing_or_corrupt_timer \
  test_wedge_escalation_deferred_while_worktree_is_written \
  test_write_deferral_resurfaces_on_the_bounded_cadence \
  test_secondmate_home_supervision_churn_is_not_write_evidence \
  test_timer_repair_drops_a_finished_write_deferral_chain \
  test_terminal_first_sight_drops_a_finished_write_deferral_chain \
  test_triage_log_size_cap_accepts_spaced_wc_counts \
  test_procevent_captured_result_surfaces_proactively \
  test_procevent_unacknowledged_result_redrains_until_handled \
  test_procevent_marker_keys_are_injective \
  test_procevent_headlines_classify_queue_keys \
  test_procevent_launch_failed_episodes_are_each_delivered \
  test_procevent_surface_serializes_with_drain \
  test_procevent_surface_crash_boundaries \
  test_procevent_marker_failure_exits_and_replays \
  test_heartbeat_no_change_absorbed \
  test_heartbeat_backstop_surfaces_unsurfaced_status \
  test_heartbeat_backstop_surfaces_a_masked_status \
  test_afk_heartbeat_preserves_idle_accounting \
  test_beacon_stays_fresh_while_absorbing \
  test_afk_signal_records_heartbeat_endpoint \
  test_afk_present_reverts_watcher_to_one_shot \
  test_afk_paused_changed_pane_hands_off_plain_stale \
  test_exit_picker_stale_names_the_dialog \
  test_exit_picker_wedge_keeps_climbing \
  test_quoted_exit_picker_stays_ordinary_stale \
  test_secondmate_exit_picker_stays_quiet \
  test_closed_exit_picker_drops_saved_dialog_name
