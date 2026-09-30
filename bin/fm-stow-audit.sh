#!/usr/bin/env bash
# Stow-pass integrity audit: removal accounting and perishable referent checks.
# Usage:
#   fm-stow-audit.sh snapshot
#   fm-stow-audit.sh relocated <destination-file>
#   fm-stow-audit.sh verify
#   fm-stow-audit.sh referents
#
# `snapshot` copies the current startup-memory files (data/captain.md,
# data/captain-shared.md, data/learnings.md) into state/.stow-audit/ so the
# same pass's `verify` has a before-state to diff against; it overwrites any
# previous snapshot and clears any recorded relocation receipts. `relocated`
# records one live offload destination file for this pass, used after the stow
# skill's offload flow confirms the destination holds the quoted entry; the
# receipt only names where verify should look - the fact's words must actually
# be present at the destination, or the removal is still refused. `verify`
# diffs the snapshot against the edited files, data/memory-archive.md, and
# every recorded relocation destination, and refuses (exit 1) while any
# removed entry's fact is absent from all of them, naming each unaccounted
# entry. `referents` checks every perishable (`<!--p:...-->`) entry's named
# backlog task ids against this home's backlog and surfaces (exit 1) each
# entry whose id is resolved; an id it cannot resolve reads `unknown`, never
# `open` and never `resolved`.
#
# ENTRY MODEL (shared by both checks). A heading line, a blank line, and a
# line holding only an HTML comment are structure, never entries. A top-level
# `- ` or `* ` bullet starts an entry and indented lines continue it; any
# other content line at column zero is a one-line entry of its own.
#
# COMPARISON RULE (verify). Entries are normalized: HTML comments (tier
# markers) stripped, lowercased, every non-alphanumeric run collapsed to one
# space. A snapshot entry is accounted for when, in this order:
#   1. its normalized text appears token-aligned inside a single entry of the
#      edited files (kept, possibly inside a merge), of the archive (archived
#      verbatim with provenance), or of a recorded relocation destination
#      (relocated to a live JIT owner); or
#   2. a single entry of one of those three corpora contains at least two
#      thirds of its distinctive tokens - its deduplicated normalized tokens
#      of length >= 4 minus the fixed stopword list below - which is how a
#      genuine consolidation merge passes without a false alarm.
# An entry with fewer than three distinctive tokens is accounted only by rule
# 1. Everything else is unaccounted and refused by name. The rule is
# deliberately mechanical: it proves a removed fact's words survived
# somewhere recoverable, not that surviving prose still means the same thing.
#
# REFERENT RULE (referents). Only explicitly `<!--p:...-->`-marked entries are
# scanned, because the perishable tier is the one whose prose promises a
# checkable expiry condition; task mentions in other tiers are not expiry
# conditions and flagging them forever would train readers to ignore the
# check. The backlog itself is the id authority: one bounded `tasks-axi list`
# builds an id-to-state map, and every entry token that passes the canonical
# task-id validation (fm_task_id_creation_valid, bin/fm-pr-lib.sh) and names a
# listed row takes its verdict from that map, so no shape grammar can silently
# skip an accepted backlog identity. Tokens keep the canonical id charset
# (case, dots, and underscores intact) and are also tried with trailing dots
# stripped, so sentence punctuation cannot hide an id. A validated token
# absent from the map is reported `unknown` only when it is id-shaped
# (lowercase hyphenated segments ending in one or two letters plus one or two
# digits): that narrow shape only labels absent ids as unverifiable mentions,
# never gates a listed one, because ordinary prose words also pass the
# canonical validation and no grammar can recognize an id the backlog does
# not hold. Verdicts: a listed row in state `done` is `resolved`; any other
# listed state is `open`; an id-shaped token missing from the listing
# (including one pruned past done_keep), a failed or absent backlog listing,
# and an id past the verdict cap are `unknown`.
#
# COST. Both checks are local text comparison over files bounded by the
# startup-memory budget, plus - for `referents` only - exactly one backlog
# listing bounded by FM_TASKS_AXI_TIMEOUT (default 20s), with
# FM_STOW_AUDIT_REFERENT_MAX (default 25) capping the distinct ids given
# verdicts.
#
# Exit codes: 0 clean, 1 findings that need this pass's action, 2 usage or
# environment error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SNAP="$STATE/.stow-audit"
MEMORY_FILES="captain.md captain-shared.md learnings.md"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

