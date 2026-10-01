#!/usr/bin/env bash
# Behavior tests for the publish judge (bin/fm-publish-judge.sh) and its hook
# in the publish gate (bin/fm-publish-gate.sh pre-push and check-text, the
# latter reached through the gh publish guard).
#
# Every sample is synthetic, and the judges are the stub `codex` and `pi` from
# tests/lib.sh's fm_fake_publish_judges: they allow unless the test's
# FM_TEST_JUDGE_REFUSE pattern matches the material, so these cases pin the
# plumbing (what reaches the judge, which verdict wins, fail-closed, cache,
# fallback, public-only) rather than a model's judgment. The live smoke per
# model is `fm-publish-judge.sh probe`, run by hand.
set -u

unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-publish-gate.sh"
JUDGE="$ROOT/bin/fm-publish-judge.sh"
PRETOOL="$ROOT/bin/fm-arm-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-publish-judge)

PIN_NAME='Example Owner'
# Fixture emails are assembled at runtime so the committed lines never carry
# an address the staged-change email check would refuse.
PIN_EMAIL="4242+example-owner@""users.noreply.github.com"
PRIVATE_TERM='Zorblaxify'

CFG="$TMP_ROOT/config/publish-guard"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$CFG" "$FAKEBIN"
if ! command -v gitleaks >/dev/null 2>&1; then
  printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKEBIN/gitleaks"
  chmod +x "$FAKEBIN/gitleaks"
fi
cat >"$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
# Answers only the live privacy read of acme/secret-app, in any argument order.
[ "$1" = api ] || exit 1
case " $* " in *" repos/acme/secret-app "*) printf 'true\n' ;; *) exit 1 ;; esac
SH
chmod +x "$FAKEBIN/gh"
# The gate may answer its live privacy read only from a configured gh.
printf '%s\n' "$FAKEBIN/gh" >"$CFG/gh"
fm_fake_publish_judges "$FAKEBIN" "$CFG"
export PATH="$FAKEBIN:$PATH"
export FM_STATE_OVERRIDE="$TMP_ROOT/state"
export FM_TEST_JUDGE_CALLS="$TMP_ROOT/judge-calls"
export FM_TEST_JUDGE_PROMPTS="$TMP_ROOT/judge-prompts"
unset FM_PUBLISH_JUDGE_TIERS FM_PUBLISH_JUDGE_TIMEOUT FM_PUBLISH_JUDGE_CHUNK

printf 'name=%s\nemail=%s\n' "$PIN_NAME" "$PIN_EMAIL" >"$CFG/identity"
printf '# synthetic denylist\n%s\n' "$PRIVATE_TERM" >"$CFG/denylist"
: >"$CFG/poison-commits"
{
  printf 'public %s\n' "$TMP_ROOT/public.git"
  printf 'public acme/widgets\nprivate acme/secret-app\n'
} >"$CFG/allowlist"

# The synthetic samples.
printf 'Retry the fetch on a transient network error.\n\nTested with the unit suite.\n' >"$TMP_ROOT/body-clean.md"
# Written to pass the gate's literal narrative pattern, so only the judge sees it.
printf 'The owner asked me to ship this after the client call went badly, so I skipped the flaky test as they wanted.\n' >"$TMP_ROOT/body-narrative.md"
NARRATIVE_RE='owner asked me'
IDENTIFIER_LINE='# thanks to Dana Synthwell, 14 Quillfeather Lane, for the report'
IDENTIFIER_RE='Quillfeather Lane'

calls() {
  if [ -f "$FM_TEST_JUDGE_CALLS" ]; then wc -l <"$FM_TEST_JUDGE_CALLS" | tr -d ' '; else echo 0; fi
}

reset_judges() {
  rm -rf "$FM_STATE_OVERRIDE" "$FM_TEST_JUDGE_CALLS" "$FM_TEST_JUDGE_PROMPTS" "$CFG/judge-overrides"
  unset FM_TEST_JUDGE_CODEX FM_TEST_JUDGE_PI FM_TEST_JUDGE_REFUSE
}

