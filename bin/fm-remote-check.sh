#!/usr/bin/env bash
# fm-remote-check.sh - run firstmate's lint and behavior tests for the
# committed branch head on a remote Linux host over ssh.
#
# Usage:
#   fm-remote-check.sh lint [fm-lint.sh args...] [--then <step>...]
#   fm-remote-check.sh test <fm-test-run.sh args...> [--then <step>...]
#   fm-remote-check.sh --help
#
# Examples:
#   fm-remote-check.sh lint
#   fm-remote-check.sh lint --partition 1of2 --then lint --partition 2of2
#   fm-remote-check.sh lint --then test --changed --jobs 8
#
# Each step runs the checked tree's own bin/fm-lint.sh or bin/fm-test-run.sh
# with the given arguments, in order; every step runs even after one fails.
# Output streams back live, and a final local line names the host, commit,
# exit status, and wall time. The exit status is the first failing step's,
# or 0. Exit 75 means no remote run happened (no config/remote-runner, an
# invalid host line, or an unreachable host): fall back to CI's lint jobs.
# Exit 64 is a usage error.
#
# The host comes only from the one-line ssh host alias in
# $FM_HOME/config/remote-runner (FM_CONFIG_OVERRIDE replaces the directory);
# nothing else names it. The checked commit is this repository's HEAD. Only
# committed history is sent: a git bundle of HEAD plus origin/main (else
# main) when present, so the remote reproduces fm-lint.sh's changed-file mode
# and fm-test-run.sh --changed against the same base. Uncommitted edits,
# untracked files, and the home's config/, data/ and state/ never leave this
# machine; a dirty tree only prints a note.
#
# The remote side is this same script, sent beside the bundle and run as
# `bash runner.sh --remote-side <dir>`. It works in a fresh
# ~/fm-remote-check/<commit>.XXXXXX directory, removes it on exit, and sweeps
# directories older than a day left by interrupted runs. It checks out the
# commit on the local branch name (detached when local HEAD is detached),
# prepends ~/.local/bin to PATH, and installs the tree's pinned ShellCheck
# and actionlint there with bin/fm-install-shellcheck.sh and
# bin/fm-install-actionlint.sh when the installed version differs from the
# pin. No local environment is passed to the remote. Each step runs in its
# own process group, and a dropped connection (the runner losing its ssh
# parent) or a signal stops the step and removes the directory. The remote
# needs bash, git, tar, curl, xz and ps; there is no daemon or queue, so
# concurrent runs simply share the host, and running the two lint partitions
# as two concurrent invocations roughly halves full-lint wall time.
set -u

REMOTE_BASE_NAME=fm-remote-check
EXIT_USAGE=64
EXIT_UNAVAILABLE=75

rc_die() {  # <exit-code> <message>
  printf 'fm-remote-check.sh: %s\n' "$2" >&2
  exit "$1"
}

rc_usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

# Validates the step list in "$@": one or more `lint|test [args...]` groups
# separated by --then. Prints nothing; returns nonzero with a message.
rc_validate_steps() {
  local expect_step=1 arg saw_test_args=0 in_test=0
  [ "$#" -gt 0 ] || { printf 'fm-remote-check.sh: name a step: lint or test\n' >&2; return 1; }
  for arg in "$@"; do
    if [ "$expect_step" -eq 1 ]; then
      case "$arg" in
        lint) in_test=0 ;;
        test) in_test=1; saw_test_args=0 ;;
        *) printf 'fm-remote-check.sh: unknown step %s; expected lint or test\n' "$arg" >&2; return 1 ;;
      esac
      expect_step=0
      continue
    fi
    if [ "$arg" = --then ]; then
      if [ "$in_test" -eq 1 ] && [ "$saw_test_args" -eq 0 ]; then
        printf 'fm-remote-check.sh: a test step needs fm-test-run.sh selection arguments\n' >&2
        return 1
      fi
      expect_step=1
      continue
    fi
    saw_test_args=1
  done
  [ "$expect_step" -eq 0 ] || { printf 'fm-remote-check.sh: --then must be followed by a step\n' >&2; return 1; }
  if [ "$in_test" -eq 1 ] && [ "$saw_test_args" -eq 0 ]; then
    printf 'fm-remote-check.sh: a test step needs fm-test-run.sh selection arguments\n' >&2
    return 1
  fi
}

# ---------------------------------------------------------------- remote side

rc_remote_shellcheck_version() {
  shellcheck --version 2>/dev/null | awk '/^version:/ {print $2; exit}'
}

rc_remote_actionlint_version() {
  actionlint -version 2>/dev/null | awk 'NR == 1 {print; exit}'
}

