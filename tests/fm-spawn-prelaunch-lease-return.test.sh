#!/usr/bin/env bash
# Regression tests for when fm-spawn.sh's pre-launch abort may return the slot
# it leased. `treehouse return --force` resets the slot, so it is safe only
# when nothing it resets belongs to anyone else:
#
# - the pane shell sitting in the slot is proven gone. Herdr proves that only
#   with a structured pane_not_found; any other failed read is unknown. Zellij
#   and cmux have no structured absence read at all. An unknown endpoint keeps
#   the lease and its receipt, the rule teardown uses.
# - the slot holds only wiring this spawn wrote after leasing it. A wiring
#   path already present at lease time belongs to an earlier tenant.
# - any provisional task record was rolled back, so no record is left naming
#   a slot Treehouse may hand to another task.
#
# Each case drives the abort cleanup functions extracted from fm-spawn.sh, in
# the EXIT trap's order, against the real backend adapters, with a fake
# backend CLI and a fake treehouse on PATH. No real Herdr, Zellij, or cmux
# server is started, and no tmux server is touched.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh" || exit 1

SPAWN="$ROOT/bin/fm-spawn.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found; the herdr presence read needs it"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-spawn-prelaunch-lease-return)
trap fm_test_cleanup EXIT

FUNCS="$TMP_ROOT/abort-cleanup.sh"
FNS="spawn_endpoint_absent spawn_endpoint_proven_absent spawn_endpoint_close_confirmed
  spawn_slot_status spawn_slot_holds_only_spawn_wiring spawn_prelaunch_abort_cleanup
  spawn_prelaunch_return_lease"
for fn in $FNS; do
  awk -v fn="$fn" '$0 ~ "^" fn "\\(\\) *\\{" {on=1} on {print} on && /^}/ {exit}' "$SPAWN"
done > "$FUNCS"
for fn in $FNS; do
  grep -q "^$fn()" "$FUNCS" || fail "could not extract $fn from bin/fm-spawn.sh"
done

# The driver leases the slot, recording its state as the spawn does, then runs
# what the EXIT trap runs for a fresh spawn that created its endpoint and
# leased its slot: the endpoint close and, after the task record's rollback,
# the lease return. FM_TEST_RECORD_STUCK=1 stands for a failed rollback, and
# FM_TEST_WRITE_WIRING=1 writes the Claude wiring file after the lease. The
# close itself is a no-op, as when Herdr skips a close it could not lock.
DRIVER="$TMP_ROOT/driver.sh"
cat > "$DRIVER" <<'SH'
#!/usr/bin/env bash
set -u
. "$FM_TEST_ROOT/bin/fm-backend.sh"
. "$FM_TEST_FUNCS"
fm_backend_kill() { printf 'kill %s\n' "$*" >> "$FM_TEST_CASE/kill-calls"; return 0; }
fm_control_harness_family() { printf 'claude\n'; }
fm_control_harness_wiring_paths() { printf '%s\n' "$2/.claude/settings.local.json"; }
BACKEND=$FM_TEST_BACKEND T=$FM_TEST_TARGET W=fm-$FM_TEST_ID ID=$FM_TEST_ID
HARNESS=claude WT=$FM_TEST_WT PROJ_ABS=$FM_TEST_PROJ STATE=$FM_TEST_CASE STATE_REAL=$FM_TEST_CASE
SPAWN_TREEHOUSE_RECEIPT=$FM_TEST_CASE/$FM_TEST_ID.treehouse-lease
SPAWN_TREEHOUSE_PROJECT_LOCK= SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=1
SPAWN_PRELAUNCH_ENDPOINT=1 SPAWN_PRELAUNCH_WIRING=0 SPAWN_PRELAUNCH_LEASE=1
SPAWN_PRELAUNCH_ENDPOINT_GONE=1 SPAWN_SLOT_LEASED_STATUS_OK=0
SPAWN_FRESH_COMMIT_PENDING=${FM_TEST_RECORD_STUCK:-0}
SPAWN_SLOT_LEASED_STATUS=$(spawn_slot_status) && SPAWN_SLOT_LEASED_STATUS_OK=1
if [ "${FM_TEST_WRITE_WIRING:-0}" = 1 ]; then
  mkdir -p "$WT/.claude" && printf '{}\n' > "$WT/.claude/settings.local.json"
