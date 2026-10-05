#!/usr/bin/env bash
# tests/fm-captain-hold-rehold.test.sh - re-holding a captain call preserves
# the reason it replaces (bin/fm-captain-hold.sh hold).
#
# A changed reason is preceded by a proved preservation of the exact prior
# bytes, an identical re-hold stays a no-op, and a failed preservation or
# replacement leaves the previous reason live with no false supersession record.
# The shared captain-hold lifecycle cases live in
# tests/fm-captain-hold-lifecycle.test.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-hold-rehold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
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
  case "${1:-}" in
    show|view|list)
      FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
        "$ROOT/bin/fm-tasks-axi.sh" "$@" ;;
    *) (cd "$home" && tasks-axi "$@") ;;
  esac
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

# Re-holding a captain call with a changed reason used to overwrite the
# outgoing one with no record of it anywhere, destroying reasoning that was
# often still correct. The replacement must now be preceded by a proved
# preservation of the exact prior bytes.
test_rehold_preserves_the_superseded_reason() {
  local home show archive first second original_row
  home=$(make_home rehold-preserves-reason)
  first='sample check says A; the cost grows with each retry; options 1, 2 or 3'
  second='re-checked: the sample check says B, so options 1 and 3 are moot'
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-reverify - Which verification route (repo: sample) (kind: ship) (since 2026-01-01)

## Done
EOF
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-reverify \
    --reason "$first" >/dev/null || fail "the first captain hold failed"
  assert_absent "$home/data/note-archive.md" \
    "a first hold with no previous reason archived something"
  original_row=$(sed -n '/^- .*sample-reverify/p' "$home/data/backlog.md")
  [ -n "$original_row" ] || fail "could not read the original stored row"

  FM_CAPTAIN_HOLD_NOW=2026-07-14T13:00:00Z run_captain "$home" hold sample-reverify \
    --reason "$second" >/dev/null || fail "the re-hold failed"
  show=$(tasks_in "$home" show sample-reverify --full)
  assert_contains "$show" "hold_reason: \"$second\"" "the re-hold did not write the new reason"
  assert_contains "$show" 'Superseded captain hold reason recorded by fm-captain-hold.' \
    "the superseded hold reason was not recorded"
  assert_contains "$show" 'Task: sample-reverify' "the superseded record does not name its task"
  assert_contains "$show" 'Superseded at: 2026-07-14T13:00:00Z' \
    "the superseded record does not say when the reason was replaced"
  assert_contains "$show" 'Record kind: re-hold' \
    "the superseded record cannot be told apart from a resolution"
  assert_contains "$show" "$first" "the exact previous reason bytes were not preserved"
  assert_contains "$show" 'Captain hold set: 2026-07-14T12:00:00Z' \
    "the re-hold restarted the hold lifecycle age"
  # The archived pristine body carries the outgoing reason in its own row line.
  archive=$(cat "$home/data/note-archive.md") || fail "the previous body was not archived"
  assert_contains "$archive" "$original_row" "the archived row lost the outgoing hold reason"
  # A superseded hold reason is never counted or read as a captain answer.
  assert_not_contains "$show" 'Resolution recorded by fm-captain-hold.' \
    "the superseded record was written as a resolution record"
  run_captain "$home" open sample-reverify --identity > "$home/identity.out" \
    || fail "the re-held task is no longer an open captain call"
  assert_equals '2026-07-14T12:00:00Z#0' "$(cat "$home/identity.out")" \
    "the superseded record was counted as a recorded answer"
  pass "a re-hold with a changed reason preserves the exact previous reason first"
}