rc_remote_ensure_tool() {  # <tool> <required-version> <installer>
  local tool=$1 required=$2 installer=$3 have
  have=$("rc_remote_${tool}_version") || have=
  [ "$have" = "$required" ] && return 0
  [ -x "$installer" ] || return 0
  printf '== fm-remote-check: installing %s %s into ~/.local/bin\n' "$tool" "$required"
  "$installer" "$HOME/.local/bin" >/dev/null
}

rc_remote_tools() {
  local lock="$HOME/$REMOTE_BASE_NAME/.tools.lock" required
  mkdir -p "$HOME/.local/bin"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock"
    flock 9
  fi
  if [ -x bin/fm-lint.sh ] && required=$(bin/fm-lint.sh --required-version 2>/dev/null); then
    rc_remote_ensure_tool shellcheck "$required" bin/fm-install-shellcheck.sh
  fi
  if [ -x bin/fm-lint-workflows.sh ] && required=$(bin/fm-lint-workflows.sh --required-version 2>/dev/null); then
    rc_remote_ensure_tool actionlint "$required" bin/fm-install-actionlint.sh
  fi
  if command -v flock >/dev/null 2>&1; then
    exec 9>&-
  fi
}

# Stops the running step's process group, then exits with <code>; the EXIT
# trap removes the run directory.
rc_remote_stop() {  # <code>
  [ -z "${RC_STEP_PID:-}" ] || kill -TERM -- "-$RC_STEP_PID" 2>/dev/null
  exit "$1"
}

# A dropped connection reparents the runner away from the ssh session, and a
# step that buffers its output would never meet a broken pipe, so poll the
# parent and stop the runner when it changes.
rc_remote_watchdog() {  # <runner-pid> <parent-pid> <step-pid>
  local ppid
  while kill -0 "$3" 2>/dev/null; do
    sleep 2
    ppid=$(ps -o ppid= -p "$1" 2>/dev/null) || ppid=
    ppid=${ppid//[[:space:]]/}
    if [ "$ppid" != "$2" ]; then
      kill -TERM "$1" 2>/dev/null
      return 0
    fi
  done
}

rc_remote_main() {  # <run-dir>
  local dir=$1 base="$HOME/$REMOTE_BASE_NAME" sha branch step start rc first_rc=0 arg
  local parent=$PPID watchdog
  local -a argv step_args
  case "$dir" in
    "$base"/?*) ;;
    *) rc_die 1 "remote run directory $dir is outside $base" ;;
  esac
  RC_REMOTE_DIR=$dir
  trap 'cd / && rm -rf "$RC_REMOTE_DIR"' EXIT
  trap 'rc_remote_stop 129' HUP
  trap 'rc_remote_stop 130' INT
  trap 'rc_remote_stop 143' TERM
  find "$base" -mindepth 1 -maxdepth 1 -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null || true

  sha=$(sed -n 's/^sha=//p' "$dir/meta")
  branch=$(sed -n 's/^branch=//p' "$dir/meta")
  argv=()
  while IFS= read -r -d '' arg; do argv+=("$arg"); done < "$dir/argv"

  git init -q "$dir/work" || rc_die 1 "git init failed on the remote"
  cd "$dir/work" || exit 1
  if git bundle list-heads ../src.bundle | grep -q ' refs/remotes/origin/main$'; then
    git fetch -q ../src.bundle '+refs/remotes/origin/main:refs/remotes/origin/main' \
      || rc_die 1 "could not fetch the base ref from the bundle"
  elif git bundle list-heads ../src.bundle | grep -q ' refs/heads/main$'; then
    git fetch -q ../src.bundle '+refs/heads/main:refs/remotes/origin/main' \
      || rc_die 1 "could not fetch the base ref from the bundle"
  fi
  git fetch -q ../src.bundle HEAD || rc_die 1 "could not fetch the checked commit from the bundle"
  if [ -n "$branch" ]; then
    git checkout -q -B "$branch" "$sha" || rc_die 1 "could not check out $sha"
  else
    git checkout -q --detach "$sha" || rc_die 1 "could not check out $sha"
  fi
  [ "$(git rev-parse HEAD)" = "$sha" ] || rc_die 1 "remote checkout does not match $sha"

  export PATH="$HOME/.local/bin:$PATH"
  rc_remote_tools || rc_die 1 "installing the pinned linters failed"

  set -- ${argv[@]+"${argv[@]}"} --then
  step=
  step_args=()
  for arg in "$@"; do
    if [ -z "$step" ]; then
      step=$arg
      continue
    fi
    if [ "$arg" != --then ]; then
      step_args+=("$arg")
      continue
    fi
    printf '== fm-remote-check: %s %s\n' "$step" "${step_args[*]-}"
    start=$SECONDS
    # Job control gives each step its own process group to stop as a whole.
    set -m
    case "$step" in
      lint) bin/fm-lint.sh ${step_args[@]+"${step_args[@]}"} </dev/null & ;;
      test) bin/fm-test-run.sh ${step_args[@]+"${step_args[@]}"} </dev/null & ;;
    esac
    RC_STEP_PID=$!
    set +m
    rc_remote_watchdog "$$" "$parent" "$RC_STEP_PID" </dev/null >/dev/null 2>&1 &
    watchdog=$!
    wait "$RC_STEP_PID"
    rc=$?
    RC_STEP_PID=
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    printf '== fm-remote-check: %s exit %s (%ss)\n' "$step" "$rc" "$((SECONDS - start))"
    [ "$first_rc" -ne 0 ] || first_rc=$rc
    step=
    step_args=()
  done
  exit "$first_rc"
}