fi
spawn_prelaunch_abort_cleanup
spawn_prelaunch_return_lease
SH

make_case() {  # <name> -> case_dir|proj|wt|fakebin
  local name=$1 case_dir proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  fm_fake_treehouse_lease "$fakebin"
  fm_git_worktree "$proj" "$wt" "fm/$name"
  printf 'lease\n' > "$case_dir/pe-$name.treehouse-lease"
  printf '%s\n' "$case_dir|$proj|$wt|$fakebin"
}

# A backend CLI stub that fails every call, printing <body> when given.
fake_cli() {  # <fakebin> <tool> [body]
  printf '%s' "${3:-}" > "$1/$2-body"
  cat > "$1/$2" <<'SH'
#!/usr/bin/env bash
tool=$(basename "$0")
printf '%s\n' "$*" >> "$(dirname "$0")/$tool-calls"
[ ! -s "$(dirname "$0")/$tool-body" ] || { cat "$(dirname "$0")/$tool-body"; printf '\n'; }
exit 1
SH
  chmod +x "$1/$2"
}

PANE_GONE='{"error":{"code":"pane_not_found","message":"pane not found"}}'

run_cleanup() {  # <backend> <target> <case_dir> <proj> <wt> <fakebin> <name>
  FM_TEST_ROOT="$ROOT" FM_TEST_FUNCS="$FUNCS" FM_TEST_BACKEND=$1 FM_TEST_TARGET=$2 \
    FM_TEST_CASE=$3 FM_TEST_PROJ=$4 FM_TEST_WT=$5 FM_TEST_ID="pe-$7" \
    PATH="$6:$PATH" bash "$DRIVER" 2>&1
}

# A kept lease keeps its receipt and reports why.
assert_lease_kept() {  # <label> <case_dir> <fakebin> <name> <output> [reason]
  local label=$1 case_dir=$2 fakebin=$3 name=$4 out=$5
  local reason=${6:-because its endpoint may still be open}
  ! grep -q '^return ' "$fakebin/treehouse-calls" 2>/dev/null ||
    fail "$label: the slot was returned when it must be kept: $out"
  [ -f "$case_dir/pe-$name.treehouse-lease" ] || fail "$label: the retained lease lost its receipt: $out"
  case "$out" in
    *"$reason"*) ;;
    *) fail "$label: the retention must be reported ($reason), got: $out" ;;
  esac
}

test_herdr_unknown_presence_keeps_the_lease() {
  local fields case_dir proj wt fakebin out
  fields=$(make_case herdr-unknown)
  IFS='|' read -r case_dir proj wt fakebin <<EOF
$fields
EOF
  fake_cli "$fakebin" herdr '{"error":{"code":"server_error","message":"protocol error"}}'
  out=$(run_cleanup herdr fmtest:p7 "$case_dir" "$proj" "$wt" "$fakebin" herdr-unknown)
  grep -q '^pane get p7' "$fakebin/herdr-calls" 2>/dev/null ||
    fail "herdr-unknown: the case must read the pane, or it proves nothing: $out"
  assert_lease_kept herdr-unknown "$case_dir" "$fakebin" herdr-unknown "$out"
  pass "fm-spawn.sh: a Herdr pane whose presence reads as unknown keeps the leased slot"
}

test_herdr_silent_failure_keeps_the_lease() {
  local fields case_dir proj wt fakebin out
  fields=$(make_case herdr-silent)
  IFS='|' read -r case_dir proj wt fakebin <<EOF
$fields
EOF
  fake_cli "$fakebin" herdr
  out=$(run_cleanup herdr fmtest:p7 "$case_dir" "$proj" "$wt" "$fakebin" herdr-silent)
  assert_lease_kept herdr-silent "$case_dir" "$fakebin" herdr-silent "$out"
  pass "fm-spawn.sh: a Herdr pane read that fails without a structured answer keeps the leased slot"
}

