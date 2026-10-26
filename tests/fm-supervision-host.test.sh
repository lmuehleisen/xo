#!/usr/bin/env bash
# Supervision host behavior: reporting and stop-hook handoff.
# Shared fixtures and cases keep the same bounds across the serial suites.
# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"

assert_lost_handoff_keeps_watching() {  # <boundary|pass-through>
  local mode=$1 home watcher
  home=$(make_primary_home "lost-handoff-$mode")
  : > "$home/config/supervision-handoff-ack"
  : > "$home/hook.own-group"
  printf 'project=demo\nwindow=fm-other\nharness=claude\n' > "$home/state/other.meta"
  FM_SUPERVISION_HANDOFF_RETRY_SECONDS=3 FM_SUPERVISION_HOST_PARK_SECONDS=3600 \
    FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "$mode: no initial watcher"
  if [ "$mode" = boundary ]; then
    echo 3600 > "$home/park-clock"
  else
    append_status "$home" 'which export format?' needs-decision
  fi
  wait_until 250 hook_exited "$home" || fail "$mode: no hand-back"
  assert_rewoke_main "$home" "$mode"
  # The hand-back keeps the row the default path writes: it is what the
  # diagnosis of an unsupervised home reads first.
  if [ "$mode" = boundary ]; then
    assert_re '	boundary	after [0-9]+s$' "$home/state/.supervision-host.log" "$mode: the hand-back dropped the boundary row"
  else
    assert_re '	pass-through	attended	main-only	' "$home/state/.supervision-host.log" "$mode: the hand-back dropped the pass-through row"
  fi
  kill -TERM -- "-$(cat "$home/hook.pgid")" 2>/dev/null || true
  # Drop the continuation entirely: no drain, acknowledgement, or Stop follows.
  watcher_live "$home" || fail "$mode: lost continuation left no verified watcher"
  watcher=$(cat "$home/state/.watch.lock/pid")
  printf 'working [at=%s]: another event\n' "$(date +%s)" >> "$home/state/other.status"
  wait_until 250 bash -c '! kill -0 "$1" 2>/dev/null' _ "$watcher" \
    || fail "$mode: the successor did not observe the later event"
  wait_until 150 watcher_live "$home" || fail "$mode: a successor close left supervision down"
  wait_until 150 grep -q 'retry' "$home/state/.supervision-handoff.log" \
    || fail "$mode: the unacknowledged hand-back was not raised again"
  assert_grep 'other.status' "$home/state/.wake-queue" "the later event must stay durable"
  assert_grep 'supervision-handoff' "$home/state/.wake-queue" "the hand-back must remain acknowledgeable"
  main_drain "$home" > "$home/main-drain.out"
  assert_grep 'supervision-handoff' "$home/main-drain.out" "main must receive the hand-back again"
  [ -n "$MAIN_ACK" ] || fail "$mode: no main acknowledgement"
  [ -f "$home/state/.supervision-handoff-pending" ] || fail "$mode: presentation incorrectly confirmed ownership"
  FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" "$@"' "$ROOT/bin/fm-wake-drain.sh" \
    --ack-through 0 --recovery-generation "${MAIN_ACK##* }" > "$home/stale-ack.out" 2>&1 \
    || fail "$mode: the stale acknowledgement could not be checked"
  [ -f "$home/state/.supervision-handoff-pending" ] || fail "$mode: a stale acknowledgement confirmed unseen work"
  # shellcheck disable=SC2086 # The drain's printed arguments.
  FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" "$@"' "$ROOT/bin/fm-wake-drain.sh" $MAIN_ACK \
    || fail "$mode: main could not acknowledge"
  wait_until 150 bash -c '[ ! -e "$1/state/.supervision-handoff-pending" ]' _ "$home" \
    || fail "$mode: acknowledgement did not confirm ownership"
  watcher_live "$home" || fail "$mode: acknowledgement stopped supervision"
  echo 0 > "$home/park-clock"
  turn_end "$home"
  wait_until 250 host_owns_the_only_cycle "$home" || fail "$mode: the next park did not take over exactly one watcher"
  stop_home_processes "$home"
  pass "host+hook: $mode survives a lost continuation, retries, and transfers one watcher after acknowledgement"
}

test_lost_boundary_handoff() { assert_lost_handoff_keeps_watching boundary; }
test_lost_pass_through_handoff() { assert_lost_handoff_keeps_watching pass-through; }

# A close that turns main-only at its turn hands back through the same opt-in
# path and must keep its pass-through row too. The hand-back stops the successor
# this turn confirmed, and the owner replaces that stopped arm within its poll,
# so the live-watcher check waits for it.
test_acknowledged_handoff_at_the_turn_keeps_the_pass_through_row() {
  local home
  home=$(make_primary_home hook-turns-main-only-ack)
  : > "$home/config/supervision-handoff-ack"
  turn_main_only_at_second_offer "$home"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "ack turns-main-only: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'step one'
  wait_until 250 hook_exited "$home" || fail "ack turns-main-only: the Stop hook never closed: $(cat "$home/state/.supervision-host.log")"
  [ "$(cat "$home/offer-count" 2>/dev/null)" -ge 2 ] || fail "fixture: the close was not accepted before it turned main-only"
  assert_rewoke_main "$home" "ack turns-main-only"
  [ -f "$home/state/.supervision-handoff-pending" ] || fail "ack turns-main-only: the close was not handed back for acknowledgement"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "ack turns-main-only: the hand-back dropped the pass-through row"
  wait_until 150 watcher_live "$home" || fail "ack turns-main-only: the hand-back left no watcher: $(cat "$home/state/.watch-cycle-exits.log")"
  stop_home_processes "$home"
  pass "host+hook: an acknowledged hand-back at the turn keeps its pass-through row"
}

# The transport fixture exercises the existing busy/composer/submit readers,
# not a Claude run: live continuation acceptance remains a documented limit.
test_handoff_retry_respects_the_receiving_pane() {
  local home doorbell record real_ps
  home=$(make_primary_home handoff-doorbell)
  real_ps=$(command -v ps)
  cat > "$home/fakebin/ps" <<SH
#!/usr/bin/env bash
if [ "\$1:\$2" = '-o:pgid=,tpgid=' ]; then
  if [ -f "\$FM_HOME/background-session" ]; then printf '77 88\\n'; else printf '77 77\\n'; fi
  exit 0
fi
exec "$real_ps" "\$@"
SH
  chmod +x "$home/fakebin/ps"
  : > "$home/config/supervision-handoff-ack"
  printf '❯ human draft\n' > "$home/screen"
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *'%77'*) ;; *) exit 1 ;; esac
case "$1:$*" in
  display-message:*'#{pane_pid}'*)
    if [ -f "$FM_HOME/foreign-pane" ]; then printf '999999\n'; else cat "$FM_HOME/state/.lock"; fi ;;
  display-message:*'#{cursor_y}'*) printf '0\n' ;;
  capture-pane:*) cat "$FM_HOME/screen" ;;
  send-keys:*) printf '%s\n' "$*" >> "$FM_HOME/submits" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$home/fakebin/tmux"
  TMUX_PANE=%77 FM_SUPERVISION_HANDOFF_RETRY_SECONDS=3 start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "doorbell: no initial watcher"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 hook_exited "$home" || fail "doorbell: no hand-back"
  wait_until 150 grep -q 'retry' "$home/state/.supervision-handoff.log" || fail "doorbell: no retry"
  [ ! -s "$home/submits" ] || fail "doorbell: retry overwrote human input"
  printf '❯ \n' > "$home/screen"
  : > "$home/foreign-pane"
  # Observe a complete new retry while the pane does not own this session.
  cp "$home/state/.supervision-handoff.log" "$home/retries-before"
  wait_until 150 bash -c '! cmp -s "$1/retries-before" "$1/state/.supervision-handoff.log"' _ "$home" \
    || fail "doorbell: no foreign-pane retry"
  [ ! -s "$home/submits" ] || fail "doorbell: retry reached another session's pane"
  rm "$home/foreign-pane"
  : > "$home/background-session"
  cp "$home/state/.supervision-handoff.log" "$home/retries-before"
  wait_until 150 bash -c '! cmp -s "$1/retries-before" "$1/state/.supervision-handoff.log"' _ "$home" \
    || fail "doorbell: no background-session retry"
  [ ! -s "$home/submits" ] || fail "doorbell: retry reached a different foreground conversation"
  rm "$home/background-session"
  wait_until 150 grep -q $'\tretry\t.*\tempty$' "$home/state/.supervision-handoff.log" \
    || fail "doorbell: the submit helper did not confirm the idle owning pane's retry"
  [ -s "$home/submits" ] || fail "doorbell: idle owning pane received no retry"
  assert_grep 'Enter' "$home/submits" "the retry must submit, not merely type"
  doorbell=$(grep -- '-l ' "$home/submits" | head -1)
  record=$(printf '%s\n' "$doorbell" | grep -o '/[^ ]*/operational-inbox/[^ ]*\.msg')
  [ -n "$record" ] && [ -f "$record" ] || fail "doorbell: no durable operational record"
  assert_grep 'watcher: check: supervision-handoff' "$record" "the retry must be operational watcher input"
  [ -f "$home/state/.supervision-handoff-pending" ] || fail "doorbell: submission was mistaken for acknowledgement"
  stop_home_processes "$home"
  pass "host+hook: hand-back retry submits only to the idle owning pane without replacing human input"
}

