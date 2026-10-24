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
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

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
  # The sample decision card's call is held open in this home's own backlog.
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice - Perishable-first admission (repo: sample) (kind: captain) (hold: Adopt it?) (hold-kind: captain)
  Captain hold set: 2026-08-19T00:00:00Z

## Done
EOF
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
  end) : > "$state/ended"; printf 'session:\n  status: ended\n'; exit 0 ;;
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
  local home=$1 state
  shift
  state=${FM_TEST_BOARD_STATE:-$home/state}
  PATH="$home/fakebin:$TEST_PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_FAKE_STATE="$home/lavish-state" LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" "$@"
}

run_board_timed() {  # <seconds> <home> <args...>
  local seconds=$1 home=$2 state
  shift 2
  state=${FM_TEST_BOARD_STATE:-$home/state}
  fm_run_timed "$seconds" env PATH="$home/fakebin:$TEST_PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" \
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

# Whether this host can read the held call at all; without a compatible
# tasks-axi the build keeps every card display-only, the safe direction.
held_call_readable() {  # <home>
  run_hold "$1" open sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice \
    --distinguish-absent >/dev/null 2>&1
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
      "owner": "(main)",
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
write_snapshot_stub() {  # <home>; a canonical-snapshot shape for the refresh tests
  local home=$1
  local stub="$home/fakebin/snapshot-stub"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "schema": "fm-bearings.v1",
  "home": "test-home",
  "generated": "2026-08-19T00:00:00Z",
  "in_flight": [
    { "id": "sample-live-task", "kind": "ship", "state": "validating",
      "repo": "sample", "name": "Sample live task", "doing": "validating" }
  ],
  "decisions_open": [
    { "id": "sample-open-call", "key": "sample-open-call", "verb": "needs-decision",
      "summary": "Sample open call", "owner": "(main)" }
  ],
  "landed": [
    { "id": "sample-landed-task", "what": "Land the sample change",
      "artifact": "https://github.com/example/sample/pull/7", "owner": "(main)" }
  ],
  "gates": [
    { "id": "sample-gate", "title": "Dispatched sample gate", "blocked_by": "-",
      "reason": "Waiting for worker capacity", "owner": "(main)", "filed": "2026-08-18" },
    { "id": "(sample-inventory)", "title": "Sample inventory warning", "blocked_by": "-",
      "reason": "inventory mismatch", "owner": "(main)", "filed": null }
  ]
}
JSON
SH
  chmod +x "$stub"
}

stash_store_card() {  # <home> <key> [state]; a raise-time record shape for one key
  local home=$1 key=$2 state
  state=${3:-$home/state}
  mkdir -p "$state/decision-cards"
  jq -n --arg key "$key" '{schema:"fm-decision-card.v1", generated:"2026-08-18T00:00:00Z",
    card:{key:$key, type:"decision", repo:"sample", title:"Raise-time storage choice",
      options:[{value:"keep", label:"Keep it"}], allow_freeform:true}}' \
    > "$state/decision-cards/$key.json"
}

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

  # With no stale cards, the effective payload is the input payload apart
  # from the reconcile choice the build adds to every decision card.
  # The escaped </script> string can no longer terminate the data block.
  extract_payload "$board" | jq -S . > "$home/extracted.json" \
    || fail "the built board does not carry parseable payload JSON"
  jq -S '.captains_call = [.captains_call[]
      | .options = [.options[] | select(.value != "reconcile")]]' \
    "$home/extracted.json" > "$home/stripped.json" && mv "$home/stripped.json" "$home/extracted.json"
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
  jq -S '.captains_call = [.captains_call[]
      | .options = [.options[] | select(.value != "reconcile")]]' \
    "$home/extracted.json" > "$home/stripped.json" && mv "$home/stripped.json" "$home/extracted.json"
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
  fm_test_tasks_toml "$home/.tasks.toml"
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
  local home data board out sid
  home=$(make_lavish_home view view)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"

  out=$(run_board "$home" build "$data") || fail "a view-mode build failed: $out"
  assert_contains "$out" "session: live" "view mode did not establish a Lavish session: $out"
  assert_contains "$out" "url: http://127.0.0.1:4387/session/0123456789abcdef" "view mode did not print the session URL: $out"
  assert_contains "$out" "open: http://127.0.0.1:4387/session/0123456789abcdef" "view mode did not open the session URL: $out"
  assert_not_contains "$out" "next_step" "build echoed lavish-axi's agent instructions: $out"
  sid=$(board_source_id "$home")
  assert_not_contains "$out" "bound: " "view mode bound an answer source: $out"
  assert_contains "$out" "armed: $sid" "view mode did not arm the board so its feedback reaches firstmate: $out"
  ! run_hold "$home" binding "$sid" >/dev/null 2>&1 || fail "view mode bound the board to the answer intake"
  extract_payload "$board" | jq -e 'has("interactive") | not' >/dev/null \
    || fail "a view-mode board was made interactive"
  extract_payload "$board" | jq -e '[.captains_call[] | select(.type == "decision") | .options[].value] | index("reconcile") != null' >/dev/null \
    || fail "a view-mode board lost the standard reconcile choice"
  extract_payload "$board" | jq -e '[.captains_call[].answerable] | all(. == null)' >/dev/null \
    || fail "a view-mode board made a card answerable"
  [ "$(cat "$home/lavish-state/env")" = "TELEMETRY=0 NO_OPEN=1 HOST=127.0.0.1" ] \
    || fail "lavish-axi did not run under the pinned environment: $(cat "$home/lavish-state/env")"
  pass "view mode opens the read-only board in Lavish, armed but unbound, under the pinned environment"
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