# judge_text <body-file> -> rc; stdout in OUT, stderr in ERR
OUT="" ERR=""
judge_text() {
  local rc
  OUT=$("$JUDGE" text --dest acme/widgets --config "$CFG" "title:$TMP_ROOT/title.txt" "body:$1" 2>"$TMP_ROOT/err")
  rc=$?
  ERR=$(cat "$TMP_ROOT/err")
  return "$rc"
}
printf 'Retry transient fetch errors\n' >"$TMP_ROOT/title.txt"

pinned() {
  env GIT_AUTHOR_NAME="$PIN_NAME" GIT_AUTHOR_EMAIL="$PIN_EMAIL" \
    GIT_COMMITTER_NAME="$PIN_NAME" GIT_COMMITTER_EMAIL="$PIN_EMAIL" "$@"
}

fresh_repo() { # <name> -> repo path; origin is the allowlisted public bare repo
  local repo="$TMP_ROOT/$1" hooks="$TMP_ROOT/$1.hooks"
  rm -rf "$TMP_ROOT/public.git" "$repo" "$hooks"
  git init -q --bare -b main "$TMP_ROOT/public.git"
  git init -q -b main "$repo"
  mkdir -p "$hooks"
  "$GATE" install "$hooks" --config "$CFG" >/dev/null 2>&1 || fail "gate install failed"
  # These cases prove the push side, so they commit content the gate's staged
  # check would stop at commit time.
  rm -f "$hooks/pre-commit"
  git -C "$repo" config core.hooksPath "$hooks"
  git -C "$repo" remote add origin "$TMP_ROOT/public.git"
  printf 'base\n' >"$repo/README.md"
  git -C "$repo" add README.md
  pinned git -C "$repo" commit -q -m 'initial commit' || fail "initial commit failed"
  printf '%s\n' "$repo"
}

commit_file() { # <repo> <file> <content> <message>
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" >"$1/$2"
  git -C "$1" add "$2"
  pinned git -C "$1" commit -q -m "$4"
}

test_clean_text_is_allowed() {
  reset_judges
  FM_TEST_JUDGE_REFUSE=$NARRATIVE_RE judge_text "$TMP_ROOT/body-clean.md" || fail "a clean PR body should be allowed: $ERR"
  assert_equals allow "$(printf '%s' "$OUT" | jq -r .verdict)" "the verdict JSON says allow"
  assert_equals codex/gpt-6.1-sol "$(printf '%s' "$OUT" | jq -r .judge)" "the primary judge answered"
  assert_equals 1 "$(calls)" "one judge call"
  pass "a clean PR title and body are allowed by the primary judge"
}

test_operator_narrative_is_refused() {
  reset_judges
  export FM_TEST_JUDGE_REFUSE=$NARRATIVE_RE
  judge_text "$TMP_ROOT/body-narrative.md" && fail "an operator-direction narrative should be refused"
  assert_equals refuse "$(printf '%s' "$OUT" | jq -r .verdict)" "the verdict JSON says refuse"
  assert_equals 'text 1: stub finding' "$(printf '%s' "$OUT" | jq -r '.reasons[0]')" "the judge's reason is carried"
  assert_contains "$ERR" "fm-publish-judge: REFUSED" "refusal line"
  assert_contains "$ERR" "finding: text 1: stub finding" "finding line"
  assert_contains "$ERR" "fix: rewrite or remove" "one-line fix"
  assert_contains "$ERR" "fm-publish-judge.sh override $(printf '%s' "$OUT" | jq -r '.hashes[0]')" "the fix names the captain override for this content"
  pass "a PR body with an operator-direction narrative is refused with its finding and a one-line fix"
}

