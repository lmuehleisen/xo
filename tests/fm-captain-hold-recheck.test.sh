#!/usr/bin/env bash
# tests/fm-captain-hold-recheck.test.sh - presentation receipts: the
# read-only re-verification every captain-facing surface runs on each call it
# is about to show (bin/fm-captain-hold.sh recheck), the receipt the snapshot
# attaches to presented rows, and the board's publish-time recheck.
#
# The promise pinned here: verified means the call's structured premises still
# hold, changed means one provably moved, and unknown means a needed source
# could not be read - shown plainly rather than silently treated as still
# true. Cost stays bounded to the presented rows.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
BOARD="$ROOT/bin/fm-bearings-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-hold-recheck)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'MD'
## In flight

## Queued

## Done
MD
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

run_recheck() {  # <home> <command args...>
  local home=$1
  shift
  run_captain "$home" recheck "$@"
}

run_bearings() {  # <home> [extra args]
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_BEARINGS_NOW=2026-07-14T12:00:00Z "$BEARINGS" --json "$@"
}

run_board() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$BOARD" "$@"
}

# Extract the injected payload back out of a built board page.
extract_payload() {  # <board-path>
  sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$1" \
    | sed '1d;$d'
}

receipt_field() {  # <receipt-json> <jq-expr>
  printf '%s' "$1" | jq -r "$2"
}

test_recheck_verified_open_call() {
  local home receipt before
  home=$(make_home verified)
  tasks_in "$home" add call-1 'Choose the launch flag' --kind scout --repo sample >/dev/null
  run_captain "$home" hold call-1 --reason 'captain must pick the flag' >/dev/null
  before=$(cat "$home/data/backlog.md")
  receipt=$(run_recheck "$home" call-1) || fail "recheck failed on an open call"
  assert_equals "$(receipt_field "$receipt" .schema)" "fm-presentation-receipt.v1" "receipt schema"
  assert_equals "$(receipt_field "$receipt" .task)" "call-1" "receipt task"
  assert_equals "$(receipt_field "$receipt" .source)" "backlog" "receipt source"
  assert_equals "$(receipt_field "$receipt" .verdict)" "verified" "open call verdict"
  assert_equals "$(receipt_field "$receipt" '.checks.call')" "verified" "call check"
  assert_equals "$(receipt_field "$receipt" '.checks.deferral')" "none" "deferral check"
  assert_equals "$(receipt_field "$receipt" '.checks.blockers')" "none" "blockers check"
  assert_equals "$(receipt_field "$receipt" '.checks.linked_work')" "self" "self-held linked work"
  assert_equals "$(receipt_field "$receipt" '.checks.reconcile')" "clear" "reconcile check"
  printf '%s' "$receipt" | jq -e '.checked_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' >/dev/null \
    || fail "checked_at is not a UTC stamp: $(receipt_field "$receipt" .checked_at)"
  printf '%s' "$receipt" | jq -e '.revision | type == "string" and length > 0' >/dev/null \
    || fail "a verified receipt has no revision"
  [ "$(cat "$home/data/backlog.md")" = "$before" ] || fail "recheck rewrote the backlog"
  pass "an open captain call rechecks verified with a revision and mutates nothing"
}

test_recheck_expect_revision_expiry() {
  local home receipt revision
  home=$(make_home expect)
  tasks_in "$home" add call-2 'Pick the port' --kind scout --repo sample >/dev/null
  run_captain "$home" hold call-2 --reason 'captain must pick the port' >/dev/null
  receipt=$(run_recheck "$home" call-2)
  revision=$(receipt_field "$receipt" .revision)
  receipt=$(run_recheck "$home" call-2 --expect "$revision") || fail "recheck --expect failed"
  assert_equals "$(receipt_field "$receipt" .verdict)" "verified" "a matching revision did not stay verified"
  receipt=$(run_recheck "$home" call-2 --expect "stale-revision") || fail "recheck --expect stale failed"
  assert_equals "$(receipt_field "$receipt" .verdict)" "changed" "a stale revision was not expired"
  assert_contains "$(receipt_field "$receipt" .detail)" "moved since the receipt revision" "stale-revision detail"
  # A real record change also expires the earlier revision.
  run_captain "$home" hold call-2 --reason 'captain must pick the port after the rename' >/dev/null
  receipt=$(run_recheck "$home" call-2 --expect "$revision")
  assert_equals "$(receipt_field "$receipt" .verdict)" "changed" "a moved record kept an expired receipt"
  pass "--expect expires a receipt whose revision no longer matches the record"
}

