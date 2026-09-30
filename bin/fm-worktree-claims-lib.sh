#!/usr/bin/env bash
# Shared local Firstmate worktree-claim inventory for spawn and teardown.
# Callers source fm-backend.sh, fm-wake-lib.sh and fm-secondmate-registry-lib.sh.
# Allocation/return callers hold fm_treehouse_project_lock_path through publication
# or cleanup; per-task locks alone cannot serialize different claimants.

fm_worktree_canonical_dir() {
  [ -n "$1" ] && [ -d "$1" ] || return 1
  ( CDPATH='' cd -- "$1" && pwd -P )
}

# Read only: Treehouse owns this JSON and its lease mutation API. An incomplete
# concurrent write or malformed/duplicate entry refuses rather than guessing.
# Node is already part of Firstmate's universal toolchain.
fm_worktree_durably_leased() {  # <canonical-slot>
  local slot=$1 pool
  pool=$(dirname "$(dirname "$slot")")
  [ -f "$pool/treehouse-state.json" ] && [ ! -L "$pool/treehouse-state.json" ] || return 1
  node - "$pool/treehouse-state.json" "$slot" <<'JS'
const fs = require('fs');
try {
  const state = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  if (!Array.isArray(state.worktrees)) process.exit(1);
  const matches = state.worktrees.filter(entry => {
    if (typeof entry.path !== 'string') throw new Error('invalid path');
    try { return fs.realpathSync(entry.path) === process.argv[3]; }
    catch { return entry.path === process.argv[3]; }
  });
  process.exit(matches.length === 1 && matches[0].leased === true ? 0 : 1);
} catch { process.exit(1); }
JS
}

# Positive owner proof before a slot is returned, read from the same record.
# Spawn leases with holder "<FM_HOME>:<task-id>"; the home half compares by
# resolved path against each spelling the caller names for the task's own home
# (its configured home and the home owning its state directory), so a symlinked
# or overridden spelling of that same home still matches.
# A home argument of "-" also accepts the bare "<task-id>" holder that
# bin/fm-home-seed.sh records when it leases a secondmate home.
# Prints "mine", "unleased" (no durable holder: a pre-lease claim), or
# "other <holder>"; returns 1 when the record cannot answer (missing,
# unsafe, malformed, or no single entry for the slot).
fm_worktree_lease_owner() {  # <canonical-slot> <task-id> <home>...
  local slot=$1 id=$2 pool
  shift 2
  pool=$(dirname "$(dirname "$slot")")
  [ -f "$pool/treehouse-state.json" ] && [ ! -L "$pool/treehouse-state.json" ] || return 1
  node - "$pool/treehouse-state.json" "$slot" "$id" "$@" <<'JS'
const fs = require('fs');
const [file, slot, id, ...homes] = process.argv.slice(2);
const real = p => { try { return fs.realpathSync(p); } catch { return p; } };
try {
  const state = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!Array.isArray(state.worktrees)) process.exit(1);
  const matches = state.worktrees.filter(entry => {
    if (typeof entry.path !== 'string') throw new Error('invalid path');
    return real(entry.path) === slot;
  });
  if (matches.length !== 1) process.exit(1);
  const entry = matches[0];
  if (entry.leased !== true) { console.log('unleased'); process.exit(0); }
  const holder = typeof entry.lease_holder === 'string' ? entry.lease_holder : '';
  const split = holder.lastIndexOf(':');
  const bare = homes.includes('-') && holder === id;
  const mine = bare || (split > 0 && holder.slice(split + 1) === id
    && homes.some(home => home !== '-' && real(holder.slice(0, split)) === real(home)));
  console.log(mine ? 'mine' : `other ${holder || '<no holder>'}`);
} catch { process.exit(1); }
JS
}

fm_worktree_claims_for_path() {  # <own-meta> <state> <worktree>
  local own=$1 state=$2 worktree=$3 slot dir meta field path matched
  FM_WORKTREE_CLAIMS=()
  slot=$(fm_worktree_canonical_dir "$worktree") || return 1
  collect_local_firstmate_states "$state" || return 1
  for dir in "${TREEHOUSE_OWNER_STATES[@]}"; do
    for meta in "$dir"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      [ ! "$meta" -ef "$own" ] || continue
      matched=0
      for field in worktree home; do
        path=$(fm_meta_get "$meta" "$field")
        path=$(fm_worktree_canonical_dir "$path") || continue
        [ "$path" != "$slot" ] || matched=1
      done
      [ "$matched" = 0 ] || FM_WORKTREE_CLAIMS+=("$meta")
    done
  done
}