test_malformed_toggle_counts_as_off_and_a_malformed_request_refuses() {
  local home data out
  home=$(make_lavish_home malformed sometimes)
  data="$home/payload.json"
  write_valid_payload "$data"
  out=$(run_board "$home" build "$data" 2>&1) || fail "a malformed config/lavish refused the board: $out"
  assert_contains "$out" "lavish: off (config/lavish must be off, view, or answers (got sometimes))" \
    "the malformed toggle was not reported as off: $out"
  assert_contains "$out" "open: $home/.lavish/bearings-board.html" "a malformed toggle did not build the static board: $out"
  assert_absent "$home/lavish-state/env" "a malformed toggle still invoked lavish-axi"
  home=$(make_lavish_home malformed-request)
  data="$home/payload.json"
  write_valid_payload "$data"
  if out=$(run_board "$home" build "$data" --lavish maybe 2>&1); then
    fail "a malformed request built a board: $out"
  fi
  assert_absent "$home/.lavish/bearings-board.html" "a malformed request still produced a board"
  home=$(make_lavish_home empty-request answers)
  data="$home/payload.json"
  write_valid_payload "$data"
  if out=$(run_board "$home" build "$data" --lavish= 2>&1); then
    fail "an empty request built a board: $out"
  fi
  assert_contains "$out" "got an empty value" "the empty request was not named: $out"
  assert_absent "$home/.lavish/bearings-board.html" "an empty request still produced a board"
  pass "a malformed toggle builds the static board and says why, and a malformed request refuses"
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
  if held_call_readable "$home"; then
    extract_payload "$board" | jq -e '
      [.captains_call[] | select(.type == "decision") | .answerable == true and .options[-1].value == "reconcile"] | all' >/dev/null \
      || fail "a decision card held in this home is not answerable with the reconcile choice"
  else
    extract_payload "$board" | jq -e '
      [.captains_call[] | select(.type == "decision") | (has("answerable") | not) and ([.options[].value] | index("reconcile") == null)] | all' >/dev/null \
      || fail "a decision card whose call cannot be read was made answerable"
  fi
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

test_answers_mode_keeps_other_homes_calls_display_only() {
  local home data board out
  home=$(make_lavish_home remote-call answers)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  jq '.captains_call += [{
        "key":"remote-mate-call","type":"decision","repo":"sample","owner":"mate-one",
        "title":"Secondmate decision","options":[{"value":"yes","label":"Yes"}]
      }]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data") || fail "the answers build failed: $out"
  assert_absent "$home/state/decision-cards/remote-mate-call.json" \
    "another home's decision card was persisted into the local store"
  extract_payload "$board" | jq -e '
    [.captains_call[] | select(.key == "remote-mate-call")]
    | length == 1 and (.[0] | has("answerable") | not)' >/dev/null \
    || fail "a call this home does not hold was made answerable"
  if held_call_readable "$home"; then
    # A secondmate card whose task id collides with a call this home holds, and
    # a card that does not say whose call it is, both stay display-only.
    jq '.captains_call = [(.captains_call[0] | .owner = "mate-one")]' "$data" > "$data.remote"
    out=$(run_board "$home" build "$data.remote") || fail "the colliding-id answers build failed: $out"
    extract_payload "$board" | jq -e '[.captains_call[] | select(has("answerable"))] | length == 0' >/dev/null \
      || fail "a secondmate card sharing a local task id was made answerable"
    jq '.captains_call[0] |= del(.owner)' "$data" > "$data.unowned"
    out=$(run_board "$home" build "$data.unowned") || fail "the ownerless answers build failed: $out"
    extract_payload "$board" | jq -e '[.captains_call[] | select(has("answerable"))] | length == 0' >/dev/null \
      || fail "a card with no owner was made answerable"
    jq '.captains_call = [(.captains_call[0] | .owner = "mate-one"), .captains_call[0]]' "$data" > "$data.both"
    out=$(run_board "$home" build "$data.both") || fail "the shared-id answers build failed: $out"
    extract_payload "$board" | jq -e '
      [.captains_call[] | select(.type == "decision") | {owner, answerable}]
      == [{"owner":"mate-one","answerable":null},{"owner":"(main)","answerable":true}]' >/dev/null \
      || fail "a shared task id did not keep only this home's card answerable"
  fi
  pass "answers mode keeps a call another home holds display-only, even when its task id matches a local call"
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

