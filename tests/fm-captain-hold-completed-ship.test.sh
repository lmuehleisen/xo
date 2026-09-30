#!/usr/bin/env bash
# tests/fm-captain-hold-completed-ship.test.sh - holding a completed ship for
# the captain's approval (bin/fm-captain-hold.sh hold and complete).
#
# A finished ship awaiting approval enters an idempotent declared wait, stays in
# flight and held, appears in Bearings' captain calls, and never hides a newer
# worker event. The watcher's side of the same wait is pinned by
# tests/fm-watch-completed-ship-hold.test.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-hold-completed-ship)
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
  (cd "$home" && tasks-axi "$@")
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

run_bearings() {  # <home> [extra args]
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind" \
    "spawn_gen=fixture-$id"
}

test_completed_ship_hold_declares_wait() {
  local home id before after last show variant json
  for variant in hold complete; do
    home=$(make_home "completed-ship-$variant")
    id='finished-ship'
    tasks_in "$home" add "$id" 'Completed branch awaiting approval' --kind ship --repo sample --start >/dev/null
    write_origin_meta "$home" "$id" ship
    printf 'mode=local-only\n' >> "$home/state/$id.meta"
    printf 'done: ready in branch fm/finished-ship\n' > "$home/state/$id.status"
    if [ "$variant" = hold ]; then
      run_captain "$home" hold "$id" --reason 'Awaiting local merge approval' >/dev/null
    else
      tasks_in "$home" hold "$id" --kind captain --reason 'Awaiting local merge approval' >/dev/null
      run_captain "$home" complete "$id" "$id" >/dev/null
    fi
    last=$(tail -n 1 "$home/state/$id.status")
    # Self-announced status lines carry an emission stamp (bin/fm-wake-lib.sh).
    printf '%s\n' "$last" | grep -Eq '^captain-held \[key=completed-ship-hold\]( \[at=[0-9]+\])?: tracked by finished-ship$' \
      || fail "plain-done ship did not enter its declared wait: $last"
    before=$(wc -c < "$home/state/$id.status")
    run_captain "$home" hold "$id" --reason 'Awaiting local merge approval' >/dev/null
    run_captain "$home" complete "$id" "$id" >/dev/null
    after=$(wc -c < "$home/state/$id.status")
    [ "$before" = "$after" ] || fail "retry appended duplicate captain-held status"
    show=$(tasks_in "$home" show "$id" --full)
    assert_contains "$show" 'held: yes' "completed ship lost its approval requirement"
    assert_contains "$show" 'state: in_flight' "declaring a wait closed the ship"
    json=$(run_bearings "$home") || fail "Bearings failed for the completed held ship"
    printf '%s' "$json" | jq -e --arg id "$id" '.decisions_open | any(.id == $id)' >/dev/null \
      || fail "completed ship awaiting approval is missing from Captain's Call"
    # A new worker event must not be hidden by a repeated hold/complete.
    printf 'blocked: new permission prompt\n' >> "$home/state/$id.status"
    run_captain "$home" hold "$id" --reason 'Awaiting local merge approval' >/dev/null
    [ "$(tail -n 1 "$home/state/$id.status")" = 'blocked: new permission prompt' ] \
      || fail "hold hid a new permission gate"
  done
  pass "holding a completed ship declares an idempotent wait without closing work or hiding a new gate"
}


test_completed_ship_hold_declares_wait
