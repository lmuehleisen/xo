#!/usr/bin/env bash
# fm-upstream-removed-helper-scan.sh - flag a helper the merge removed that is still mentioned.
#
# Usage: fm-upstream-removed-helper-scan.sh <merge-base> <upstream> <merged>
#   <merge-base>  the upstream commit the previous integration merged
#   <upstream>    the upstream commit this integration merges
#   <merged>      the merge commit, including conflict resolutions
#
# Run this after the merge commit exists, beside bin/fm-upstream-callsite-scan.sh.
# The call-site scan reads diffs, so it cannot see a helper defined at the merge
# base or the upstream tip, absent from the merged commit, and still mentioned.
# That is a surviving caller of a helper upstream deleted, or merged lines that
# still call a helper the resolution dropped.
#
# The scan is read-only and runs in the current repository. A definition is a
# column-0 `name() {` line in a bin/ or tests/ *.sh file. A name in that set at
# <merge-base> or <upstream>, and not at <merged>, is missing. A reference is a
# whole-word mention of a missing name in a bin/ or tests/ *.sh file at
# <merged>, including comments. Letters, digits, `_`, and `-` are word
# characters, so a longer name is not a mention.
# A column-0 definition inside a fixture heredoc counts as a definition.
# An indented definition, a `function name` definition, an indirect call, and
# a mention outside bin/ and tests/ shell files are not detected.
# A helper defined only on the pre-merge fork, and not at the base or upstream
# tip, is outside this scan.
# Unreferenced missing names are counted, not listed.
#
# Output: `REF: <name> <path>:<line>: <text>` lines, then one `SUMMARY:` line.
# Exit 0 when no REF line was printed, 1 when at least one was, 2 on usage or
# git errors.
set -u

usage() {
  sed -n '4,7s/^# \{0,1\}//p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

case "${1:-}" in -h|--help) sed -n '2,30s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 0 ;; esac
[ "$#" -eq 3 ] || usage
base=$1 upstream=$2 merged=$3
for ref in "$base" "$upstream" "$merged"; do
  git rev-parse --verify --quiet "$ref^{commit}" >/dev/null || {
    echo "error: not a commit in this repository: $ref" >&2
    exit 2
  }
done

work=$(mktemp -d "${TMPDIR:-/tmp}/fm-removed-helper.XXXXXX") || {
  echo "error: could not create a temporary directory" >&2
  exit 2
}
trap 'rm -rf "$work"' EXIT

# Raw `git grep` lines for <rev>, rewritten as path<TAB>lineno<TAB>text.
collect_lines() {  # <rev> <dest>
  local raw=$work/raw rc
  # -G keeps `.` a basic regexp when grep.patternType is fixed.
  git -c color.ui=never grep -n -I -G -e . "$1" -- bin tests >"$raw" 2>"$work/grep.err"
  rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "error: git grep failed for $1" >&2
    cat "$work/grep.err" >&2
    exit 2
  fi
  # `next` stays in a top-level action: macOS awk rejects it inside an if.
  awk -v prefix="$1:" '
    index($0, prefix) != 1 { next }
    {
      rest = substr($0, length(prefix) + 1)
      p = index(rest, ":")
      if (p >= 2) {
        path = substr(rest, 1, p - 1)
        if (path ~ /\.sh$/) {
          rest = substr(rest, p + 1)
          c = index(rest, ":")
          if (c >= 2) {
            lineno = substr(rest, 1, c - 1)
            if (lineno ~ /^[0-9]+$/) {
              text = substr(rest, c + 1)
              printf "%s\t%s\t%s\n", path, lineno, text
            }
          }
        }
      }
    }
  ' "$raw" >"$2"
}

defined_names() {  # <lines-file>
  awk '
    {
      text = $0
      sub(/^[^\t]*\t[^\t]*\t/, "", text)
      if (match(text, /^[A-Za-z_][A-Za-z0-9_]*\(\) \{/)) {
        print substr(text, 1, RLENGTH - 4)
      }
    }
  ' "$1" | LC_ALL=C sort -u
}

collect_lines "$base" "$work/base.lines"
collect_lines "$upstream" "$work/upstream.lines"
collect_lines "$merged" "$work/merged.lines"
{ defined_names "$work/base.lines"; defined_names "$work/upstream.lines"; } \
  | LC_ALL=C sort -u >"$work/either"
defined_names "$work/merged.lines" >"$work/defined"
# Names were sorted in the C locale. comm must use that same order.
LC_ALL=C comm -23 "$work/either" "$work/defined" >"$work/missing" || {
  echo "error: could not compare helper names" >&2
  exit 2
}
missing_count=$(grep -c . "$work/missing" || true)

: >"$work/hits"
awk -v names="$work/missing" '
  BEGIN {
    while ((getline n < names) > 0) { if (n != "") { want[n] = 1 } }
    close(names)
  }
  {
    path = $0
    sub(/\t.*/, "", path)
    rest = substr($0, length(path) + 2)
    lineno = rest
    sub(/\t.*/, "", lineno)
    text = substr(rest, length(lineno) + 2)
    scan = text
    while (match(scan, /[A-Za-z_][A-Za-z0-9_-]*/)) {
      tok = substr(scan, RSTART, RLENGTH)
      if (tok in want) {
        key = tok SUBSEP path SUBSEP lineno
        if (!(key in seen)) {
          seen[key] = 1
          printf "%s\t%s\t%s\t%s\n", tok, path, lineno, text
        }
      }
      scan = substr(scan, RSTART + RLENGTH)
    }
  }
' "$work/merged.lines" | LC_ALL=C sort -t "$(printf '\t')" -k2,2 -k3,3n -k1,1 >"$work/hits"

if [ -s "$work/hits" ]; then
  ref_count=$(wc -l <"$work/hits" | tr -d ' ')
  name_count=$(cut -f1 "$work/hits" | LC_ALL=C sort -u | grep -c . || true)
  while IFS="$(printf '\t')" read -r name path lineno text; do
    printf 'REF: %s %s:%s: %s\n' "$name" "$path" "$lineno" "$text"
  done <"$work/hits"
else
  ref_count=0
  name_count=0
fi
printf 'SUMMARY: %d referenced missing helper(s), %d reference(s), %d unreferenced missing helper(s)\n' \
  "$name_count" "$ref_count" "$((missing_count - name_count))"
[ "$ref_count" -eq 0 ]