test_view_mode_ends_the_session_when_it_cannot_listen() {
  local home data out
  home=$(make_lavish_home view-no-listener view)
  data="$home/payload.json"
  write_valid_payload "$data"
  if out=$(FM_LAVISH_POLL_RETRY_DELAY=0 run_board "$home" build "$data" 2>&1); then
    fail "a view build succeeded without a listener: $out"
  fi
  assert_contains "$out" "cannot arm the board" "the view build did not fail at arming: $out"
  assert_contains "$out" "ended the board session" "the failed view build did not say it ended the session: $out"
  assert_present "$home/lavish-state/ended" "a view board that cannot listen kept its session open for feedback"
  pass "a view build that cannot arm its listener ends the session instead of taking feedback nobody collects"
}

test_build_refuses_a_symlinked_board_path() {
  local home data out
  home=$(make_lavish_home symlinked answers)
  data="$home/payload.json"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the answers build failed"
  printf '<html></html>\n' > "$home/elsewhere.html"
  rm -f "$home/.lavish/bearings-board.html"
  ln -s "$home/elsewhere.html" "$home/.lavish/bearings-board.html"
  if out=$(run_board "$home" build "$data" --lavish off 2>&1); then
    fail "a build replaced a symlinked board path: $out"
  fi
  assert_contains "$out" "is a symlink" "the symlink refusal was not named: $out"
  [ -L "$home/.lavish/bearings-board.html" ] || fail "the refused build touched the symlinked board path"
  rm -f "$home/.lavish/bearings-board.html"
  mv "$home/.lavish" "$home/real-lavish"
  ln -s "$home/real-lavish" "$home/.lavish"
  if out=$(run_board "$home" build "$data" --lavish off 2>&1); then
    fail "a build used a symlinked .lavish directory: $out"
  fi
  assert_contains "$out" "is a symlink" "the directory symlink refusal was not named: $out"
  pass "a build refuses a board path replaced by a symlink"
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
  assert_contains "$out" "unbound: $sid" "declining answers did not unbind the source: $out"
  ! run_hold "$home" binding "$sid" >/dev/null 2>&1 || fail "declining answers left the binding"
  source_registered "$home" "$sid" || fail "a view board lost the listener that carries its feedback"
  out=$(run_board "$home" build "$data" --lavish view) || fail "a second view rebuild failed: $out"
  assert_not_contains "$out" "unbound: " "a view rebuild with nothing bound reported an unbind: $out"

  out=$(run_board "$home" build "$data" --lavish off) || fail "the off rebuild failed: $out"
  assert_contains "$out" "retired: $sid" "an off build did not retire the board listener: $out"
  ! source_registered "$home" "$sid" || fail "an off build left the board listener registered"

  # A deleted board still has its answer source found and retired.
  run_board "$home" build "$data" >/dev/null || fail "the answers build before deletion failed"
  rm -f "$home/.lavish/bearings-board.html"
  out=$(run_board "$home" build "$data" --lavish off) || fail "an off rebuild of a deleted board failed: $out"
  assert_contains "$out" "unbound: $sid" "a deleted board's answer source was not unbound: $out"
  assert_contains "$out" "retired: $sid" "a deleted board's answer source was not retired: $out"
  ! run_hold "$home" binding "$sid" >/dev/null 2>&1 || fail "a deleted board kept its answer binding"
  ! source_registered "$home" "$sid" || fail "a deleted board kept its answer source registered"

  # A binding that cannot be removed refuses the downgrade and keeps the
  # earlier board, because that binding is what lets an open page change tasks.
  # A read-only directory cannot stop root, so root skips only this case.
  if [ "$(id -u)" = 0 ]; then
    pass "a build below answers unbinds an earlier answer source, and off retires its listener"
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
  pass "a build below answers unbinds an earlier answer source, and off retires its listener"
}