test_recheck_absent_and_closed_calls() {
  local home receipt
  home=$(make_home absent)
  receipt=$(run_recheck "$home" call-ghost) || fail "recheck failed on an absent call"
  assert_equals "$(receipt_field "$receipt" .verdict)" "changed" "absent call verdict"
  assert_equals "$(receipt_field "$receipt" '.checks.call')" "changed" "absent call check"
  assert_contains "$(receipt_field "$receipt" .detail)" "has no record" "absent detail"
  tasks_in "$home" add call-3 'Choose the color' --kind scout --repo sample >/dev/null
  run_captain "$home" hold call-3 --reason 'captain must pick the color' >/dev/null
  printf 'keep the current color\n' > "$home/state/decision.txt"
  run_captain "$home" answer call-3 --decision-file "$home/state/decision.txt" >/dev/null
  receipt=$(run_recheck "$home" call-3)
  assert_equals "$(receipt_field "$receipt" .verdict)" "changed" "answered call verdict"
  assert_equals "$(receipt_field "$receipt" '.checks.call')" "changed" "answered call check"
  assert_contains "$(receipt_field "$receipt" .detail)" "is closed" "answered call detail"
  pass "absent and answered calls recheck as changed rather than silently verified"
}

test_recheck_deferral_verdicts() {
  local home receipt revision
  home=$(make_home deferral)
  tasks_in "$home" add call-future 'Decide tomorrow' --kind scout --repo sample >/dev/null
  run_captain "$home" hold call-future --reason 'deferred decision' --until 2099-01-01 >/dev/null
  receipt=$(run_recheck "$home" call-future)
  assert_equals "$(receipt_field "$receipt" .verdict)" "verified" "future deferral verdict"
  assert_equals "$(receipt_field "$receipt" '.checks.deferral')" "future" "future deferral check"
  # A deferral already lapsed when the call is presented is disclosed, not
  # cried as movement: nothing moved since the presented state was captured.
  tasks_in "$home" add call-lapsed 'Decide yesterday' --kind scout --repo sample >/dev/null
  run_captain "$home" hold call-lapsed --reason 'deferred decision' --until 2020-01-01 >/dev/null
  receipt=$(run_recheck "$home" call-lapsed)
  assert_equals "$(receipt_field "$receipt" '.checks.deferral')" "lapsed" "lapsed deferral check"
  assert_equals "$(receipt_field "$receipt" .verdict)" "verified" "a lapsed deferral misreports moved"
  assert_contains "$(receipt_field "$receipt" .detail)" "has passed" "lapsed deferral detail"
  # But a hold that crosses its date between a composition receipt and a
  # publish --expect does expire: the presented face changed.
  tasks_in "$home" add call-due 'Decide by mid-July' --kind scout --repo sample >/dev/null
  run_captain "$home" hold call-due --reason 'deferred decision' --until 2026-07-10 >/dev/null
  receipt=$(FM_CAPTAIN_HOLD_NOW=2026-07-01T00:00:00Z run_recheck "$home" call-due)
  assert_equals "$(receipt_field "$receipt" '.checks.deferral')" "future" "pre-due deferral check"
  revision=$(receipt_field "$receipt" .revision)
  receipt=$(FM_CAPTAIN_HOLD_NOW=2026-07-14T00:00:00Z run_recheck "$home" call-due --expect "$revision")
  assert_equals "$(receipt_field "$receipt" '.checks.deferral')" "lapsed" "post-due deferral check"
  assert_equals "$(receipt_field "$receipt" .verdict)" "changed" "a crossed due date stayed verified"
  pass "a live deferral verifies, a lapsed one discloses without crying moved, and a crossed date expires"
}

