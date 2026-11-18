#!/usr/bin/env bash
# fm-watch-triage behavior cases with shared fixtures.
# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

# Opt-in config/paused-recheck-silent: an unchanged paused declaration that was
# already surfaced once is rechecked without a wake; first sight, a changed
# declaration, a due declared time, and an open decision still wake.
silent_recheck_fixture() {  # <name> <until-epoch> <status-age-secs> -> dir
  local dir state window key
  dir=$(make_case "$1"); state="$dir/state"; window="test:fm-until"
  printf 'idle, waiting for the reset\n' > "$dir/pane.txt"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/until.meta"
  printf 'paused: rate limit resets, until %s, then resuming\n' "$(iso_utc_at "$2")" > "$state/until.status"
  set_mtime "$(( $(date +%s) - $3 ))" "$state/until.status"
  printf '%s' "$(seen_sig "$state/until.status")" > "$state/.seen-until_status"
  key=$(watch_window_key "$window")
  printf '%s' "$(hash_text 'idle, waiting for the reset')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  mkdir -p "$dir/config"
  printf '%s\n' "$dir"
}

silent_recheck_case() {  # <name> <flag:on|off> <status-body> -> dir; leaves the first-sight wake acked
  local name=$1 flag=$2 body=$3 dir state key
  dir=$(silent_recheck_fixture "$name" "$(( $(date +%s) + 86400 ))" 500); state="$dir/state"
  printf '%s\n' "$body" > "$state/until.status"
  set_mtime "$(( $(date +%s) - 500 ))" "$state/until.status"
  printf '%s' "$(seen_sig "$state/until.status")" > "$state/.seen-until_status"
  mkdir -p "$dir/config"
  [ "$flag" = on ] && : > "$dir/config/paused-recheck-silent"
  until_watch "$dir" 240
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "first sight of a declared pause did not wake ($name): $(cat "$dir/watch.out")"; }
  ack_stopped_cycle "$state" || fail "could not acknowledge the first-sight wake ($name)"
  key=$(watch_window_key test:fm-until)
  set_mtime "$(( $(date +%s) - 600 ))" "$state/.paused-resurfaced-$key"
  : > "$dir/watch.out"
  printf '%s\n' "$dir"
}

test_silent_recheck_flag_on_absorbs_unchanged_pause() {
  local dir state key before
  dir=$(silent_recheck_case silent-on on 'paused: rate limit resets, until 2999-01-01T00:00Z, then resuming'); state="$dir/state"
  key=$(watch_window_key test:fm-until)
  before=$(cat "$state/.paused-resurfaced-$key")
  until_watch "$dir" 240
  if ! wait_poll_cycle "$state" "$UNTIL_PID" || ! wait_poll_cycle "$state" "$UNTIL_PID"; then
    reap "$UNTIL_PID"; fail "an unchanged paused recheck woke the supervisor with the flag on: $(cat "$dir/watch.out")"
  fi
  reap "$UNTIL_PID"
  [ "$(cat "$state/.paused-resurfaced-$key")" = "$before" ] || fail "the recheck changed the declaration scope"
  [ "$state/.paused-resurfaced-$key" -nt "$state/until.status" ] || fail "the recheck was not recorded in the throttle marker"
  grep -F 'rechecked without a wake' "$state/.watch-triage.log" >/dev/null || fail "the silent recheck was not logged"
  pass "with paused-recheck-silent on, an unchanged paused declaration is rechecked without a wake"
}

test_silent_recheck_flag_off_still_wakes() {
  local dir state
  dir=$(silent_recheck_case silent-off off 'paused: rate limit resets, until 2999-01-01T00:00Z, then resuming'); state="$dir/state"
  until_watch "$dir" 240
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "an unchanged paused recheck did not wake with the flag off"; }
  grep -F 'stale: test:fm-until' "$dir/watch.out" >/dev/null || fail "the recheck wake was not printed with the flag off: $(cat "$dir/watch.out")"
  pass "with paused-recheck-silent absent, the unchanged paused recheck still wakes"
}

