# shellcheck shell=bash
# Shared discovery for tests that exercise the installed Pi SDK.
# Source this file, then call fm_test_pi_package_dir before using the SDK.

fm_test_is_pi_package() {
  local package_dir=$1
  [ -f "$package_dir/package.json" ] || return 1
  node -e 'try { if (require(process.argv[1]).name === "@earendil-works/pi-coding-agent") process.exit(0); } catch (_) {} process.exit(1);' \
    "$package_dir/package.json" >/dev/null 2>&1
}

fm_test_resolve_path() {
  local path=$1 link parent hops=0
  case "$path" in
    /*) ;;
    *) path="$PWD/$path" ;;
  esac
  while [ -L "$path" ]; do
    [ "$hops" -lt 40 ] || return 1
    link=$(readlink "$path") || return 1
    case "$link" in
      /*) path=$link ;;
      *) path="$(dirname "$path")/$link" ;;
    esac
    hops=$((hops + 1))
  done
  [ -e "$path" ] || return 1
  parent=$(cd -P "$(dirname "$path")" 2>/dev/null && pwd) || return 1
  printf '%s/%s\n' "$parent" "$(basename "$path")"
}

fm_test_nearest_pi_package() {
  local path=$1 dir
  dir=$(dirname "$path")
  while :; do
    if fm_test_is_pi_package "$dir"; then
      (cd -P "$dir" 2>/dev/null && pwd)
      return 0
    fi
    [ "$dir" != / ] || return 1
    dir=$(dirname "$dir")
  done
}

fm_test_pi_wrapper_target() {
  awk '
    /^[[:space:]]*#/ { next }
    /(^|[;[:space:]])exec[[:space:]]+/ {
      line = $0
      sub(/^.*exec[[:space:]]+/, "", line)
      if (substr(line, 1, 1) == "\"") {
        sub(/^\"/, "", line)
        sub(/\".*$/, "", line)
      } else if (substr(line, 1, 1) == "\047") {
        sub(/^\047/, "", line)
        sub(/\047.*$/, "", line)
      } else {
        sub(/[[:space:]].*$/, "", line)
      }
      if (line != "" && line !~ /[$`]/ && line != "env") {
        print line
        exit
      }
    }
  ' "$1"
}

fm_test_pi_package_dir() {
  local candidate npm_root pi_path resolved next package_dir hops=0
  # shellcheck disable=SC2034 # consumed by test files that source this helper
  FM_TEST_PI_PACKAGE_DIR=
  # shellcheck disable=SC2034 # consumed by test files that source this helper
  FM_TEST_PI_PACKAGE_REASON=

  if [ -n "${FM_PI_PACKAGE_DIR:-}" ]; then
    candidate=$(cd -P "$FM_PI_PACKAGE_DIR" 2>/dev/null && pwd) || candidate=
    if [ -n "$candidate" ] && fm_test_is_pi_package "$candidate"; then
      FM_TEST_PI_PACKAGE_DIR=$candidate
      return 0
    fi
    FM_TEST_PI_PACKAGE_REASON="FM_PI_PACKAGE_DIR does not name an @earendil-works/pi-coding-agent package"
    return 1
  fi

  npm_root=$(npm root -g 2>/dev/null) || npm_root=
  if [ -n "$npm_root" ]; then
    candidate="$npm_root/@earendil-works/pi-coding-agent"
    if fm_test_is_pi_package "$candidate"; then
      FM_TEST_PI_PACKAGE_DIR=$(cd -P "$candidate" 2>/dev/null && pwd) || return 1
      return 0
    fi
  fi

  pi_path=$(type -P pi 2>/dev/null) || pi_path=
  while [ -n "$pi_path" ] && [ "$hops" -lt 16 ]; do
    resolved=$(fm_test_resolve_path "$pi_path") || break
    if package_dir=$(fm_test_nearest_pi_package "$resolved"); then
      # shellcheck disable=SC2034 # consumed by test files that source this helper
      FM_TEST_PI_PACKAGE_DIR=$package_dir
      return 0
    fi
    [ -f "$resolved" ] || break
    next=$(fm_test_pi_wrapper_target "$resolved")
    [ -n "$next" ] || break
    case "$next" in
      /*) pi_path=$next ;;
      *) pi_path="$(dirname "$resolved")/$next" ;;
    esac
    hops=$((hops + 1))
  done

  # shellcheck disable=SC2034 # consumed by test files that source this helper
  FM_TEST_PI_PACKAGE_REASON="installed @earendil-works/pi-coding-agent package not found at npm root or through pi on PATH"
  return 1
}
