#!/usr/bin/env bash
# Behavior tests for bin/fm-lavish.sh: the home toggle, the per-request
# override, availability against the pinned version, the pinned environment,
# and the refused hook, update, and share subcommands.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAVISH="$ROOT/bin/fm-lavish.sh"
TMP_ROOT=$(fm_test_tmproot fm-lavish)

# A real lavish-axi on the host must never answer for the stub.
TEST_PATH=$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r dir; do
  [ -n "$dir" ] && [ ! -e "$dir/lavish-axi" ] && printf '%s:' "$dir"
done)
TEST_PATH=${TEST_PATH%:}

# A home whose lavish-axi stub reports LAVISH_FAKE_VERSION (default the pin)
# and records each non-version invocation's arguments and environment.
make_home() {  # <name> [config/lavish mode]
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/config"
  [ -z "${2-}" ] || printf '%s\n' "$2" > "$home/config/lavish"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1-}" = --version ]; then
  printf '%s\n' "${LAVISH_FAKE_VERSION:-0.1.80}"
  exit 0
fi
printf 'args=%s TELEMETRY=%s NO_OPEN=%s HOST=%s\n' "$*" "${LAVISH_AXI_TELEMETRY-unset}" \
  "${LAVISH_AXI_NO_OPEN-unset}" "${LAVISH_AXI_HOST-unset}"
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

run_lavish() {  # <home> <args...>
  local home=$1
  shift
  env -u LAVISH_AXI_HOST -u LAVISH_AXI_TELEMETRY -u LAVISH_AXI_NO_OPEN \
    PATH="$home/fakebin:$TEST_PATH" FM_HOME="$home" "$LAVISH" "$@"
}

test_home_toggle_defaults_off_and_reads_each_mode() {
  local home mode
  home=$(make_home default)
  [ "$(run_lavish "$home" mode)" = off ] || fail "an absent config/lavish is not off"
  for mode in off view answers; do
    printf '%s\n' "$mode" > "$home/config/lavish"
    [ "$(run_lavish "$home" mode)" = "$mode" ] || fail "config/lavish=$mode was not read back"
  done
  pass "the home toggle defaults to off and reads off, view, and answers"
}

test_malformed_toggle_and_request_exit_2() {
  local home rc
  home=$(make_home malformed often)
  rc=0; run_lavish "$home" mode >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a malformed config/lavish exited $rc, not 2"
  rc=0; run_lavish "$home" resolve >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "resolve over a malformed config/lavish exited $rc, not 2"
  home=$(make_home spaced)
  printf 'a n s w e r s\n' > "$home/config/lavish"
  rc=0; run_lavish "$home" mode >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a mode word with internal whitespace exited $rc, not 2"
  : > "$home/config/lavish"
  rc=0; run_lavish "$home" mode >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "an empty config/lavish exited $rc, not 2"
  printf '  view  \n' > "$home/config/lavish"
  [ "$(run_lavish "$home" mode)" = view ] || fail "a mode word with surrounding whitespace was not read"
  home=$(make_home bad-request)
  rc=0; run_lavish "$home" resolve --lavish yes >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a malformed request exited $rc, not 2"
  printf 'answers\n' > "$home/config/lavish"
  rc=0; run_lavish "$home" resolve --lavish= >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "an empty request exited $rc, not 2"
  pass "a malformed toggle or request exits 2 instead of guessing"
}

test_request_overrides_the_home_toggle_both_ways() {
  local home out
  home=$(make_home declines answers)
  out=$(run_lavish "$home" resolve --lavish off) || fail "resolve --lavish off failed"
  assert_contains "$out" "mode: off" "--lavish off did not decline: $out"
  assert_contains "$out" "wanted: off (request)" "the request was not named as the source: $out"

  home=$(make_home asks)
  out=$(run_lavish "$home" resolve --lavish answers) || fail "resolve --lavish answers failed"
  assert_contains "$out" "mode: answers" "--lavish answers on an off home did not resolve to answers: $out"

  out=$(run_lavish "$home" resolve) || fail "plain resolve failed"
  assert_contains "$out" "mode: off" "an absent toggle did not resolve to off: $out"
  assert_contains "$out" "wanted: off (home)" "the home toggle was not named as the source: $out"
  pass "a per-request mode wins over the home toggle in both directions"
}

test_unavailable_or_off_pin_resolves_off_with_a_reason() {
  local home out
  home=$(make_home missing view)
  rm -f "$home/fakebin/lavish-axi"
  out=$(run_lavish "$home" resolve) || fail "resolve failed without lavish-axi"
  assert_contains "$out" "mode: off" "a missing lavish-axi did not resolve off: $out"
  assert_contains "$out" "reason: lavish-axi is not installed; install: npm install -g --ignore-scripts lavish-axi@0.1.80" \
    "the missing binary was not explained with the hook-free install: $out"

  home=$(make_home off-pin view)
  out=$(LAVISH_FAKE_VERSION=0.1.79 run_lavish "$home" resolve) || fail "resolve failed off-pin"
  assert_contains "$out" "mode: off" "an off-pin lavish-axi did not resolve off: $out"
  assert_contains "$out" "lavish-axi 0.1.79 is installed but this home is pinned to 0.1.80" \
    "the off-pin version was not explained: $out"
  pass "an unavailable or off-pin lavish-axi resolves off and says why"
}

