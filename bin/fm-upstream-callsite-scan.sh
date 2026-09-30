#!/usr/bin/env bash
# fm-upstream-callsite-scan.sh - flag fork code that an upstream merge can break silently.
#
# Usage: fm-upstream-callsite-scan.sh <previous-upstream> <upstream> <fork>
#   <previous-upstream>  the upstream commit the last integration merged
#   <upstream>           the upstream commit this integration merges
#   <fork>               the fork commit before this integration (usually origin/main)
#
# A clean textual merge can still break fork behavior when one side changes a
# shared helper, a function body a test extracts, or a harness enumeration
# without touching the other side's lines. Run this after every upstream merge,
# before tests, and account for every reported line in the PR body.
#
# The scan is read-only and runs in the current repository. "Upstream diff" is
# `git diff <previous-upstream> <upstream>`, "fork diff" is
# `git diff <previous-upstream> <fork>`, and a name matches as a whole word
# (letters, digits, `_`, and `-` are word characters).
#   1. Redefined helpers: function definition lines under bin/, matched at line
#      start as `name() {`, that the upstream diff both removes and adds.
#      Fork call sites: lines under bin/ the fork diff adds that mention one,
#      excluding definition lines.
#   2. Fork-redefined helpers: the same test on the fork diff. Upstream call
#      sites: lines under bin/ the upstream diff adds that mention one,
#      excluding definition lines, in a file that defines it or that mentions
#      the basename of a file defining it at <upstream> (such as sourcing it).
#   3. Test extractions: lines under tests/ the fork diff adds that address a
#      function by a `/^name()` pattern (a sed or awk body extraction) whose
#      body under bin/ differs between <previous-upstream> and <upstream>.
#   4. Harness lists: non-comment lines under bin/ the upstream diff adds that
#      name at least four harnesses yet omit a fork-only harness. Harness names are the
#      `print own harness:` list in bin/fm-harness.sh's usage; fork-only ones are
#      listed at <fork> and not at <upstream>.
# A convention change confined to a helper's body, and an enumeration spread
# over several lines, are not detected, so this complements the suite.
#
# Output: `REDEFINED: <name>`, `CALLSITE: <name> <path>: <line>`,
# `FORK_REDEFINED: <name>`, `UPSTREAM_CALLSITE: <name> <path>: <line>`,
# `EXTRACTION: <name> <path>: <line>`, and
# `HARNESS_LIST: missing <names> <path>: <line>` lines, then a `SUMMARY:` line.
# Exit 0 when no CALLSITE, UPSTREAM_CALLSITE, EXTRACTION, or HARNESS_LIST line
# was printed, 1 when at least one was, 2 on usage or git errors.
set -u

usage() {
  sed -n '3,6s/^# \{0,1\}//p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

case "${1:-}" in -h|--help) sed -n '2,43s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 0 ;; esac
[ "$#" -eq 3 ] || usage
base=$1 upstream=$2 fork=$3
for ref in "$base" "$upstream" "$fork"; do
  git rev-parse --verify --quiet "$ref^{commit}" >/dev/null || {
    echo "error: not a commit in this repository: $ref" >&2
    exit 2
  }
done

git_diff() {  # <from> <to> <path>
  git diff --no-color --no-ext-diff "$1" "$2" -- "$3"
}
upstream_bin=$(git_diff "$base" "$upstream" bin) || exit 2
fork_bin=$(git_diff "$base" "$fork" bin) || exit 2
fork_tests=$(git_diff "$base" "$fork" tests) || exit 2

