#!/usr/bin/env bash
# Live attached-viewer regression for the Herdr teardown focus guard.
#
# PR #4131 gated the active-tab close refusal on a LIVE foreground client
# instead of the persisted `.focused` pointer, but only its two detached
# scenarios could be driven live: every pseudo-terminal the runner built
# started at a zero-sized window grid, so Herdr registered no foreground client
# and `terminal title clear` kept answering `no_foreground_client`. That was a
# harness limit, not a product one. `fm-herdr-lab.sh viewer start` now attaches
# a real Herdr TUI over a pty sized before the fork, which turns those
# untestable cases into this regression:
#
#   3. a viewer sitting on the target tab blocks the close;
#   4. a viewer that moves ONTO the target between planning and the mutation
#      boundary still blocks it, because the guard re-reads focus there;
#   5. a viewer that moves OFF the target instead keeps its fresh non-target
#      focus after the close, rather than being dragged back to a stale
#      pre-planning pointer;
#   7. the projection's seeded-tab prune inherits the same refusal.
#
# Scenarios 4 and 5 need a focus change at one exact product boundary, so a
# PATH shim performs the real `tab focus` when the close helper issues its
# planning `pane get`. Every Herdr call, the shim's included, still routes
# through the guarded lab helper against a named non-default session.
#
# The guard submits no model prompts, so the shared live gate runs it wherever
# herdr, jq, and python3 exist. Re-run it after every Herdr upgrade: a release
# that changed the foreground-client contract would surface here first.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fm_live_gate default-on FM_HERDR_ATTACHED_VIEWER_LIVE_E2E herdr jq python3

[ -x "$LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $LAB_HELPER"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-herdr-attached-viewer)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FOCUS_SWITCH_CONTROL="$TMP_ROOT/focus-switch"
ORIGINAL_PATH=$PATH
LAB_SESSION=$("$LAB_HELPER" name fm-herdr-attached-viewer)
export LAB_HELPER LAB_SESSION ORIGINAL_PATH FOCUS_SWITCH_CONTROL

cleanup() {
  local status=$?
  env PATH="$ORIGINAL_PATH" "$LAB_HELPER" viewer stop "$LAB_SESSION" >/dev/null 2>&1 || status=1
  env PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$LAB_SESSION" || fail "could not provision the isolated Herdr lab"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" "$@"; }

# The adapter under test calls `herdr` by name. This shim strips the trailing
# session flag the helper will re-append, refuses any caller-supplied one, and
# optionally performs one real focus change at the requested product boundary
# before forwarding the call.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ -f "$FOCUS_SWITCH_CONTROL/trigger" ] && [ "$*" = "$(cat "$FOCUS_SWITCH_CONTROL/trigger")" ]; then
  rm -f "$FOCUS_SWITCH_CONTROL/trigger"
  env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" \
    tab focus "$(cat "$FOCUS_SWITCH_CONTROL/tab")" >/dev/null 2>&1
  printf '%s\n' switched > "$FOCUS_SWITCH_CONTROL/done"
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

mkdir -p "$FOCUS_SWITCH_CONTROL"

# Arm the shim to run `tab focus <tab>` immediately before the adapter's own
# `pane get <pane>` planning read, which is the last product call before the
# close helper re-reads focus at its mutation boundary.
arm_focus_switch() { # <tab-id> <pane-id>
  rm -f "$FOCUS_SWITCH_CONTROL/done"
  printf '%s\n' "$1" > "$FOCUS_SWITCH_CONTROL/tab"
  printf 'pane get %s\n' "$2" > "$FOCUS_SWITCH_CONTROL/trigger"
}

assert_focus_switch_fired() { # <label>
  [ -f "$FOCUS_SWITCH_CONTROL/done" ] \
    || fail "$1: the mid-close focus switch never ran, so the timing boundary was not exercised"
  rm -f "$FOCUS_SWITCH_CONTROL/done" "$FOCUS_SWITCH_CONTROL/trigger"
}

# Drive one real adapter entry point with the shim on PATH.
drive() { # <function> <argument...>
  PATH="$FAKEBIN:$ORIGINAL_PATH" bash -c '
    . "$1/bin/backends/herdr.sh"
    fm_backend_herdr_cli() {
      local session=$1
      shift
      HERDR_SESSION="$session" herdr "$@" --session "$session"
    }
    fn=$2
    shift 2
    "$fn" "$@" || exit $?
    if [ "$fn" = fm_backend_herdr_projection_create_task ]; then
      printf "%s\t%s\t%s\n" "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" \
        "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" "$FM_BACKEND_HERDR_PROJECTION_PANE_ID"
    fi
  ' _ "$ROOT" "$@" 2>&1
}