test_judge_unavailable_is_refused() {
  reset_judges
  FM_TEST_JUDGE_CODEX=down FM_TEST_JUDGE_PI=down judge_text "$TMP_ROOT/body-clean.md" \
    && fail "a publication no judge answered should be refused"
  assert_contains "$ERR" "no publish judge answered for public destination acme/widgets" "unavailable refusal"
  assert_contains "$ERR" "codex: failed (exit 1)" "names why codex gave nothing"
  assert_contains "$ERR" "pi: failed (exit 1)" "names why pi gave nothing"
  assert_contains "$ERR" "fix: sign the judge in" "one-line fix"
  assert_equals 2 "$(calls)" "both tiers were tried"
  # Nothing is cached for an unanswered call: the judge is asked again.
  judge_text "$TMP_ROOT/body-clean.md" || fail "the same text should pass once a judge answers: $ERR"
  assert_equals 3 "$(calls)" "the retry reached a judge"

  reset_judges
  printf '%s\n' "$TMP_ROOT/no-such/codex" >"$CFG/codex"
  printf 'pi\n' >"$CFG/pi"
  judge_text "$TMP_ROOT/body-clean.md" && fail "with no judge installed a public publication should be refused"
  assert_contains "$ERR" "codex: not installed" "names the missing codex"
  assert_contains "$ERR" "pi: not installed" "a relative judge path is never looked up on PATH"
  assert_equals 0 "$(calls)" "no stub on PATH answered"
  fm_fake_publish_judges "$FAKEBIN" "$CFG"

  reset_judges
  FM_PUBLISH_JUDGE_TIERS='' judge_text "$TMP_ROOT/body-clean.md" && fail "an empty judge list should refuse"
  assert_contains "$ERR" "no judge tier is configured" "empty tier list"
  pass "with no judge answering (down, not installed, or none configured) a public publication is refused, never allowed"
}

test_fallback_tier_answers() {
  reset_judges
  FM_TEST_JUDGE_CODEX=down judge_text "$TMP_ROOT/body-clean.md" || fail "the fallback judge should answer: $ERR"
  assert_equals pi/xai/grok-4.7 "$(printf '%s' "$OUT" | jq -r .judge)" "the fallback judge answered"

  reset_judges
  FM_TEST_JUDGE_CODEX=prose FM_TEST_JUDGE_REFUSE=$NARRATIVE_RE judge_text "$TMP_ROOT/body-narrative.md" \
    && fail "the fallback judge's refusal should stand"
  assert_equals pi/xai/grok-4.7 "$(printf '%s' "$OUT" | jq -r .judge)" "an answer with no verdict falls through"

  reset_judges
  local started elapsed
  started=$(date +%s)
  FM_TEST_JUDGE_CODEX=hang FM_PUBLISH_JUDGE_TIMEOUT=2 judge_text "$TMP_ROOT/body-clean.md" \
    || fail "a hung primary should fall back: $ERR"
  elapsed=$(($(date +%s) - started))
  [ "$elapsed" -lt 20 ] || fail "a hung judge should be cut at its bound (took ${elapsed}s)"
  assert_equals pi/xai/grok-4.7 "$(printf '%s' "$OUT" | jq -r .judge)" "the timed-out primary fell back"

  reset_judges
  FM_TEST_JUDGE_REFUSE=$NARRATIVE_RE FM_TEST_JUDGE_PI=down judge_text "$TMP_ROOT/body-narrative.md"
  assert_equals 1 "$(calls)" "a clean refusal is final and never asked of the next judge"
  pass "the fallback judge answers when the primary is down, hung, or verdictless, and a refusal is final"
}

test_verdicts_are_cached_by_content() {
  reset_judges
  judge_text "$TMP_ROOT/body-clean.md" || fail "first call: $ERR"
  judge_text "$TMP_ROOT/body-clean.md" || fail "second call: $ERR"
  assert_equals 1 "$(calls)" "identical content is judged once"
  assert_equals true "$(printf '%s' "$OUT" | jq -r .cached)" "the second verdict is from the cache"
  export FM_TEST_JUDGE_REFUSE=$NARRATIVE_RE
  judge_text "$TMP_ROOT/body-narrative.md"
  judge_text "$TMP_ROOT/body-narrative.md" && fail "a cached refusal still refuses"
  assert_equals 2 "$(calls)" "a refusal is cached too"
  unset FM_TEST_JUDGE_REFUSE
  "$JUDGE" text --dest acme/other --config "$CFG" "body:$TMP_ROOT/body-clean.md" >/dev/null 2>&1 || fail "other dest"
  assert_equals 3 "$(calls)" "the cache is per destination"
  [ -s "$FM_STATE_OVERRIDE/publish-judge/log.jsonl" ] || fail "each decision is logged"
  pass "verdicts are cached by content hash per destination, refusals included, and logged"
}