test_herdr_pane_not_found_returns_the_slot() {
  local fields case_dir proj wt fakebin out
  fields=$(make_case herdr-gone)
  IFS='|' read -r case_dir proj wt fakebin <<EOF
$fields
EOF
  fake_cli "$fakebin" herdr "$PANE_GONE"
  out=$(FM_TEST_WRITE_WIRING=1 run_cleanup herdr fmtest:p7 "$case_dir" "$proj" "$wt" "$fakebin" herdr-gone)
  grep -qxF -- "return --force $wt" "$fakebin/treehouse-calls" 2>/dev/null ||
    fail "herdr-gone: a pane proven gone must return the slot; treehouse calls: $(cat "$fakebin/treehouse-calls" 2>/dev/null); output: $out"
  [ ! -e "$case_dir/pe-herdr-gone.treehouse-lease" ] || fail "herdr-gone: the returned slot kept its receipt"
  pass "fm-spawn.sh: a Herdr pane proven gone returns a slot holding only the wiring written after leasing"
}

test_no_proof_backend_keeps_the_lease() {  # <backend> <target>
  local backend=$1 target=$2 name="$1-failed" fields case_dir proj wt fakebin out
  fields=$(make_case "$name")
  IFS='|' read -r case_dir proj wt fakebin <<EOF
$fields
EOF
  fake_cli "$fakebin" "$backend"
  out=$(run_cleanup "$backend" "$target" "$case_dir" "$proj" "$wt" "$fakebin" "$name")
  assert_lease_kept "$name" "$case_dir" "$fakebin" "$name" "$out"
  pass "fm-spawn.sh: a $backend endpoint whose existence read fails keeps the leased slot"
}

# A wiring path already in the slot when it was leased was left by an earlier
# tenant, even though this spawn's harness writes the same path.
test_preexisting_wiring_keeps_the_lease() {
  local fields case_dir proj wt fakebin out
  fields=$(make_case wiring-before)
  IFS='|' read -r case_dir proj wt fakebin <<EOF
$fields
EOF
  mkdir -p "$wt/.claude"
  printf '{"earlier":"tenant"}\n' > "$wt/.claude/settings.local.json"
  fake_cli "$fakebin" herdr "$PANE_GONE"
  out=$(FM_TEST_WRITE_WIRING=1 run_cleanup herdr fmtest:p7 "$case_dir" "$proj" "$wt" "$fakebin" wiring-before)
  assert_lease_kept wiring-before "$case_dir" "$fakebin" wiring-before "$out" \
    'holds content this spawn did not write (.claude/settings.local.json)'
  [ -f "$wt/.claude/settings.local.json" ] || fail "wiring-before: the earlier tenant's file was removed"
  pass "fm-spawn.sh: a wiring path already in the slot when leased keeps the lease"
}

# A provisional task record that could not be rolled back still names the
# slot, so the slot must not go back to the pool.
test_stuck_record_keeps_the_lease() {
  local fields case_dir proj wt fakebin out
  fields=$(make_case record-stuck)
  IFS='|' read -r case_dir proj wt fakebin <<EOF
$fields
EOF
  fake_cli "$fakebin" herdr "$PANE_GONE"
  out=$(FM_TEST_RECORD_STUCK=1 run_cleanup herdr fmtest:p7 "$case_dir" "$proj" "$wt" "$fakebin" record-stuck)
  assert_lease_kept record-stuck "$case_dir" "$fakebin" record-stuck "$out" 'could not be rolled back'
  pass "fm-spawn.sh: a task record that could not be rolled back keeps the lease"
}

test_herdr_unknown_presence_keeps_the_lease
test_herdr_silent_failure_keeps_the_lease
test_herdr_pane_not_found_returns_the_slot
test_no_proof_backend_keeps_the_lease zellij fmtest:3
test_no_proof_backend_keeps_the_lease cmux ws-1:sf-1
test_preexisting_wiring_keeps_the_lease
test_stuck_record_keeps_the_lease
