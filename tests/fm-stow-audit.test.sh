#!/usr/bin/env bash
# Behavioral coverage for the stow-pass integrity audit: a plainly removed
# unique fact is refused by name while a genuine consolidation, an archived
# removal, and a receipted live relocation pass without a false alarm, a
# receipt whose destination lacks the fact still refuses, and the perishable
# referent check takes its verdicts from the backlog listing itself - so ids
# outside any shape grammar are still checked - surfaces a resolved id,
# leaves an open one alone, keeps other tiers out of scope, and reads an
# unresolvable referent as unknown rather than as either verdict.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUDIT="$ROOT/bin/fm-stow-audit.sh"
TMP_ROOT=$(fm_test_tmproot fm-stow-audit)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
fm_test_require_tmproot "$TMP_ROOT"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}

# --- verify: a plainly removed unique fact is refused by name ---------------

home=$(make_home removal)
cat > "$home/data/learnings.md" <<'MD'
# Learnings
- Treehouse pool slots share one repo, so workers must create their task branch before editing. <!--a:2026-08-03-->
- Codex writes its trust prompt to stderr, not stdout. <!--a:2026-07-28-->
MD
FM_HOME="$home" "$AUDIT" snapshot >/dev/null || fail "removal: snapshot failed"
cat > "$home/data/learnings.md" <<'MD'
# Learnings
- Treehouse pool slots share one repo, so workers must create their task branch before editing. <!--a:2026-09-11-->
MD
out=$(FM_HOME="$home" "$AUDIT" verify 2>&1)
status=$?
[ "$status" -eq 1 ] || fail "removal: expected exit 1, got $status: $out"
case "$out" in
  *'unaccounted: file=data/learnings.md'*'Codex writes its trust prompt'*) ;;
  *) fail "removal: refusal does not name the removed entry: $out" ;;
esac
case "$out" in
  *REFUSED*) ;;
  *) fail "removal: missing refusal line: $out" ;;
esac
pass "verify refuses a plain removal and names the removed entry"

# The marker-only date refresh on the surviving entry must not read as a
# removal: the snapshot had two entries and exactly one is unaccounted.
case "$out" in
  *'unaccounted=1'*) ;;
  *) fail "removal: expected exactly one unaccounted entry: $out" ;;
esac
pass "verify treats a marker date refresh as the same kept entry"

# --- verify: a genuine consolidation passes without a false alarm -----------

home=$(make_home consolidation)
cat > "$home/data/learnings.md" <<'MD'
# Learnings
- Grok launches require the identity marker scrubbed from the launch template. <!--a:2026-08-01-->
- Kimi launches require the identity marker scrubbed from the launch template. <!--a:2026-08-02-->
MD
FM_HOME="$home" "$AUDIT" snapshot >/dev/null || fail "consolidation: snapshot failed"
cat > "$home/data/learnings.md" <<'MD'
# Learnings
- Grok and Kimi launches require the identity marker scrubbed from the launch template. <!--a:2026-09-11-->
MD
out=$(FM_HOME="$home" "$AUDIT" verify 2>&1)
status=$?
[ "$status" -eq 0 ] || fail "consolidation: expected exit 0, got $status: $out"
case "$out" in
  *'unaccounted=0'*'removal-audit ok'*) ;;
  *) fail "consolidation: expected a clean audit: $out" ;;
esac
pass "verify passes a consolidation merge that preserves both facts"

# --- verify: an archived removal with provenance passes ---------------------

home=$(make_home archived)
cat > "$home/data/learnings.md" <<'MD'
# Learnings
- Treehouse pool slots share one repo, so workers must create their task branch before editing. <!--a:2026-08-03-->
- Codex writes its trust prompt to stderr, not stdout. <!--a:2026-07-28-->
MD
FM_HOME="$home" "$AUDIT" snapshot >/dev/null || fail "archived: snapshot failed"
cat > "$home/data/learnings.md" <<'MD'
# Learnings
- Treehouse pool slots share one repo, so workers must create their task branch before editing. <!--a:2026-08-03-->
MD
cat > "$home/data/memory-archive.md" <<'MD'
## 2026-09-11 stow
- (from learnings.md, tier: aging, reinforced: 2026-07-28) Codex writes its trust prompt to stderr, not stdout. [archived: unreinforced 45d]
MD
out=$(FM_HOME="$home" "$AUDIT" verify 2>&1)
status=$?
[ "$status" -eq 0 ] || fail "archived: expected exit 0, got $status: $out"
case "$out" in
  *'archived=1'*'removal-audit ok'*) ;;
  *) fail "archived: expected the removal accounted as archived: $out" ;;
esac
pass "verify passes a removal archived with provenance"