test_silent_recheck_flag_on_wakes_for_an_open_decision() {
  local dir state body
  body=$(printf 'needs-decision [at=%s] [key=open-q]: which option\npaused: rate limit resets, until 2999-01-01T00:00Z, then resuming' "$(date +%s)")
  dir=$(silent_recheck_case silent-open-decision on "$body"); state="$dir/state"
  until_watch "$dir" 240
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "an open decision did not wake an unchanged pause with the flag on"; }
  pass "with paused-recheck-silent on, an open decision still wakes"
}

test_silent_recheck_flag_on_wakes_for_a_changed_declaration() {
  local dir state
  dir=$(silent_recheck_case silent-changed on 'paused: rate limit resets, until 2999-01-01T00:00Z, then resuming'); state="$dir/state"
  printf 'paused: a different wait, until 2999-01-01T00:00Z\n' > "$state/until.status"
  set_mtime "$(( $(date +%s) - 500 ))" "$state/until.status"
  printf '%s' "$(seen_sig "$state/until.status")" > "$state/.seen-until_status"
  until_watch "$dir" 240
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "a changed declaration did not wake with the flag on"; }
  pass "with paused-recheck-silent on, a changed declaration still wakes"
}

test_silent_recheck_flag_on_absorbs_unchanged_pause_for_a_live_ship_agent() {
  local dir state
  dir=$(silent_recheck_case silent-live-ship on 'paused: rate limit resets, until 2999-01-01T00:00Z, then resuming'); state="$dir/state"
  printf 'window=test:fm-until\nkind=ship\nharness=grok\nbackend=tmux\n' > "$state/until.meta"
  FM_FAKE_TMUX_CURRENT_COMMAND=grok until_watch "$dir" 240
  if ! wait_poll_cycle "$state" "$UNTIL_PID" || ! wait_poll_cycle "$state" "$UNTIL_PID"; then
    reap "$UNTIL_PID"; fail "an unchanged paused recheck woke the supervisor for a live ship agent with the flag on: $(cat "$dir/watch.out")"
  fi
  reap "$UNTIL_PID"
  pass "with paused-recheck-silent on, an unchanged paused recheck for a live ship agent is silent"
}

test_silent_recheck_flag_on_absorbs_a_ticking_pane_for_a_live_ship_agent() {
  local dir state
  dir=$(silent_recheck_case silent-ticking on 'paused: waiting on the vendor reply'); state="$dir/state"
  printf 'window=test:fm-until\nkind=ship\nharness=grok\nbackend=tmux\n' > "$state/until.meta"
  printf 'idle, waiting for the reset 12:01\n' > "$dir/pane.txt"
  printf '%s' "$(hash_text 'idle, waiting for the reset 12:01')" > "$state/.hash-$(watch_window_key test:fm-until)"
  FM_FAKE_TMUX_CURRENT_COMMAND=grok until_watch "$dir" 240
  if ! wait_poll_cycle "$state" "$UNTIL_PID" || ! wait_poll_cycle "$state" "$UNTIL_PID"; then
    reap "$UNTIL_PID"; fail "a changed pane on an unchanged paused declaration woke the supervisor with the flag on: $(cat "$dir/watch.out")"
  fi
  reap "$UNTIL_PID"
  pass "with paused-recheck-silent on, a ticking pane on an unchanged paused declaration is silent"
}

test_silent_recheck_flag_on_wakes_when_the_agent_exited() {
  local dir state
  dir=$(silent_recheck_case silent-dead on 'paused: rate limit resets, until 2999-01-01T00:00Z, then resuming'); state="$dir/state"
  printf 'window=test:fm-until\nkind=ship\nharness=grok\nbackend=tmux\n' > "$state/until.meta"
  FM_FAKE_TMUX_CURRENT_COMMAND=zsh until_watch "$dir" 240
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "a paused recheck for an exited agent did not wake with the flag on"; }
  grep -F 'stale: test:fm-until' "$dir/watch.out" >/dev/null || fail "the exited-agent recheck wake was not printed: $(cat "$dir/watch.out")"
  pass "with paused-recheck-silent on, a paused recheck for an exited agent still wakes"
}