print_error() {
  printf 'stow-audit: %s\n' "$1" >&2
}

# Parse one memory file into one entry per output line:
# <label>\t<extra>\t<normalized>\t<original, tabs and newlines flattened>.
# <extra> is the caller-supplied second field (source file for snapshot
# entries, empty otherwise).
parse_entries() {  # <label> <extra> <file>
  local label=$1 extra=$2 file=$3
  [ -f "$file" ] || return 0
  awk -v label="$label" -v extra="$extra" '
    function flush(   norm, orig) {
      if (cur == "") return
      orig = cur
      gsub(/\t/, " ", orig)
      norm = cur
      gsub(/<!--[^>]*-->/, " ", norm)
      norm = tolower(norm)
      gsub(/[^a-z0-9]+/, " ", norm)
      sub(/^ +/, "", norm)
      sub(/ +$/, "", norm)
      if (norm != "") printf "%s\t%s\t%s\t%s\n", label, extra, norm, orig
      cur = ""
    }
    /^[ \t]*$/ { flush(); next }
    /^#/ { flush(); next }
    /^[ \t]*<!--[^>]*-->[ \t]*$/ { flush(); next }
    /^[-*] / { flush(); cur = $0; next }
    /^[ \t]/ { if (cur != "") { cur = cur " " $0; next } }
    { flush(); cur = $0; flush() }
    END { flush() }
  ' "$file"
}

snapshot() {
  mkdir -p "$SNAP"
  local file present='' absent=''
  for file in $MEMORY_FILES; do
    rm -f "$SNAP/$file"
    if [ -f "$DATA/$file" ]; then
      cp "$DATA/$file" "$SNAP/$file"
      present="$present${present:+,}$file"
    else
      absent="$absent${absent:+,}$file"
    fi
  done
  rm -f "$SNAP/relocations"
  printf 'taken=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SNAP/meta"
  printf 'stow-audit: snapshot taken files=%s absent=%s\n' \
    "${present:-none}" "${absent:-none}"
}

relocated() {  # <destination-file>
  local dest=$1
  if [ ! -f "$SNAP/meta" ]; then
    print_error "no snapshot for this pass - run 'fm-stow-audit.sh snapshot' before recording a relocation"
    return 2
  fi
  if [ ! -f "$dest" ] || [ ! -r "$dest" ]; then
    print_error "relocation destination is not a readable file: $dest"
    return 2
  fi
  dest="$(cd "$(dirname "$dest")" && pwd -P)/$(basename "$dest")"
  if [ -f "$SNAP/relocations" ] && grep -qxF "$dest" "$SNAP/relocations"; then
    printf 'stow-audit: relocation already recorded dest=%s\n' "$dest"
    return 0
  fi
  printf '%s\n' "$dest" >> "$SNAP/relocations"
  printf 'stow-audit: relocation recorded dest=%s\n' "$dest"
}