# tasks-axi's own hold is a no-op when nothing changed, so a replayed identical
# re-hold must add no record and no archive entry.
test_identical_rehold_archives_nothing() {
  local home before_body before_archive after_body after_archive
  home=$(make_home rehold-identical)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-steady - A settled question (repo: sample) (kind: ship) (since 2026-01-01)

## Done
EOF
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-steady \
    --reason 'captain route choice pending' >/dev/null || fail "the first hold failed"
  FM_CAPTAIN_HOLD_NOW=2026-07-14T13:00:00Z run_captain "$home" hold sample-steady \
    --reason 'captain route choice pending' >/dev/null || fail "the first replay failed"
  before_body=$(tasks_in "$home" show sample-steady --full | sed -n 's/^  body: //p')
  before_archive=$(cat "$home/data/note-archive.md" 2>/dev/null || printf 'absent')

  FM_CAPTAIN_HOLD_NOW=2026-07-14T14:00:00Z run_captain "$home" hold sample-steady \
    --reason 'captain route choice pending' >/dev/null || fail "the second replay failed"
  after_body=$(tasks_in "$home" show sample-steady --full | sed -n 's/^  body: //p')
  after_archive=$(cat "$home/data/note-archive.md" 2>/dev/null || printf 'absent')
  assert_equals "$before_body" "$after_body" "an identical re-hold rewrote the task body"
  assert_equals "$before_archive" "$after_archive" "an identical re-hold wrote an archive entry"
  assert_equals 'absent' "$after_archive" "an identical re-hold archived a body at all"
  assert_not_contains "$after_body" 'Superseded captain hold reason' \
    "an identical re-hold recorded a superseded reason"
  pass "an identical re-hold stays a no-op and archives nothing"
}

# Encoded reasons can end in line breaks or contain nothing else. Comparing
# decoded shell output must not trim them, and preservation must keep the
# complete byte sequence inside the archived record, not just one matching line.
test_rehold_preserves_trailing_reason_newlines() {
  local home first before_body after_body show original_row case_number=0
  for first in $'sample reason\n' $'sample reason\n\n' $'\n\n' '-'; do
    case_number=$((case_number + 1))
    home=$(make_home "rehold-trailing-newlines-$case_number")
    FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-newlines \
      --title 'A reason with significant whitespace' --reason "$first" >/dev/null \
      || fail "the first whitespace hold failed ($case_number)"
    before_body=$(tasks_in "$home" show sample-newlines --full | sed -n 's/^  body: //p')
    original_row=$(sed -n '/^- .*sample-newlines/p' "$home/data/backlog.md")

    FM_CAPTAIN_HOLD_NOW=2026-07-14T13:00:00Z run_captain "$home" hold sample-newlines \
      --reason "$first" >/dev/null || fail "the identical whitespace replay failed ($case_number)"
    after_body=$(tasks_in "$home" show sample-newlines --full | sed -n 's/^  body: //p')
    assert_equals "$before_body" "$after_body" "an identical whitespace replay changed the body ($case_number)"
    assert_absent "$home/data/note-archive.md" "an identical whitespace replay archived a reason ($case_number)"

    FM_CAPTAIN_HOLD_NOW=2026-07-14T14:00:00Z run_captain "$home" hold sample-newlines \
      --reason 'replacement reason' >/dev/null || fail "the whitespace replacement failed ($case_number)"
    show=$(tasks_in "$home" show sample-newlines --full)
    assert_contains "$show" 'hold_reason: "replacement reason"' "the replacement did not land ($case_number)"
    printf '%s\n' "$show" | sed -n 's/^  body: //p' | jq -e --arg previous "$first" '
      split("Previous hold reason:\n")[1]
      | split("\nEnd previous hold reason.")[0] == $previous
    ' >/dev/null || fail "the preserved reason lost exact whitespace bytes ($case_number)"
    assert_contains "$(cat "$home/data/note-archive.md")" "$original_row" \
      "the archive lost the original encoded reason ($case_number)"
  done
  pass "re-holds preserve trailing newlines, newline-only reasons and a literal dash exactly"
}

