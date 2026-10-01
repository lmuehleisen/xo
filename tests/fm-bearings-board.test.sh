#!/usr/bin/env bash
# Behavior tests for bin/fm-bearings-board.sh: fail-closed payload validation,
# stale-card filtering, effective-payload round-trip through the built page,
# idempotent rebuild of the stable local HTML file, and the optional Lavish
# modes: the home toggle, the per-request override, view, and answers with
# bind-before-arm.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A real lavish-axi on the host must never answer for a stub, so every run
# below searches only the fixture's fakebin plus PATH without any directory
# that holds one.
TEST_PATH=$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r dir; do
  [ -n "$dir" ] && [ ! -e "$dir/lavish-axi" ] && printf '%s:' "$dir"
done)
TEST_PATH=${TEST_PATH%:}

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data"
  fm_fakebin "$home" >/dev/null
  printf '%s\n' "$home"
}

# A home with a lavish-axi stub at the pinned version, reproducing the shapes
# the real lavish-axi 0.1.80 prints: `status: opened` with the session URL,
# and a captain-ended session that a plain open refuses while EXITING 0 with
# `status: user-ended`; `--reopen` restores it. The stub records the
# environment each open ran with. Markers under lavish-state drive it:
# `user-ended` makes the next plain open refuse, and `refuse-reopen` makes even
# --reopen leave it ended. `poll` is a real blocking listener released by
# `poll-trigger`. `off-pin-once-open` makes --version report an off-pin version
# once a session exists, so the pin check at arm refuses after the page served.
make_lavish_home() {  # <name> [config/lavish mode]
  local home="$TMP_ROOT/$1" fakebin
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data" "$home/lavish-state" "$home/config"
  [ -z "${2-}" ] || printf '%s\n' "$2" > "$home/config/lavish"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u
state=${LAVISH_FAKE_STATE:?}
emit() {  # <canonical-file> <status>
  printf 'session:\n'
  printf '  file: %s\n' "$1"
  printf '  url: "http://127.0.0.1:4387/session/0123456789abcdef"\n'
  printf '  status: %s\n' "$2"
  printf 'next_step: "Now you must run lavish-axi poll"\n'
}
case "${1-}" in
  --version)
    if [ -e "$state/off-pin-once-open" ] && [ -e "$state/state.json" ]; then
      printf '0.1.81\n'
    else
      printf '%s\n' "${LAVISH_FAKE_VERSION:-0.1.80}"
    fi
    exit 0
    ;;
  poll)
    limit=${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}
    while [ ! -e "$state/poll-trigger" ]; do
      [ "$SECONDS" -lt "$limit" ] || exit 75
      sleep 0.05
    done
    printf 'session:\n  status: ended\n'
    exit 0
    ;;
esac
printf 'TELEMETRY=%s NO_OPEN=%s HOST=%s\n' "${LAVISH_AXI_TELEMETRY-unset}" \
  "${LAVISH_AXI_NO_OPEN-unset}" "${LAVISH_AXI_HOST-unset}" >> "$state/env"
file=$1
shift
reopen=0
for arg in "$@"; do [ "$arg" != --reopen ] || reopen=1; done
real=$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")
if [ -e "$state/refuse-reopen" ] || { [ -e "$state/user-ended" ] && [ "$reopen" = 0 ]; }; then
  emit "$real" user-ended
  exit 0
fi
rm -f -- "$state/user-ended"
jq -n --arg file "$real" \
  '{sessions:{"0123456789abcdef":{file:$file,url:"http://127.0.0.1:4387/session/0123456789abcdef"}}}' \
  > "$state/state.json"
emit "$real" opened
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

run_board() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$TEST_PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_FAKE_STATE="$home/lavish-state" LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" "$@"
}

run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$TEST_PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

run_hold() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$TEST_PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-captain-hold.sh" "$@"
}

board_source_id() {  # <home>
  local home=$1
  PATH="$home/fakebin:$TEST_PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$home/.lavish/bearings-board.html"
}

source_registered() {  # <home> <source-id>
  run_procevent "$1" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$2"
}