test_build_persists_decision_cards_durably() {
  local home data store key
  home=$(make_home durable-cards)
  data="$home/payload.json"
  store="$home/state/decision-cards"
  key=sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice
  write_valid_payload "$data"

  run_board "$home" build "$data" >/dev/null || fail "a valid payload did not build"
  assert_present "$store/$key.json" "build did not persist the effective decision card"
  [ "$(jq -r '.card.title' "$store/$key.json")" = "Perishable-first admission" ] \
    || fail "the persisted card does not carry the composed title"
  jq -e '.schema == "fm-decision-card.v1"
         and (any(.card.options[]; .value == "reconcile"))' "$store/$key.json" >/dev/null \
    || fail "the persisted card must be the effective card, reconcile choice included"

  # A rebuild that no longer cards the key keeps the record: an absent or
  # unestablished task must not hide the options a later reader needs.
  jq --arg key "$key" '.captains_call = [.captains_call[] | select(.key != $key)]' \
    "$data" > "$data.next" && mv "$data.next" "$data"
  run_board "$home" build "$data" >/dev/null || fail "a rebuild without the card did not build"
  assert_present "$store/$key.json" "a rebuild without the card pruned a call that may still be open"
  pass "build persists the effective decision cards for later readers"
}

test_build_prunes_closed_merge_cards_by_underlying_task() {
  local home data store live closed key
  home=$(make_home prune-merge-cards)
  data="$home/payload.json"
  store="$home/state/decision-cards"
  live=sample-live-call
  closed=sample-closed-call
  write_valid_payload "$data"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<EOF
## In flight

## Queued
- [ ] $live - Decide the live sample (repo: sample) (kind: captain) (hold: choose) (hold-kind: captain)

## Done
- [x] $closed - Decide the closed sample (repo: sample) (kind: captain) (hold: chose) (hold-kind: captain)
EOF
  mkdir -p "$store"
  for key in "merge.$live" "merge.$closed"; do
    jq -n --arg key "$key" '{schema:"fm-decision-card.v1", generated:"2026-08-19T00:00:00Z",
      card:{key:$key, type:"merge", repo:"sample", title:"Merge sample", risk:"low",
        options:[{value:"merge", label:"Merge"}], allow_freeform:true}}' > "$store/$key.json"
  done

  run_board "$home" build "$data" >/dev/null || fail "a build with stored merge cards failed"
  assert_present "$store/merge.$live.json" "build pruned a merge card whose underlying call is live"
  assert_absent "$store/merge.$closed.json" "build retained a merge card whose underlying call is closed"
  pass "build prunes merge cards by their underlying captain-held task"
}

# The bearings skill forbids two cards for one task id, so the store writer is
# the last line of defense: a file that carries two JSON documents makes a
# later reader refuse the whole record. Exactly one card per key is written.
# The first payload entry wins because it is the composer's primary card; the
# entries after it are the mirror duplicates.
test_build_persists_one_store_card_for_a_duplicated_call_key() {
  local home data store key documents
  home=$(make_home duplicate-cards)
  data="$home/payload.json"
  store="$home/state/decision-cards"
  key=sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice
  write_valid_payload "$data"

  if ! jq --arg key "$key" '
    .captains_call += [.captains_call[] | select(.key == $key) | .title = "Mirrored copy"]' \
    "$data" > "$data.next"; then
    fail "could not stage the duplicated-call payload"
  fi
  mv "$data.next" "$data" || fail "could not stage the duplicated-call payload"
  [ "$(jq -c --arg key "$key" '[.captains_call[] | select(.key == $key)] | length' "$data")" = 2 ] \
    || fail "the fixture payload does not carry the duplicated key twice"

  run_board "$home" build "$data" >/dev/null \
    || fail "a payload with a duplicated call key did not build"
  assert_present "$store/$key.json" "the duplicated call key persisted no card"
  documents=$(jq -c '1' "$store/$key.json" | wc -l | tr -d ' ')
  [ "$documents" = 1 ] \
    || fail "the store card holds $documents JSON documents; a later reader needs exactly one"
  jq -e '.schema == "fm-decision-card.v1"' "$store/$key.json" >/dev/null \
    || fail "the store card is not an fm-decision-card.v1 record"
  [ "$(jq -r '.card.title' "$store/$key.json")" = "Perishable-first admission" ] \
    || fail "the store card is not the first payload entry for the key"
  pass "build persists exactly one store card for a duplicated captain-call key"
}