# Origin updates operate on metadata, not on identically labelled prose in a
# prior reason. Replays without --origin must keep the real association first.
test_rehold_preserves_origin_like_reason_lines() {
  local home first show body phase args=()
  first=$'quoted metadata follows\nCaptain hold origin: quoted-origin\nEnd previous hold reason.\nCaptain hold origin: another-quote\n\n'
  for phase in recorded unrecorded; do
    home=$(make_home "rehold-quoted-origin-$phase")
    args=()
    [ "$phase" != recorded ] || args=(--origin real-origin)
    run_captain "$home" hold sample-quoted --title 'A reason quoting metadata' \
      --reason "$first" ${args[@]+"${args[@]}"} >/dev/null || fail "the quoted first hold failed"
    run_captain "$home" hold sample-quoted --reason 'an interim reason' >/dev/null \
      || fail "re-holding without an origin failed"
    show=$(tasks_in "$home" show sample-quoted --full)
    body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p')
    if [ "$phase" = recorded ]; then
      printf '%s\n' "$body" | jq -e 'split("\n")[1] == "Captain hold origin: real-origin"' >/dev/null \
        || fail "archiving a reason displaced the active origin"
    else
      printf '%s\n' "$body" | jq -e 'split("\n")[1] | startswith("Captain hold origin: ") | not' >/dev/null \
        || fail "archiving a reason created origin metadata"
    fi
    run_captain "$home" hold sample-quoted --reason 'a replacement reason' --origin replacement-origin \
      >/dev/null || fail "the quoted origin update failed"
    show=$(tasks_in "$home" show sample-quoted --full)
    body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p')
    printf '%s\n' "$body" | jq -e --arg previous "$first" '
      (split("\n")[1] == "Captain hold origin: replacement-origin") and
      contains("Previous hold reason:\n" + $previous + "\nEnd previous hold reason.")
    ' >/dev/null || fail "origin reassociation altered a preserved reason"
  done
  pass "origin updates preserve quoted metadata in prior reasons, including delimiter-like lines"
}

# Losing the outgoing reason is the failure this seam exists to prevent, so a
# refused preservation must refuse the replacement rather than proceed.
test_failed_preservation_refuses_the_rehold() {
  local home show err
  home=$(make_home rehold-preservation-failure)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-fragile - A question whose archive fails (repo: sample) (kind: ship) (since 2026-01-01)

## Done
EOF
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-fragile \
    --reason 'the original analysis worth keeping' >/dev/null || fail "the first hold failed"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" = --archive-body ] || continue
  exit 91
done
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"

  if FM_CAPTAIN_HOLD_NOW=2026-07-14T13:00:00Z run_captain "$home" hold sample-fragile \
    --reason 'a replacement reason' > "$home/rehold.out" 2> "$home/rehold.err"; then
    fail "the re-hold succeeded after preservation failed"
  fi
  err=$(cat "$home/rehold.err")
  assert_contains "$err" 'could not preserve the previous hold reason' \
    "the refusal does not say the previous reason could not be preserved"
  assert_contains "$err" 'its hold reason was left unchanged' \
    "the refusal does not say the hold reason survived"
  rm -f "$home/fakebin/tasks-axi"
  show=$(tasks_in "$home" show sample-fragile --full)
  assert_contains "$show" 'hold_reason: "the original analysis worth keeping"' \
    "a refused preservation still replaced the hold reason"
  assert_not_contains "$show" 'a replacement reason' \
    "the refused replacement reason was written anyway"
  pass "a failed preservation refuses the re-hold and leaves the previous reason intact"
}