# A realistic payload: a cross-origin full-identity decision key past the old
# 64-char cap, a merge card, a dispatchable charted row, and a string that
# tries to terminate the data block early.
write_valid_payload() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-bearings-board.v1",
  "home": "test-home",
  "generated": "2026-08-19T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice",
      "type": "decision",
      "repo": "sample",
      "title": "Perishable-first admission",
      "about": "A payload string that tries to break out: </script><b>x</b>",
      "decide": "Adopt it?",
      "options": [
        { "value": "yes", "label": "Adopt", "hint": "recommended" },
        { "value": "no", "label": "Keep current" }
      ],
      "allow_freeform": true
    },
    {
      "key": "merge.sample-task",
      "type": "merge",
      "repo": "sample",
      "title": "Merge: sample change",
      "detail": "validation green",
      "task_id": "sample-task",
      "pr_url": "https://github.com/example/sample/pull/1",
      "checks": "green",
      "risk": "low",
      "options": [
        { "value": "merge", "label": "Merge now" },
        { "value": "hold", "label": "Not yet" }
      ],
      "allow_freeform": true
    }
  ],
  "underway": [],
  "landed": [],
  "charted": [
    { "id": "sample-queued", "repo": "sample", "title": "Queued work", "reason": "", "dispatchable": true }
  ],
  "charted_more": 0
}
EOF
}

# Extract the injected payload back out of a built board page.
extract_payload() {  # <board-path>
  sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$1" \
    | sed '1d;$d'
}

test_path_is_stable_and_home_scoped() {
  local home
  home=$(make_home path)
  [ "$(run_board "$home" path)" = "$home/.lavish/bearings-board.html" ] \
    || fail "the board path is not the stable home-scoped location"
  pass "path prints the stable home-scoped board location"
}

test_build_refuses_malformed_payloads_before_touching_the_board() {
  local home data board rc out
  home=$(make_home refusal)
  board="$home/.lavish/bearings-board.html"
  data="$home/payload.json"

  printf 'not json\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-JSON payload was accepted"
  assert_contains "$out" "not valid JSON" "the non-JSON refusal did not say why: $out"

  printf '{"schema":"fm-bearings-board.v2"}\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a wrong-schema payload was accepted"
  assert_contains "$out" "fm-bearings-board.v1" "the schema refusal did not name the contract: $out"

  write_valid_payload "$data"
  jq '.captains_call[0].key = (reduce range(129) as $i (""; . + "x"))' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a 129-char captains_call key was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].dispatchable)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a charted row without a dispatchable boolean was accepted"

  write_valid_payload "$data"
  jq '.charted[0].kind = "alarm"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown charted kind was accepted"

  write_valid_payload "$data"
  jq '.charted[0].kind = "warning"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a dispatchable warning row was accepted"

  write_valid_payload "$data"
  jq '.charted_warning_more = -1' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a negative omitted-warning count was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].subject = {"artifact":"quota-axi","version":"0.1"}' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an invalid structured version subject was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].type = "verdict"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown captains_call type was accepted"

  write_valid_payload "$data"
  jq 'del(.captains_call[0].options[0].value)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option without an answer value was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].options[0].label = ""' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option with an empty label was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].repo)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a fleet row without an explicit repo marker was accepted"

  write_valid_payload "$data"
  jq '.underway = [{"id":"sample-task","repo":"sample","state":"working",
    "kind":"ship","doing":"implementing"}]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an underway row without an explicit name marker was accepted"

  for invalid_filed in "last Tuesday" "2026-13-01" "2026-08-14T99:30:00Z" "2026-02-29"; do
    write_valid_payload "$data"
    jq --arg filed "$invalid_filed" '.charted[0].filed = $filed' "$data" > "$data.tmp" \
      && mv "$data.tmp" "$data"
    set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
    [ "$rc" -ne 0 ] || fail "an invalid filed date was accepted: $invalid_filed"
  done

  write_valid_payload "$data"
  jq '.captains_call[0].allow_freeform = "yes"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-boolean renderer field was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].options = [] | .captains_call[0].allow_freeform = false' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unanswerable captains_call item was accepted"

  write_valid_payload "$data"
  jq '.captains_call[1].pr_url = "javascript:alert(1)"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Captain’s Call PR URL was accepted"

  write_valid_payload "$data"
  jq '.landed = [{
    "id": "sample-landed",
    "repo": "sample",
    "what": "Landed work",
    "owner": "firstmate",
    "pr_url": "data:text/html,unsafe"
  }]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Landed PR URL was accepted"

  assert_absent "$board" "a refused payload still produced a board"
  pass "build refuses malformed payloads before touching the board"
}