test_build_merges_the_durable_card_store_first() {
  local home data store key
  home=$(make_home store-first)
  data="$home/payload.json"
  store="$home/state/decision-cards"
  key=sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "a valid payload did not build"

  # The raise-time writer (bin/fm-captain-hold.sh) lands this record shape.
  jq -n --arg key "$key" '{schema:"fm-decision-card.v1", generated:"2026-08-19T00:00:00Z",
    card:{key:$key, type:"decision", repo:"sample", title:"Raise-time card",
      about:"written where the question was raised", close:"release",
      options:[{value:"ship", label:"Ship it"},{value:"wait", label:"Wait"}],
      allow_freeform:true}}' > "$store/$key.json"
  run_board "$home" build "$data" >/dev/null || fail "a rebuild with a stored card did not build"

  extract_payload "$home/.lavish/bearings-board.html" > "$home/served.json"
  jq -e --arg key "$key" '
    (.captains_call[] | select(.key == $key) | .title) == "Raise-time card"
    and ((.captains_call[] | select(.key == $key)
      | [.options[] | select(.value == "reconcile")] | length) == 1)
    and ((.captains_call[] | select(.key == $key) | .owner) == "(main)")
    and ((.captains_call[] | select(.key == $key) | .close) == "release")' "$home/served.json" >/dev/null \
    || fail "the board did not serve the stored copy with one injected reconcile choice"
  jq -e --arg key "$key" '.card.title == "Raise-time card"' "$store/$key.json" >/dev/null \
    || fail "the persisted effective card is not the stored copy"
  pass "build merges the durable card store first for its key"
}

test_build_serializes_store_merge_and_persistence_with_card_writers() {
  local home data key lock acquired release locker_pid build_pid published=0
  home=$(make_home store-writer-race)
  data="$home/payload.json"
  key=sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice
  lock="$home/state/.control-$key.lock"
  acquired="$home/lock-acquired"
  release="$home/release-lock"
  write_valid_payload "$data"

  STATE="$home/state" FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    : > "$3"
    while [ ! -e "$4" ]; do sleep 0.05; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$acquired" "$release" &
  locker_pid=$!
  for _ in $(seq 1 100); do
    [ -e "$acquired" ] && break
    sleep 0.05
  done
  [ -e "$acquired" ] || fail "the card writer fixture did not acquire the task lock"

  run_board "$home" build "$data" > "$home/build.out" 2>&1 &
  build_pid=$!
  for _ in $(seq 1 20); do
    if [ -e "$home/.lavish/bearings-board.html" ]; then
      published=1
      break
    fi
    sleep 0.05
  done
  stash_store_card "$home" "$key"
  : > "$release"
  wait "$locker_pid" || fail "the card writer fixture did not release the task lock"
  wait "$build_pid" || fail "the serialized board build failed: $(cat "$home/build.out")"

  [ "$published" -eq 0 ] || fail "the board published while the card writer held the task lock"
  extract_payload "$home/.lavish/bearings-board.html" > "$home/served.json"
  jq -e --arg key "$key" '
    (.captains_call[] | select(.key == $key) | .title) == "Raise-time storage choice"' \
    "$home/served.json" >/dev/null \
    || fail "the build did not preserve the card published before the task lock was released"
  jq -e '.card.title == "Raise-time storage choice"' \
    "$home/state/decision-cards/$key.json" >/dev/null \
    || fail "the build overwrote the card published before the task lock was released"
  pass "build serializes card-store merge and persistence with raise-time writers"
}