test_run_refuses_hooks_updates_and_sharing() {
  local home sub out
  home=$(make_home refuse view)
  for sub in setup update share; do
    if out=$(run_lavish "$home" run "$sub" hooks 2>&1); then
      fail "run $sub was allowed: $out"
    fi
    assert_contains "$out" "refusing 'lavish-axi $sub'" "run $sub was not refused by name: $out"
    assert_not_contains "$out" "args=" "run $sub reached lavish-axi: $out"
  done
  if out=$(run_lavish "$home" run --json setup plugin 2>&1); then
    fail "a flag-prefixed setup was allowed: $out"
  fi
  if out=$(run_lavish "$home" run --port 4387 setup hooks 2>&1); then
    fail "setup behind an option value was allowed: $out"
  fi
  assert_contains "$out" "refusing 'lavish-axi setup'" "setup behind an option value was not refused by name: $out"
  pass "run refuses setup, update, and share before lavish-axi starts"
}

test_run_pins_the_environment() {
  local home out
  home=$(make_home pinned)
  out=$(run_lavish "$home" run board.html) || fail "run failed: $out"
  [ "$out" = "args=board.html TELEMETRY=0 NO_OPEN=1 HOST=127.0.0.1" ] \
    || fail "run did not default to loopback with telemetry and auto-open off: $out"

  out=$(LAVISH_AXI_TELEMETRY=1 LAVISH_AXI_NO_OPEN=0 \
    PATH="$home/fakebin:$TEST_PATH" FM_HOME="$home" "$LAVISH" run board.html) || fail "run failed: $out"
  assert_contains "$out" "TELEMETRY=0 NO_OPEN=1" "an ambient opt-in overrode the pin: $out"

  out=$(LAVISH_AXI_HOST=0.0.0.0 PATH="$home/fakebin:$TEST_PATH" FM_HOME="$home" "$LAVISH" run board.html) \
    || fail "run failed with an ambient host: $out"
  assert_contains "$out" "HOST=127.0.0.1" "an ambient LAVISH_AXI_HOST widened the bound address: $out"

  printf '%s\n' 10.0.0.5 > "$home/config/lavish-axi-host"
  out=$(run_lavish "$home" run board.html) || fail "run failed with a host file: $out"
  assert_contains "$out" "HOST=10.0.0.5" "config/lavish-axi-host did not set the host: $out"
  printf 'two words\n' > "$home/config/lavish-axi-host"
  if out=$(run_lavish "$home" run board.html 2>&1); then
    fail "a malformed config/lavish-axi-host was accepted: $out"
  fi
  pass "run pins telemetry off, auto-open off, and the configured or loopback host"
}

test_run_refuses_an_off_pin_binary() {
  local home out
  home=$(make_home run-off-pin)
  if out=$(LAVISH_FAKE_VERSION=0.2.0 run_lavish "$home" run board.html 2>&1); then
    fail "run used an off-pin lavish-axi: $out"
  fi
  assert_contains "$out" "pinned to 0.1.80" "the off-pin refusal did not name the pin: $out"
  pass "run refuses an off-pin lavish-axi"
}

# The process-event adapter enforces the same pin at registration and at every
# listener start, so a source armed before an upgrade cannot restart on it.
test_adapter_refuses_an_off_pin_binary() {
  local home out
  home=$(make_home adapter-off-pin)
  mkdir -p "$home/state" "$home/art"
  printf '<html></html>\n' > "$home/art/board.html"
  if out=$(LAVISH_FAKE_VERSION=0.1.81 PATH="$home/fakebin:$TEST_PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-procevent-lavish.sh" arm "$home/art/board.html" 2>&1); then
    fail "the adapter armed a board on an off-pin lavish-axi: $out"
  fi
  assert_contains "$out" "pinned to 0.1.80" "the arm refusal did not name the pin: $out"
  if out=$(LAVISH_FAKE_VERSION=0.1.81 PATH="$home/fakebin:$TEST_PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-procevent-lavish.sh" poll "$home/art/board.html" 2>&1); then
    fail "a listener started on an off-pin lavish-axi: $out"
  fi
  assert_contains "$out" "pinned to 0.1.80" "the poll refusal did not name the pin: $out"
  assert_not_contains "$out" "args=" "the off-pin lavish-axi was invoked: $out"

  # A malformed host file never makes an on-pin binary look unavailable to a
  # listener start, which routes by the board's own saved session.
  printf 'two words\n' > "$home/config/lavish-axi-host"
  out=$(PATH="$home/fakebin:$TEST_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    LAVISH_AXI_STATE_DIR="$home/no-sessions" "$ROOT/bin/fm-procevent-lavish.sh" poll "$home/art/board.html" 2>&1) || true
  assert_not_contains "$out" "pinned to" "a malformed host file made the on-pin binary look unavailable: $out"
  assert_contains "$out" "cannot resolve the board server from its Lavish session" \
    "the listener start did not reach session routing: $out"
  pass "the process-event adapter refuses an off-pin lavish-axi at arm and at every listener start"
}

test_install_command_is_pinned_and_hook_free() {
  local out
  out=$("$LAVISH" install-command)
  [ "$out" = "npm install -g --ignore-scripts lavish-axi@0.1.80" ] \
    || fail "the install command is not the pinned hook-free form: $out"
  pass "the install command pins the version and runs no setup"
}

test_home_toggle_defaults_off_and_reads_each_mode
test_malformed_toggle_and_request_exit_2
test_request_overrides_the_home_toggle_both_ways
test_unavailable_or_off_pin_resolves_off_with_a_reason
test_run_refuses_hooks_updates_and_sharing
test_run_pins_the_environment
test_run_refuses_an_off_pin_binary
test_adapter_refuses_an_off_pin_binary
test_install_command_is_pinned_and_hook_free