test_recheck_reconcile_pending_stays_verified() {
  local home receipt
  home=$(make_home reconcile)
  tasks_in "$home" add call-5 'Decide with a pending re-check' --kind scout --repo sample >/dev/null
  run_captain "$home" hold call-5 --reason 'captain decision pending' >/dev/null
  run_captain "$home" bind board-1 >/dev/null
  printf 'call-5\n' | run_captain "$home" reconcile-requests --source-id board-1 \
    --source "captured review result" >/dev/null
  receipt=$(run_recheck "$home" call-5)
  assert_equals "$(receipt_field "$receipt" '.checks.reconcile')" "pending" "pending reconcile check"
  assert_equals "$(receipt_field "$receipt" .verdict)" "verified" "a pending request changed the verdict"
  pass "a pending reconcile request is disclosed without changing the verdict"
}

test_recheck_linked_origin_states() {
  local home receipt
  home=$(make_home linked)
  tasks_in "$home" add work-9 'Gated work item' --kind ship --repo sample >/dev/null
  fm_write_meta "$home/state/work-9.meta" \
    "window=firstmate:fm-work-9" \
    "worktree=$home/projects/missing-work-9" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship" \
    "spawn_gen=fixture-work-9"
  printf 'done: finished normally\n' > "$home/state/work-9.status"
  run_captain "$home" hold call-6 --title 'Call on work-9' --reason 'captain call' \
    --repo sample --origin work-9 >/dev/null
  receipt=$(run_recheck "$home" call-6)
  assert_equals "$(receipt_field "$receipt" '.checks.linked_work')" "consistent" "quiet origin check"
  assert_equals "$(receipt_field "$receipt" .verdict)" "verified" "quiet origin verdict"
  printf 'working: resumed\n' >> "$home/state/work-9.status"
  receipt=$(run_recheck "$home" call-6)
  assert_equals "$(receipt_field "$receipt" '.checks.linked_work')" "changed" "active origin check"
  assert_equals "$(receipt_field "$receipt" .verdict)" "changed" "active origin verdict"
  rm -f "$home/state/work-9.status"
  receipt=$(run_recheck "$home" call-6)
  assert_equals "$(receipt_field "$receipt" '.checks.linked_work')" "unknown" "unreadable origin check"
  assert_equals "$(receipt_field "$receipt" .verdict)" "unknown" "unreadable origin verdict"
  pass "a linked origin's quiet, active, and unreadable states verify, change, and mark unknown"
}

test_recheck_linked_origin_open_decision() {
  local home receipt
  home=$(make_home openkey)
  tasks_in "$home" add work-10 'Gated work item' --kind ship --repo sample >/dev/null
  fm_write_meta "$home/state/work-10.meta" \
    "window=firstmate:fm-work-10" \
    "worktree=$home/projects/missing-work-10" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship" \
    "spawn_gen=fixture-work-10"
  # A needs-decision the fold still holds open wins over a later resolved
  # event for another key: the origin is not quietly completed while the
  # captain's question stands.
  printf 'needs-decision [key=api-shape]: which payload shape\nresolved [key=log-name]: named the log\n' \
    > "$home/state/work-10.status"
  run_captain "$home" hold call-8 --title 'Call on work-10' --reason 'captain call' \
    --repo sample --origin work-10 >/dev/null
  receipt=$(run_recheck "$home" call-8)
  assert_equals "$(receipt_field "$receipt" '.checks.linked_work')" "changed" "open decision check"
  assert_equals "$(receipt_field "$receipt" .verdict)" "changed" "open decision verdict"
  printf 'resolved [key=api-shape]: use the v2 envelope\n' >> "$home/state/work-10.status"
  receipt=$(run_recheck "$home" call-8)
  assert_equals "$(receipt_field "$receipt" '.checks.linked_work')" "consistent" "answered decision check"
  assert_equals "$(receipt_field "$receipt" .verdict)" "verified" "answered decision verdict"
  # An open blocked key is the same standing decision, not quiet completion.
  printf 'blocked [key=await-secret]: secret never provisioned\nresolved [key=note-x]: noted\n' \
    > "$home/state/work-10.status"
  receipt=$(run_recheck "$home" call-8)
  assert_equals "$(receipt_field "$receipt" '.checks.linked_work')" "changed" "open blocker check"
  assert_equals "$(receipt_field "$receipt" .verdict)" "changed" "open blocker verdict"
  pass "an open needs-decision or blocked key on the origin never verifies"
}