test_build_ignores_a_malformed_store_card_without_failing() {
  local home data store key out
  home=$(make_home store-malformed)
  data="$home/payload.json"
  store="$home/state/decision-cards"
  key=sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "a valid payload did not build"
  jq -n --arg key "$key" '{schema:"fm-decision-card.v1", generated:"2026-08-19T00:00:00Z",
    card:{key:$key, type:"decision", repo:"sample", options:[]}}' > "$store/$key.json"
  out=$(run_board "$home" build "$data" 2>&1) || fail "a malformed stored card failed the build"
  assert_contains "$out" "ignored-store-card: $key" "the build did not name the ignored record"
  extract_payload "$home/.lavish/bearings-board.html" > "$home/served.json"
  jq -e --arg key "$key" '(.captains_call[] | select(.key == $key) | .title) == "Perishable-first admission"' \
    "$home/served.json" >/dev/null \
    || fail "the payload copy was not used when the stored record was malformed"
  pass "build ignores a malformed store card and keeps the payload copy"
}

test_refresh_composes_from_the_snapshot_and_merges_the_store_card() {
  local home stub key
  home=$(make_home refresh)
  key=sample-open-call
  write_snapshot_stub "$home"
  stub="$home/fakebin/snapshot-stub"
  stash_store_card "$home" "$key"
  FM_BEARINGS_BOARD_SNAPSHOT="$stub" run_board "$home" refresh >/dev/null \
    || fail "refresh did not build the board from the snapshot"
  extract_payload "$home/.lavish/bearings-board.html" > "$home/served.json"
  jq -e --arg key "$key" '
    (.captains_call[] | select(.key == $key) | .title) == "Raise-time storage choice"
    and ((.captains_call[] | select(.key == $key)
      | [.options[] | select(.value == "reconcile")] | length) == 1)
    and ((.captains_call[] | select(.key == $key) | .owner) == "(main)")
    and ([.underway[].id] == ["sample-live-task"])
    and ([.landed[].id] == ["sample-landed-task"])
    and ([.charted[].id] == ["sample-gate", "sample-inventory"])
    and ((.charted[] | select(.id == "sample-inventory") | .kind) == "warning")
    and ((.underway[] | select(.id == "sample-live-task") | .repo) == "sample")
    and ([.charted[] | select(.dispatchable != false)] | length == 0)' "$home/served.json" >/dev/null \
    || fail "the refreshed board did not carry the snapshot rows and the stored card copy"
  pass "refresh composes the snapshot rows and merges the stored decision card"
}

test_refresh_uses_the_configured_state_store() {
  local home state stub key
  home=$(make_home refresh-state-override)
  state="$home/override-state"
  key=sample-open-call
  mkdir -p "$state"
  write_snapshot_stub "$home"
  stub="$home/fakebin/snapshot-stub"
  stash_store_card "$home" "$key" "$state"

  FM_TEST_BOARD_STATE="$state" FM_BEARINGS_BOARD_SNAPSHOT="$stub" \
    run_board "$home" refresh >/dev/null \
    || fail "refresh failed with a configured state override"
  extract_payload "$home/.lavish/bearings-board.html" > "$home/served.json"
  jq -e --arg key "$key" '
    (.captains_call[] | select(.key == $key) | .title) == "Raise-time storage choice"' \
    "$home/served.json" >/dev/null \
    || fail "refresh did not merge the authored card from the configured state store"
  jq -e '.card.title == "Raise-time storage choice"' \
    "$state/decision-cards/$key.json" >/dev/null \
    || fail "refresh did not persist the card in the configured state store"
  assert_absent "$home/state/decision-cards/$key.json" \
    "refresh wrote a parallel card into the default home state"
  pass "refresh reads and persists cards in the configured state store"
}

test_build_skips_an_out_of_contract_store_filename_before_locking() {
  local home data store key out rc
  home=$(make_home invalid-store-key)
  data="$home/payload.json"
  store="$home/state/decision-cards"
  key=merge.
  while [ "${#key}" -lt 242 ]; do key=${key}a; done
  write_valid_payload "$data"
  mkdir -p "$store"
  jq -n --arg key "$key" '{schema:"fm-decision-card.v1", generated:"2026-08-19T00:00:00Z",
    card:{key:$key, type:"merge", repo:"sample", title:"Oversized key", risk:"low",
      options:[{value:"hold", label:"Hold"}], allow_freeform:true}}' > "$store/$key.json"

  set +e
  out=$(run_board_timed 10 "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 124 ] || fail "build hung while locking an out-of-contract store filename"
  [ "$rc" -eq 0 ] || fail "build failed while skipping an out-of-contract store filename: $out"
  assert_contains "$out" "ignored-store-card: $key (file name is not a valid card key)" \
    "build did not name the out-of-contract store filename"
  pass "build skips an out-of-contract store filename before locking"
}