# These run inside command substitutions, where `fail` would exit only the
# subshell and let the script carry on with empty ids. They return non-zero
# instead, and every call site carries its own `|| fail`.
new_workspace() { # <label> -> "<workspace>\t<tab>\t<pane>"
  local out
  out=$(lab workspace create --cwd "$ROOT" --label "$1" --no-focus) || return 1
  printf '%s' "$out" | jq -er '
    [.result.workspace.workspace_id, .result.tab.tab_id, .result.root_pane.pane_id] | @tsv
  '
}

new_tab() { # <workspace> <label> -> "<tab>\t<pane>"
  local out
  out=$(lab tab create --workspace "$1" --label "$2" --cwd "$ROOT") || return 1
  printf '%s' "$out" | jq -er '[.result.tab.tab_id, .result.root_pane.pane_id] | @tsv'
}

focused_tab() {
  lab workspace list | jq -er '
    [.result.workspaces[] | select(.focused == true)] | select(length == 1) | .[0].active_tab_id
  '
}

pane_exists() { lab pane get "$1" >/dev/null 2>&1; }

foreground_reason() {
  lab terminal title clear | jq -er '.result.reason'
}

# --- the attachment itself, which is what #4131 could not do ----------------

REASON=$(foreground_reason) || fail "could not probe the session's foreground client"
[ "$REASON" = no_foreground_client ] \
  || fail "the fresh lab already had a foreground client (reason=$REASON)"

"$LAB_HELPER" viewer start "$LAB_SESSION" >/dev/null \
  || fail "could not attach a real foreground Herdr viewer over a sized pty"
REASON=$(foreground_reason) || fail "could not probe the session's foreground client"
[ "$REASON" = cleared ] \
  || fail "the attached pty viewer did not register as a foreground client (reason=$REASON)"
pass "attached viewer: a pty sized before the fork registers as a real Herdr foreground client"