test_silent_recheck_flag_on_wakes_when_declared_time_is_due() {
  local dir state
  dir=$(silent_recheck_fixture silent-due "$(( $(date +%s) - 30 ))" 500); state="$dir/state"
  mkdir -p "$dir/config"; : > "$dir/config/paused-recheck-silent"
  until_watch "$dir" 240
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "a due declared time did not wake with the flag on"; }
  grep -F 'declared clearing time has passed' "$dir/watch.out" >/dev/null || fail "the due wake was not the declared-time recheck"
  pass "with paused-recheck-silent on, a due declared time still wakes"
}

# The superseded-wait check is opt-in through config/paused-wait-supersession;
# cases arm it unless asked for the flag-absent default.
make_superseded_pause_case() {  # <name> <status-line> [armed|unarmed]
  local name=$1 status_line=$2 arm=${3:-armed} dir state window key sig
  dir=$(make_case "$name"); state="$dir/state"; window="test:fm-superseded"
  mkdir -p "$dir/config"
  [ "$arm" = unarmed ] || : > "$dir/config/paused-wait-supersession"
  printf 'idle at declared wait\n' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/paused.meta"
  printf '%s\n' "$status_line" > "$state/paused.status"
  sig=$(seen_sig "$state/paused.status"); printf '%s' "$sig" > "$state/.seen-paused_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'idle at declared wait')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' "$dir"
}

superseded_pause_round() {  # <dir> <crew-state-line> <exit|absorb> [busy]
  local dir=$1 crew_state=$2 mode=$3 busy=${4:-no} state="$1/state" out="$1/watch.out" pid
  local command=zsh busy_max=999999
  case "$busy" in
    yes|recent) command=grok; [ "$busy" = yes ] && busy_max=1; printf 'working\nCtrl+c:cancel\n' > "$dir/pane.txt" ;;
  esac
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-superseded \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_FAKE_TMUX_CURRENT_COMMAND="$command" \
    FM_FAKE_CREW_STATE="$crew_state" FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE_LOG="$dir/crew-state.log" \
    FM_BUSY_TURN_MAX_SECS="$busy_max" FM_PAUSE_RESURFACE_SECS=240 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" >> "$out" 2>&1 &
  pid=$!
  if [ "$mode" = exit ]; then
    wait_for_exit "$pid" 100 || { reap "$pid"; return 1; }
  else
    wait_poll_cycle "$state" "$pid" 100 || { reap "$pid"; return 1; }
    reap "$pid"
  fi
}