# A stored record the shared contract rejects is named and skipped, not merged
# into the payload where the validator would fail the whole refresh.
test_refresh_ignores_a_malformed_store_card() {
  local home stub out rc
  home=$(make_home refresh-malformed-store)
  write_snapshot_stub "$home"
  stub="$home/fakebin/snapshot-stub"
  mkdir -p "$home/state/decision-cards"
  jq -n --arg key "merge.sample-open-call" '{
    schema:"fm-decision-card.v1", generated:"2026-08-18T00:00:00Z",
    card:{key:$key, type:"merge", repo:"sample", title:"", risk:"low", options:[]}
  }' > "$home/state/decision-cards/merge.sample-open-call.json"
  set +e
  out=$(FM_BEARINGS_BOARD_SNAPSHOT="$stub" run_board "$home" refresh 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a malformed stored card failed the whole refresh: $out"
  assert_contains "$out" "ignored-store-card: merge.sample-open-call" \
    "the malformed stored card was not named and skipped: $out"
  extract_payload "$home/.lavish/bearings-board.html" > "$home/served.json"
  jq -e '([.captains_call[].key] | index("merge.sample-open-call")) == null' "$home/served.json" >/dev/null \
    || fail "the malformed stored card still reached the board payload"
  pass "refresh skips a malformed stored card and keeps the board current"
}

# The schema an envelope declares is part of the stored form: a record that
# would merge as fm-decision-card.v1 is named and skipped once it names another
# schema, in both the build merge and the refresh merge.
test_build_ignores_a_store_envelope_of_another_schema() {
  local home data store key out
  home=$(make_home store-old-schema)
  data="$home/payload.json"
  store="$home/state/decision-cards"
  key=sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "a valid payload did not build"
  jq -n --arg key "$key" '{schema:"fm-decision-card.v1", generated:"2026-08-19T00:00:00Z",
    card:{key:$key, type:"decision", repo:"sample", title:"Raise-time card",
      options:[{value:"ship", label:"Ship it"}], allow_freeform:true}}' > "$store/$key.json"
  run_board "$home" build "$data" >/dev/null || fail "a rebuild with a stored card did not build"
  extract_payload "$home/.lavish/bearings-board.html" > "$home/served.json"
  jq -e --arg key "$key" '(.captains_call[] | select(.key == $key) | .title) == "Raise-time card"' \
    "$home/served.json" >/dev/null || fail "the control fm-decision-card.v1 record was not merged"
  jq -n --arg key "$key" '{schema:"fm-decision-card.v0", generated:"2026-08-19T00:00:00Z",
    card:{key:$key, type:"decision", repo:"sample", title:"Raise-time card",
      options:[{value:"ship", label:"Ship it"}], allow_freeform:true}}' > "$store/$key.json"
  out=$(run_board "$home" build "$data" 2>&1) || fail "an old-schema stored record failed the build"
  assert_contains "$out" "ignored-store-card: $key (envelope schema must be fm-decision-card.v1)" \
    "the build did not name the old-schema record: $out"
  extract_payload "$home/.lavish/bearings-board.html" > "$home/served.json"
  jq -e --arg key "$key" '(.captains_call[] | select(.key == $key) | .title) == "Perishable-first admission"' \
    "$home/served.json" >/dev/null \
    || fail "an old-schema stored record replaced the payload copy"
  pass "build ignores a store envelope that names another schema"
}