# A live-process snapshot is insufficient: that process can exit before get.
# Until a legacy claim is safely retired, require a durable lease for EVERY
# recorded pool slot sharing this project's identity, even with spare capacity.
# Treehouse v2.0.0 has no exclusion API and may select any unleased clean slot;
# get itself resets it before returning a path. Never retry get/return here.
fm_worktree_require_leased_claims() {  # <own-meta> <state> <project-lock>
  local own=$1 state=$2 project_lock=$3 dir meta project lock field slot pool
  collect_local_firstmate_states "$state" || return 1
  for dir in "${TREEHOUSE_OWNER_STATES[@]}"; do
    for meta in "$dir"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      [ ! "$meta" -ef "$own" ] || continue
      [ "$(fm_meta_get "$meta" backend)" != orca ] || continue
      for field in worktree home; do
        slot=$(fm_meta_get "$meta" "$field")
        slot=$(fm_worktree_canonical_dir "$slot") || continue
        pool=$(dirname "$(dirname "$slot")")
        [ -e "$pool/treehouse-state.json" ] || [ -L "$pool/treehouse-state.json" ] || continue
        # Non-pool homes need no allocator identity (a secondmate home may
        # not be a Git checkout). A recorded pool slot with an unknown
        # project still refuses: it could belong to this allocation.
        project=$(fm_meta_get "$meta" project)
        lock=$(fm_treehouse_project_lock_path "$project") || {
          echo "REFUSED: cannot establish the pool identity of task ${meta##*/}; inspect $meta before acquiring a slot." >&2
          return 1
        }
        [ "$lock" = "$project_lock" ] || continue
        if ! fm_worktree_durably_leased "$slot"; then
          echo "REFUSED: task ${meta##*/} still claims unleased pool slot $slot; refusing before treehouse get can reset its work." >&2
          echo "Complete its guarded teardown or reconcile its stale claim first; no pool operation was attempted." >&2
          return 1
        fi
      done
    done
  done
}

collect_local_firstmate_states() {
  local record_state=$1 root home reg line child known existing i=0
  local -a homes
  record_state=$(fm_worktree_canonical_dir "$record_state") || return 1
  TREEHOUSE_OWNER_STATES=("$record_state")
  root=$(fm_firstmate_root_home "$FM_HOME") || {
    echo "REFUSED: cannot resolve the root Firstmate home; nothing was changed" >&2
    return 1
  }
  homes=("$root")
  while [ "$i" -lt "${#homes[@]}" ]; do
    home=${homes[$i]}
    i=$((i + 1))
    known=0
    for existing in "${TREEHOUSE_OWNER_STATES[@]}"; do
      [ "$existing" != "$home/state" ] || known=1
    done
    [ "$known" = 1 ] || TREEHOUSE_OWNER_STATES+=("$home/state")
    reg="$home/data/secondmates.md"
    [ ! -e "$reg" ] && [ ! -L "$reg" ] && continue
    [ -f "$reg" ] && [ ! -L "$reg" ] || {
      echo "REFUSED: local Firstmate registry is unsafe at $reg; nothing was changed" >&2
      return 1
    }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "- "*)
          secondmate_registry_parse_line "$line" || {
            echo "REFUSED: malformed local Firstmate registry entry in $reg; nothing was changed" >&2
            return 1
          }
          [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
          child=$(fm_worktree_canonical_dir "$SECONDMATE_REGISTRY_HOME") || {
            echo "REFUSED: registered local Firstmate home is unavailable: $SECONDMATE_REGISTRY_HOME; nothing was changed" >&2
            return 1
          }
          known=0
          for existing in "${homes[@]}"; do
            [ "$existing" != "$child" ] || known=1
          done
          [ "$known" = 1 ] || homes+=("$child")
          ;;
      esac
    done < "$reg"
  done
}
