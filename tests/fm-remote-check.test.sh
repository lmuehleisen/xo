#!/usr/bin/env bash
# bin/fm-remote-check.sh runs a checked tree's lint and tests on the ssh host
# named only by config/remote-runner, sends only committed history, cleans up
# its remote directory, refuses cleanly when no host is usable, and returns
# the remote exit status. A stub ssh runs the remote command locally against a
# fake remote HOME, so no test touches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-remote-check-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
SSH_LOG="$TMP_ROOT/ssh.log"
export SSH_LOG

cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
# Stub ssh: skip options, log the host, then run the command under the fake
# remote HOME as a child whose parent is this stub, the way sshd parents a
# session, and record the stub's pid so a case can drop the "connection".
# Host "unreachable" fails like a real connection error.
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
host=$1
shift
printf '%s\n' "$host" >> "$SSH_LOG"
[ "$host" != unreachable ] || exit 255
printf '%s\n' "$$" > "$FAKE_REMOTE_HOME/ssh.pid"
HOME=$FAKE_REMOTE_HOME sh -c "$*" 0<&0 &
wait "$!"
SH
chmod +x "$FAKEBIN/ssh"

# new_fixture <name>: a firstmate-shaped repo whose fake lint and test runners
# report what the remote checkout holds and exit with a committed status.
# Prints the repo path.
new_fixture() {
  local repo="$TMP_ROOT/$1"
  mkdir -p "$repo/bin" "$TMP_ROOT/$1.remote-home"
  cp "$ROOT/bin/fm-remote-check.sh" "$repo/bin/"
  cat > "$repo/bin/fm-lint.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --required-version ]; then echo 9.9.9; exit 0; fi
printf 'LINT args=[%s] branch=%s base=%s\n' "$*" "$(git rev-parse --abbrev-ref HEAD)" \
  "$(git rev-parse --verify -q origin/main || echo none)"
find . -path ./.git -prune -o -type f -print | sort | sed 's/^/LINT file /'
printf 'LINT shellcheck=%s\n' "$(command -v shellcheck || echo none)"
if [ -f lint-sleep ]; then
  printf '%s\n' "$$" > "$HOME/lint.pid"
  sleep 60
fi
exit "$(cat lint-exit)"
SH
  cat > "$repo/bin/fm-test-run.sh" <<'SH'
#!/usr/bin/env bash
printf 'TEST args=[%s]\n' "$*"
prev=
for arg in "$@"; do
  base=
  [ "$prev" != --base ] || base=$arg
  case "$arg" in --base=*) base=${arg#--base=} ;; esac
  [ -z "$base" ] || printf 'TEST base %s=%s\n' "$base" "$(git rev-parse --verify -q "$base^{commit}" || echo missing)"
  prev=$arg
done
exit "$(cat test-exit)"
SH
  cat > "$repo/bin/fm-install-shellcheck.sh" <<'SH'
#!/usr/bin/env bash
printf 'installed\n' >> "$HOME/installs.log"
mkdir -p "$1"
printf '#!/bin/sh\nprintf "version: 9.9.9\\n"\n' > "$1/shellcheck"
chmod +x "$1/shellcheck"
SH
  chmod +x "$repo"/bin/*.sh
  printf 'config/\ndata/\nstate/\n' > "$repo/.gitignore"
  printf '0\n' > "$repo/lint-exit"
  printf '0\n' > "$repo/test-exit"
  printf 'tracked\n' > "$repo/tracked.txt"
  git -C "$repo" init -q -b main
  git -C "$repo" add -A
  git -C "$repo" commit -qm base
  git clone -q --bare "$repo" "$repo.origin.git"
  git -C "$repo" remote add origin "$repo.origin.git"
  git -C "$repo" fetch -q origin
  git -C "$repo" checkout -q -b feature
  printf 'COMMITTED-MARKER\n' > "$repo/feature.txt"
  git -C "$repo" add feature.txt
  git -C "$repo" commit -qm feature
  mkdir -p "$repo/config" "$repo/data" "$repo/state"
  printf 'devbox-alias\n' > "$repo/config/remote-runner"
  printf 'PRIVATE-DATA-MARKER\n' > "$repo/data/secret.md"
  printf 'PRIVATE-STATE-MARKER\n' > "$repo/state/x.status"
  printf 'UNTRACKED-MARKER\n' > "$repo/untracked.txt"
  printf '%s\n' "$repo"
}

# run_check <repo> <args...>: run the fixture's copy with its own home.
# Sets OUT (combined output) and RC.
run_check() {
  local repo=$1
  shift
  : > "$SSH_LOG"
  OUT=$(cd "$TMP_ROOT" && PATH="$FAKEBIN:$PATH" FAKE_REMOTE_HOME="$repo.remote-home" \
    FM_HOME="$repo" "$repo/bin/fm-remote-check.sh" "$@" 2>&1)
  RC=$?
}

test_host_comes_from_config() {
  local repo
  repo=$(new_fixture host)
  run_check "$repo" lint
  expect_code 0 "$RC" "a clean lint run"
  assert_equals "devbox-alias" "$(sort -u "$SSH_LOG")" "every ssh call targets the configured host"
  assert_contains "$OUT" "LINT args=[] branch=feature base=$(git -C "$repo" rev-parse origin/main)" \
    "the remote checks the local branch against the same base"
  assert_contains "$OUT" "devbox-alias $(git -C "$repo" rev-parse --short=12 HEAD) exit 0" \
    "the local summary names host, commit and status"
  pass "the host comes from config/remote-runner and the branch and base reach the remote"
}

test_only_committed_tree_is_sent() {
  local repo clone
  repo=$(new_fixture private)
  printf 'DIRTY-EDIT-MARKER\n' >> "$repo/tracked.txt"
  printf '# DIRTY-RUNNER-MARKER\n' >> "$repo/bin/fm-remote-check.sh"
  run_check "$repo" lint
  expect_code 0 "$RC" "a lint run with private files present"
  assert_contains "$OUT" "LINT file ./feature.txt" "the committed tree reaches the remote"
  assert_contains "$OUT" "uncommitted changes are not sent" "a dirty tree prints a note"
  assert_not_contains "$OUT" "LINT file ./config" "config/ must not reach the remote"
  assert_not_contains "$OUT" "LINT file ./data" "data/ must not reach the remote"
  assert_not_contains "$OUT" "LINT file ./state" "state/ must not reach the remote"
  assert_not_contains "$OUT" "LINT file ./untracked.txt" "untracked files must not reach the remote"

  # Capture the exact stream a real ssh would carry and inspect every object.
  mkdir -p "$TMP_ROOT/capture"
  cat > "$TMP_ROOT/capture/ssh" <<'SH'
#!/usr/bin/env bash
case "$*" in *' true') exit 0 ;; esac
cat > "$CAPTURE"
SH
  chmod +x "$TMP_ROOT/capture/ssh"
  (cd "$TMP_ROOT" && PATH="$TMP_ROOT/capture:$PATH" CAPTURE="$TMP_ROOT/stream.tar" FM_HOME="$repo" \
    "$repo/bin/fm-remote-check.sh" lint >/dev/null 2>&1)
  mkdir -p "$TMP_ROOT/stream"
  tar -xf "$TMP_ROOT/stream.tar" -C "$TMP_ROOT/stream" || fail "the stream is not a tar archive"
  assert_equals "argv meta runner.sh src.bundle" "$(find "$TMP_ROOT/stream" -mindepth 1 -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" \
    "the stream holds only the runner, its arguments, the commit id and the bundle"
  clone="$TMP_ROOT/stream-clone"
  git init -q "$clone"
  git -C "$clone" fetch -q "$TMP_ROOT/stream/src.bundle" '+refs/*:refs/bundle/*' '+HEAD:refs/bundle/HEAD' \
    || fail "the bundle does not fetch"
  git -C "$clone" rev-list --objects --all | awk '{print $1}' \
    | git -C "$clone" cat-file --batch > "$TMP_ROOT/objects"
  assert_grep "COMMITTED-MARKER" "$TMP_ROOT/objects" "the object dump holds committed content"
  assert_grep "rc_remote_main" "$TMP_ROOT/stream/runner.sh" "the committed runner is sent"
  if grep -a -r -E 'PRIVATE-|UNTRACKED-|DIRTY-|devbox-alias' "$TMP_ROOT/objects" "$TMP_ROOT/stream"; then
    fail "the bundle carries private, untracked or uncommitted content"
  fi
  pass "only committed history is sent; config, data, state, untracked and dirty edits stay local"
}

test_refuses_when_unconfigured() {
  local repo
  repo=$(new_fixture unconfigured)
  rm "$repo/config/remote-runner"
  run_check "$repo" lint
  expect_code 75 "$RC" "no config/remote-runner"
  assert_contains "$OUT" "config/remote-runner" "the refusal names the file to create"
  assert_equals 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "the refusal is one line"
  [ ! -s "$SSH_LOG" ] || fail "ssh ran without a configured host"

  printf -- '-oProxyCommand=evil\n' > "$repo/config/remote-runner"
  run_check "$repo" lint
  expect_code 75 "$RC" "an option-shaped host line"
  [ ! -s "$SSH_LOG" ] || fail "ssh ran with an option-shaped host"

  printf 'unreachable\n' > "$repo/config/remote-runner"
  run_check "$repo" lint
  expect_code 75 "$RC" "an unreachable host"
  assert_contains "$OUT" "cannot reach unreachable" "the refusal names the host"
  assert_contains "$OUT" "rely on CI" "the refusal points at the CI fallback"
  pass "an absent, invalid or unreachable host refuses with exit 75 and a one-line fix"
}

test_exit_status_propagates() {
  local repo
  repo=$(new_fixture status)
  printf '7\n' > "$repo/lint-exit"
  printf '3\n' > "$repo/test-exit"
  git -C "$repo" commit -qam 'failing checks'
  run_check "$repo" lint --partition 1of2 --then test --changed --jobs 4
  expect_code 7 "$RC" "a failing lint followed by a failing test"
  assert_contains "$OUT" "LINT args=[--partition 1of2]" "lint gets its arguments"
  assert_contains "$OUT" "TEST args=[--changed --jobs 4]" "the test step still runs after a failed lint"
  assert_contains "$OUT" "== fm-remote-check: test exit 3" "each step reports its own status"

  printf '0\n' > "$repo/lint-exit"
  git -C "$repo" commit -qam 'lint passes'
  run_check "$repo" lint --then test tests/a.test.sh
  expect_code 3 "$RC" "a passing lint followed by a failing test"
  pass "the first failing step's remote exit status is the local exit status"
}

test_remote_cleans_up_and_installs_tools_once() {
  local repo home
  repo=$(new_fixture cleanup)
  home="$repo.remote-home"
  run_check "$repo" lint
  expect_code 0 "$RC" "first run"
  assert_contains "$OUT" "LINT shellcheck=$home/.local/bin/shellcheck" "the pinned linter is on the remote PATH"
  run_check "$repo" lint
  expect_code 0 "$RC" "second run"
  assert_equals 1 "$(wc -l < "$home/installs.log" | tr -d ' ')" "the linter installs only when missing"
  assert_equals "" "$(find "$home/fm-remote-check" -mindepth 1 -maxdepth 1 -type d)" \
    "no remote run directory survives"
  pass "the remote installs pinned tools on first use and removes its run directory"
}

test_dropped_connection_stops_the_step() {
  local repo home lint_pid i
  repo=$(new_fixture dropped)
  home="$repo.remote-home"
  : > "$repo/lint-sleep"
  git -C "$repo" add lint-sleep
  git -C "$repo" commit -qm 'slow lint'
  (cd "$TMP_ROOT" && PATH="$FAKEBIN:$PATH" FAKE_REMOTE_HOME="$home" FM_HOME="$repo" \
    "$repo/bin/fm-remote-check.sh" lint >/dev/null 2>&1) &
  for i in $(seq 1 100); do
    [ -s "$home/lint.pid" ] && break
    sleep 0.1
  done
  lint_pid=$(cat "$home/lint.pid" 2>/dev/null) || fail "the slow lint never started"
  [ -n "$(find "$home/fm-remote-check" -mindepth 1 -maxdepth 1 -type d)" ] \
    || fail "the run directory is missing while the step runs"
  kill -KILL "$(cat "$home/ssh.pid")"
  for i in $(seq 1 100); do
    kill -0 "$lint_pid" 2>/dev/null || break
    sleep 0.1
  done
  ! kill -0 "$lint_pid" 2>/dev/null || fail "the step outlived the dropped connection"
  for i in $(seq 1 50); do
    [ -n "$(find "$home/fm-remote-check" -mindepth 1 -maxdepth 1 -type d)" ] || break
    sleep 0.1
  done
  assert_equals "" "$(find "$home/fm-remote-check" -mindepth 1 -maxdepth 1 -type d)" \
    "the run directory is removed after a dropped connection"
  wait
  pass "a dropped connection stops the running step and removes the run directory"
}

test_usage_errors() {
  local repo
  repo=$(new_fixture usage)
  run_check "$repo" build
  expect_code 64 "$RC" "an unknown step"
  run_check "$repo" test
  expect_code 64 "$RC" "a test step without a selection"
  run_check "$repo" lint --then
  expect_code 64 "$RC" "a dangling --then"
  [ ! -s "$SSH_LOG" ] || fail "ssh ran for a usage error"
  pass "malformed step lists are usage errors that never reach ssh"
}

test_host_comes_from_config
test_only_committed_tree_is_sent
test_refuses_when_unconfigured
test_exit_status_propagates
test_remote_cleans_up_and_installs_tools_once
test_named_base_refs_reach_the_remote() {
  local repo base_sha orphan
  repo=$(new_fixture bases)
  base_sha=$(git -C "$repo" rev-parse main)
  git -C "$repo" branch release main
  git -C "$repo" tag v1 main
  run_check "$repo" test --changed --base release --then test --changed --base=v1 \
    --then test --changed --base HEAD~1
  expect_code 0 "$RC" "base refs named by the test steps"
  assert_contains "$OUT" "TEST base release=$base_sha" "a named branch base is recreated remotely"
  assert_contains "$OUT" "TEST base v1=$base_sha" "a --base= tag is recreated remotely"
  assert_contains "$OUT" "TEST base HEAD~1=$base_sha" "a base inside the sent history resolves"

  run_check "$repo" test --changed --base no-such-ref
  expect_code 64 "$RC" "an unknown base"
  [ ! -s "$SSH_LOG" ] || fail "ssh ran for an unknown base"
  orphan=$(git -C "$repo" commit-tree -m orphan "$(git -C "$repo" mktree </dev/null)")
  run_check "$repo" test --changed --base "$orphan"
  expect_code 64 "$RC" "a commit outside the sent history"
  assert_contains "$OUT" "name a branch or tag" "the refusal says how to fix it"
  [ ! -s "$SSH_LOG" ] || fail "ssh ran for an unsendable base"
  pass "named --base refs reach the remote and unsendable bases refuse before ssh"
}

test_dropped_connection_stops_the_step
test_named_base_refs_reach_the_remote
test_usage_errors
