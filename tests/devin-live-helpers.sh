#!/usr/bin/env bash
# tests/devin-live-helpers.sh - fork-only lab for the Devin live guards that
# exercise fork behavior (the reviewed permission policy and the rate-limit
# retry) on the real generated launch, the same way the common guard
# tests/fm-devin-signals-live-e2e.test.sh does.
#
# Source after tests/fixtures.sh and the guard's fm_live_gate:
#   devin_lab_init <label>
#       Resolves devin and tmux, skips the guard when Devin is signed out or
#       has no file credentials to copy, and builds an isolated home (H), user
#       HOME ($H/user-home, with copied credentials), project (PROJ), and
#       worktree (WT) under a fresh LAB, removed on exit.
#   devin_lab_spawn <id> <brief-text> [fm-spawn args...]
#       Writes the brief, runs the real fm-spawn with fixture tmux and a real
#       devin, then starts the generated launch in a pane of this lab's own
#       tmux server. Write the user config under $H/user-home/.config/devin
#       first; set DEVIN_LAB_PANE_ENV to extra `NAME=value` words for the pane.
#       Afterwards PATH resolves `tmux` to this lab's server and FM_HOME is H,
#       so the real fm-send and fm-control drive the pane.
#   capture, screen_text, wait_file <path>, wait_idle
#
# Every tmux call runs with TMUX and TMUX_PANE removed on the lab's own -S
# socket and `devin-lab` session, never the default server.
unset TMUX TMUX_PANE

# ROOT comes from tests/lib.sh, which the guard sources through fixtures.sh.
# shellcheck disable=SC2153
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

devin_lab_init() {  # <label>
  DEVIN_BIN=$(command -v devin)
  REAL_TMUX=$(command -v tmux)
  VERSION=$(devin --version)
  if ! devin auth status 2>/dev/null | grep -q '^Logged in'; then
    printf 'skip: live: %s is signed out; run devin auth login\n' "$VERSION"
    exit 0
  fi
  local credentials="$HOME/.local/share/devin/credentials.toml"
  if [ ! -r "$credentials" ]; then
    printf 'skip: live: %s has no file credentials to copy into the isolated home\n' "$VERSION"
    exit 0
  fi
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX")
  LAB=$(cd "$LAB" && pwd -P)
  # Unix-domain socket paths have a small OS byte limit.
  SOCKET="$LAB/tmux.sock"
  case "$SOCKET" in "$PWD"/*) SOCKET=${SOCKET#"$PWD"/} ;; esac
  trap devin_lab_cleanup EXIT
  H="$LAB/home"
  WT="$LAB/wt"
  PROJ="$LAB/project"
  fm_test_spawn_home "$H" devin
  fm_git_worktree "$PROJ" "$WT" devin-lab
  git -C "$WT" config user.name 'Devin Live Guard'
  git -C "$WT" config user.email devin-live-guard@example.invalid
  mkdir -p "$H/user-home/.local/share/devin" "$H/user-home/.config/devin" "$LAB/bin"
  cp "$credentials" "$H/user-home/.local/share/devin/credentials.toml"
  chmod 600 "$H/user-home/.local/share/devin/credentials.toml"
}

devin_lab_cleanup() {
  local rc=$?
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1 || true
  if [ "$rc" -ne 0 ] && [ -n "${DEVIN_LAB_KEEP:-}" ]; then
    printf 'Devin lab evidence retained: %s\n' "$LAB" >&2
  else
    rm -rf "$LAB"
  fi
}

devin_lab_spawn() {  # <id> <brief-text> [fm-spawn args...]
  local id=$1 brief=$2 fakebin
  shift 2
  ID=$id
  fm_test_spawn_brief "$H" "$ID" "$brief"
  fakebin=$(make_spawn_fakebin "$LAB/fake" claude)
  ln -s "$DEVIN_BIN" "$fakebin/devin"
  FM_FAKE_LAUNCH_LOG="$LAB/launch.sh" fm_test_run_spawn "$H" "$WT" "$fakebin" "$ID" "$PROJ" \
    --scout --harness devin "$@" > "$LAB/spawn.log" 2>&1 \
    || fail "fm-spawn failed: $(cat "$LAB/spawn.log")"
  sed -i.bak "s/^window=firstmate:/window=devin-lab:/" "$H/state/$ID.meta" && rm -f "$H/state/$ID.meta.bak"
  printf '#!/bin/sh\nexec env -u TMUX -u TMUX_PANE "%s" -S "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/bin/tmux"
  chmod +x "$LAB/bin/tmux"
  export PATH="$LAB/bin:$PATH" FM_HOME="$H"
  unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
  TARGET="devin-lab:fm-$ID"
  tmux new-session -d -s devin-lab -n "fm-$ID" -x 120 -y 40 -c "$WT" \
    "HOME='$H/user-home' ${DEVIN_LAB_PANE_ENV:-} /bin/sh '$LAB/launch.sh'; exec /bin/bash --noprofile --norc" \
    || fail 'could not start pane'
}

capture() { tmux capture-pane -p -e -t "$TARGET"; }
screen_text() { tmux capture-pane -p -t "$TARGET"; }

wait_file() {  # <path>
  local path=$1 i
  for i in $(seq 1 480); do [ -s "$path" ] && return 0; sleep 0.5; done
  fail "timed out waiting for ${path##*/}"
}

wait_idle() {
  local i
  for i in $(seq 1 240); do
    [ "$(fm_busy_classify tmux "$TARGET" devin "$ID" "$H/state")" = 'idle devin-hook' ] && return 0
    sleep 0.5
  done
  fail 'Stop did not produce semantic idle'
}