test_build_injects_effective_payload_locally() {
  local home data board out
  home=$(make_home build)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"

  out=$(run_board "$home" build "$data") || fail "a valid payload did not build"
  assert_contains "$out" "board: $board" "build did not report the board path: $out"
  assert_contains "$out" "served: $board" "build did not report the served board: $out"
  assert_contains "$out" "open: $board" "build did not report the local HTML path: $out"
  assert_not_contains "$out" "bound: " "build still bound a Lavish answer source: $out"
  assert_not_contains "$out" "armed: " "build still armed a Lavish process-event source: $out"
  assert_present "$board" "build reported success without a board"

  # With no stale cards, the effective payload is the input payload exactly.
  # The escaped </script> string can no longer terminate the data block.
  extract_payload "$board" | jq -S . > "$home/extracted.json" \
    || fail "the built board does not carry parseable payload JSON"
  jq -S . "$data" > "$home/expected.json"
  diff -u "$home/expected.json" "$home/extracted.json" >/dev/null \
    || fail "the injected payload does not round-trip to the input document"
  grep -qF '</script><b>' "$board" \
    && fail "a payload string embedded a live closing script tag in the page"
  grep -qxF '__FM_BEARINGS_BOARD_DATA__' "$board" \
    && fail "the data slot survived injection"

  pass "build injects the payload into a local HTML board without Lavish"
}

test_build_registers_no_answer_source() {
  local home data board out
  home=$(make_home order-proof)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  out=$(run_board "$home" build "$data") || fail "the order-proof board build failed"
  assert_present "$board" "build did not write the board"
  assert_not_contains "$out" "bound: " "build bound a Lavish source: $out"
  assert_not_contains "$out" "armed: " "build armed a Lavish source: $out"
  [ ! -d "$home/state/procevent" ] \
    || [ -z "$(find "$home/state/procevent" -name '*.source' 2>/dev/null)" ] \
    || fail "build registered a process-event source"
  pass "board build does not arm Lavish or consume answers"
}

test_build_does_not_invoke_lavish() {
  local home data out
  home=$(make_home no-lavish)
  data="$home/payload.json"
  write_valid_payload "$data"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOME/lavish-was-invoked"
exit 91
SH
  chmod +x "$home/fakebin/lavish-axi"

  out=$(run_board "$home" build "$data" 2>&1) || fail "build invoked or required Lavish: $out"
  assert_present "$home/.lavish/bearings-board.html" "build did not write the board without Lavish"
  assert_absent "$home/lavish-was-invoked" "build invoked lavish-axi"
  assert_not_contains "$out" "bound: " "build bound a Lavish source without Lavish: $out"
  assert_not_contains "$out" "armed: " "build armed a Lavish source without Lavish: $out"
  pass "build writes the local HTML board without invoking Lavish"
}

test_rebuild_is_idempotent_and_refreshes_in_place() {
  local home data board out records
  home=$(make_home rearm)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"

  jq '.generated = "2026-08-19T01:00Z"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data") || fail "the rebuild failed"
  assert_contains "$out" "board: $board" "the rebuild did not report the board: $out"
  extract_payload "$board" | jq -e '.generated == "2026-08-19T01:00Z"' >/dev/null \
    || fail "the rebuild did not refresh the board payload in place"
  records=$(find "$home/state/procevent" -name '*.source' 2>/dev/null | wc -l | tr -d ' ')
  [ "$records" = 0 ] || fail "rebuilding registered $records Lavish sources"
  pass "rebuild refreshes the board in place without Lavish"
}