# --- verify: a live relocation refuses without its receipt, passes with it --

home=$(make_home relocated)
cat > "$home/data/learnings.md" <<'MD'
# Learnings
- Treehouse pool slots share one repo, so workers must create their task branch before editing. <!--a:2026-08-03-->
- Muse trust prompts require the sandbox flag disabled on the first launch in an Orca pane. <!--a:2026-07-28-->
MD
FM_HOME="$home" "$AUDIT" snapshot >/dev/null || fail "relocated: snapshot failed"
mkdir -p "$home/.agents/skills/orca-notes"
cat > "$home/.agents/skills/orca-notes/SKILL.md" <<'MD'
# orca-notes
- Muse trust prompts require the sandbox flag disabled on the first launch in an Orca pane.
MD
cat > "$home/data/learnings.md" <<'MD'
# Learnings
- Treehouse pool slots share one repo, so workers must create their task branch before editing. <!--a:2026-08-03-->
MD
out=$(FM_HOME="$home" "$AUDIT" verify 2>&1)
status=$?
[ "$status" -eq 1 ] || fail "relocated: expected a refusal before the receipt, got $status: $out"
FM_HOME="$home" "$AUDIT" relocated "$home/.agents/skills/orca-notes/SKILL.md" >/dev/null \
  || fail "relocated: receipt recording failed"
out=$(FM_HOME="$home" "$AUDIT" verify 2>&1)
status=$?
[ "$status" -eq 0 ] || fail "relocated: expected exit 0 after the receipt, got $status: $out"
case "$out" in
  *'relocated=1'*'removal-audit ok'*) ;;
  *) fail "relocated: expected the removal accounted as relocated: $out" ;;
esac
pass "verify passes a receipted live relocation and refuses the same removal without it"

# --- verify: a receipt whose destination lacks the fact still refuses -------

home=$(make_home emptyreloc)
cat > "$home/data/learnings.md" <<'MD'
# Learnings
- Muse trust prompts require the sandbox flag disabled on the first launch in an Orca pane. <!--a:2026-07-28-->
MD
FM_HOME="$home" "$AUDIT" snapshot >/dev/null || fail "emptyreloc: snapshot failed"
printf '# notes\n- An unrelated note about something else entirely.\n' > "$home/other-note.md"
: > "$home/data/learnings.md"
FM_HOME="$home" "$AUDIT" relocated "$home/other-note.md" >/dev/null \
  || fail "emptyreloc: receipt recording failed"
out=$(FM_HOME="$home" "$AUDIT" verify 2>&1)
status=$?
[ "$status" -eq 1 ] || fail "emptyreloc: expected exit 1, got $status: $out"
case "$out" in
  *'unaccounted: file=data/learnings.md'*'Muse trust prompts'*) ;;
  *) fail "emptyreloc: refusal does not name the removed entry: $out" ;;
esac
pass "verify refuses a relocation receipt whose destination does not hold the fact"

# --- relocated: refuses an unreadable destination and needs a snapshot ------

out=$(FM_HOME="$home" "$AUDIT" relocated "$home/missing.md" 2>&1)
status=$?
[ "$status" -eq 2 ] || fail "relocated-missing: expected exit 2, got $status: $out"
home=$(make_home noreceiptsnap)
out=$(FM_HOME="$home" "$AUDIT" relocated /etc/hosts 2>&1)
status=$?
[ "$status" -eq 2 ] || fail "relocated-nosnapshot: expected exit 2, got $status: $out"
pass "relocated refuses a missing destination and a pass with no snapshot"

# --- verify: refuses to run without this pass's snapshot --------------------

home=$(make_home nosnapshot)
: > "$home/data/learnings.md"
out=$(FM_HOME="$home" "$AUDIT" verify 2>&1)
status=$?
[ "$status" -eq 2 ] || fail "nosnapshot: expected exit 2, got $status: $out"
case "$out" in
  *'no snapshot'*) ;;
  *) fail "nosnapshot: expected the missing-snapshot diagnostic: $out" ;;
esac
pass "verify refuses without a pass snapshot"

# --- referents: unresolvable tool reads unknown, never a verdict ------------

home=$(make_home unreachable)
cat > "$home/data/learnings.md" <<'MD'
# Learnings
- Waiting on the upstream fix before enabling (tracked: fm-open-task-a1). <!--p:2026-09-10-->
MD
out=$(env PATH="$BASE_PATH" FM_HOME="$home" "$AUDIT" referents 2>&1)
status=$?
[ "$status" -eq 0 ] || fail "unreachable: expected exit 0, got $status: $out"
case "$out" in
  *'id=fm-open-task-a1 verdict=unknown'*) ;;
  *) fail "unreachable: expected an unknown verdict: $out" ;;