test_captain_override() {
  reset_judges
  export FM_TEST_JUDGE_REFUSE=$NARRATIVE_RE
  judge_text "$TMP_ROOT/body-narrative.md"
  local hash rc
  hash=$(printf '%s' "$OUT" | jq -r '.hashes[0]')
  "$JUDGE" override "$hash" --config "$CFG" </dev/null >/dev/null 2>"$TMP_ROOT/err"
  rc=$?
  [ "$rc" -ne 0 ] || fail "an override without an interactive terminal should be refused"
  assert_contains "$(cat "$TMP_ROOT/err")" "needs the captain at an interactive terminal" "override refusal"
  [ ! -e "$CFG/judge-overrides" ] || fail "a refused override writes nothing"
  "$JUDGE" override not-a-hash --config "$CFG" </dev/null >/dev/null 2>&1
  [ $? -eq 2 ] || fail "an override of something that is not a hash is a usage error"
  # What a confirmed override records: the hash, allowed without a judge call.
  printf '%s 2026-01-01T00:00:00Z\n' "$hash" >"$CFG/judge-overrides"
  rm -rf "$FM_STATE_OVERRIDE"
  judge_text "$TMP_ROOT/body-narrative.md" || fail "an overridden hash should be allowed: $ERR"
  assert_equals 1 "$(calls)" "an override needs no judge call"
  assert_equals captain-override "$(printf '%s' "$OUT" | jq -r .judge)" "attributed to the override"
  pass "only a confirmed captain override allows refused content, and only that exact content"
}

test_large_material_is_chunked() {
  reset_judges
  local i
  for i in $(seq 1 40); do printf 'Line %s of a long neutral description.\n' "$i"; done >"$TMP_ROOT/body-long.md"
  FM_PUBLISH_JUDGE_CHUNK=300 judge_text "$TMP_ROOT/body-long.md" || fail "clean chunks should all pass: $ERR"
  [ "$(calls)" -gt 2 ] || fail "long material should be judged in several chunks (got $(calls) calls)"
  reset_judges
  printf 'The owner asked me to add this last line.\n' >>"$TMP_ROOT/body-long.md"
  FM_TEST_JUDGE_REFUSE=$NARRATIVE_RE FM_PUBLISH_JUDGE_CHUNK=300 judge_text "$TMP_ROOT/body-long.md" \
    && fail "one refused chunk should refuse the whole publication"
  pass "material beyond the chunk size is judged in chunks and every chunk must be allowed"
}

test_gate_push_uses_the_judge() {
  reset_judges
  local repo out
  export FM_TEST_JUDGE_REFUSE=$IDENTIFIER_RE
  repo=$(fresh_repo push)
  commit_file "$repo" src/fetch.sh 'retry_fetch() { for i in 1 2 3; do fetch && return; done; }' 'Retry the fetch three times'
  out=$(git -C "$repo" push -q origin main 2>&1) || fail "a clean code change should be pushed: $out"
  assert_equals 1 "$(calls)" "the public push was judged"
  assert_contains "$(cat "$FM_TEST_JUDGE_PROMPTS")" "=== commit " "the judge sees the commits grouped by location"
  assert_contains "$(cat "$FM_TEST_JUDGE_PROMPTS")" "retry_fetch()" "the judge sees the added lines"

  commit_file "$repo" src/credits.sh "$IDENTIFIER_LINE" 'Add credits'
  out=$(git -C "$repo" push -q origin main 2>&1) && fail "a hidden personal identifier should be refused"
  assert_contains "$out" "fm-publish-judge: REFUSED" "the judge refused the push"
  assert_contains "$out" "fix: rewrite or remove" "the push refusal carries the fix"
  [ "$(git -C "$TMP_ROOT/public.git" rev-parse main)" != "$(git -C "$repo" rev-parse main)" ] \
    || fail "the refused commit must not reach the destination"
  pass "a public push is judged after the literal checks: clean code passes and a hidden identifier is refused"
}