test_build_refuses_a_template_without_exactly_one_slot() {
  local home data rc out
  home=$(make_home badslot)
  data="$home/payload.json"
  write_valid_payload "$data"
  printf '<html><body>no slot</body></html>\n' > "$home/broken-template.html"
  set +e
  out=$(FM_BEARINGS_BOARD_TEMPLATE="$home/broken-template.html" run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a template with no data slot was accepted"
  assert_contains "$out" "data slot" "the slot refusal did not say why: $out"
  assert_absent "$home/.lavish/bearings-board.html" "a refused template still produced a board"
  pass "build refuses a template without exactly one data slot"
}

test_charted_kind_is_optional_and_accepts_both_values() {
  local home data
  home=$(make_home chartedkind)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.charted = [
        {"id":"a","repo":"sample","title":"Queued","reason":"","dispatchable":true},
        {"id":"b","repo":"sample","title":"Queued too","reason":"gated","dispatchable":true,"kind":"queued"},
        {"id":"c","repo":"sample","title":"Integrity notice","reason":"main inventory","dispatchable":false,"kind":"warning"}
      ] | .charted_warning_more = 2' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null \
    || fail "an omitted, queued, and warning charted kind was refused"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    ([.charted[] | .kind // "queued"]) == ["queued", "queued", "warning"]
      and .charted_warning_more == 2
  ' >/dev/null || fail "the built board did not carry the charted kinds and omitted-warning count it was given"
  pass "charted kind is optional and accepts queued and warning"
}

# --- A landed subject is not a live call -------------------------------------

test_build_drops_decision_cards_whose_subject_already_landed() {
  local home data board out
  home=$(make_home landed-cards)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  jq '.captains_call = [
        {"key":"landed-by-task","type":"decision","repo":"sample","title":"Already shipped",
         "options":[{"value":"yes","label":"Yes"}]},
        {"key":"timeout-reattach","type":"decision","repo":"sample","title":"Already merged",
         "pr_url":"https://github.com/sample/sample/pull/7",
         "options":[{"value":"yes","label":"Yes"}]},
        {"key":"quota-version","type":"decision","repo":"sample","title":"Old quota release",
         "subject":{"artifact":"quota-axi","version":"0.1.37"},
         "options":[{"value":"yes","label":"Yes"}]},
        {"key":"still-open","type":"decision","repo":"sample","title":"Genuinely open",
         "subject":{"artifact":"quota-axi","version":"0.2.0"},
         "options":[{"value":"yes","label":"Yes"}]}
      ]
      | .landed = [
        {"id":"landed-by-task","repo":"sample","what":"shipped it","owner":"crew"},
        {"id":"some-other-task","repo":"sample","what":"merged timeout reattach","owner":"crew",
         "pr_url":"https://github.com/sample/sample/pull/7"},
        {"id":"quota-release","repo":"sample","what":"published quota-axi","owner":"crew",
         "subject":{"artifact":"quota-axi","version":"0.1.38"}},
        {"id":"unrelated\nstill-open","repo":"sample","what":"unrelated multiline identity","owner":"crew"}
      ]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  out=$(run_board "$home" build "$data" 2>&1) || fail "the hygiene build failed: $out"
  assert_contains "$out" "dropped-landed-card: landed-by-task" \
    "the build did not report dropping the landed work item card: $out"
  assert_contains "$out" "dropped-landed-card: timeout-reattach" \
    "the build did not report dropping the merged timeout/reattach card: $out"
  assert_contains "$out" "dropped-landed-card: quota-version" \
    "the build did not report dropping the superseded quota-axi version card: $out"
  extract_payload "$board" | jq -S . > "$home/extracted.json" \
    || fail "the stale-filtered board does not carry parseable payload JSON"
  jq -S '.captains_call = [.captains_call[] | select(.key == "still-open")]' \
    "$data" > "$home/expected.json"
  diff -u "$home/expected.json" "$home/extracted.json" >/dev/null \
    || fail "the embedded effective payload changed more than the stale cards"
  pass "build drops landed decision cards and round-trips the effective payload"
}

test_build_keeps_a_decision_absent_from_the_main_backlog() {
  local home data board out
  home=$(make_home remote-decision-card)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  write_valid_payload "$data"
  jq '.captains_call = [{
        "key":"remote-mate-call","type":"decision","repo":"sample",
        "title":"Remote secondmate decision",
        "options":[{"value":"yes","label":"Yes"}]
      }]
      | .landed = []' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  out=$(run_board "$home" build "$data" 2>&1) || fail "the remote-card build failed: $out"
  assert_not_contains "$out" "dropped-landed-card: remote-mate-call" \
    "an absent remote card was reported as landed: $out"
  extract_payload "$board" | jq -e '
    [.captains_call[] | select(.key == "remote-mate-call")] | length == 1
  ' >/dev/null || fail "the hygiene check dropped a decision absent from the main backlog"
  pass "build keeps remote decisions absent from the main backlog"
}