verify() {
  if [ ! -f "$SNAP/meta" ]; then
    print_error "no snapshot for this pass - run 'fm-stow-audit.sh snapshot' before editing"
    return 2
  fi
  sed -n 's/^taken=/stow-audit: snapshot_taken=/p' "$SNAP/meta"
  local file dest rc=0
  {
    for file in $MEMORY_FILES; do
      parse_entries A '' "$DATA/$file"
    done
    parse_entries R '' "$DATA/memory-archive.md"
    if [ -f "$SNAP/relocations" ]; then
      while IFS= read -r dest; do
        [ -n "$dest" ] || continue
        parse_entries L '' "$dest"
      done < "$SNAP/relocations"
    fi
    for file in $MEMORY_FILES; do
      parse_entries S "data/$file" "$SNAP/$file"
    done
  } | awk '
    BEGIN {
      FS = "\t"
      nstop = split("with that this from when then they them must never " \
        "always only into over under after before each every their there " \
        "which while would should could does have been being will such " \
        "than these those what where because between through during " \
        "without within still also very more most some many much other " \
        "another same both either about against here", stopword, " ")
      for (i = 1; i <= nstop; i++) STOP[stopword[i]] = 1
    }
    $1 == "A" { A[++na] = $3; next }
    $1 == "R" { R[++nr] = $3; next }
    $1 == "L" { L[++nl] = $3; next }
    $1 != "S" { next }
    {
      total++
      file = $2; norm = $3; orig = $4
      if (contained(norm, A, na)) { kept++; next }
      if (contained(norm, R, nr)) { archived++; next }
      if (contained(norm, L, nl)) { relocated++; next }
      split("", d)
      n = split(norm, tok, " ")
      dc = 0
      for (i = 1; i <= n; i++) {
        t = tok[i]
        if (length(t) < 4 || (t in STOP) || (t in d)) continue
        d[t] = 1; dc++
      }
      if (dc >= 3 && (covered(d, dc, A, na) || covered(d, dc, R, nr) || \
          covered(d, dc, L, nl))) {
        consolidated++; next
      }
      bad++
      printf "unaccounted: file=%s entry=\"%s\"\n", file, orig
    }
    function contained(norm, arr, n,   i) {
      for (i = 1; i <= n; i++)
        if (index(" " arr[i] " ", " " norm " ") > 0) return 1
      return 0
    }
    function covered(d, dc, arr, n,   i, j, m, t, hits, et, es) {
      for (i = 1; i <= n; i++) {
        m = split(arr[i], et, " ")
        split("", es)
        for (j = 1; j <= m; j++) es[et[j]] = 1
        hits = 0
        for (t in d) if (t in es) hits++
        if (3 * hits >= 2 * dc) return 1
      }
      return 0
    }
    END {
      printf "stow-audit: entries snapshot=%d kept=%d archived=%d relocated=%d consolidated=%d unaccounted=%d\n", \
        total, kept, archived, relocated, consolidated, bad
      if (bad > 0) {
        print "stow-audit: removal-audit REFUSED - archive each named entry with provenance, restore it, or record its live relocation destination with fm-stow-audit.sh relocated <file>, then re-run"
        exit 1
      }
      print "stow-audit: removal-audit ok"
    }
  ' || rc=$?
  return "$rc"
}

# Extract every candidate token from one flattened entry line: split on
# characters outside the canonical task-id charset, add a trailing-dot-
# stripped variant for each token so sentence punctuation cannot hide an id,
# and dedupe.
tokens_in_entry() {  # <original entry text>
  printf '%s\n' "$1" | tr -c 'A-Za-z0-9._-' '\n' | awk '
    /./ {
      print
      t = $0
      sub(/\.+$/, "", t)
      if (t != $0 && t != "") print t
    }
  ' | LC_ALL=C sort -u
}

# The narrow advisory shape: it only labels a token the backlog listing does
# not hold as an unverifiable id mention, and is never consulted for a listed
# row, so it can never suppress a real backlog identity's check.
id_shaped() {  # <token>
  printf '%s\n' "$1" |
    grep -qxE '[a-z][a-z0-9]*(-[a-z0-9]+)*-[a-z]{1,2}[0-9]{1,2}'
}