test_denylist_never_reaches_the_judge() {
  reset_judges
  local repo out
  repo=$(fresh_repo deny)
  commit_file "$repo" notes.txt "Built for $PRIVATE_TERM." 'Add notes'
  out=$(git -C "$repo" push -q origin main 2>&1) && fail "a denylist hit should be refused"
  assert_contains "$out" "denylist rule" "the literal gate refused first"
  assert_equals 0 "$(calls)" "material with a literal private term is never sent to a judge"

  reset_judges
  printf 'Adds a retry.\n' >"$TMP_ROOT/body-ok.md"
  "$GATE" check-text --dest acme/widgets --config "$CFG" "body:$TMP_ROOT/body-ok.md" 2>/dev/null \
    || fail "clean text should pass the gate"
  assert_equals 1 "$(calls)" "public text is judged"
  assert_not_contains "$(cat "$FM_TEST_JUDGE_PROMPTS")" "$PRIVATE_TERM" "the prompt never carries the denylist"
  assert_not_contains "$(cat "$FM_TEST_JUDGE_PROMPTS")" "$PIN_EMAIL" "the prompt never carries the identity file"
  assert_contains "$(cat "$FM_TEST_JUDGE_PROMPTS")" "Operator-direction narrative" "the prompt carries the policy categories"
  local tool
  for tool in herdr tmux orca zellij cmux treehouse gh Playwright tasks-axi quota-axi gh-axi lavish-axi chrome-devtools-axi no-mistakes \
    'Claude Code' Anthropic Codex OpenAI OpenCode Pi Grok xAI Kimi Moonshot Cursor Gemini Google Muse Rovo Atlassian omp agy Antigravity Devin Cognition; do
    assert_contains "$(cat "$FM_TEST_JUDGE_PROMPTS")" "$tool" "the prompt names $tool as an allowed public tool"
  done
  pass "the judge runs only after the literal checks pass and never receives the private config"
}

test_private_and_local_destinations_skip_the_judge() {
  reset_judges
  printf 'Adds a retry.\n' >"$TMP_ROOT/body-ok.md"
  "$GATE" check-text --dest acme/secret-app --config "$CFG" "body:$TMP_ROOT/body-ok.md" 2>/dev/null \
    || fail "text to a confirmed private repo should pass"
  local repo out scratch="$TMP_ROOT/scratch.git"
  repo=$(fresh_repo local)
  git init -q --bare -b main "$scratch"
  git -C "$repo" remote add scratch "$scratch"
  out=$(git -C "$repo" push -q scratch main 2>&1) || fail "a push to an unlisted local path should pass: $out"
  "$JUDGE" text --dest acme/widgets --config "$CFG" >/dev/null 2>&1 || fail "no text has nothing to judge"
  assert_equals 0 "$(calls)" "private and local destinations, and an empty text set, never call the judge"
  pass "private and local destinations never reach the judge"
}