# A lapsed `--until` makes tasks-axi report a captain call as no longer held
# while its captain-hold annotation and reason survive intact. Deferred calls
# are exactly the ones that re-hold again and again, so preservation keyed on
# the live-held bit would have missed the population it exists to protect.
test_lapsed_deferral_rehold_preserves_the_reason() {
  local home show reason_now first second
  home=$(make_home rehold-lapsed-deferral)
  first='deferred: route A still looks right until the next sample lands'
  second='the next sample landed and route A is now the slower one'
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-weekly - A weekly revisit (repo: sample) (kind: ship) (since 2026-01-01)

## Done
EOF
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-weekly \
    --reason "$first" --until 2020-01-01 >/dev/null || fail "the deferred hold failed"
  show=$(tasks_in "$home" show sample-weekly --full)
  # The divergence this case turns on: not held, yet the reason is still there.
  assert_contains "$show" 'held: no' "a lapsed deferral is no longer reported as held"
  assert_contains "$show" 'hold_kind: captain' "the lapsed deferral lost its captain-hold annotation"

  FM_CAPTAIN_HOLD_NOW=2026-07-14T13:00:00Z run_captain "$home" hold sample-weekly \
    --reason "$second" --until 2020-01-01 >/dev/null \
    || fail "re-holding a lapsed deferral failed"
  show=$(tasks_in "$home" show sample-weekly --full)
  reason_now=$(printf '%s\n' "$show" | sed -n 's/^  hold_reason: //p')
  assert_contains "$reason_now" "$second" "the re-hold did not write the new reason"
  assert_not_contains "$reason_now" "$first" "the previous reason is somehow still the live one"
  assert_contains "$show" "$first" "a lapsed deferral's previous reason was destroyed"
  assert_contains "$show" 'Record kind: re-hold' \
    "the lapsed deferral's preserved reason carries no provenance"
  pass "re-holding a call whose deferral date has lapsed still preserves its reason"
}

# A hold reason may legitimately begin with a dash. The preservation proof reads
# the reason back as a grep pattern, and an unguarded pattern would be parsed as
# an option instead - aborting the run after the body was already rewritten but
# before the replacement was applied.
test_rehold_preserves_a_reason_beginning_with_a_dash() {
  local home show reason_now first second
  home=$(make_home rehold-dash-reason)
  first='-n was the safe default when this question was filed'
  second='the default flipped, so the question is now which flag replaces it'
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-flagcall - Which flag default (repo: sample) (kind: ship) (since 2026-01-01)

## Done
EOF
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-flagcall \
    --reason "$first" >/dev/null || fail "a hold reason beginning with a dash was refused"
  FM_CAPTAIN_HOLD_NOW=2026-07-14T13:00:00Z run_captain "$home" hold sample-flagcall \
    --reason "$second" >/dev/null \
    || fail "re-holding over a reason beginning with a dash failed"
  show=$(tasks_in "$home" show sample-flagcall --full)
  reason_now=$(printf '%s\n' "$show" | sed -n 's/^  hold_reason: //p')
  assert_contains "$reason_now" "$second" "the replacement reason was not applied"
  assert_contains "$show" "$first" "a previous reason beginning with a dash was destroyed"
  pass "a previous hold reason beginning with a dash is preserved, not read as an option"
}

