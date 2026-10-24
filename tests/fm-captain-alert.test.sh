#!/usr/bin/env bash
# Behavior tests for bin/fm-captain-alert.sh, the one-way Discord captain alert
# notifier, and the away-record reach it feeds (bin/fm-afk-contract.sh) and the
# return-brief line it prints (brief-line).
#
# Every case runs against a scratch home whose outcome store is written through
# the real bin/fm-branch-outcome.sh append and whose away record is written by
# the real bin/fm-afk-contract.sh enter. Delivery goes through the
# FM_CAPTAIN_ALERT_EXEC stub transport, so no case ever contacts Discord, and
# the fallback alarm goes through the FM_CAPTAIN_ALERT_SENTINEL stub.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ALERT="$ROOT/bin/fm-captain-alert.sh"
OUTCOME="$ROOT/bin/fm-branch-outcome.sh"
CONTRACT="$ROOT/bin/fm-afk-contract.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-alert)
SECRET=TOKENMUSTNOTLEAK
NOW0=1800000000

# The stub reads the curl config from stdin, keeps each payload, and answers
# from $STUB_DIR/mode (one mode per line; the first line is consumed per call,
# and the last line repeats).
STUB="$TMP_ROOT/stub-transport.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
cat > "$STUB_DIR/config"
n=$(( $(cat "$STUB_DIR/calls" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$STUB_DIR/calls"
cp "$1" "$STUB_DIR/payload.$n"
mode=$(head -n 1 "$STUB_DIR/mode" 2>/dev/null || echo ok)
if [ "$(wc -l < "$STUB_DIR/mode" 2>/dev/null | tr -d ' ')" -gt 1 ]; then
  tail -n +2 "$STUB_DIR/mode" > "$STUB_DIR/mode.next" && mv "$STUB_DIR/mode.next" "$STUB_DIR/mode"
fi
case "$mode" in
  ok) printf '{"id":"9000%s"}' "$n" > "$2"; printf '200' ;;
  noid) printf '{}' > "$2"; printf '200' ;;
  429) printf '{"retry_after":0.2}' > "$2"; printf '429' ;;
  429long) printf '{"retry_after":40}' > "$2"; printf '429' ;;
  404) printf '{"message":"Unknown Webhook"}' > "$2"; printf '404' ;;
  500) printf '500' ;;
  net) exit 6 ;;
esac
EOF
chmod +x "$STUB"

SENTINEL="$TMP_ROOT/stub-sentinel.sh"
cat > "$SENTINEL" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$STUB_DIR/fallback"
EOF
chmod +x "$SENTINEL"

# make_home <name> [configured]: a scratch home with an empty store; with
# `configured` its .env carries a webhook whose token is $SECRET.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/stub"
  printf 'ok\n' > "$home/stub/mode"
  if [ "${2:-}" = configured ]; then
    printf 'FM_DISCORD_ALERT_WEBHOOK=https://discord.example.invalid/api/webhooks/1/%s\n' "$SECRET" > "$home/.env"
  fi
  printf '%s\n' "$home"
}

H=
NOW=$NOW0
use_home() { H=$1; NOW=$NOW0; }