if [ "${1:-}" = --remote-side ]; then
  [ "$#" -eq 2 ] || rc_die 1 "--remote-side takes exactly one directory"
  rc_remote_main "$2"
fi

# ----------------------------------------------------------------- local side

case "${1:-}" in
  -h|--help) rc_usage; exit 0 ;;
esac
rc_validate_steps "$@" || exit "$EXIT_USAGE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

HOST=
if [ -f "$CONFIG/remote-runner" ]; then
  IFS= read -r HOST < "$CONFIG/remote-runner" || true
  HOST=${HOST%$'\r'}
  HOST=${HOST#"${HOST%%[![:space:]]*}"}
  HOST=${HOST%"${HOST##*[![:space:]]}"}
fi
[ -n "$HOST" ] \
  || rc_die "$EXIT_UNAVAILABLE" "no remote runner: put an ssh host alias in $CONFIG/remote-runner (or set FM_HOME to the home that has one), else rely on CI"
case "$HOST" in
  -*|*[!A-Za-z0-9._@-]*)
    rc_die "$EXIT_UNAVAILABLE" "invalid host in $CONFIG/remote-runner: write one ssh host alias of letters, digits, '.', '_', '@' or '-', else rely on CI"
    ;;
esac

cd "$FM_ROOT" || exit 1
SHA=$(git rev-parse --verify -q HEAD) || rc_die 1 "no commit to check in $FM_ROOT"
BRANCH=$(git symbolic-ref --short -q HEAD) || BRANCH=
if [ -n "$BRANCH" ] && ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  BRANCH=
fi
BASE_REF=
if git rev-parse --verify -q refs/remotes/origin/main >/dev/null; then
  BASE_REF=refs/remotes/origin/main
elif git rev-parse --verify -q refs/heads/main >/dev/null; then
  BASE_REF=refs/heads/main
fi
if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  printf 'fm-remote-check.sh: note: uncommitted changes are not sent; checking committed %s\n' "${SHA:0:12}" >&2
fi

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15)
ssh "${SSH_OPTS[@]}" "$HOST" true </dev/null >/dev/null 2>&1 \
  || rc_die "$EXIT_UNAVAILABLE" "cannot reach $HOST over ssh (check the host and your ssh config), else rely on CI"

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-check.XXXXXX") || rc_die 1 "cannot create a staging directory"
trap 'rm -rf "$STAGE"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cat "${BASH_SOURCE[0]}" > "$STAGE/runner.sh"
printf 'sha=%s\nbranch=%s\n' "$SHA" "$BRANCH" > "$STAGE/meta"
printf '%s\0' "$@" > "$STAGE/argv"
git bundle create -q "$STAGE/src.bundle" HEAD ${BASE_REF:+"$BASE_REF"} \
  || rc_die 1 "git bundle of HEAD failed"

REMOTE_CMD="set -e; umask 077; b=\"\$HOME/$REMOTE_BASE_NAME\"; mkdir -p \"\$b\"; d=\$(mktemp -d \"\$b/${SHA:0:12}.XXXXXX\"); tar -xf - -C \"\$d\" || { rm -rf \"\$d\"; exit 1; }; exec bash \"\$d/runner.sh\" --remote-side \"\$d\""

printf 'fm-remote-check.sh: checking %s%s on %s\n' "${SHA:0:12}" "${BRANCH:+ ($BRANCH)}" "$HOST" >&2
START=$SECONDS
COPYFILE_DISABLE=1 tar --format=ustar -cf - -C "$STAGE" runner.sh meta argv src.bundle \
  | ssh -T "${SSH_OPTS[@]}" "$HOST" "$REMOTE_CMD"
RC=${PIPESTATUS[1]}
printf 'fm-remote-check.sh: %s %s exit %s in %ss\n' "$HOST" "${SHA:0:12}" "$RC" "$((SECONDS - START))" >&2
exit "$RC"