test_declared_wait_surfaces_superseding_state() {
  local dir state window
  dir=$(make_superseded_pause_case gate-unreported 'paused: waiting for validation run R')
  state="$dir/state"; window=test:fm-superseded
  superseded_pause_round "$dir" \
    'state: parked · source: run-step · ask-user: authority decision · run: R' exit \
    || fail "idle paused run parked at an unreported human gate did not surface"
  grep -F "stale: $window (paused wait superseded: run R is parked at a human-owed gate with no open decision)" \
    "$dir/watch.out" >/dev/null || fail "gate wake did not identify the run and missing decision"
  ack_stopped_cycle "$state" || fail "could not acknowledge the idle gate wake"
  superseded_pause_round "$dir" \
    'state: parked · source: run-step · ask-user: authority decision · run: R' absorb \
    || fail "the same declaration and run re-alarmed inside the cadence"
  [ ! -s "$state/.wake-queue" ] || fail "the same declaration and run produced a duplicate wake"

  dir=$(make_superseded_pause_case gate-reported 'paused: waiting for validation run R')
  state="$dir/state"
  printf 'needs-decision [key=nm-R-review]: decide the ask-user finding\npaused: waiting for validation run R\n' > "$state/paused.status"
  sig=$(seen_sig "$state/paused.status"); printf '%s' "$sig" > "$state/.seen-paused_status"
  superseded_pause_round "$dir" \
    'state: parked · source: run-step · ask-user: authority decision · run: R' absorb \
    || fail "an already-open decision did not preserve the declared-wait cadence"
  [ ! -s "$state/.wake-queue" ] || fail "gate with an open needs-decision generated a stale wake"

  dir=$(make_superseded_pause_case gate-working 'paused: waiting for validation run R')
  state="$dir/state"
  superseded_pause_round "$dir" 'state: working · source: run-step · validating (running) · run: R' absorb \
    || fail "a working validation run did not preserve the declared-wait cadence"
  [ ! -s "$state/.wake-queue" ] || fail "working run generated a stale wake"

  dir=$(make_superseded_pause_case gate-terminal 'paused: waiting for validation run R')
  state="$dir/state"
  superseded_pause_round "$dir" 'state: done · source: run-step · run: R' exit \
    || fail "terminal validation run did not supersede the declared wait"
  grep -F 'paused wait superseded: current run R is terminal (done)' "$dir/watch.out" >/dev/null \
    || fail "terminal wake did not identify the superseded wait"

  dir=$(make_superseded_pause_case gate-terminal-pr 'paused: waiting for validation run R')
  state="$dir/state"
  superseded_pause_round "$dir" 'state: done · source: run-step · run: R1 · pr=https://example.test/1' exit \
    || fail "terminal run with PR did not supersede the declared wait"
  grep -F 'current run R1 is terminal (done)' "$dir/watch.out" >/dev/null \
    || fail "PR suffix obscured the first terminal run id"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first terminal wake"
  superseded_pause_round "$dir" 'state: done · source: run-step · run: R2 · pr=https://example.test/2' exit \
    || fail "second terminal run with PR did not supersede the declared wait"
  grep -F 'current run R2 is terminal (done)' "$dir/watch.out" >/dev/null \
    || fail "different terminal run shared the first run's throttle"

  dir=$(make_superseded_pause_case gate-busy-recent 'paused: waiting for validation run R')
  superseded_pause_round "$dir" \
    'state: parked · source: run-step · ask-user: authority decision · run: R' exit recent \
    || fail "recent busy paused run parked at an unreported human gate did not surface"
  grep -F 'run R is parked at a human-owed gate' "$dir/watch.out" >/dev/null \
    || fail "recent busy gate wake did not identify the run"

  dir=$(make_superseded_pause_case gate-busy-old 'paused: waiting for validation run R')
  state="$dir/state"
  set_mtime "$(( $(date +%s) - 500 ))" "$state/paused.meta"
  superseded_pause_round "$dir" \
    'state: parked · source: run-step · ask-user: authority decision · run: R' exit yes \
    || fail "old busy paused run parked at an unreported human gate did not surface"
  grep -F 'run R is parked at a human-owed gate' "$dir/watch.out" >/dev/null \
    || fail "old busy gate wake did not identify the run"
  ack_stopped_cycle "$state" || fail "could not acknowledge the busy gate wake"
  superseded_pause_round "$dir" \
    'state: parked · source: run-step · ask-user: authority decision · run: R' absorb yes \
    || fail "the repeated busy poll failed"
  [ ! -s "$state/.wake-queue" ] || fail "the busy gate repeated inside the cadence"

  pass "declared waits surface unreported gates and terminal runs once, while working runs and answered gates keep the pause cadence on idle and busy paths"
}

# Absent config/paused-wait-supersession the same superseding states keep main's
# declared-wait handling: no superseded wake, nothing queued, and no crew-state
# read beyond the one the idle declared-wait recheck already spends (none on the
# busy paths), counted through the stub's read log.
test_superseded_wait_check_is_opt_in() {
  local c n crew_state busy reads got dir state
  for c in "idle-gate|state: parked · source: run-step · ask-user: authority decision · run: R|no|1" \
           "idle-terminal|state: done · source: run-step · run: R|no|1" \
           "busy-recent|state: parked · source: run-step · ask-user: authority decision · run: R|recent|0" \
           "busy-old|state: parked · source: run-step · ask-user: authority decision · run: R|yes|0"; do
    IFS='|' read -r n crew_state busy reads <<< "$c"
    dir=$(make_superseded_pause_case "unarmed-$n" 'paused: waiting for validation run R' unarmed)
    state="$dir/state"
    [ "$busy" != yes ] || set_mtime "$(( $(date +%s) - 500 ))" "$state/paused.meta"
    superseded_pause_round "$dir" "$crew_state" absorb "$busy" \
      || fail "$n: flag-absent watcher round failed"
    ! grep -F 'paused wait superseded' "$dir/watch.out" >/dev/null \
      || fail "$n: flag-absent watcher surfaced a superseded wait"
    [ ! -s "$state/.wake-queue" ] || fail "$n: flag-absent watcher queued a wake"
    got=0
    [ ! -f "$dir/crew-state.log" ] || got=$(wc -l < "$dir/crew-state.log" | tr -d ' ')
    [ "$got" = "$reads" ] || fail "$n: flag-absent watcher read crew state $got times, want $reads"
  done
  pass "without config/paused-wait-supersession superseding states keep the declared-wait cadence and spend no extra crew-state read"
}