run() {  # <args...>: runs the notifier in $H at $NOW; output in $OUT, status in $RC
  RC=0
  OUT=$(env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$H" STUB_DIR="$H/stub" \
    FM_CAPTAIN_ALERT_EXEC="$STUB" FM_CAPTAIN_ALERT_SENTINEL="$SENTINEL" \
    FM_CAPTAIN_ALERT_NOW="$NOW" ${EXTRA_ENV:-} "$ALERT" "$@" 2>&1) || RC=$?
  printf '%s\n' "$OUT" >> "$H/all-output"
}

sweep() { run check; expect_code 0 "$RC" "check exit"; }

append() {  # <task> <verdict> <summary> [silent]
  FM_HOME="$H" "$OUTCOME" append --task "$1" --verdict "$2" --summary "$3" \
    --silent "${4:-false}" >/dev/null || fail "append to the outcome store"
}

go_away() { FM_HOME="$H" "$CONTRACT" enter --words "away for a test" >/dev/null 2>&1 || fail "enter away"; }
go_quiet() { FM_HOME="$H" FM_AFK_MODE=quiet "$CONTRACT" enter >/dev/null 2>&1 || fail "enter quiet"; }
come_back() { FM_HOME="$H" "$CONTRACT" archive >/dev/null 2>&1 || fail "archive away record"; }

calls() { cat "$H/stub/calls" 2>/dev/null || echo 0; }
payload() { jq -r '.content' "$H/stub/payload.$1"; }
stub_mode() { printf '%s\n' "$@" > "$H/stub/mode"; }

test_help_and_usage() {
  use_home "$(make_home help)"
  run --help
  expect_code 0 "$RC" "help exit"
  assert_contains "$OUT" "fm-captain-alert.sh brief-line --since <epoch>" "help lists brief-line"
  run bogus
  expect_code 2 "$RC" "unknown action exit"
  pass "fm-captain-alert: help and usage"
}

test_arm_starts_at_the_store_tail_and_disarm_removes_everything() {
  use_home "$(make_home arm configured)"
  append old captain "historical decision"
  append old captain "historical decision two"
  go_away
  run arm
  expect_code 0 "$RC" "arm exit"
  assert_contains "$OUT" "cursor at outcome 2" "arm names the starting cursor"
  assert_present "$H/state/captain-alert.check.sh" "arm writes the shim"
  assert_present "$H/state/captain-alert.check-trust" "arm registers the shim"
  sweep
  assert_equals 0 "$(calls)" "nothing historical is posted at arm"
  run disarm
  expect_code 0 "$RC" "disarm exit"
  assert_absent "$H/state/captain-alert.check.sh" "disarm removes the shim"
  assert_absent "$H/state/captain-alert.check-trust" "disarm removes the trust binding"
  assert_absent "$H/state/.captain-alert" "disarm removes the record"
  pass "fm-captain-alert: arm starts at the store tail; disarm removes the check"
}

test_posts_only_while_away() {
  use_home "$(make_home gating configured)"
  run arm
  append attended captain "attended decision"
  sweep
  assert_equals 0 "$(calls)" "attended rows are not posted"
  go_quiet
  append quiet captain "quiet decision"
  sweep
  assert_equals 0 "$(calls)" "quiet-mode rows are not posted"
  come_back
  append before captain "recorded before entry"
  sleep 1
  go_away
  sweep
  assert_equals 0 "$(calls)" "rows recorded before the away entry are not posted at the next sweep"
  append alpha captain "decision on alpha: pick A or B"
  append alpha routine "routine progress"
  append alpha routine "nothing changed" true
  append beta captain "PR ready: https://github.com/example/repo/pull/1"
  sweep
  assert_equals 1 "$(calls)" "one post for the away sweep"
  local content
  content=$(payload 1)
  assert_contains "$content" "XO needs you (2):" "the headline counts the captain rows"
  assert_contains "$content" "- alpha: decision on alpha: pick A or B" "alpha is headlined"
  assert_contains "$content" "- beta: PR ready: https://github.com/example/repo/pull/1" "the PR URL is carried"
  assert_not_contains "$content" "routine progress" "routine rows are not posted"
  assert_equals "XO" "$(jq -r .username "$H/stub/payload.1")" "the sender is XO"
  assert_equals "4" "$(jq -r .flags "$H/stub/payload.1")" "embeds are suppressed and notifications are not"
  assert_equals "[]" "$(jq -c .allowed_mentions.parse "$H/stub/payload.1")" "no mention is parsed from text"
  assert_equals "" "$OUT" "a successful sweep prints nothing"
  come_back
  append gamma captain "after return"
  sweep
  assert_equals 1 "$(calls)" "rows after the return are not posted"
  pass "fm-captain-alert: posts only while the away posture stands"
}

test_burst_coalesces_cooldown_folds_and_cap_holds() {
  use_home "$(make_home burst configured)"
  run arm
  go_away
  local i
  for i in $(seq 1 80); do append loop captain "loop outcome $i"; done
  sweep
  assert_equals 1 "$(calls)" "an 80-row burst is one post"
  assert_contains "$(payload 1)" "XO needs you (80):" "the burst headline counts every row"
  assert_contains "$(payload 1)" "- loop: loop outcome 80 (+79 more)" "the burst headlines the latest summary"
  NOW=$((NOW0 + 300)); append loop captain "loop again"
  sweep
  assert_equals 1 "$(calls)" "a task inside its cooldown is not re-headlined"
  NOW=$((NOW0 + 600)); append other captain "decision on other"
  sweep
  assert_equals 2 "$(calls)" "a new task posts"
  assert_contains "$(payload 2)" "- other: decision on other" "the new task is headlined"
  assert_contains "$(payload 2)" "- +1 update on loop" "the cooled task is folded into a count"
  NOW=$((NOW0 + 3700)); append loop captain "loop after cooldown"
  sweep
  assert_equals 3 "$(calls)" "the task is headlined again after its cooldown"
  assert_contains "$(payload 3)" "- loop: loop after cooldown" "the cooled-down task is headlined"

  use_home "$(make_home cap configured)"
  run arm
  go_away
  EXTRA_ENV="FM_CAPTAIN_ALERT_COOLDOWN_SECS=0"
  for i in $(seq 1 9); do
    NOW=$((NOW0 + i * 300)); append "task$i" captain "decision $i"
    sweep
  done
  assert_equals 7 "$(calls)" "six posts plus one volume notice in the hour"
  assert_contains "$(payload 7)" "alert volume is high" "the seventh post is the volume notice"
  NOW=$((NOW0 + 300 + 3600 + 1)); sweep
  assert_equals 8 "$(calls)" "the waiting rows go out once the hour rolls"
  assert_contains "$(payload 8)" "XO needs you (3):" "the held rows are summarized, not lost"
  EXTRA_ENV=
  pass "fm-captain-alert: bursts coalesce, cooldown folds, and the hourly cap holds"
}

test_success_needs_a_message_id_and_transient_failures_retry() {
  use_home "$(make_home transient configured)"
  run arm
  go_away
  append alpha captain "decision on alpha"
  stub_mode noid
  sweep
  assert_equals "" "$OUT" "one transient failure prints nothing yet"
  assert_equals 1 "$(wc -l < "$H/state/.captain-alert-pending.jsonl" | tr -d ' ')" "the row stays queued without a message id"
  stub_mode net
  NOW=$((NOW0 + 300)); sweep
  assert_contains "$OUT" "captain alerts: Discord delivery failing since" "a second failing sweep reports"
  assert_equals 1 "$(wc -l < "$H/stub/fallback" | tr -d ' ')" "the fallback alarm fires once"
  NOW=$((NOW0 + 600)); sweep
  assert_equals "" "$OUT" "an unchanged failure is not reported again"
  assert_equals 1 "$(wc -l < "$H/stub/fallback" | tr -d ' ')" "the fallback alarm stays once per episode"
  stub_mode ok
  NOW=$((NOW0 + 900)); sweep
  assert_contains "$OUT" "captain alerts: Discord delivery is working again" "recovery is reported once"
  assert_contains "$(payload "$(calls)")" "- alpha: decision on alpha" "the queued row is delivered on recovery"
  NOW=$((NOW0 + 1200)); sweep
  assert_equals "" "$OUT" "after recovery the check is silent"
  stub_mode 500
  append beta captain "decision on beta"
  NOW=$((NOW0 + 1500)); sweep
  NOW=$((NOW0 + 1800)); sweep
  assert_contains "$OUT" "Discord server error" "a 5xx is transient and reported"
  assert_equals 2 "$(wc -l < "$H/stub/fallback" | tr -d ' ')" "a new episode fires the fallback again"
  pass "fm-captain-alert: success needs a message id; transient failures retry"
}

test_rate_limit_waits_once_when_it_fits() {
  use_home "$(make_home ratelimit configured)"
  run arm
  go_away
  append alpha captain "decision on alpha"
  stub_mode 429 ok
  sweep
  assert_equals 2 "$(calls)" "a short retry_after is retried once in the same sweep"
  assert_absent "$H/state/.captain-alert-pending.jsonl" "the retried post drains the queue"
  append beta captain "decision on beta"
  stub_mode 429long
  NOW=$((NOW0 + 300)); sweep
  assert_equals 3 "$(calls)" "a long retry_after is not waited out"
  assert_present "$H/state/.captain-alert-pending.jsonl" "the row waits for the next sweep"
  pass "fm-captain-alert: a rate limit waits once only when it fits"
}

test_permanent_rejection_stops_until_test_or_new_webhook() {
  use_home "$(make_home permanent configured)"
  run arm
  go_away
  append alpha captain "decision on alpha"
  stub_mode 404
  sweep
  assert_contains "$OUT" "webhook rejected: HTTP 404" "a 404 is reported on the first sweep"
  NOW=$((NOW0 + 300)); append beta captain "decision on beta"; sweep
  assert_equals 1 "$(calls)" "a rejected webhook is never retried"
  assert_equals "" "$OUT" "the rejection is not reported again"
  run reach
  assert_equals none "$OUT" "a rejected webhook gives the away entry no reach"
  printf 'FM_DISCORD_ALERT_WEBHOOK=https://discord.example.invalid/api/webhooks/2/%s\n' "$SECRET" > "$H/.env"
  stub_mode ok
  NOW=$((NOW0 + 600)); sweep
  assert_equals 2 "$(calls)" "a changed webhook value resumes posting"
  assert_contains "$(payload 2)" "XO needs you (2):" "the rows held during the rejection are summarized"
  stub_mode 404
  append gamma captain "decision on gamma"
  NOW=$((NOW0 + 900)); sweep
  stub_mode ok
  run test
  expect_code 0 "$RC" "test exit"
  assert_contains "$OUT" "Discord accepted message 9000" "test names the accepted message id"
  assert_contains "$OUT" "confirm it reached your phone" "test asks for the phone confirmation"
  assert_contains "$(payload "$(calls)")" "XO test alert" "the test message is labelled"
  run status
  assert_contains "$OUT" "failure: none" "a successful test clears the rejection"
  pass "fm-captain-alert: a permanent rejection stops posting until a test or a new webhook"
}

test_unconfigured_and_url_secrecy() {
  use_home "$(make_home unconfigured)"
  run arm
  assert_contains "$OUT" "FM_DISCORD_ALERT_WEBHOOK is not set" "arm notes the missing webhook"
  go_away
  append alpha captain "decision on alpha"
  sweep
  assert_contains "$OUT" "captain alerts: FM_DISCORD_ALERT_WEBHOOK is not set in .env" "an unconfigured armed home is reported"
  NOW=$((NOW0 + 300)); sweep
  assert_equals "" "$OUT" "and only once"
  run reach
  assert_equals none "$OUT" "an unconfigured notifier gives no reach"
  run test
  expect_code 1 "$RC" "test refuses without a webhook"

  local home
  for home in "$TMP_ROOT"/*/; do
    [ -d "$home/state" ] || continue
    if grep -rF "$SECRET" "$home/state" "$home/all-output" >/dev/null 2>&1; then
      fail "the webhook token leaked into state or output under $home"
    fi
    if [ -f "$home/stub/config" ]; then
      assert_grep "$SECRET" "$home/stub/config" "the URL reaches the transport on stdin"
      assert_grep "wait=true" "$home/stub/config" "the post waits for the created message"
    fi
  done
  pass "fm-captain-alert: unconfigured homes are reported and the URL never leaks"
}

test_mention_and_brief_detail() {
  use_home "$(make_home mention configured)"
  printf 'FM_DISCORD_ALERT_DETAIL=brief\nFM_DISCORD_ALERT_MENTION_USER_ID=123456\n' >> "$H/.env"
  run arm
  go_away
  append alpha captain "secret project detail @everyone"
  append beta captain "another"
  sweep
  local content
  content=$(payload 1)
  assert_contains "$content" "<@123456> XO needs you: 2 outcomes across 2 tasks; details wait in XO." "brief mode posts counts with the mention"
  assert_not_contains "$content" "secret project detail" "brief mode leaves summaries in XO"
  assert_equals '["123456"]' "$(jq -c .allowed_mentions.users "$H/stub/payload.1")" "only the configured user may be mentioned"
  run post "wedge alarm text"
  expect_code 0 "$RC" "post exit"
  assert_contains "$(payload 2)" "wedge alarm text" "post sends the given text"
  pass "fm-captain-alert: mention option and brief detail"
}

test_contract_reach_and_brief_line() {
  use_home "$(make_home reach configured)"
  go_away
  assert_equals none "$(FM_HOME="$H" "$CONTRACT" field reach_channels)" "an unarmed notifier records no reach"
  come_back
  run arm
  run test
  go_away
  assert_equals discord "$(FM_HOME="$H" "$CONTRACT" field reach_channels)" "an armed, configured notifier records discord reach"
  assert_contains "$(FM_HOME="$H" "$CONTRACT" readback)" "Notify-only: outcomes that need you are also posted to your XO Discord alerts channel (last confirmed test: 2027-01-15T08:00Z)" "the read-back names the notify-only reach and the test time"
  FM_HOME="$H" "$CONTRACT" validate >/dev/null 2>&1 || fail "a discord-reach record validates"
  come_back
  FM_HOME="$H" FM_AFK_MODE=quiet "$CONTRACT" enter >/dev/null 2>&1 || fail "enter quiet"
  assert_equals none "$(FM_HOME="$H" "$CONTRACT" field reach_channels)" "a quiet record never records reach"
  come_back
  go_away
  sed -i.bak 's/^reach_channels: .*/reach_channels: pager/' "$H/state/.afk-contract"
  if FM_HOME="$H" "$CONTRACT" validate >/dev/null 2>&1; then
    fail "an unknown reach value must be refused"
  fi
  mv "$H/state/.afk-contract.bak" "$H/state/.afk-contract"

  append alpha captain "decision on alpha"
  sweep
  run brief-line --since "$NOW0"
  assert_equals "Discord alerts: 1 posted during the away window" "$OUT" "the brief counts posts in the window"
  stub_mode 404
  append beta captain "decision on beta"
  NOW=$((NOW0 + 300)); sweep
  run brief-line --since "$NOW0"
  assert_contains "$OUT" "GAP: Discord alerts failing since" "a failing channel is a gap in the brief"
  assert_contains "$OUT" "1 outcomes not posted" "the gap counts what was not posted"
  pass "fm-captain-alert: the away record's reach and the return-brief line"
}

command -v jq >/dev/null 2>&1 || { pass "fm-captain-alert: jq unavailable; skipped"; exit 0; }

test_help_and_usage
test_arm_starts_at_the_store_tail_and_disarm_removes_everything
test_posts_only_while_away
test_burst_coalesces_cooldown_folds_and_cap_holds
test_success_needs_a_message_id_and_transient_failures_retry
test_rate_limit_waits_once_when_it_fits
test_permanent_rejection_stops_until_test_or_new_webhook
test_unconfigured_and_url_secrecy
test_mention_and_brief_detail
test_contract_reach_and_brief_line
