#!/usr/bin/env bash
# fm-lavish.sh - resolve this home's optional Lavish mode and run lavish-axi
# under the pinned environment.
#
# Usage:
#   fm-lavish.sh mode
#   fm-lavish.sh resolve [--lavish <off|view|answers>]
#   fm-lavish.sh run <lavish-axi arguments...>
#   fm-lavish.sh install-command
#
# mode             Print the home toggle (config/lavish): off, view, or answers.
# resolve          Print the effective mode for one artifact or brief:
#                    mode: <off|view|answers>
#                    wanted: <mode> (home|request)
#                    reason: <why the effective mode is off>   (only then)
#                  --lavish is the per-request override and wins over the home
#                  toggle in both directions. A wanted mode resolves to off
#                  when the pinned lavish-axi is unavailable.
# run              Run lavish-axi with the given arguments under the pinned
#                  environment. Refuses any argument that is `setup`, `update`,
#                  or `share`, wherever it appears, and refuses when the pinned
#                  version is not the one installed.
#                  This is the only way Firstmate and its workers start Lavish.
# install-command  Print the one hook-free, version-pinned install command.
#
# Malformed config or a malformed request exits 2. bin/fm-lavish-lib.sh owns
# the modes, the pin, the pinned environment, and the forbidden subcommands.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-lavish-lib.sh
. "$SCRIPT_DIR/fm-lavish-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() { printf 'fm-lavish: %s\n' "$*" >&2; exit "${2:-1}"; }

cmd_resolve() {
  local request=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lavish) [ "$#" -ge 2 ] || die "--lavish requires a value" 2; request=$2; shift 2 ;;
      --lavish=*) request=${1#--lavish=}; shift ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  fm_lavish_resolve "$CONFIG" "$request" || exit 2
  printf 'mode: %s\n' "$FM_LAVISH_MODE"
  printf 'wanted: %s (%s)\n' "$FM_LAVISH_WANTED" "$FM_LAVISH_WANTED_FROM"
  [ -z "$FM_LAVISH_REASON" ] || printf 'reason: %s\n' "$FM_LAVISH_REASON"
}

cmd_run() {
  local arg reason
  # Every argument, not just the first non-option one: an option's value can
  # sit in front of the subcommand.
  for arg in "$@"; do
    if fm_lavish_forbidden_command "$arg"; then
      die "refusing 'lavish-axi $arg': this home never installs Lavish hooks or plugins, self-updates it, or publishes to a third-party host"
    fi
  done
  reason=$(fm_lavish_unavailable_reason "$CONFIG") || die "$reason; install: $(fm_lavish_install_command)"
  fm_lavish_pin_env "$CONFIG" || exit 2
  exec lavish-axi "$@"
}

case "${1-}" in
  mode) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; fm_lavish_home_mode "$CONFIG" || exit 2 ;;
  resolve) shift; cmd_resolve "$@" ;;
  run) shift; cmd_run "$@" ;;
  install-command) fm_lavish_install_command ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