# The flag scopes the check to the foreground watcher: while the away-mode flag
# exists, a busy paused worker whose run is parked at an unreported human gate
# gets no superseded wake and no crew-state read, exactly as with the flag absent.
test_superseded_wait_check_skips_away_mode() {
  local c busy mode arm got dir out
  for c in recent:absorb yes:exit; do
    busy=${c%%:*} mode=${c#*:} out=''
    for arm in unarmed armed; do
      dir=$(make_superseded_pause_case "away-busy-$busy-$arm" 'paused: waiting for validation run R' "$arm")
      date '+%s' > "$dir/state/.afk"
      [ "$busy" != yes ] || set_mtime "$(( $(date +%s) - 500 ))" "$dir/state/paused.meta"
      superseded_pause_round "$dir" \
        'state: parked · source: run-step · ask-user: authority decision · run: R' "$mode" "$busy" \
        || fail "busy-$busy $arm: away-mode watcher round failed: $(cat "$dir/watch.out")"
      ! grep -F 'paused wait superseded' "$dir/watch.out" >/dev/null \
        || fail "busy-$busy $arm: away-mode watcher surfaced a superseded wait"
      got=0
      [ ! -f "$dir/crew-state.log" ] || got=$(wc -l < "$dir/crew-state.log" | tr -d ' ')
      [ "$got" = 0 ] || fail "busy-$busy $arm: away-mode watcher read crew state $got times, want 0"
      if [ "$arm" = unarmed ]; then
        out=$(cat "$dir/watch.out")
      else
        [ "$(cat "$dir/watch.out")" = "$out" ] \
          || fail "busy-$busy: armed away-mode output differs from flag-absent: $(cat "$dir/watch.out") vs $out"
      fi
    done
  done
  pass "with the away-mode flag present an armed busy paused worker at a human gate behaves exactly as with the flag absent: no superseded wake and no crew-state read"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

fm_test_run \
  test_required_captain_hold_tests_fail_without_tasks_axi \
  test_nonterminal_stale_not_working_surfaced \
  test_nonterminal_stale_paused_absorbed_then_resurfaced \
  test_declared_wait_surfaces_superseding_state \
  test_superseded_wait_check_is_opt_in \
  test_superseded_wait_check_skips_away_mode \
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
  test_pause_ceiling_dated_overdue_pause_opens_one_decision \
  test_pause_ceiling_absent_keeps_old_pauses_on_the_recheck \
  test_overdue_resume_race_uses_pause_snapshot \
  test_busy_overdue_pause_does_not_enter_wedge_ladder \
  test_overdue_marker_survives_reconcile_and_closes_on_working \
  test_overdue_terminal_status_ignores_pane_display_churn \
  test_reused_task_id_does_not_inherit_overdue_pause \
  test_malformed_dated_pause_is_not_undated_overdue \
  test_undated_pause_age_uses_the_pause_line \
  test_undated_pause_overdue_bound \
  test_silent_recheck_flag_on_absorbs_unchanged_pause \
  test_silent_recheck_flag_off_still_wakes \
  test_silent_recheck_flag_on_wakes_for_an_open_decision \
  test_silent_recheck_flag_on_wakes_for_a_changed_declaration \
  test_silent_recheck_flag_on_absorbs_unchanged_pause_for_a_live_ship_agent \
  test_silent_recheck_flag_on_absorbs_a_ticking_pane_for_a_live_ship_agent \
  test_silent_recheck_flag_on_wakes_when_the_agent_exited \
  test_silent_recheck_flag_on_wakes_when_declared_time_is_due \
  test_paused_bg_job_without_until_stays_silent_after_the_job_ends \
  test_paused_bg_job_until_timeout_rechecks_after_the_job_ends