test_recheck_unreadable_source_is_unknown() {
  local home receipt
  home=$(make_home unreadable)
  tasks_in "$home" add call-7 'Choose the window' --kind scout --repo sample >/dev/null
  run_captain "$home" hold call-7 --reason 'captain decision pending' >/dev/null
  # A missing file reads as an empty backlog (definite absence); a present but
  # unreadable one is the read failure this case needs.
  chmod 000 "$home/data/backlog.md"
  receipt=$(run_recheck "$home" call-7) || fail "recheck failed on an unreadable backlog"
  chmod 644 "$home/data/backlog.md"
  assert_equals "$(receipt_field "$receipt" '.checks.call')" "unknown" "unreadable call check"
  assert_equals "$(receipt_field "$receipt" .verdict)" "unknown" "unreadable backlog verdict"
  pass "an unreadable source reports unknown rather than silently verified"
}

test_snapshot_attaches_receipts_to_presented_calls() {
  local home json
  home=$(make_home snap)
  tasks_in "$home" add call-8 'Live decision' --kind scout --repo sample >/dev/null
  run_captain "$home" hold call-8 --reason 'captain must decide' >/dev/null
  tasks_in "$home" add call-9 'Deferred decision' --kind scout --repo sample >/dev/null
  run_captain "$home" hold call-9 --reason 'deferred' --until 2099-01-01 >/dev/null
  json=$(run_bearings "$home") || fail "snapshot failed"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "call-8"
      and .receipt.schema == "fm-presentation-receipt.v1"
      and .receipt.verdict == "verified"
      and .receipt.task == "call-8"
      and .receipt.source == "backlog"))
    and (.gates | any(.id == "call-9" and .captain == true
      and .receipt.schema == "fm-presentation-receipt.v1"
      and .receipt.verdict == "verified"))
  ' >/dev/null || fail "presented calls lack their rechecked receipts: $json"
  pass "the snapshot attaches a rechecked receipt to each presented captain call and marks captain gates"
}

test_snapshot_no_decisions_runs_no_recheck() {
  local home json
  home=$(make_home snap-empty)
  json=$(run_bearings "$home") || fail "empty snapshot failed"
  printf '%s' "$json" | jq -e '
    .decisions_open == [] and (.gates | all(.receipt == null))
  ' >/dev/null || fail "an empty home carried receipt work"
  pass "a turn presenting no decisions runs no recheck"
}

write_board_payload() {  # <path> <card-key> [extra-card-fields]
  local extra=${3:-}
  cat > "$1" <<EOF
{
  "schema": "fm-bearings-board.v1",
  "home": "test-home",
  "generated": "2026-08-19T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "$2",
      "type": "decision",
      "repo": "sample",
      "title": "Sample decision",
      "about": "What this call is about",
      "decide": "Decide it?",
      "owner": "(main)"${extra:+,$extra},
      "options": [
        { "value": "yes", "label": "Yes" },
        { "value": "no", "label": "No" }
      ],
      "allow_freeform": true
    }
  ],
  "underway": [],
  "landed": [],
  "charted": [
    { "id": "$2", "repo": "sample", "title": "Deferred call", "reason": "until 2099-01-01",
      "dispatchable": false, "captain": true, "owner": "(main)" }
  ],
  "charted_more": 0
}
EOF
}