esac
case "$out" in
  *'verdict=resolved'*|*'verdict=open'*) fail "unreachable: unavailable evidence must not read as a verdict: $out" ;;
esac
pass "referents reads an unreachable referent as unknown"

# --- referents against a real backlog ---------------------------------------

if ! command -v tasks-axi >/dev/null 2>&1; then
  pass "skipped real-backlog referent cases: tasks-axi not found"
  exit 0
fi

home=$(make_home referents)
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$home/.tasks.toml"
(cd "$home" \
  && tasks-axi add fm-open-task-a1 "open fixture task" \
  && tasks-axi add fm-fixed-task-b2 "landed fixture task" \
  && tasks-axi add task-cap3 "open task outside the suffix grammar" \
  && tasks-axi add task9 "landed task outside the suffix grammar" \
  && tasks-axi add my_task-b8 "landed task an underscore-splitting tokenizer would fragment" \
  && tasks-axi "done" fm-fixed-task-b2 \
  && tasks-axi "done" task9 \
  && tasks-axi "done" my_task-b8) >/dev/null 2>&1 \
  || fail "referents: backlog fixture setup failed"
cat > "$home/data/learnings.md" <<'MD'
# Learnings
- Waiting on the upstream fix before enabling (tracked: fm-open-task-a1). <!--p:2026-09-10-->
- No harness launch template scrubs the marker yet (tracked: fm-fixed-task-b2). <!--p:2026-09-10-->
- Blocked on a task nobody filed here (tracked: fm-ghost-task-z9). <!--p:2026-09-10-->
- Held until task9 lands upstream. <!--p:2026-09-10-->
- Still broken while task-cap3 stays open. <!--p:2026-09-10-->
- The wrapper double-frees; the fix is tracked as my_task-b8. <!--p:2026-09-10-->
- An aging entry mentioning fm-fixed-task-b2 stays out of referent scope. <!--a:2026-09-10-->
MD
out=$(FM_HOME="$home" "$AUDIT" referents 2>&1)
status=$?
[ "$status" -eq 1 ] || fail "referents: expected exit 1 on a resolved referent, got $status: $out"
case "$out" in
  *'id=fm-fixed-task-b2 verdict=resolved state=done'*) ;;
  *) fail "referents: resolved id not surfaced: $out" ;;
esac
case "$out" in
  *SURFACED*) ;;
  *) fail "referents: missing surfaced line: $out" ;;
esac
pass "referents surfaces an entry naming a resolved task id"

case "$out" in
  *'id=fm-open-task-a1 verdict=open'*) ;;
  *) fail "referents: open id not reported open: $out" ;;
esac
pass "referents leaves an entry naming an open task id alone"

case "$out" in
  *'id=fm-ghost-task-z9 verdict=unknown'*) ;;
  *) fail "referents: missing id must read unknown: $out" ;;
esac
case "$out" in
  *'id=fm-ghost-task-z9 verdict=resolved'*|*'id=fm-ghost-task-z9 verdict=open'*)
    fail "referents: missing id read as a verdict: $out" ;;
esac
pass "referents reads a missing backlog id as unknown"

case "$out" in
  *'stays out of referent scope'*) fail "referents: an aging entry must stay out of scope: $out" ;;
esac
pass "referents scans only perishable entries"

# Backlog identities outside the old suffix grammar must still be checked:
# the listing, not a shape, is the id authority.
case "$out" in
  *'id=task9 verdict=resolved state=done'*) ;;
  *) fail "referents: resolved id outside the suffix grammar not surfaced: $out" ;;
esac
case "$out" in
  *'id=task-cap3 verdict=open'*) ;;
  *) fail "referents: open id outside the suffix grammar not reported open: $out" ;;
esac
pass "referents checks backlog ids no shape grammar would accept"

# An underscore id stays whole: it is resolved as itself and its task-b8
# suffix is never probed as a different id.
case "$out" in
  *'id=my_task-b8 verdict=resolved state=done'*) ;;
  *) fail "referents: underscore id not resolved intact: $out" ;;
esac
case "$out" in
  *'id=task-b8 '*) fail "referents: underscore id fragmented into a different probe: $out" ;;
esac
pass "referents keeps an underscore id whole through sentence punctuation"

# Prose words pass the canonical charset too, so the summary counting only
# the six real mentions proves prose earns no verdict lines.
case "$out" in
  *'entries=6 ids=6 resolved=3 open=2 unknown=1'*) ;;
  *) fail "referents: expected exactly the six id mentions verdicted: $out" ;;
esac
pass "referents gives ordinary prose tokens no verdict"