# --- The read-only board exposes no reconcile control ------------------------

test_build_refuses_a_payload_that_occupies_the_reconcile_value() {
  local home data rc out
  home=$(make_home reconcile-reserved)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call[0].options += [{"value":"reconcile","label":"Something else"}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e
  out=$(run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a payload occupying the reserved reconcile value was accepted"
  assert_absent "$home/.lavish/bearings-board.html" "a refused payload still produced a board"
  pass "build refuses a payload that occupies the reserved reconcile value"
}

test_build_refuses_a_nondecision_reconcile_value() {
  local home data rc out
  home=$(make_home merge-reconcile-reserved)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call[1].options += [{"value":"reconcile","label":"Merge action"}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e
  out=$(run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a merge card occupying the reconcile value was accepted"
  assert_absent "$home/.lavish/bearings-board.html" "a refused merge card still produced a board"
  pass "build reserves reconcile across non-decision cards"
}

test_view_mode_opens_the_read_only_board_in_lavish() {
  local home data board out
  home=$(make_lavish_home view view)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"

  out=$(run_board "$home" build "$data") || fail "a view-mode build failed: $out"
  assert_contains "$out" "session: live" "view mode did not establish a Lavish session: $out"
  assert_contains "$out" "url: http://127.0.0.1:4387/session/0123456789abcdef" "view mode did not print the session URL: $out"
  assert_contains "$out" "open: http://127.0.0.1:4387/session/0123456789abcdef" "view mode did not open the session URL: $out"
  assert_not_contains "$out" "next_step" "build echoed lavish-axi's agent instructions: $out"
  assert_not_contains "$out" "bound: " "view mode bound an answer source: $out"
  assert_not_contains "$out" "armed: " "view mode armed an answer source: $out"
  extract_payload "$board" | jq -e 'has("interactive") | not' >/dev/null \
    || fail "a view-mode board was made interactive"
  extract_payload "$board" | jq -e '[.captains_call[].options[].value] | index("reconcile") == null' >/dev/null \
    || fail "a view-mode board carries the answers-only reconcile choice"
  [ "$(cat "$home/lavish-state/env")" = "TELEMETRY=0 NO_OPEN=1 HOST=127.0.0.1" ] \
    || fail "lavish-axi did not run under the pinned environment: $(cat "$home/lavish-state/env")"
  pass "view mode opens the read-only board in Lavish under the pinned environment"
}

test_per_request_override_wins_over_the_home_toggle() {
  local home data out
  home=$(make_lavish_home decline view)
  data="$home/payload.json"
  write_valid_payload "$data"
  out=$(run_board "$home" build "$data" --lavish off) || fail "a declined build failed: $out"
  assert_contains "$out" "open: $home/.lavish/bearings-board.html" "--lavish off did not keep the static board: $out"
  assert_absent "$home/lavish-state/env" "--lavish off still invoked lavish-axi"

  home=$(make_lavish_home ask)
  data="$home/payload.json"
  write_valid_payload "$data"
  out=$(run_board "$home" build "$data" --lavish view) || fail "a requested build failed: $out"
  assert_contains "$out" "session: live" "--lavish view on an off home did not open Lavish: $out"
  pass "a per-request --lavish override wins over the home toggle in both directions"
}

test_unavailable_lavish_falls_back_to_the_static_board() {
  local home data out
  home=$(make_lavish_home missing view)
  data="$home/payload.json"
  write_valid_payload "$data"
  rm -f "$home/fakebin/lavish-axi"
  out=$(run_board "$home" build "$data") || fail "a build without lavish-axi failed: $out"
  assert_contains "$out" "lavish: off (lavish-axi is not installed; install: npm install -g --ignore-scripts lavish-axi@0.1.80)" \
    "a missing lavish-axi was not reported with the hook-free install: $out"
  assert_contains "$out" "open: $home/.lavish/bearings-board.html" "a missing lavish-axi did not keep the static board: $out"

  home=$(make_lavish_home off-pin answers)
  data="$home/payload.json"
  write_valid_payload "$data"
  out=$(LAVISH_FAKE_VERSION=0.1.81 run_board "$home" build "$data") || fail "an off-pin build failed: $out"
  assert_contains "$out" "lavish: off (lavish-axi 0.1.81 is installed but this home is pinned to 0.1.80" \
    "an off-pin lavish-axi was not refused: $out"
  assert_not_contains "$out" "bound: " "an off-pin lavish-axi still bound answers: $out"
  pass "an unavailable or off-pin lavish-axi keeps the static board and says why"
}

test_malformed_toggle_refuses_before_touching_the_board() {
  local home data out
  home=$(make_lavish_home malformed sometimes)
  data="$home/payload.json"
  write_valid_payload "$data"
  if out=$(run_board "$home" build "$data" 2>&1); then
    fail "a malformed config/lavish built a board: $out"
  fi
  assert_contains "$out" "config/lavish must be off, view, or answers" "the malformed toggle was not named: $out"
  assert_absent "$home/.lavish/bearings-board.html" "a malformed toggle still produced a board"
  if out=$(run_board "$home" build "$data" --lavish maybe 2>&1); then
    fail "a malformed request built a board: $out"
  fi
  home=$(make_lavish_home empty-request answers)
  data="$home/payload.json"
  write_valid_payload "$data"
  if out=$(run_board "$home" build "$data" --lavish= 2>&1); then
    fail "an empty request built a board: $out"
  fi
  assert_contains "$out" "got an empty value" "the empty request was not named: $out"
  assert_absent "$home/.lavish/bearings-board.html" "an empty request still produced a board"
  pass "a malformed toggle or request refuses before the board is touched"
}

test_answers_mode_binds_then_arms() {
  local home data board out sid
  home=$(make_lavish_home answers answers)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"

  out=$(run_board "$home" build "$data") || fail "an answers-mode build failed: $out"
  sid=$(board_source_id "$home")
  assert_contains "$out" "bound: $sid" "answers mode did not bind the board source: $out"
  assert_contains "$out" "armed: $sid" "answers mode did not arm the board source: $out"
  [ "$(run_hold "$home" binding "$sid")" = "(any)" ] || fail "the board source is not bound any-origin"
  source_registered "$home" "$sid" || fail "the board source is not registered after build"
  extract_payload "$board" | jq -e '.interactive == true' >/dev/null \
    || fail "an answers-mode board is not interactive"
  extract_payload "$board" | jq -e '
    [.captains_call[] | select(.type == "decision") | .options[-1].value] | all(. == "reconcile")' >/dev/null \
    || fail "a decision card lacks the reconcile choice"
  extract_payload "$board" | jq -e '
    [.captains_call[] | select(.type != "decision") | .options[].value] | index("reconcile") == null' >/dev/null \
    || fail "a non-decision card received the reconcile choice"

  assert_contains "$out" "answers: open" "the answer controls were not reported published: $out"
  out=$(run_board "$home" build "$data") || fail "an answers-mode rebuild failed: $out"
  assert_contains "$out" "already-armed: $sid" "a rebuild re-armed an already registered source: $out"
  pass "answers mode makes decision cards answerable, binds, then arms once"
}

test_answers_mode_does_not_bind_or_arm_when_the_session_stays_ended() {
  local home data sid
  home=$(make_lavish_home ended answers)
  data="$home/payload.json"
  write_valid_payload "$data"
  : > "$home/lavish-state/refuse-reopen"
  if run_board "$home" build "$data" >/dev/null 2>&1; then
    fail "build served a board whose session stayed ended"
  fi
  sid=$(board_source_id "$home")
  ! run_hold "$home" binding "$sid" >/dev/null 2>&1 \
    || fail "build bound the board while its session was ended"
  ! source_registered "$home" "$sid" || fail "build armed the board while its session was ended"
  pass "answers mode never binds or arms a board whose session stays ended"
}

test_answers_mode_keeps_controls_hidden_until_listening() {
  local home data board out
  home=$(make_lavish_home no-listener answers)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  : > "$home/lavish-state/off-pin-once-open"
  if out=$(run_board "$home" build "$data" 2>&1); then
    fail "an answers build succeeded without a listener: $out"
  fi
  assert_contains "$out" "cannot arm the board" "the build did not fail at arming: $out"
  assert_not_contains "$out" "answers: open" "answer controls were reported published without a listener: $out"
  assert_present "$board" "the read-only page was not served while answers were pending"
  extract_payload "$board" | jq -e 'has("interactive") | not' >/dev/null \
    || fail "the board exposed answer controls before its listener was confirmed"
  extract_payload "$board" | jq -e '[.captains_call[].options[].value] | index("reconcile") == null' >/dev/null \
    || fail "the read-only page carried the reconcile choice"
  grep -qF '</script><b>' "$board" \
    && fail "the read-only page embedded a live closing script tag"
  [ -z "$(find "$home/.lavish" -name '.board.*')" ] || fail "a failed answers build left a staged page behind"
  pass "answers mode serves the board read-only until its source is bound and listening"
}

test_answers_mode_reopens_a_session_the_captain_ended() {
  local home data out
  home=$(make_lavish_home reopen answers)
  data="$home/payload.json"
  write_valid_payload "$data"
  : > "$home/lavish-state/user-ended"
  out=$(run_board "$home" build "$data") || fail "the build refused a recoverable ended session: $out"
  assert_contains "$out" "session: reopened" "the build did not reopen the ended session: $out"
  assert_contains "$out" "armed: " "the reopened board was not armed: $out"
  pass "answers mode reopens a session the captain ended once, then arms it"
}

test_dropping_below_answers_retires_the_answer_source() {
  local home data out sid
  home=$(make_lavish_home downgrade answers)
  data="$home/payload.json"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the answers build failed"
  sid=$(board_source_id "$home")
  source_registered "$home" "$sid" || fail "the answers build did not register its source"

  out=$(run_board "$home" build "$data" --lavish view) || fail "the view rebuild failed: $out"
  assert_contains "$out" "retired: $sid" "declining answers did not retire the source: $out"
  ! run_hold "$home" binding "$sid" >/dev/null 2>&1 || fail "declining answers left the binding"
  ! source_registered "$home" "$sid" || fail "declining answers left the source registered"
  out=$(run_board "$home" build "$data" --lavish view) || fail "a second view rebuild failed: $out"
  assert_not_contains "$out" "retired: " "a view rebuild with nothing bound reported a retirement: $out"

  # A binding that cannot be removed refuses the downgrade and keeps the
  # earlier board, because that binding is what lets an open page change tasks.
  # A read-only directory cannot stop root, so root skips only this case.
  if [ "$(id -u)" = 0 ]; then
    pass "a build below answers retires and unbinds an earlier answer source"
    return 0
  fi
  run_board "$home" build "$data" >/dev/null || fail "the second answers build failed"
  [ "$(run_hold "$home" binding "$sid")" = "(any)" ] || fail "the second answers build did not bind"
  chmod a-w "$home/state/decision-bindings"
  if out=$(run_board "$home" build "$data" --lavish off 2>&1); then
    chmod u+w "$home/state/decision-bindings"
    fail "a downgrade succeeded while its binding could not be removed: $out"
  fi
  chmod u+w "$home/state/decision-bindings"
  assert_contains "$out" "refusing to drop below answers" "the refused downgrade was not explained: $out"
  [ "$(run_hold "$home" binding "$sid")" = "(any)" ] || fail "the refused downgrade lost the binding"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '.interactive == true' >/dev/null \
    || fail "the refused downgrade replaced the earlier board"
  pass "a build below answers retires and unbinds an earlier answer source"
}

test_path_is_stable_and_home_scoped
test_build_refuses_malformed_payloads_before_touching_the_board
test_charted_kind_is_optional_and_accepts_both_values
test_build_injects_effective_payload_locally
test_build_registers_no_answer_source
test_build_does_not_invoke_lavish
test_rebuild_is_idempotent_and_refreshes_in_place
test_build_refuses_a_template_without_exactly_one_slot
test_build_drops_decision_cards_whose_subject_already_landed
test_build_keeps_a_decision_absent_from_the_main_backlog
test_build_refuses_a_payload_that_occupies_the_reconcile_value
test_build_refuses_a_nondecision_reconcile_value
test_view_mode_opens_the_read_only_board_in_lavish
test_per_request_override_wins_over_the_home_toggle
test_unavailable_lavish_falls_back_to_the_static_board
test_malformed_toggle_refuses_before_touching_the_board
test_answers_mode_binds_then_arms
test_answers_mode_does_not_bind_or_arm_when_the_session_stays_ended
test_answers_mode_keeps_controls_hidden_until_listening
test_answers_mode_reopens_a_session_the_captain_ended
test_dropping_below_answers_retires_the_answer_source