redefined_names() {  # <diff>: names whose definition line the diff removes and adds
  printf '%s\n' "$1" | awk '
    match($0, /^[-+][A-Za-z_][A-Za-z0-9_]*\(\) \{/) {
      side = substr($0, 1, 1)
      name = substr($0, 2, RLENGTH - 5)
      seen[name] = seen[name] side
    }
    END { for (n in seen) if (seen[n] ~ /-/ && seen[n] ~ /\+/) print n }
  ' | LC_ALL=C sort
}

added_mentions() {  # <diff> <name>: "<path><TAB><line>" per added non-definition mention
  printf '%s\n' "$1" | awk -v name="$2" '
    /^\+\+\+ / { path = substr($0, 5); sub(/^b\//, "", path); next }
    /^\+/ {
      line = substr($0, 2)
      if (line ~ ("^[[:space:]]*" name "\\(\\)")) next
      rest = line
      while ((i = index(rest, name)) > 0) {
        before = (i > 1) ? substr(rest, i - 1, 1) : ""
        after = substr(rest, i + length(name), 1)
        if (before !~ /[A-Za-z0-9_-]/ && after !~ /[A-Za-z0-9_-]/) {
          printf "%s\t%s\n", path, line
          break
        }
        rest = substr(rest, i + length(name))
      }
    }
  '
}

definition_paths() {  # <diff> <name>: paths where the diff touches the definition line
  printf '%s\n' "$1" | awk -v name="$2" '
    /^--- / { old = substr($0, 5); sub(/^a\//, "", old); next }
    /^\+\+\+ / { new = substr($0, 5); sub(/^b\//, "", new); next }
    /^-/ && substr($0, 2) ~ ("^" name "\\(\\) \\{") { print old }
    /^\+/ && substr($0, 2) ~ ("^" name "\\(\\) \\{") { print new }
  ' | grep -v '^/dev/null$' | LC_ALL=C sort -u
}

uses_definition() {  # <path> <defining paths>: the caller defines or names a defining file
  local path=$1 def content
  while IFS= read -r def; do
    [ -n "$def" ] || continue
    [ "$path" = "$def" ] && return 0
  done <<<"$2"
  content=$(git show "$upstream:$path" 2>/dev/null) || return 1
  while IFS= read -r def; do
    [ -n "$def" ] || continue
    case "$content" in *"${def##*/}"*) return 0 ;; esac
  done <<<"$2"
  return 1
}

function_body() {  # <rev> <name>: every bin/ body of name at rev, in path order
  local rev=$1 name=$2 file
  git grep -l -E "^$name\(\)" "$rev" -- bin 2>/dev/null | while IFS= read -r file; do
    printf '%s\n' "$file"
    git show "$file" | awk -v name="$name" '
      !on && $0 ~ ("^" name "\\(\\)") { on = 1; print; if ($0 ~ /\}[[:space:]]*$/) exit; next }
      on { print; if ($0 ~ /^\}/) exit }
    '
  done | sed "s|^$rev:||"
}

harness_names() {  # <rev>: bin/fm-harness.sh usage names at rev, one per line
  git show "$1:bin/fm-harness.sh" 2>/dev/null \
    | sed -n 's/.*print own harness: *\([^ ]*\).*/\1/p' | head -n 1 \
    | tr '|' '\n' | grep -v -x -e unknown -e ''
}

findings=0
names=$(redefined_names "$upstream_bin")
calls=0
for name in $names; do
  printf 'REDEFINED: %s\n' "$name"
done
for name in $names; do
  while IFS=$'\t' read -r path line; do
    [ -n "$path" ] || continue
    printf 'CALLSITE: %s %s: %s\n' "$name" "$path" "$line"
    calls=$((calls + 1))
  done < <(added_mentions "$fork_bin" "$name")
done

fork_names=$(redefined_names "$fork_bin")
reverse=0
for name in $fork_names; do
  printf 'FORK_REDEFINED: %s\n' "$name"
done
for name in $fork_names; do
  defs=$(definition_paths "$fork_bin" "$name")
  while IFS=$'\t' read -r path line; do
    [ -n "$path" ] || continue
    uses_definition "$path" "$defs" || continue
    printf 'UPSTREAM_CALLSITE: %s %s: %s\n' "$name" "$path" "$line"
    reverse=$((reverse + 1))
  done < <(added_mentions "$upstream_bin" "$name")
done

extractions=0
while IFS=$'\t' read -r name path line; do
  [ -n "$name" ] || continue
  [ "$(function_body "$base" "$name")" = "$(function_body "$upstream" "$name")" ] && continue
  printf 'EXTRACTION: %s %s: %s\n' "$name" "$path" "$line"
  extractions=$((extractions + 1))
done < <(printf '%s\n' "$fork_tests" | awk '
  /^\+\+\+ / { path = substr($0, 5); sub(/^b\//, "", path); next }
  /^\+/ {
    line = substr($0, 2)
    rest = line
    while (match(rest, /\/\^[A-Za-z_][A-Za-z0-9_]*\(\)/)) {
      name = substr(rest, RSTART + 2, RLENGTH - 4)
      if (!((path, name) in seen)) { seen[path, name] = 1; printf "%s\t%s\t%s\n", name, path, line }
      rest = substr(rest, RSTART + RLENGTH)
    }
  }
')

fork_harnesses=$(harness_names "$fork")
upstream_harnesses=$(harness_names "$upstream")
for side in "$fork:$fork_harnesses" "$upstream:$upstream_harnesses"; do
  [ -n "${side#*:}" ] || {
    echo "error: no 'print own harness:' list in bin/fm-harness.sh at ${side%%:*}" >&2
    exit 2
  }
done
fork_only=$(printf '%s\n' "$fork_harnesses" | grep -v -x -F -f <(printf '%s\n' "$upstream_harnesses") || true)
lists=0
if [ -n "$fork_only" ]; then
  while IFS=$'\t' read -r missing path line; do
    [ -n "$missing" ] || continue
    printf 'HARNESS_LIST: missing %s %s: %s\n' "$missing" "$path" "$line"
    lists=$((lists + 1))
  done < <(printf '%s\n' "$upstream_bin" | awk \
    -v known="$(printf '%s\n' "$upstream_harnesses" | tr '\n' ' ')" \
    -v extra="$(printf '%s\n' "$fork_only" | tr '\n' ' ')" '
    function has(text, word,   rest, i, before, after) {
      rest = text
      while ((i = index(rest, word)) > 0) {
        before = (i > 1) ? substr(rest, i - 1, 1) : ""
        after = substr(rest, i + length(word), 1)
        if (before !~ /[A-Za-z0-9_-]/ && after !~ /[A-Za-z0-9_-]/) return 1
        rest = substr(rest, i + length(word))
      }
      return 0
    }
    BEGIN { nk = split(known, k, " "); ne = split(extra, e, " ") }
    /^\+\+\+ / { path = substr($0, 5); sub(/^b\//, "", path); next }
    /^\+/ {
      line = substr($0, 2)
      if (line ~ /^[[:space:]]*#/) next
      count = 0
      for (j = 1; j <= nk; j++) count += has(line, k[j])
      if (count < 4) next
      missing = ""
      for (j = 1; j <= ne; j++) if (!has(line, e[j])) missing = missing (missing == "" ? "" : ",") e[j]
      if (missing != "") printf "%s\t%s\t%s\n", missing, path, line
    }
  ')
fi

findings=$((calls + reverse + extractions + lists))
printf 'SUMMARY: %s redefined helper(s), %s fork-only call site(s), %s fork-redefined helper(s), %s upstream call site(s), %s test extraction(s), %s harness list(s) missing a fork harness\n' \
  "$(printf '%s\n' "$names" | grep -c . || true)" "$calls" \
  "$(printf '%s\n' "$fork_names" | grep -c . || true)" "$reverse" "$extractions" "$lists"
[ "$findings" -eq 0 ]