test_main_only_close_after_handled_turn_restores_inherited_handling
test_main_only_close_after_handled_turn_delivers_restore_failure
test_returned_driver_is_caught_attended
test_returned_driver_is_caught_away
test_lost_boundary_handoff
test_lost_pass_through_handoff
test_acknowledged_handoff_at_the_turn_keeps_the_pass_through_row
test_handoff_retry_respects_the_receiving_pane
test_claude_stop_hook_restores_handoff_when_successor_closed_before_exit_to_main
test_claude_stop_hook_restores_handoff_when_successor_closed_mid_engine_turn
test_claude_stop_hook_notifies_when_closed_successor_downtime_restore_fails
test_claude_stop_hook_notifies_when_closed_announced_successor_downtime_restore_fails
test_park_exit_probe_uses_half_second_child_sleeps
test_report_surface_enforces_actor_turn_and_scope
test_report_after_the_return_is_queued_for_main
test_dispatch_entry_scopes_rows_and_renders_the_away_tail
test_branch_outcomes_only_on_a_host_home_off_pi
test_branch_outcomes_put_captain_first_and_collapse_routine_overflow
test_branch_outcomes_collapse_repeated_captain_outcomes_per_task
test_branch_outcomes_present_a_long_away_window_once
test_branch_outcomes_budgets_count_bytes
test_branch_outcomes_stay_unread_when_a_projection_fails
test_branch_outcomes_stay_unread_without_jq
test_branch_outcomes_stay_unread_when_the_drain_cannot_print
test_branch_outcomes_date_a_legacy_backlog_without_adopting_it
test_branch_ack_keeps_older_keyed_decision_open
test_branch_outcomes_date_an_outcome_carried_across_a_switch_off_pi
test_branch_outcomes_keep_an_unshown_outcome_until_acknowledged
test_branch_outcomes_keep_a_drain_presented_outcome_across_a_switch_to_pi
test_branch_outcomes_keep_a_drain_presented_outcome_across_an_index_repair