# Projection creation must keep the attached viewer's exact prior selection.
# The CLI shim also scopes version/server probes to this same guarded lab.
FIXTURE=$(new_workspace observer-focus) || fail "could not create the observer workspace"
BEFORE_CREATE=${FIXTURE#*$'\t'}
BEFORE_CREATE=${BEFORE_CREATE%%$'\t'*}
lab tab focus "$BEFORE_CREATE" >/dev/null || fail "could not focus the observer tab"
BEFORE_CREATE=$(focused_tab) || fail "could not capture attached-viewer focus"
OUT=$(HERDR_SESSION="$LAB_SESSION" drive fm_backend_herdr_projection_create_task \
  "$ROOT" '└ example · p:AbCdEfGhIjKlMnOpQrStUv' 'fm-example')
STATUS=$?
[ "$STATUS" -eq 0 ] || fail "attached-viewer projection creation failed: $OUT"
[ "$(focused_tab)" = "$BEFORE_CREATE" ] || fail "projection creation moved attached-viewer focus"
pass "attached viewer: projected workspace and task creation preserve the exact prior tab"

# Advance only the adapter's clock, leaving the lab helper and viewer on real
# time, to exercise the production lease against an actual attached client.
IFS=$'\t' read -r LEASE_WS LEASE_TAB LEASE_PANE <<<"$OUT"
LEASE_PARENT=$(lab tab get "$BEFORE_CREATE" | jq -er '.result.tab.workspace_id') \
  || fail "could not resolve the launching workspace"
LEASE_PARENT_LABEL=$(lab workspace list | jq -er --arg ws "$LEASE_PARENT" \
  '.result.workspaces[] | select(.workspace_id == $ws) | .label') \
  || fail "could not read the exact launching workspace label"
mkdir -p "$TMP_ROOT/state"
drive fm_backend_herdr_projection_journal_create "$TMP_ROOT/state" example >/dev/null \
  || fail "could not create the live lease journal"
drive fm_backend_herdr_projection_journal_write_v2 "$TMP_ROOT/state/example.herdr-presentation" \
  example AbCdEfGhIjKlMnOpQrStUv "$TMP_ROOT" "$LAB_SESSION" \
  "$LEASE_WS" "$LEASE_TAB" "$LEASE_PANE" "$LEASE_PARENT" "$LEASE_PARENT_LABEL" \
  '└ example · p:AbCdEfGhIjKlMnOpQrStUv' fm-example >/dev/null \
  || fail "could not bind the live lease journal"
printf '%s\n' 'kind=ship' 'spawn_gen=live-example' "window=$LAB_SESSION:$LEASE_PANE" \
  "herdr_session=$LAB_SESSION" "herdr_workspace_id=$LEASE_WS" \
  "herdr_tab_id=$LEASE_TAB" "herdr_pane_id=$LEASE_PANE" > "$TMP_ROOT/state/example.meta"
printf 'done [at=10000]: ready\n' > "$TMP_ROOT/state/example.status"
LEASE_CLOCK="$TMP_ROOT/lease-clock"
export LEASE_CLOCK
printf '10000\n' > "$LEASE_CLOCK"
cat > "$FAKEBIN/date" <<'SH'
#!/usr/bin/env bash
if [ "$*" = +%s ]; then cat "$LEASE_CLOCK"; else exec /bin/date "$@"; fi
SH
chmod +x "$FAKEBIN/date"
lab tab focus "$LEASE_TAB" >/dev/null || fail "could not focus the finished task"
OUT=$(drive fm_backend_herdr_projection_close_finished_task \
  "$LAB_SESSION" "$LEASE_PANE" "$TMP_ROOT/state" example "$TMP_ROOT")
STATUS=$?
[ "$STATUS" -ne 0 ] && pane_exists "$LEASE_PANE" \
  || fail "the initial lease did not protect the attached viewer: $OUT"
printf '10900\n' > "$LEASE_CLOCK"
OUT=$(drive fm_backend_herdr_projection_close_finished_task \
  "$LAB_SESSION" "$LEASE_PANE" "$TMP_ROOT/state" example "$TMP_ROOT")
STATUS=$?
rm -f "$FAKEBIN/date"
[ "$STATUS" -eq 0 ] || fail "the real attached-viewer lease did not expire: $OUT"
if pane_exists "$LEASE_PANE"; then fail "the expired lease left the finished pane"; fi
[ "$(focused_tab)" = "$BEFORE_CREATE" ] || fail "lease expiry did not preserve the exact launching tab"
[ "$(foreground_reason)" = cleared ] || fail "lease expiry detached the foreground viewer"
pass "attached viewer: finished-task focus lease refuses initially and closes after a verified launching-tab handoff at expiry"

# --- scenario 3: a viewer on the target tab blocks the close ---------------

FIXTURE=$(new_workspace viewer-active) || fail "could not create the scenario 3 workspace"
IFS=$'\t' read -r WS_THREE TAB_THREE_A PANE_THREE_A <<<"$FIXTURE"
# A second tab keeps the close a plain one rather than an emptying-workspace plan.
new_tab "$WS_THREE" viewer-active-b >/dev/null || fail "could not create the scenario 3 companion tab"
lab tab focus "$TAB_THREE_A" >/dev/null || fail "could not focus the scenario 3 target tab"
[ "$(focused_tab)" = "$TAB_THREE_A" ] || fail "scenario 3 did not start focused on the target tab"

OUT=$(drive fm_backend_herdr_projection_close_pane_focus_preserving "$LAB_SESSION" "$PANE_THREE_A")
STATUS=$?
[ "$STATUS" -ne 0 ] || fail "a live viewer on the target tab did not block the close: $OUT"
assert_contains "$OUT" "target is the captain's active tab" \
  "the live-viewer refusal did not name the captain's active tab: $OUT"
pane_exists "$PANE_THREE_A" \
  || fail "the close proceeded and destroyed the tab the live viewer was watching"
pass "attached viewer: a live client on the target tab refuses the close and keeps the pane"

# --- scenario 4: the viewer moves ONTO the target mid-close ----------------

FIXTURE=$(new_workspace viewer-late-on) || fail "could not create the scenario 4 workspace"
IFS=$'\t' read -r WS_FOUR TAB_FOUR_A PANE_FOUR_A <<<"$FIXTURE"
FIXTURE=$(new_tab "$WS_FOUR" viewer-late-on-b) || fail "could not create the scenario 4 companion tab"
IFS=$'\t' read -r TAB_FOUR_B _ <<<"$FIXTURE"
lab tab focus "$TAB_FOUR_B" >/dev/null || fail "could not focus away from the scenario 4 target"
[ "$(focused_tab)" = "$TAB_FOUR_B" ] || fail "scenario 4 did not start focused off the target tab"

arm_focus_switch "$TAB_FOUR_A" "$PANE_FOUR_A"
OUT=$(drive fm_backend_herdr_projection_close_pane_focus_preserving "$LAB_SESSION" "$PANE_FOUR_A")
STATUS=$?
assert_focus_switch_fired "scenario 4"
[ "$STATUS" -ne 0 ] \
  || fail "a viewer that moved onto the target after planning did not block the close: $OUT"
assert_contains "$OUT" "target is the captain's active tab" \
  "the late-switch refusal did not come from the fresh active-tab check: $OUT"
pane_exists "$PANE_FOUR_A" \
  || fail "the close destroyed a tab the viewer had moved onto before the mutation boundary"
[ "$(focused_tab)" = "$TAB_FOUR_A" ] \
  || fail "the refused close restored over the viewer's fresh target selection"
pass "attached viewer: focus moving onto the target between planning and mutation still blocks the close"

# --- scenario 5: the viewer moves OFF the target mid-close -----------------

FIXTURE=$(new_workspace viewer-late-off) || fail "could not create the scenario 5 workspace"
IFS=$'\t' read -r WS_FIVE TAB_FIVE_A PANE_FIVE_A <<<"$FIXTURE"
FIXTURE=$(new_tab "$WS_FIVE" viewer-late-off-b) || fail "could not create the scenario 5 companion tab"
IFS=$'\t' read -r TAB_FIVE_B _ <<<"$FIXTURE"
lab tab focus "$TAB_FIVE_A" >/dev/null || fail "could not focus the scenario 5 target tab"
[ "$(focused_tab)" = "$TAB_FIVE_A" ] || fail "scenario 5 did not start focused on the target tab"

arm_focus_switch "$TAB_FIVE_B" "$PANE_FIVE_A"
OUT=$(drive fm_backend_herdr_projection_close_pane_focus_preserving "$LAB_SESSION" "$PANE_FIVE_A")
STATUS=$?
assert_focus_switch_fired "scenario 5"
[ "$STATUS" -eq 0 ] \
  || fail "the close was refused even though the live viewer had moved off the target: $OUT"
if pane_exists "$PANE_FIVE_A"; then
  fail "the close reported success but left the target pane behind"
fi
[ "$(focused_tab)" = "$TAB_FIVE_B" ] \
  || fail "the close did not preserve the viewer's fresh non-target focus (focus is $(focused_tab), expected $TAB_FIVE_B)"
pass "attached viewer: a close preserves the fresh non-target focus the viewer moved to"

# --- scenario 7: the projection's seeded-tab prune inherits the refusal ----

FIXTURE=$(new_workspace viewer-seeded) || fail "could not create the scenario 7 workspace"
IFS=$'\t' read -r WS_SEVEN TAB_SEVEN_SEEDED PANE_SEVEN_SEEDED <<<"$FIXTURE"
FIXTURE=$(new_tab "$WS_SEVEN" fm-viewer-seeded-task) || fail "could not create the scenario 7 task tab"
IFS=$'\t' read -r _ PANE_SEVEN_TASK <<<"$FIXTURE"
lab tab list --workspace "$WS_SEVEN" \
  | jq -e --arg tab "$TAB_SEVEN_SEEDED" '.result.tabs[] | select(.tab_id == $tab) | .label == "1"' >/dev/null \
  || fail "the seeded tab is not the label-1 default tab the prune identifies"
lab tab focus "$TAB_SEVEN_SEEDED" >/dev/null || fail "could not focus the seeded tab"
[ "$(focused_tab)" = "$TAB_SEVEN_SEEDED" ] || fail "scenario 7 did not start focused on the seeded tab"

OUT=$(drive fm_backend_herdr_workspace_prune_seeded_default_tab \
  "$LAB_SESSION" "$WS_SEVEN" "$TAB_SEVEN_SEEDED" focus-preserving)
STATUS=$?
[ "$STATUS" -ne 0 ] || fail "the seeded prune did not refuse the tab a live viewer was watching: $OUT"
assert_contains "$OUT" "target is the captain's active tab" \
  "the seeded prune refusal did not come from the live-viewer guard: $OUT"
pane_exists "$PANE_SEVEN_SEEDED" \
  || fail "the seeded prune closed the tab the live viewer was watching"
pane_exists "$PANE_SEVEN_TASK" || fail "the seeded prune disturbed the task pane"
pass "attached viewer: the projection seeded-tab prune refuses while a live client watches it"

# --- detaching restores the no-client contract the detached tests rely on ---

"$LAB_HELPER" viewer stop "$LAB_SESSION" >/dev/null \
  || fail "could not detach the lab viewer"
REASON=$(foreground_reason) || fail "could not probe the session's foreground client"
[ "$REASON" = no_foreground_client ] \
  || fail "the lab still reported a foreground client after the viewer stopped (reason=$REASON)"
OUT=$(drive fm_backend_herdr_projection_close_pane_focus_preserving "$LAB_SESSION" "$PANE_THREE_A")
STATUS=$?
[ "$STATUS" -eq 0 ] || fail "the same close was still refused after the viewer detached: $OUT"
if pane_exists "$PANE_THREE_A"; then
  fail "the detached close reported success but left the pane behind"
fi
pass "attached viewer: detaching releases the refusal, so the guard tracks the client and not the pointer"
