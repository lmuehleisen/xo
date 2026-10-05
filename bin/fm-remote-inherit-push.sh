#!/usr/bin/env bash
# Push the declared inherited-material allowlist in one remote job.
# Usage: fm-remote-inherit-push.sh <secondmate-id> <generation>
#
# The item set is derived from the ONE declared owner
# (FM_INHERITABLE_CONFIG in bin/fm-config-inherit-lib.sh), the same declaration
# the receiving bin/fm-remote-inherit.sh enforces, so the two implementations in
# one code revision cannot drift silently. Different local and remote revisions
# fail closed as documented by that owner. FM_CONFIG_INHERIT_LIVE=1 marks a live
# convergence push into an already-running home and skips session-scoped items,
# exactly as the local propagation path does. Each safe source is snapshotted
# before transfer; source failures preserve that item and still transfer the
# others. The library owns the batch wire format and its aggregate byte bound.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}
file_link_count() {
  if [ "$(uname)" = Darwin ]; then /usr/bin/stat -f %l "$1" 2>/dev/null; else stat -c %h "$1" 2>/dev/null; fi
}
[ "$#" -eq 2 ] || { echo "usage: fm-remote-inherit-push.sh <secondmate-id> <generation>" >&2; exit 2; }
ID=$1
GENERATION=$2
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac
case "$GENERATION" in ''|*[!0-9]*) die "generation must be a positive integer" ;; esac
[ "${#GENERATION}" -le 18 ] && [ "$GENERATION" -ge 1 ] || die "generation is outside the supported range"
REMOTE=$(secondmate_registry_field "$DATA/secondmates.md" "$ID" remote 2>/dev/null || true)
[ "$REMOTE" = 1 ] || die "secondmate $ID is not a remote route"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-inherit-push.XXXXXX") || die "cannot create inheritance staging directory"
trap 'rm -rf -- "$TMP"' EXIT
EMPTY="$TMP/empty"
: > "$EMPTY"
EMPTY_HASH=$(sha256_file "$EMPTY") || die "cannot hash empty inheritance payload"

BATCH="$TMP/batch"
printf 'fm-inherit-batch.v1\n' > "$BATCH"
MODE=launch
[ "${FM_CONFIG_INHERIT_LIVE:-0}" != 1 ] || MODE=live
stage_item() { # <relative-path>
  local rel=$1 source source_present snapshot bytes hash missing reason
  if [ "$MODE" = live ]; then
    case "$rel" in
      config/*)
        if fm_config_inherit_item_session_scoped "${rel#config/}"; then
          fm_config_inherit_batch_record skip "$rel" 0 "$EMPTY_HASH" "$EMPTY" >> "$BATCH"
          return
        fi
        ;;
    esac
  fi
  case "$rel" in
    config/*) source="$CONFIG/${rel#config/}" ;;
    data/*) source="$DATA/${rel#data/}" ;;
  esac
  source_present=$(fm_config_source_present "$source") || return 1
  if [ "$source_present" = 1 ]; then
    [ -f "$source" ] && [ ! -L "$source" ] || { printf 'error: inherited source is unsafe: %s\n' "$source" >&2; return 1; }
    [ "$(file_link_count "$source")" = 1 ] || { printf 'error: inherited source is hardlinked: %s\n' "$source" >&2; return 1; }
    snapshot="$TMP/$(printf '%s' "$rel" | tr '/' '_')"
    cp -p -- "$source" "$snapshot" || return 1
    [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
    if [ "$rel" = data/captain-shared.md ]; then
      if ! missing=$(shared_captain_header_valid "$snapshot"); then
        reason="shared captain preferences have no valid primary-authoritative header"
        [ -z "$missing" ] || reason="$reason: missing \"$missing\""
        printf 'error: %s\n' "$reason" >&2
        return 1
      fi
    fi
    bytes=$(LC_ALL=C wc -c < "$snapshot" | tr -d ' ') || return 1
    [ "$bytes" -le 1048576 ] || { printf 'error: inherited source exceeds the byte bound: %s\n' "$source" >&2; return 1; }
    hash=$(sha256_file "$snapshot") || return 1
    fm_config_inherit_batch_record put "$rel" "$bytes" "$hash" "$snapshot" >> "$BATCH"
  else
    fm_config_inherit_batch_record absent "$rel" 0 "$EMPTY_HASH" "$EMPTY" >> "$BATCH"
  fi
}
ITEMS=$(fm_config_inherit_items)
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if ! stage_item "$rel"; then
    printf 'error: cannot stage inherited item: %s; destination will be preserved\n' "$rel" >&2
    fm_config_inherit_batch_record error "$rel" 0 "$EMPTY_HASH" "$EMPTY" >> "$BATCH" \
      || die "cannot record failed inherited item"
  fi
done <<EOF
$ITEMS
EOF
BATCH_BYTES=$(LC_ALL=C wc -c < "$BATCH" | tr -d ' ')
[ "$BATCH_BYTES" -le 1048576 ] || die "inheritance batch exceeds the remote job byte bound"
"$SCRIPT_DIR/fm-on.sh" --stdin "$ID" fm-remote-inherit.sh batch "$GENERATION" "$MODE" < "$BATCH"
