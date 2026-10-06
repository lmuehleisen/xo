# shellcheck shell=bash
# fm-lavish-lib.sh - the one owner of this fork's optional Lavish policy.
#
# Lavish (lavish-axi) is optional at two levels, and both use the same three
# modes:
#   off      no Lavish: boards stay static local files and every answer stays in
#            chat. This is the default.
#   view     Stage A: /ops lavish opens its read-only board in Lavish, and a
#            scout may host a crew Lavish review loop for a visual deliverable.
#   answers  view plus Stage B: the /ops lavish board's decision cards take
#            answers in the page, fed through bin/fm-captain-hold.sh's one
#            keyed-answer intake. Chat stays the primary answer path.
# The home toggle is the optional local, gitignored config/lavish holding one of
# those words (absent means off). A per-request override, passed by the caller
# as an explicit mode for one artifact or brief, wins over the home toggle in
# both directions. Anything else in config/lavish counts as off, never a guessed
# mode, with the reason reported; anything else in a request is refused.
#
# Availability is separate from the wanted mode: Lavish is available only when
# lavish-axi is on PATH and reports exactly FM_LAVISH_AXI_PIN, because this home
# installs a pinned version and never self-updates it. A wanted mode whose
# binary is missing or off-pin resolves to off with a stated reason, so the
# caller keeps today's static behavior and can say why.
#
# Every Firstmate invocation of lavish-axi runs under fm_lavish_pin_env:
#   LAVISH_AXI_TELEMETRY=0   the published build reports usage by default
#   LAVISH_AXI_NO_OPEN=1     never open a browser on this machine's own screen
#   LAVISH_AXI_HOST          config/lavish-axi-host, else 127.0.0.1; an ambient
#                            LAVISH_AXI_HOST is ignored, so only the home's own
#                            file can widen the bound address. Workers reach the
#                            home's file through the FM_HOME their brief names.
#                            An explicit host also stops Lavish's own Tailscale
#                            detection, so the default never binds a tailnet
#                            address.
# fm_lavish_forbidden_command refuses the subcommands that install agent hooks
# or plugins, self-update, or publish to a third-party host.
# FM_LAVISH_AXI_PIN is also the version in fm_lavish_install_command, the one
# hook-free install line bin/fm-bootstrap.sh prints.

FM_LAVISH_AXI_PIN=0.1.80

fm_lavish_install_command() {
  printf 'npm install -g --ignore-scripts lavish-axi@%s\n' "$FM_LAVISH_AXI_PIN"
}

# fm_lavish_mode_valid <word>
fm_lavish_mode_valid() {
  case "${1-}" in
    off|view|answers) return 0 ;;
  esac
  return 1
}

# fm_lavish_home_mode <config-dir>
# Prints the home toggle's mode. Returns 2 with the reason on stderr when
# config/lavish exists but is not exactly one known word.
fm_lavish_home_mode() {
  local file="$1/lavish" value
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf 'off\n'
    return 0
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'config/lavish must be a readable regular file\n' >&2
    return 2
  fi
  # Trim the ends only: whitespace inside the word leaves it malformed, and a
  # present but empty file is malformed rather than the absent-file default.
  value=$(tr -s '[:space:]' ' ' < "$file")
  value=${value# }
  value=${value% }
  if ! fm_lavish_mode_valid "$value"; then
    printf 'config/lavish must be off, view, or answers (got %s)\n' "${value:-an empty file}" >&2
    return 2
  fi
  printf '%s\n' "$value"
}

# fm_lavish_host <config-dir>
fm_lavish_host() {
  local file="$1/lavish-axi-host" value
  if [ -e "$file" ] || [ -L "$file" ]; then
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
      printf 'config/lavish-axi-host must be a readable regular file\n' >&2
      return 2
    fi
    value=$(cat "$file") || return 2
    case "$value" in
      ''|*[[:space:]]*)
        printf 'config/lavish-axi-host must contain one non-empty address without whitespace\n' >&2
        return 2 ;;
    esac
    printf '%s\n' "$value"
    return 0
  fi
  printf '127.0.0.1\n'
}

# fm_lavish_pin_env <config-dir>
# Exports the pinned environment into the calling shell. Telemetry and
# auto-open are pinned first, so a malformed host file (return 2) still never
# leaves either at its vendor default.
fm_lavish_pin_env() {
  local host
  LAVISH_AXI_TELEMETRY=0
  LAVISH_AXI_NO_OPEN=1
  export LAVISH_AXI_TELEMETRY LAVISH_AXI_NO_OPEN
  host=$(fm_lavish_host "$1") || return 2
  LAVISH_AXI_HOST=$host
  export LAVISH_AXI_HOST
}

# fm_lavish_unavailable_reason <config-dir>
# Prints nothing and returns 0 when the pinned lavish-axi is available;
# otherwise prints why not and returns 1. The version probe runs with telemetry
# and auto-open pinned off, because lavish-axi reports even --version, but it
# never reads config/lavish-axi-host: a malformed host must not make a binary
# that is on the pin look unavailable to a poll that routes by its session.
fm_lavish_unavailable_reason() {
  local version
  if ! command -v lavish-axi >/dev/null 2>&1; then
    printf 'lavish-axi is not installed\n'
    return 1
  fi
  version=$(LAVISH_AXI_TELEMETRY=0 LAVISH_AXI_NO_OPEN=1 lavish-axi --version 2>/dev/null | tr -d '[:space:]')
  if [ "$version" != "$FM_LAVISH_AXI_PIN" ]; then
    printf 'lavish-axi %s is installed but this home is pinned to %s\n' "${version:-of unknown version}" "$FM_LAVISH_AXI_PIN"
    return 1
  fi
  return 0
}

# fm_lavish_resolve <config-dir> [<requested-mode>]
# Sets FM_LAVISH_WANTED (the request, else the home toggle, off when that is
# malformed), FM_LAVISH_WANTED_FROM (request or home), FM_LAVISH_MODE (the
# effective mode), and FM_LAVISH_REASON (why the effective mode is off when
# something else was wanted or the toggle is malformed, or empty).
# Returns 2 on a malformed request.
# shellcheck disable=SC2034 # The FM_LAVISH_* results are read by the callers.
fm_lavish_resolve() {
  local config=$1 request=${2-} reason
  FM_LAVISH_REASON=
  if [ -n "$request" ]; then
    if ! fm_lavish_mode_valid "$request"; then
      printf 'the Lavish request must be off, view, or answers (got %s)\n' "$request" >&2
      return 2
    fi
    FM_LAVISH_WANTED=$request
    FM_LAVISH_WANTED_FROM=request
  else
    FM_LAVISH_WANTED_FROM=home
    if ! FM_LAVISH_WANTED=$(fm_lavish_home_mode "$config" 2>/dev/null); then
      # A malformed home toggle counts as off, the safe direction, and says why
      # rather than refusing every unrelated board and scout.
      FM_LAVISH_WANTED=off
      FM_LAVISH_MODE=off
      FM_LAVISH_REASON=$(fm_lavish_home_mode "$config" 2>&1 >/dev/null)
      return 0
    fi
  fi
  FM_LAVISH_MODE=$FM_LAVISH_WANTED
  if [ "$FM_LAVISH_WANTED" != off ] && ! reason=$(fm_lavish_unavailable_reason "$config"); then
    FM_LAVISH_MODE=off
    FM_LAVISH_REASON="$reason; install: $(fm_lavish_install_command)"
  fi
}

# fm_lavish_forbidden_command <first-argument>
fm_lavish_forbidden_command() {
  case "${1-}" in
    setup|update|share) return 0 ;;
  esac
  return 1
}