test_gh_guard_uses_the_judge() {
  reset_judges
  local out rc
  export FM_TEST_JUDGE_REFUSE=$NARRATIVE_RE
  cp "$TMP_ROOT/body-narrative.md" "$TMP_ROOT/pr-body.md"
  out=$(cd "$TMP_ROOT" && FM_CONFIG_OVERRIDE="$TMP_ROOT/config" "$PRETOOL" --publish-only --claude \
    --command 'gh pr create --repo acme/widgets --title "Skip the flaky test" --body-file pr-body.md' 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "the gh guard should refuse what the judge refuses (rc=$rc): $out"
  assert_contains "$out" "fm-publish-judge: REFUSED" "the refusal comes from the judge"
  out=$(cd "$TMP_ROOT" && FM_CONFIG_OVERRIDE="$TMP_ROOT/config" "$PRETOOL" --publish-only --claude \
    --command 'gh pr create --repo acme/widgets --title "Retry transient fetch errors" --body-file body-clean.md' 2>&1 >/dev/null) \
    || fail "a clean PR should pass the gh guard: $out"
  pass "the gh publish guard refuses PR text the judge refuses and passes clean text"
}

cached_verdicts() {
  find "$FM_STATE_OVERRIDE/publish-judge/cache" -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

# A verdict counts only from a judge call that completed: an allow printed
# before a nonzero exit, or before the bound cut the call, is no verdict, is
# never cached, and falls through to the next judge or refuses.
test_verdict_from_a_failed_call_is_not_accepted() {
  reset_judges
  FM_TEST_JUDGE_CODEX=failjson FM_TEST_JUDGE_PI=failjson judge_text "$TMP_ROOT/body-clean.md" \
    && fail "an allow from judges that exited nonzero should not be accepted"
  assert_equals refuse "$(printf '%s' "$OUT" | jq -r .verdict)" "the verdict JSON says refuse"
  assert_contains "$ERR" "codex: failed (exit 7)" "names the failed codex call"
  assert_contains "$ERR" "pi: failed (exit 7)" "names the failed pi call"
  assert_equals 0 "$(cached_verdicts)" "a failed call caches nothing"
  judge_text "$TMP_ROOT/body-clean.md" || fail "the same text should pass once a judge completes: $ERR"
  assert_equals 3 "$(calls)" "the retry reached a judge again"

  reset_judges
  FM_TEST_JUDGE_CODEX=failjson judge_text "$TMP_ROOT/body-clean.md" || fail "the fallback judge should answer: $ERR"
  assert_equals pi/xai/grok-4.7 "$(printf '%s' "$OUT" | jq -r .judge)" "a failed primary falls back"

  reset_judges
  local started elapsed
  started=$(date +%s)
  FM_TEST_JUDGE_CODEX=hangjson FM_TEST_JUDGE_PI=hangjson FM_PUBLISH_JUDGE_TIMEOUT=2 judge_text "$TMP_ROOT/body-clean.md" \
    && fail "an allow written before the bound cut the call should not be accepted"
  elapsed=$(($(date +%s) - started))
  [ "$elapsed" -lt 20 ] || fail "a hung judge should be cut at its bound (took ${elapsed}s)"
  assert_contains "$ERR" "codex: timed out after 2s" "names the timed-out codex call"
  assert_contains "$ERR" "pi: timed out after 2s" "names the timed-out pi call"
  assert_equals 0 "$(cached_verdicts)" "a timed-out call caches nothing"

  reset_judges
  FM_TEST_JUDGE_CODEX=failjson FM_TEST_JUDGE_PI=failjson "$GATE" check-text --dest acme/widgets --config "$CFG" \
    "body:$TMP_ROOT/body-clean.md" 2>/dev/null && fail "the gate should refuse when no judge call completed"
  pass "an allow from a judge call that exited nonzero or timed out is never accepted or cached"
}

# The answer must carry one verdict: several allows are no verdict, and any
# refusal among conflicting verdicts refuses.
test_one_verdict_per_answer() {
  reset_judges
  FM_TEST_JUDGE_CODEX=twoallow FM_TEST_JUDGE_PI=twoallow judge_text "$TMP_ROOT/body-clean.md" \
    && fail "an answer with several verdicts should not allow"
  assert_contains "$ERR" "codex: several verdicts in its answer" "names the ambiguous answer"
  reset_judges
  FM_TEST_JUDGE_CODEX=conflict judge_text "$TMP_ROOT/body-clean.md" && fail "a conflicting answer should refuse"
  assert_equals refuse "$(printf '%s' "$OUT" | jq -r .verdict)" "the refusal wins"
  assert_equals 1 "$(calls)" "the conflicting refusal is final"
  pass "a judge answer must hold exactly one allow, and a refusal among several verdicts refuses"
}

# Every entry point that calls a model checks the exact material against the
# denylist first, whoever called it, so a known private term never reaches a
# provider even when the judge is run directly.
test_judge_entry_points_run_the_literal_preflight() {
  reset_judges
  local out
  printf 'Built for %s.\n' "$PRIVATE_TERM" >"$TMP_ROOT/body-deny.md"
  judge_text "$TMP_ROOT/body-deny.md" && fail "direct judge text with a denylisted term should be refused"
  assert_contains "$ERR" "denylist rule" "the preflight names the rule"
  assert_contains "$ERR" "fix: remove the flagged text" "the preflight names the fix"
  assert_not_contains "$ERR" "$PRIVATE_TERM" "the refusal never echoes the term"
  assert_equals refuse "$(printf '%s' "$OUT" | jq -r .verdict)" "the verdict JSON says refuse"

  printf 'clean line\nBuilt for %s.\n' "$PRIVATE_TERM" >"$TMP_ROOT/corpus-deny.txt"
  printf 'commit abc123 notes.md:1\ncommit abc123 notes.md:2\n' >"$TMP_ROOT/where-deny.txt"
  "$JUDGE" corpus --dest acme/widgets --config "$CFG" "$TMP_ROOT/corpus-deny.txt" "$TMP_ROOT/where-deny.txt" >/dev/null 2>&1 \
    && fail "direct judge corpus with a denylisted term should be refused"
  out=$("$JUDGE" probe --tier codex --dest acme/widgets --kind text --config "$CFG" "$TMP_ROOT/body-deny.md" 2>&1) \
    && fail "a direct judge probe with a denylisted term should be refused: $out"
  assert_not_contains "$out" "$PRIVATE_TERM" "the probe refusal never echoes the term"
  assert_equals 0 "$(calls)" "no model was called"
  [ ! -s "$FM_TEST_JUDGE_PROMPTS" ] || fail "no prompt was built for a model"

  mv "$CFG/denylist" "$CFG/denylist.saved"
  judge_text "$TMP_ROOT/body-clean.md" && fail "with no denylist nothing should go to a model"
  assert_contains "$ERR" "no denylist" "names the missing denylist"
  mv "$CFG/denylist.saved" "$CFG/denylist"
  assert_equals 0 "$(calls)" "still no model call"

  out=$("$JUDGE" probe --tier codex --dest acme/widgets --kind text --config "$CFG" "$TMP_ROOT/body-clean.md" 2>&1) \
    || fail "a clean probe should run: $out"
  assert_contains "$out" '"verdict":"allow"' "a clean probe reaches the judge"
  out=$(FM_TEST_JUDGE_CODEX=failjson "$JUDGE" probe --tier codex --dest acme/widgets --kind text --config "$CFG" "$TMP_ROOT/body-clean.md" 2>&1)
  assert_contains "$out" "(no verdict, exit 7)" "a probe reports a failed call's allow as no verdict"
  pass "text, corpus, and probe each run the denylist preflight before any model call"
}

test_pi_prompt_beyond_one_argument_reaches_the_judge() {
  reset_judges
  local material="$TMP_ROOT/material-wide.txt" out
  # One line longer than Linux's 128 KiB single-argument limit, which the
  # chunker cannot split.
  { printf '=== text 1\n'; head -c 140000 /dev/zero | tr '\0' 'a'; printf ' WIDE_LINE_END\n'; } >"$material"
  out=$("$JUDGE" probe --tier pi --dest acme/widgets --kind text --config "$CFG" "$material" 2>&1) \
    || fail "a probe with a wide line should reach the pi judge: $out"
  assert_contains "$out" '"verdict":"allow"' "the pi judge answered"
  assert_equals pi "$(cat "$FM_TEST_JUDGE_CALLS")" "only the pi tier was called"
  sed -n '/^BEGIN MATERIAL /,/^END MATERIAL /{/^BEGIN MATERIAL /d;/^END MATERIAL /d;p;}' "$FM_TEST_JUDGE_PROMPTS" >"$TMP_ROOT/material-seen.txt"
  cmp -s "$material" "$TMP_ROOT/material-seen.txt" \
    || fail "the pi judge must receive the whole material ($(wc -c <"$material") bytes sent, $(wc -c <"$TMP_ROOT/material-seen.txt") received)"
  pass "the pi judge receives a prompt beyond one argument's limit intact on stdin"
}

test_pi_prompt_beyond_one_argument_reaches_the_judge
test_clean_text_is_allowed
test_operator_narrative_is_refused
test_judge_unavailable_is_refused
test_fallback_tier_answers
test_verdict_from_a_failed_call_is_not_accepted
test_one_verdict_per_answer
test_judge_entry_points_run_the_literal_preflight
test_verdicts_are_cached_by_content
test_captain_override
test_large_material_is_chunked
test_gate_push_uses_the_judge
test_denylist_never_reaches_the_judge
test_private_and_local_destinations_skip_the_judge
test_gh_guard_uses_the_judge

echo "# all fm-publish-judge tests passed"