test_board_publish_rechecks_and_marks() {
  local home data board payload receipt stale
  home=$(make_home board)
  tasks_in "$home" add call-10 'Publish-time decision' --kind scout --repo sample >/dev/null
  run_captain "$home" hold call-10 --reason 'captain must decide' >/dev/null
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_board_payload "$data" call-10
  run_board "$home" build "$data" >/dev/null || fail "board build failed"
  payload=$(extract_payload "$board")
  printf '%s' "$payload" | jq -e '
    (.captains_call[0].receipt | type == "object"
      and .schema == "fm-presentation-receipt.v1"
      and .verdict == "verified" and .task == "call-10")
    and (.charted[0].receipt.verdict == "verified")
  ' >/dev/null || fail "the published board lacks fresh receipts: $payload"
  # A stale composed revision expires at publish time.
  stale="\"receipt\":{\"schema\":\"fm-presentation-receipt.v1\",\"task\":\"call-10\",\"checked_at\":\"2026-01-01T00:00:00Z\",\"source\":\"(main)\",\"revision\":\"stale\",\"verdict\":\"verified\",\"checks\":{\"call\":\"verified\",\"deferral\":\"none\",\"blockers\":\"none\",\"reconcile\":\"clear\",\"linked_work\":\"self\"},\"detail\":\"composed earlier\"}"
  write_board_payload "$data" call-10 "$stale"
  run_board "$home" build "$data" >/dev/null || fail "board rebuild failed"
  payload=$(extract_payload "$board")
  receipt=$(printf '%s' "$payload" | jq -c '.captains_call[0].receipt')
  assert_equals "$(receipt_field "$receipt" .verdict)" "changed" "a stale composed receipt stayed verified"
  pass "the board rechecks every presented call at publish and expires stale receipts"
}

test_board_foreign_call_marks_unknown() {
  local home data board payload
  home=$(make_home board-foreign)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_board_payload "$data" mate-call-1
  jq '(.captains_call[0].owner) = "secondmate-a"
      | (.charted[0].owner) = "secondmate-a"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null || fail "foreign-owned board build failed"
  payload=$(extract_payload "$board")
  printf '%s' "$payload" | jq -e '
    (.captains_call[0].receipt.verdict == "unknown"
      and (.captains_call[0].receipt.source == "secondmate-a")
      and (.captains_call[0].receipt.detail | test("secondmate-a")))
    and (.charted[0].receipt.verdict == "unknown"
      and .charted[0].receipt.source == "secondmate-a")
  ' >/dev/null || fail "a foreign-owned call was not marked unknown: $payload"
  pass "a call owned by another home carries an explicit unknown receipt naming its owner"
}

test_board_refuses_malformed_receipt() {
  local home data rc
  home=$(make_home board-bad)
  data="$home/payload.json"
  write_board_payload "$data" call-x
  jq '.captains_call[0].receipt = {"schema":"fm-presentation-receipt.v1","verdict":"bogus"}' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  rc=0
  run_board "$home" build "$data" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed receipt was accepted"
  pass "a malformed receipt refuses the build rather than presenting as verified"
}

fm_test_run \
  test_recheck_verified_open_call \
  test_recheck_expect_revision_expiry \
  test_recheck_absent_and_closed_calls \
  test_recheck_deferral_verdicts \
  test_recheck_reconcile_pending_stays_verified \
  test_recheck_linked_origin_states \
  test_recheck_linked_origin_open_decision \
  test_recheck_unreadable_source_is_unknown \
  test_snapshot_attaches_receipts_to_presented_calls \
  test_snapshot_no_decisions_runs_no_recheck \
  test_board_publish_rechecks_and_marks \
  test_board_foreign_call_marks_unknown \
  test_board_refuses_malformed_receipt