test_refresh_ignores_a_store_envelope_of_another_schema() {
  local home stub key out rc
  home=$(make_home refresh-old-schema)
  key=merge.sample-open-call
  write_snapshot_stub "$home"
  stub="$home/fakebin/snapshot-stub"
  stash_store_card "$home" "$key"
  FM_BEARINGS_BOARD_SNAPSHOT="$stub" run_board "$home" refresh >/dev/null \
    || fail "refresh failed with a valid stored card"
  extract_payload "$home/.lavish/bearings-board.html" > "$home/served.json"
  jq -e --arg key "$key" '
    [.captains_call[].key] == [$key]
    and ((.captains_call[] | select(.key == $key) | .title) == "Raise-time storage choice")' \
    "$home/served.json" >/dev/null \
    || fail "refresh did not replace the fallback with exactly one stored merge card"
  stash_store_card "$home" "$key"
  jq '.schema = "fm-decision-card.v0"' "$home/state/decision-cards/$key.json" > "$home/old.json"
  mv -f -- "$home/old.json" "$home/state/decision-cards/$key.json"
  set +e
  out=$(FM_BEARINGS_BOARD_SNAPSHOT="$stub" run_board "$home" refresh 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "an old-schema stored record failed the whole refresh: $out"
  assert_contains "$out" "ignored-store-card: $key (envelope schema must be fm-decision-card.v1)" \
    "refresh did not name the old-schema record: $out"
  extract_payload "$home/.lavish/bearings-board.html" > "$home/served.json"
  jq -e '[.captains_call[].key] == ["sample-open-call"]' "$home/served.json" >/dev/null \
    || fail "refresh did not retain exactly the fallback for an old-schema stored record"
  pass "refresh ignores a store envelope that names another schema"
}

# A stored card for a hold the snapshot does not list as live - blocked, dated,
# reconciling, or aged - stays in the durable store and out of Captain's Call,
# where the call belongs to a disclosed Charted Next gate instead.
test_refresh_keeps_a_deferred_hold_out_of_captains_call() {
  local home stub key
  home=$(make_home refresh-deferred-card)
  key=sample-deferred-call
  write_snapshot_stub "$home"
  stub="$home/fakebin/snapshot-stub"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-deferred-call - Decide the deferred sample (repo: sample) (kind: captain) (hold: pick a route) (hold-kind: captain)

## Done
EOF
  stash_store_card "$home" "merge.$key"
  FM_BEARINGS_BOARD_SNAPSHOT="$stub" run_board "$home" refresh >/dev/null \
    || fail "refresh failed with a deferred hold's stored card present"
  extract_payload "$home/.lavish/bearings-board.html" > "$home/served.json"
  jq -e '[.captains_call[].key] | index("merge.sample-deferred-call") == null' "$home/served.json" >/dev/null \
    || fail "a refresh resurrected a deferred hold as a live decision card"
  assert_present "$home/state/decision-cards/merge.$key.json" \
    "the deferred hold lost its durable card record"
  pass "refresh keeps a deferred hold's card out of Captain's Call"
}

test_refresh_refuses_a_broken_snapshot_before_touching_the_board() {
  local home stub rc out
  home=$(make_home refresh-refusal)
  write_snapshot_stub "$home"
  stub="$home/fakebin/snapshot-stub"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$stub"
  chmod +x "$stub"
  set +e
  out=$(FM_BEARINGS_BOARD_SNAPSHOT="$stub" run_board "$home" refresh 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "refresh accepted a snapshot that failed"
  assert_absent "$home/.lavish/bearings-board.html" "a broken snapshot still published a board"
  assert_contains "$out" "snapshot failed" "the refusal does not name the failing snapshot"
  pass "refresh refuses a broken snapshot before touching the board"
}

test_path_is_stable_and_home_scoped
test_build_persists_decision_cards_durably
test_build_prunes_closed_merge_cards_by_underlying_task
test_build_persists_one_store_card_for_a_duplicated_call_key
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
test_malformed_toggle_counts_as_off_and_a_malformed_request_refuses
test_answers_mode_binds_then_arms
test_answers_mode_does_not_bind_or_arm_when_the_session_stays_ended
test_answers_mode_keeps_other_homes_calls_display_only
test_answers_mode_keeps_controls_hidden_until_listening
test_view_mode_ends_the_session_when_it_cannot_listen
test_build_refuses_a_symlinked_board_path
test_answers_mode_reopens_a_session_the_captain_ended
test_dropping_below_answers_retires_the_answer_source
test_build_merges_the_durable_card_store_first
test_build_ignores_a_malformed_store_card_without_failing
test_build_serializes_store_merge_and_persistence_with_card_writers
test_refresh_composes_from_the_snapshot_and_merges_the_store_card
test_refresh_uses_the_configured_state_store
test_build_skips_an_out_of_contract_store_filename_before_locking
test_refresh_ignores_a_malformed_store_card
test_build_ignores_a_store_envelope_of_another_schema
test_refresh_ignores_a_store_envelope_of_another_schema
test_refresh_keeps_a_deferred_hold_out_of_captains_call
test_refresh_refuses_a_broken_snapshot_before_touching_the_board