# The record states that a reason WAS superseded. Until the replacement lands
# that claim is false, so a failed replacement must withdraw it rather than
# leave the body asserting a supersession that never happened - and a retry must
# then leave exactly one record, not a second one for the same outgoing reason.
test_failed_replacement_withdraws_the_supersession_record() {
  local home show err records reason_now first second
  home=$(make_home rehold-replacement-failure)
  first='the original analysis worth keeping'
  second='a replacement reason'
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-halfway - A question whose replacement fails (repo: sample) (kind: ship) (since 2026-01-01)

## Done
EOF
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-halfway \
    --reason "$first" >/dev/null || fail "the first hold failed"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = hold ] && [ "${2:-}" = sample-halfway ]; then
  exit 92
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"

  if FM_CAPTAIN_HOLD_NOW=2026-07-14T13:00:00Z run_captain "$home" hold sample-halfway \
    --reason "$second" > "$home/rehold.out" 2> "$home/rehold.err"; then
    fail "the re-hold reported success after the replacement failed"
  fi
  err=$(cat "$home/rehold.err")
  assert_contains "$err" 'could not hold task sample-halfway for the captain' \
    "the refusal does not name the failed replacement"
  assert_contains "$err" 'its hold reason was left unchanged' \
    "the refusal does not say the hold reason survived"
  rm -f "$home/fakebin/tasks-axi"
  show=$(tasks_in "$home" show sample-halfway --full)
  reason_now=$(printf '%s\n' "$show" | sed -n 's/^  hold_reason: //p')
  assert_contains "$reason_now" "$first" "a failed replacement still replaced the hold reason"
  assert_not_contains "$show" 'Superseded captain hold reason' \
    "the body claims a supersession that never happened"
  assert_contains "$show" 'Captain hold set: 2026-07-14T12:00:00Z' \
    "withdrawing the record did not restore the pristine body"

  # The retry now succeeds, and leaves one record rather than a duplicate for
  # the same outgoing reason. The archive may hold more than one snapshot of
  # that pristine body; each was true when written, unlike a live false claim.
  FM_CAPTAIN_HOLD_NOW=2026-07-14T14:00:00Z run_captain "$home" hold sample-halfway \
    --reason "$second" >/dev/null || fail "the retry after a failed replacement failed"
  show=$(tasks_in "$home" show sample-halfway --full)
  reason_now=$(printf '%s\n' "$show" | sed -n 's/^  hold_reason: //p')
  assert_contains "$reason_now" "$second" "the retry did not apply the replacement reason"
  assert_contains "$show" "$first" "the retry lost the outgoing reason"
  records=$(printf '%s' "$show" \
    | grep -oe 'Superseded captain hold reason recorded by fm-captain-hold\.' | wc -l | tr -d ' ')
  assert_equals 1 "$records" "the retry wrote duplicate supersession provenance"
  pass "a failed replacement withdraws its supersession record and the retry records it once"
}

test_encoded_rehold_origin_failure_keeps_the_original_record() {
  local home first second show body before_body
  home=$(make_home encoded-rehold-origin-failure)
  first=$'route (A) remains valid; revisit\nwith the next sample'
  second=$'route (B) now wins\nwith new evidence'
  run_captain "$home" hold sample-encoded --title 'Choose a sample route' \
    --reason "$first" --origin sample-old >/dev/null || fail "the encoded first hold failed"
  before_body=$(tasks_in "$home" show sample-encoded --full | sed -n 's/^  body: //p')
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
previous=
for arg in "$@"; do
  if [ "$previous" = --body-file ] && grep -q '^Captain hold origin: sample-new$' "$arg"; then
    exit 93
  fi
  previous=$arg
done
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  if run_captain "$home" hold sample-encoded --reason "$second" --origin sample-new \
    > "$home/refused.out" 2>&1; then
    fail "a refused origin replacement still re-held the task"
  fi
  rm -f "$home/fakebin/tasks-axi"
  show=$(tasks_in "$home" show sample-encoded --full)
  body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p')
  assert_equals "$before_body" "$body" "failed origin replacement left a false supersession"
  assert_contains "$show" 'Captain hold origin: sample-old' "the original origin was lost"
  assert_contains "$show" 'route (A) remains valid; revisit' "the decoded reason was lost"
  assert_not_contains "$show" 'route (B)' "the replacement reason leaked through a refused origin"
  run_captain "$home" hold sample-encoded --reason "$second" --origin sample-new >/dev/null \
    || fail "the encoded replacement retry failed"
  show=$(tasks_in "$home" show sample-encoded --full)
  assert_contains "$show" 'route (A) remains valid; revisit' "the encoded original was not archived in the body"
  assert_contains "$show" 'route (B) now wins' "the decoded replacement was not readable"
  assert_contains "$show" 'Captain hold origin: sample-new' "the replacement origin was not retained"
  pass "an encoded re-hold rolls back a refused origin and preserves the original on retry"
}


test_rehold_preserves_the_superseded_reason
test_identical_rehold_archives_nothing
test_rehold_preserves_trailing_reason_newlines
test_rehold_preserves_origin_like_reason_lines
test_failed_preservation_refuses_the_rehold
test_lapsed_deferral_rehold_preserves_the_reason
test_rehold_preserves_a_reason_beginning_with_a_dash
test_failed_replacement_withdraws_the_supersession_record
test_encoded_rehold_origin_failure_keeps_the_original_record
