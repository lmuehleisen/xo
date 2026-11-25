#!/usr/bin/env bash
# fm-watch-triage behavior cases with shared fixtures.
# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

if [ -n "${FM_TEST_STOCK_BASH:-}" ]; then
  fm_test_run test_turn_ended_churn_existing_marker_absorbed
  exit 0
fi

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

fm_test_run \
  test_colliding_endpoints_keep_independent_stale_history \
  test_long_endpoint_keeps_stale_history \
  test_window_keys_encode_supported_endpoint_bytes \
  test_pi_stream_silence_uses_inspection_timer \
  test_pi_model_progress_and_legacy_fallback \
  test_pi_stream_publication_lock_revalidation \
  test_pi_stream_uninterrupted_publication \
  test_pi_stream_terminal_publication \
  test_pi_stream_counter_write_failures \
  test_pi_stream_resume_restarts_capped_episode \
  test_status_span_actionable_classifier \
  test_status_span_survives_a_later_routine_append \
  test_status_span_respects_decision_closure \
  test_status_span_closure_from_an_offset \
  test_malformed_seen_signature_reads_the_whole_log \
  test_stale_is_terminal_classifier \
  test_classifier_primitives \
  test_unrecognized_status_prefix_is_visible \
  test_crew_is_provably_working_classifier \
  test_status_is_paused_classifier \
  test_crew_absorb_class_classifier \
  test_crew_worktree_written_since_classifier \
  test_empty_write_prune_widens_the_probe \
  test_empty_write_prune_from_the_environment_widens_the_probe \
  test_worktree_write_probe_is_wall_clock_bounded \
  test_signal_crew_provably_working_classifier \
  test_secondmate_status_routine_absorbed_routed_surfaced_classifier \
  test_provably_working_signal_absorbed \
  test_turn_ended_provably_working_absorbed \
  test_turn_ended_not_working_surfaced \
  test_turn_ended_churning_pane_absorbed \
  test_turn_ended_churn_resets_prior_stale_classification \
  test_turn_ended_churn_resets_wedge_state_before_stale_poll \
  test_turn_ended_churn_existing_marker_absorbed \
  test_turn_ended_still_pane_surfaced \
  test_turn_ended_malformed_prior_hash_surfaced \
  test_unknown_alive_stale_is_bounded_after_its_first_alarm \
  test_unknown_alive_stale_without_progress_keeps_surfacing \
  test_turn_ended_trailing_newline_prior_hash_surfaced \
  test_secondmate_turn_ended_churning_pane_surfaced \
  test_turn_ended_colliding_window_key_surfaced \
  test_turn_ended_duplicate_endpoint_records_surfaced \
  test_turn_ended_mixed_positive_evidence_batch_absorbed \
  test_turn_ended_mixed_positive_evidence_batch_default_off \
  test_status_and_turn_end_batch_never_uses_churn_evidence \
  test_turn_ended_churn_absorb_off_by_default \
  test_turn_ended_churn_absorb_bounded \
  test_turn_ended_churn_timer_write_failure_surfaced \
  test_turn_ended_invalid_churn_bound_surfaced \
  test_turn_ended_oversized_churn_bound_surfaced \
  test_turn_ended_invalid_churn_deadline_surfaced \
  test_turn_ended_surfaced_batch_opens_no_partial_deadline \
  test_working_note_not_working_surfaced \
  test_secondmate_status_note_surfaced_despite_busy_agent \
  test_secondmate_routine_progress_absorbed_then_note_surfaced \
  test_secondmate_buried_block_wakes_despite_busy_agent \
  test_self_announced_close_does_not_rewake_but_next_note_does \
  test_self_announced_close_after_open_decisions_fold_does_not_rewake \
  test_folded_worker_decision_without_home_append_still_wakes \
  test_separate_self_announced_answers_after_fold_wake_once \
  test_self_announced_close_after_fold_still_surfaces_folded_worker_failure \
  test_self_announced_close_after_fold_still_surfaces_folded_secondmate_lines \
  test_actionable_signal_surfaced \
  test_needs_decision_signal_payload_marked_for_branch_exclusion \
  test_needs_decision_reconciliation_required_still_marked \
  test_captain_held_signal_payload_marked_for_branch_exclusion \
  test_pending_reply_escalation_signal_payload_marked_for_branch_exclusion \
  test_ordinary_blocked_signal_payload_remains_branch_eligible \
  test_routine_signal_payload_not_marked_needs_decision \
  test_actionable_signal_survives_a_later_routine_append \
  test_keyed_decision_signal_reads_only_the_new_span \
  test_release_completion_survives_a_later_routine_append \
  test_routine_appends_after_a_classified_event_stay_absorbed \
  test_unreadable_status_reports_once_per_file_state \
  test_permission_recovery_surfaces_preserved_status \
  test_terminal_stale_surfaced \
  test_stale_terminal_status_overridden_by_active_run \
  test_nonterminal_stale_provably_working_absorbed_then_escalated \
  test_wedge_escalation_marks_demand_deep_inspection_after_threshold \
  test_wedge_escalation_resets_when_pane_becomes_active \
  test_gone_endpoint_reports_once_instead_of_escalating_forever \
  test_live_and_unproven_endpoints_still_wedge_escalate \
  test_wedge_guards_absent_config_keeps_the_unchanged_ladder \
  test_wedge_guard_critical_defers_one_window_at_a_time_up_to_the_cap \
  test_wedge_guard_failures_fail_open \
  test_wedge_guard_never_defers_a_gone_endpoint \
  test_gone_report_rearms_when_the_endpoint_comes_back \
  test_second_death_after_a_same_window_relaunch_reports_in_full \
  test_identical_dead_display_of_a_successor_still_reports \
  test_agy_silent_stall_declined_wakes_once \
  test_agy_silent_stall_paused_worker_stays_quiet \
  test_agy_pending_prompt_stays_on_needs_decision_path \
  test_agy_silent_stall_probe_keeps_prior_interval \
  test_agy_silent_stall_mid_scan_write_stays_visible