referents() {
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  export FM_TASKS_AXI_TIMEOUT="${FM_TASKS_AXI_TIMEOUT:-20}"
  local cap="${FM_STOW_AUDIT_REFERENT_MAX:-25}"
  local tmp entries_file cache_file map_file
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-stow-audit.XXXXXX")
  # shellcheck disable=SC2064 # expand tmp now; it never changes afterwards.
  trap "rm -rf '$tmp'" RETURN
  entries_file="$tmp/entries"
  cache_file="$tmp/cache"
  map_file="$tmp/map"
  : > "$entries_file"
  : > "$cache_file"
  : > "$map_file"
  local file line orig ids id state verdict detail emitted
  local checked=0 nids=0 resolved=0 open=0 unknown=0
  for file in $MEMORY_FILES; do
    parse_entries "data/$file" '' "$DATA/$file" |
      grep -F '<!--p:' >> "$entries_file" || true
  done
  # One bounded listing is the whole backlog cost and the id authority. Only
  # the first two comma-separated fields are read - both are slugs that
  # precede any quoted title - so a title containing commas cannot shift them.
  local data_abs list_out='' reachable=0 list_error=''
  if data_abs=$(fm_backlog_data_absolute "$DATA" 2>/dev/null) \
    && list_out=$(fm_backlog_row_list "$data_abs" 2>&1); then
    reachable=1
    printf '%s\n' "$list_out" | awk -F, '
      /^  [A-Za-z0-9._-]+,/ {
        id = $1
        sub(/^ +/, "", id)
        printf "%s\t%s\n", id, $2
      }
    ' > "$map_file"
  else
    list_error=$(printf '%s\n' "${list_out:-backlog listing failed}" |
      sed -n 1p | tr '\t' ' ')
    [ -n "$list_error" ] || list_error='backlog listing failed'
  fi
  # Decide each unique candidate token once: a listed row takes its verdict
  # from the map whatever its shape, an unlisted token is an unknown id
  # mention only when id-shaped, and every other token is silent prose.
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    fm_task_id_creation_valid "$id" || continue
    state=''
    if [ "$reachable" -eq 1 ]; then
      state=$(awk -F'\t' -v id="$id" '$1 == id { print $2; exit }' "$map_file")
    fi
    if [ -z "$state" ] && ! id_shaped "$id"; then
      continue
    fi
    if [ "$nids" -ge "$cap" ]; then
      verdict=unknown
      detail="reason=\"verdict cap $cap reached\""
    else
      nids=$((nids + 1))
      if [ "$state" = 'done' ]; then
        verdict=resolved
        detail='state=done'
      elif [ -n "$state" ]; then
        verdict=open
        detail="state=$state"
      elif [ "$reachable" -eq 1 ]; then
        verdict=unknown
        detail='reason="not in backlog (possibly pruned)"'
      else
        verdict=unknown
        detail="reason=\"$list_error\""
      fi
    fi
    printf '%s\t%s\t%s\n' "$id" "$verdict" "$detail" >> "$cache_file"
  done <<EOF
$(while IFS= read -r line; do
    orig=$(printf '%s\n' "$line" | cut -f4-)
    tokens_in_entry "$orig"
  done < "$entries_file" | LC_ALL=C sort -u)
EOF
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    file=$(printf '%s\n' "$line" | cut -f1)
    orig=$(printf '%s\n' "$line" | cut -f4-)
    ids=$(tokens_in_entry "$orig")
    [ -n "$ids" ] || continue
    emitted=0
    for id in $ids; do
      verdict=$(awk -F'\t' -v id="$id" '$1 == id { print $2; exit }' "$cache_file")
      [ -n "$verdict" ] || continue
      detail=$(awk -F'\t' -v id="$id" '$1 == id { print $3; exit }' "$cache_file")
      emitted=1
      case "$verdict" in
        resolved) resolved=$((resolved + 1)) ;;
        open) open=$((open + 1)) ;;
        *) unknown=$((unknown + 1)) ;;
      esac
      printf 'referent: file=%s id=%s verdict=%s %s entry="%s"\n' \
        "$file" "$id" "$verdict" "$detail" "$orig"
    done
    [ "$emitted" -eq 0 ] || checked=$((checked + 1))
  done < "$entries_file"
  printf 'stow-audit: referents entries=%d ids=%d resolved=%d open=%d unknown=%d\n' \
    "$checked" "$nids" "$resolved" "$open" "$unknown"
  if [ "$resolved" -gt 0 ]; then
    printf 'stow-audit: referent-check SURFACED - rewrite each resolved entry from current evidence or archive it with provenance this pass\n'
    return 1
  fi
  printf 'stow-audit: referent-check ok\n'
}

case "${1:-}" in
  snapshot)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    snapshot
    ;;
  relocated)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    relocated "$2"
    ;;
  verify)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    verify
    ;;
  referents)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    referents
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
