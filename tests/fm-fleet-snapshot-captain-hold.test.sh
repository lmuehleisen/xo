#!/usr/bin/env bash
# tests/fm-fleet-snapshot-captain-hold.test.sh - captain_actionable for captain
# holds on in-flight work (bin/fm-fleet-snapshot.sh --json).
#
# An in-flight captain hold is waiting on the captain now, while a deferred,
# dependency-blocked, external, unheld, or closed record is not. The shared
# snapshot and fleet-view cases live in tests/fm-fleet-snapshot-view.test.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot-captain-hold)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

test_inflight_captain_hold_actionability() {
  local home fakebin out
  home=$(make_home inflight-captain-hold)
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux no-mistakes
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ready - Merge approval (repo: alpha) (kind: ship) (hold: choose merge) (hold-kind: captain)
- [ ] dated - Later approval (repo: alpha) (kind: ship) (hold: revisit later) (hold-kind: captain) (hold-until: 2099-01-01)
- [ ] blocked - Dependent approval blocked-by: missing (repo: alpha) (kind: ship) (hold: choose route) (hold-kind: captain)
- [ ] external - External wait (repo: alpha) (kind: ship) (hold: awaiting server) (hold-kind: external)
- [ ] working - Normal work (repo: alpha) (kind: ship)

## Queued

## Done
- [x] closed - Answered call (repo: alpha) (kind: ship) (hold: choose release) (hold-kind: captain) (done 2026-09-09)
EOF
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-09-09T12:00:00Z "$SNAPSHOT" --json) \
    || fail "in-flight captain-hold snapshot failed"
  printf '%s' "$out" | jq -e '
    (.backlog.records | length) == 6
      and ([.backlog.records[] | select(.captain_actionable) | .id] == ["ready"])
      and (.backlog.records[] | select(.id == "ready")
        | .state == "in_flight" and .current_role == "held")
  ' >/dev/null || fail "in-flight hold actionability lost its date, dependency, kind, or closed-state boundary: $out"
  pass "in-flight captain holds are actionable without promoting deferred, blocked, external, unheld, or closed work"
}

test_inflight_captain_hold_actionability
