#!/usr/bin/env bash
# Behavioral tests for bin/fm-pr-state.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pr-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-state-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
command -v jq >/dev/null 2>&1 \
  || fail "these tests run the script's own jq programs over API-shaped JSON with the real jq, which was not found"

HEAD=c2eac54c17a1ddc2633ad51b83e21e5fe888142e
OLD_HEAD_1=2710bc5efc936efb70e95b86ca3582e9da7e60f4
OLD_HEAD_2=4dc2291e6969de1bf204fbdb53c9e57a8353d4e2

# The fake gh answers every query with the JSON shape GitHub returns and runs
# the --jq program it received with the real jq, so field selection is what is
# under test. Calls without --jq get the raw served JSON back, the way gh's API
# calls behave. The pull-request object speaks GitHub's own vocabulary: an
# uppercase state with MERGED as its own value, and a null mergeable while
# GitHub is still computing one.
# It evaluates with the local jq, while gh itself embeds gojq; the live guard in
# tests/fm-pr-state-live-e2e.test.sh runs the real engine.
# Default fixtures describe a repository with no required status checks at
# all: an unprotected branch summary and an empty rules list, which the
# canonical policy read resolves to a positively empty required set, and gh's
# required view answering its "no required checks reported" sentence.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -o pipefail
head=c2eac54c17a1ddc2633ad51b83e21e5fe888142e
runs_default='{"check_runs":[]}'
branch_default='{"name":"main","protected":false}'
serve() {
  case "$*" in
    "pr view "*" --json state,mergedAt,isDraft,headRefOid,author,mergeable,reviewDecision,updatedAt,baseRefName,statusCheckRollup"*)
      jq -n --arg head "$head" --arg state "${FM_TEST_STATE-OPEN}" \
        --arg merged "${FM_TEST_MERGED_AT-}" --arg draft "${FM_TEST_DRAFT-false}" \
        --arg mergeable "${FM_TEST_VIEW_MERGEABLE-MERGEABLE}" \
        --arg decision "${FM_TEST_VIEW_REVIEW_DECISION-APPROVED}" \
        --arg base "${FM_TEST_BASE-main}" \
        --argjson rollup "${FM_TEST_ROLLUP-[]}" \
        '{state: $state, mergedAt: (if $merged == "" then null else $merged end),
          isDraft: ($draft == "true"), headRefOid: $head,
          author: {login: "prauthor", is_bot: false},
          mergeable: (if $mergeable == "null" then null else $mergeable end),
          reviewDecision: $decision, updatedAt: (env.FM_TEST_UPDATED_AT // "2020-01-01T00:00:00Z"),
          baseRefName: $base, statusCheckRollup: $rollup}'
      ;;
    "api --paginate repos/o/r/commits/"*"/check-runs")
      if [ -n "${FM_TEST_RUNS_ERROR-}" ]; then
        printf '%s\n' "$FM_TEST_RUNS_ERROR" >&2
        exit 1
      fi
      printf '%s\n' "${FM_TEST_RUNS:-$runs_default}"
      ;;
    "api --paginate repos/o/r/rules/branches/"*)
      if [ -n "${FM_TEST_RULES_ERROR-}" ]; then
        printf '%s\n' "$FM_TEST_RULES_ERROR" >&2
        exit 1
      fi
      printf '%s\n' "${FM_TEST_RULES:-[]}"
      ;;
    "api repos/o/r/branches/"*)
      if [ -n "${FM_TEST_BRANCH_ERROR-}" ]; then
        printf '%s\n' "$FM_TEST_BRANCH_ERROR" >&2
        exit 1
      fi
      printf '%s\n' "${FM_TEST_BRANCH:-$branch_default}"
      ;;
    "api graphql "*)
      [ "${FM_TEST_THREAD_ERROR:-0}" = 0 ] || exit 1
      threads='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
      printf '%s\n' "${FM_TEST_THREADS:-$threads}"
      ;;
    "api /repos/o/r/pulls/7/reviews?per_page=100 --paginate --jq "*)
      printf '%s\n' "${FM_TEST_REVIEWS:-[]}"
      ;;
    "pr checks "*" --required --json name,state,bucket --jq "*)
      if [ -n "${FM_TEST_CHECKS_ERROR-}" ]; then
        printf '%s\n' "$FM_TEST_CHECKS_ERROR" >&2
        exit 1
      fi
      if [ -z "${FM_TEST_REQUIRED_CHECKS-}" ]; then
        printf "no required checks reported on the '%s' branch\n" "${FM_TEST_BASE-main}" >&2
        exit 1
      fi
      printf '%s\n' "$FM_TEST_REQUIRED_CHECKS"
      ;;
    "pr checks "*" --json name,state,bucket --jq "*)
      if [ -n "${FM_TEST_REPORTED_CHECKS_ERROR-}" ]; then
        printf '%s\n' "$FM_TEST_REPORTED_CHECKS_ERROR" >&2
        exit 1
      fi
      checks='[{"name":"lint","state":"SUCCESS","bucket":"pass","workflow":"ci"},{"name":"optional","state":"SKIPPED","bucket":"skipping","workflow":"ci"}]'
      printf '%s\n' "${FM_TEST_REPORTED_CHECKS:-$checks}"
      ;;
    *)
      printf 'unexpected gh call: %s\n' "$*" >&2
      exit 91
      ;;
  esac
}
prog=
prev=
for arg in "$@"; do
  [ "$prev" != --jq ] || prog=$arg
  prev=$arg
done
out=$(serve "$@") || exit $?
if [ -n "$prog" ]; then
  printf '%s\n' "$out" | jq -r "$prog"
else
  printf '%s\n' "$out"
fi
SH
chmod +x "$FAKEBIN/gh"

run_state() {
  PATH="$FAKEBIN:$PATH" "$SCRIPT" https://github.com/o/r/pull/7
}

# reviews "<login> <state> <commit> <submitted_at>"... prints the JSON array
# GitHub's reviews endpoint returns for those submissions.
reviews() {
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(. != "") | split(" +"; "")
    | {user: {login: .[0], type: .[1]}, state: .[2], commit_id: .[3], submitted_at: .[4]})'
}

test_clean_pr_is_silent_and_ignores_skipped_checks() {
  local out
  out=$(run_state) || fail "clean fixture was refused"
  [ -z "$out" ] || fail "clean fixture should be silent, got: $out"
  pass "a passing required check and a skipped one leave nothing to report"
}

test_terminal_state_is_the_whole_report() {
  local out
  out=$(FM_TEST_STATE=CLOSED FM_TEST_VIEW_MERGEABLE=null run_state) \
    || fail "closed fixture was refused"
  [ "$out" = 'STATE: closed' ] \
    || fail "a closed pull request leaves the author nothing else to read, got: $out"

  out=$(FM_TEST_STATE=MERGED FM_TEST_MERGED_AT=2019-10-04T16:01:04Z \
    FM_TEST_VIEW_MERGEABLE=null FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED run_state) \
    || fail "merged fixture was refused"
  [ "$out" = 'STATE: merged at 2019-10-04T16:01:04Z' ] \
    || fail "a merged pull request says so and reports no blocker after it, got: $out"
  pass "a terminal pull request reports that state and nothing else"
}

test_draft_is_a_blocker() {
  local out
  out=$(FM_TEST_DRAFT=true run_state) || fail "draft fixture was refused"
  assert_contains "$out" 'DRAFT: pull request is not ready for review' \
    "a draft pull request leaves the author something to do"
  pass "draft state blocks readiness"
}

test_stale_blocking_reviews_explain_a_blocking_decision() {
  local out history expected
  history=$(reviews \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_1 2026-09-01T00:15:44Z" \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_2 2026-09-01T23:02:13Z" \
    "commenter User COMMENTED $OLD_HEAD_2 2026-09-01T23:10:00Z" \
    "alice User APPROVED $OLD_HEAD_2 2026-09-01T23:11:00Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "voided-review fixture was refused"
  expected=$(printf 'REVIEW DECISION: CHANGES_REQUESTED\nSTALE BLOCKING REVIEW: coderabbitai[bot] CHANGES_REQUESTED at %s' "$OLD_HEAD_2")
  [ "$out" = "$expected" ] \
    || fail "a stale verdict names the commit it was left at and no head this reading was not verified against, got: $out"
  assert_not_contains "$out" "$OLD_HEAD_1" \
    "a verdict the same reviewer later superseded is history, not a blocker"
  assert_not_contains "$out" 'commenter' \
    "a stale COMMENTED review is informational noise"
  assert_not_contains "$out" 'alice' \
    "a stale approval is not a concrete blocker"
  pass "stale changes-requested verdicts explain a blocking review decision"
}

test_approved_pr_with_only_stale_changes_requested_is_silent() {
  local out history
  history=$(reviews \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_1 2026-09-01T00:15:44Z" \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z" \
    "coderabbitai[bot] Bot APPROVED $HEAD 2026-09-02T14:05:42Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=APPROVED FM_TEST_REVIEWS=$history run_state) \
    || fail "approved stale-review fixture was refused"
  [ -z "$out" ] || fail "an approved PR with only stale review history should be silent, got: $out"
  pass "approved PR ignores stale changes-requested history"
}

test_current_changes_requested_review_is_a_blocker() {
  local out history
  history=$(reviews "coderabbitai[bot] Bot CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "current-review fixture was refused"
  [ "$out" = $'REVIEW DECISION: CHANGES_REQUESTED\nREVIEW: coderabbitai[bot] CHANGES_REQUESTED' ] \
    || fail "a verdict left at the head under review blocks readiness and names no head, got: $out"
  pass "current changes-requested review blocks readiness"
}

test_changes_requested_decision_is_never_silent() {
  local out history
  history=$(reviews \
    "bob User CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z" \
    "bob User COMMENTED $HEAD 2026-09-02T14:05:42Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "comment-after-changes fixture was refused"
  [ "$out" = $'REVIEW DECISION: CHANGES_REQUESTED\nREVIEW: bob CHANGES_REQUESTED' ] \
    || fail "a later COMMENTED review does not clear the reviewer's change request, got: $out"

  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED run_state) \
    || fail "decision-only fixture was refused"
  [ "$out" = 'REVIEW DECISION: CHANGES_REQUESTED' ] \
    || fail "GitHub's blocking decision must be printed even without an explaining review, got: $out"
  pass "a CHANGES_REQUESTED decision is always reported"
}

test_authors_own_changes_requested_review_is_not_a_blocker() {
  local out history
  history=$(reviews "prauthor User CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "self-review fixture was refused"
  assert_not_contains "$out" 'REVIEW: prauthor' \
    "the author's own verdict is not a reviewer blocking them"
  pass "the author's own review is never listed as a blocker"
}

test_pending_approval_is_not_a_blocker() {
  local out
  out=$(FM_TEST_VIEW_REVIEW_DECISION=REVIEW_REQUIRED run_state) \
    || fail "review-required fixture was refused"
  [ -z "$out" ] || fail "awaiting approval is not a blocker this command reports, got: $out"
  pass "a pending approval is not reported as a blocker"
}

test_required_failure_is_a_blocker() {
  local out
  out=$(FM_TEST_REQUIRED_CHECKS='[{"name":"CI Status","state":"FAILURE","bucket":"fail","workflow":"ci"},{"name":"lint","state":"SUCCESS","bucket":"pass","workflow":"ci"}]' run_state) \
    || fail "blocked fixture was refused"
  assert_contains "$out" 'REQUIRED CHECK: CI Status (FAILURE)' \
    "required failure was not reported"
  assert_not_contains "$out" 'lint' \
    "a passing required check is not a blocker"
  pass "required failure blocks readiness"
}

# The next two cases supply gh's own "nothing reported" sentences through
# FM_TEST_CHECKS_ERROR, so they prove the behaviour GIVEN those strings and
# nothing about the strings themselves. A gh reword is invisible to this
# hermetic suite; only a run against a real gh would catch one.
test_unreported_required_checks_are_named() {
  local out status
  out=$(FM_TEST_RULES='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci"},{"context":"deploy"}]}}]' \
    run_state) || fail "a head without reported required checks was refused"
  [ "$out" = $'REQUIRED CHECK: ci (not reported)\nREQUIRED CHECK: deploy (not reported)' ] \
    || fail "a configured required check that never reported must be named, not pass silently as ready, got: $out"
  # This asserts the branch taken for gh's sentence, not that gh still says it.

  status=0
  FM_TEST_CHECKS_ERROR='HTTP 502: Bad Gateway' run_state >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "a real check lookup failure must still refuse"
  pass "given gh's sentence, configured-but-unreported required checks are named, other check lookup failures refuse"
}

# When the required view reports nothing while required checks are configured,
# the reported view still runs so a failing advisory check stays visible.
test_reported_failure_stays_visible_behind_unreported_required() {
  local out
  out=$(FM_TEST_RULES='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci"}]}}]' \
    FM_TEST_REPORTED_CHECKS='[{"name":"backend","state":"FAILURE","bucket":"fail","workflow":"ci"}]' \
    run_state) || fail "unreported-required fixture was refused"
  assert_contains "$out" 'REQUIRED CHECK: ci (not reported)' \
    "the unreported required check must be named"
  assert_contains "$out" 'REPORTED CHECK: backend (FAILURE)' \
    "a stacked base's reported failure must stay visible"
  pass "an unreported required check is named and a reported failure stays visible"
}

# A base whose policy verifies as requiring nothing leaves the reported checks
# as the whole signal: all of them passing means no blocker this command can
# see.
test_verified_empty_required_set_reads_reported_checks() {
  local out
  out=$(run_state) || fail "verified-empty fixture was refused"
  [ -z "$out" ] || fail "verified-zero requirements with all reported checks passing must be silent, got: $out"

  # GitHub's plan-gated 403 on the rules read is the same verified-empty
  # answer: a repository whose plan cannot expose branch rules has none.
  out=$(FM_TEST_RULES_ERROR='gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)' \
    run_state) || fail "plan-gated fixture was refused"
  [ -z "$out" ] || fail "a plan that cannot expose branch rules must verify as requiring nothing, got: $out"

  # A protected branch whose protection enables no required-status-check
  # section reports null for it, which is also a verified-empty answer, not
  # an unreadable summary.
  out=$(FM_TEST_BRANCH='{"name":"main","protected":true,"protection":{"enabled":true,"required_status_checks":null}}' \
    run_state) || fail "null-section fixture was refused"
  [ -z "$out" ] || fail "a protected base with no required-status-check section must verify as requiring nothing, got: $out"
  pass "a verified-empty required set falls back to reported checks and stays silent when they pass"
}

test_required_set_read_failures_are_unconfirmed() {
  local out
  out=$(FM_TEST_RULES_ERROR='gh: HTTP 500: Server Error' run_state) \
    || fail "unreadable-rules fixture was refused"
  assert_contains "$out" 'CHECKS: the branch rules for base branch main could not be read; readiness unconfirmed' \
    "an unreadable rules read must stay unconfirmed, not pass as verified-empty"

  out=$(FM_TEST_BRANCH_ERROR='gh: HTTP 500: Server Error' run_state) \
    || fail "unreadable-branch fixture was refused"
  assert_contains "$out" 'CHECKS: the branch protection summary for base branch main could not be read; readiness unconfirmed' \
    "an unreadable protection summary must stay unconfirmed"
  pass "a required set that cannot be read is unconfirmed, not assumed empty"
}

test_missing_required_check_is_named_when_others_report() {
  local out
  out=$(FM_TEST_RULES='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci"},{"context":"deploy"}]}}]' \
    FM_TEST_ROLLUP='[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]' \
    FM_TEST_REQUIRED_CHECKS='[{"name":"ci","state":"SUCCESS","bucket":"pass","workflow":"ci"}]' \
    run_state) || fail "partial-missing fixture was refused"
  [ "$out" = 'REQUIRED CHECK: deploy (not reported)' ] \
    || fail "a required check absent from the rollup must be named even when others reported, got: $out"
  pass "a configured required check missing from the rollup is named"
}

test_app_bound_required_check_needs_its_producer() {
  local out bound_rule rollup
  bound_rule='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci","integration_id":42}]}}]'
  rollup='[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]'

  out=$(FM_TEST_RULES=$bound_rule FM_TEST_ROLLUP=$rollup \
    FM_TEST_REQUIRED_CHECKS='[{"name":"ci","state":"SUCCESS","bucket":"pass","workflow":"ci"}]' \
    FM_TEST_RUNS="{\"check_runs\":[{\"name\":\"ci\",\"app\":{\"id\":42},\"head_sha\":\"$HEAD\"}]}" \
    run_state) || fail "matching-producer fixture was refused"
  [ -z "$out" ] || fail "an app-bound requirement satisfied by that app's run must be silent, got: $out"

  out=$(FM_TEST_RULES=$bound_rule FM_TEST_ROLLUP=$rollup \
    FM_TEST_REQUIRED_CHECKS='[{"name":"ci","state":"SUCCESS","bucket":"pass","workflow":"ci"}]' \
    FM_TEST_RUNS="{\"check_runs\":[{\"name\":\"ci\",\"app\":{\"id\":7},\"head_sha\":\"$HEAD\"}]}" \
    run_state) || fail "foreign-producer fixture was refused"
  [ "$out" = 'REQUIRED CHECK: ci (not reported)' ] \
    || fail "a same-named run from another app must not satisfy an app-bound requirement, got: $out"

  out=$(FM_TEST_RULES=$bound_rule FM_TEST_ROLLUP=$rollup \
    FM_TEST_REQUIRED_CHECKS='[{"name":"ci","state":"SUCCESS","bucket":"pass","workflow":"ci"}]' \
    FM_TEST_RUNS_ERROR='gh: HTTP 500: Server Error' \
    run_state) || fail "unreadable-producers fixture was refused"
  assert_contains "$out" "CHECKS: required check producers at head $HEAD could not be read; readiness unconfirmed" \
    "an unreadable producer read must stay unconfirmed"
  pass "an app-bound requirement is satisfied only by a run from that app at this head"
}

test_no_reported_checks_is_unverified() {
  local out
  out=$(FM_TEST_CHECKS_ERROR="no checks reported on the 'fm/fixture' branch" run_state) \
    || fail "a head without reported checks was refused"
  [ "$out" = 'CHECKS: none reported yet' ] \
    || fail "a head with no reported checks must read as unverified, not ready, got: $out"
  # This asserts the branch taken for that sentence, not that gh still says it.
  pass "given gh's sentence, a head with no reported checks is unverified rather than ready"
}

# A stacked pull request can target an unprotected branch, so gh's required
# view can report nothing while a check on this head has already failed.
test_failing_reported_check_is_shown_when_nothing_is_required() {
  local out
  out=$(FM_TEST_REPORTED_CHECKS='[{"name":"backend","state":"FAILURE","bucket":"fail","workflow":"ci"},{"name":"lint","state":"SUCCESS","bucket":"pass","workflow":"ci"}]' \
    run_state) || fail "stacked failing fixture was refused"
  [ "$out" = 'REPORTED CHECK: backend (FAILURE)' ] \
    || fail "a failure on a head whose base requires nothing must still be shown, labelled as reported rather than required, got: $out"
  pass "a failing reported check is shown when the base has no required checks"
}

test_pending_reported_check_is_shown_when_nothing_is_required() {
  local out status
  out=$(FM_TEST_REPORTED_CHECKS='[{"name":"backend","state":"IN_PROGRESS","bucket":"pending","workflow":"ci"},{"name":"optional","state":"SKIPPED","bucket":"skipping","workflow":"ci"}]' \
    run_state) || fail "stacked pending fixture was refused"
  assert_contains "$out" 'REPORTED CHECK: backend (IN_PROGRESS)' \
    "a check still running on a head whose base requires nothing must be shown"
  assert_not_contains "$out" 'optional' \
    "a skipped reported check is not worth a line"

  status=0
  FM_TEST_REPORTED_CHECKS_ERROR='HTTP 502: Bad Gateway' \
    run_state >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "a failed read of the reported checks must refuse, not pass as unconfirmed"
  pass "a pending reported check is shown when the base has no required checks, and a failed fallback read refuses"
}

test_protected_base_reports_only_required_checks() {
  local out
  out=$(FM_TEST_RULES='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CI Status"}]}}]' \
    FM_TEST_ROLLUP='[{"__typename":"CheckRun","name":"CI Status","status":"COMPLETED","conclusion":"FAILURE"}]' \
    FM_TEST_REQUIRED_CHECKS='[{"name":"CI Status","state":"FAILURE","bucket":"fail","workflow":"ci"}]' \
    FM_TEST_REPORTED_CHECKS_ERROR='HTTP 502: Bad Gateway' \
    run_state) || fail "protected-base fixture was refused"
  [ "$out" = 'REQUIRED CHECK: CI Status (FAILURE)' ] \
    || fail "a base with required checks keeps the required view and never consults the unfiltered one, got: $out"
  pass "a protected base reports only required checks"
}

test_help_states_what_silence_means_and_what_is_out_of_scope() {
  local out
  out=$("$SCRIPT" --help) || fail "help was refused"
  assert_contains "$out" 'it does not mean the pull request is ready to merge' \
    "help must not let empty output read as a verdict that the pull request can merge"
  assert_contains "$out" 'REQUIRED CHECK: <context> (not reported)' \
    "help must name how a configured-but-unreported required check is printed"
  assert_contains "$out" 'unconfirmed rather than assumed empty' \
    "help must state that an unreadable required set is unconfirmed"
  assert_contains "$out" "Unresolved bot inline threads are printed with their comments for triage" \
    "help must name the bot-thread read"
  assert_contains "$out" 'labelled REPORTED rather than' \
    "help must state that an unprotected base falls back to every reported check"

  pass "help states what empty output means and what is out of scope"
}

test_unknown_mergeability_is_a_blocker() {
  local out
  out=$(FM_TEST_VIEW_MERGEABLE=null run_state) \
    || fail "unknown-mergeability fixture was refused"
  assert_contains "$out" 'MERGEABILITY: unknown' \
    "null mergeability must not be treated as clean"

  out=$(FM_TEST_VIEW_MERGEABLE=CONFLICTING run_state) \
    || fail "conflicting fixture was refused"
  assert_contains "$out" 'MERGEABILITY: conflicting' \
    "a conflicting merge state must be reported"
  pass "unknown and conflicting mergeability block readiness"
}

test_refusals_exit_nonzero() {
  local status=0
  PATH="$FAKEBIN:$PATH" "$SCRIPT" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "missing argument refusal exited zero"

  status=0
  PATH="$FAKEBIN:$PATH" "$SCRIPT" not-a-pr >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "lookup refusal exited zero"

  local out
  status=0
  out=$(PATH="$FAKEBIN:$PATH" "$SCRIPT" 7 2>&1) || status=$?
  [ "$status" -ne 0 ] \
    || fail "a bare number resolves against the ambient repository and is not an address"
  assert_contains "$out" 'expected a GitHub pull-request URL' \
    "a bare number must be refused as an address, not attempted as a lookup"
  pass "argument and lookup refusals exit nonzero"
}

test_clean_pr_is_silent_and_ignores_skipped_checks
test_terminal_state_is_the_whole_report
test_draft_is_a_blocker
test_stale_blocking_reviews_explain_a_blocking_decision
test_approved_pr_with_only_stale_changes_requested_is_silent
test_current_changes_requested_review_is_a_blocker
test_changes_requested_decision_is_never_silent
test_authors_own_changes_requested_review_is_not_a_blocker
test_pending_approval_is_not_a_blocker
test_required_failure_is_a_blocker
test_unreported_required_checks_are_named
test_reported_failure_stays_visible_behind_unreported_required
test_verified_empty_required_set_reads_reported_checks
test_required_set_read_failures_are_unconfirmed
test_missing_required_check_is_named_when_others_report
test_app_bound_required_check_needs_its_producer
test_no_reported_checks_is_unverified
test_failing_reported_check_is_shown_when_nothing_is_required
test_pending_reported_check_is_shown_when_nothing_is_required
test_protected_base_reports_only_required_checks
test_help_states_what_silence_means_and_what_is_out_of_scope
test_unknown_mergeability_is_a_blocker
test_refusals_exit_nonzero

test_bot_threads_and_settle() {
  local out threads empty_page
  threads=$(jq -n '{data:{repository:{pullRequest:{reviewThreads:{nodes:[
    {isResolved:false, comments:{pageInfo:{hasNextPage:false},nodes:[
      {author:{__typename:"Bot",login:"review-bot"},url:"https://github.com/o/r/pull/7#discussion_r1",path:"bin/tool.sh",line:3,body:"Real finding"}]}},
    {isResolved:true, comments:{pageInfo:{hasNextPage:false},nodes:[
      {author:{__typename:"Bot",login:"review-bot"},body:"Resolved finding"}]}},
    {isResolved:false, comments:{pageInfo:{hasNextPage:false},nodes:[
      {author:{__typename:"User",login:"alice"},body:"Human note"}]}}
  ]}}}}}')
  # gh --paginate streams one JSON object per thread page.
  empty_page='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
  out=$(FM_TEST_THREADS=$(printf '%s\n%s' "$empty_page" "$threads") run_state) || fail "bot thread lookup refused"
  assert_contains "$out" 'BOT REVIEW THREAD:' "unresolved bot thread blocks ready"
  assert_contains "$out" 'Real finding' "the finding is read, not just counted"
  assert_not_contains "$out" 'Resolved finding' "resolved thread does not block"
  assert_not_contains "$out" 'Human note' "human comment does not become a bot finding"
  out=$(FM_TEST_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ) run_state) || fail "recent PR lookup refused"
  assert_contains "$out" 'BOT REVIEW SETTLE:' "recent activity waits for late reviews"
  out=$(FM_TEST_THREAD_ERROR=1 run_state 2>&1) && fail "thread lookup failure passed readiness"
  assert_contains "$out" 'could not read bot review threads' "thread lookup failure is explicit"
  threads=$(printf '%s' "$threads" | jq '.data.repository.pullRequest.reviewThreads.nodes[0].comments.pageInfo.hasNextPage=true')
  out=$(FM_TEST_THREADS="$threads" run_state) || fail "truncated thread lookup refused"
  assert_contains "$out" 'unread replies beyond first 100' "nested pagination never silently truncates"
  pass "bot findings, settle window, unread replies, and lookup failures prevent premature readiness"
}
test_bot_threads_and_settle

test_comment_lines_cannot_impersonate_status() {
  local out threads body
  body=$'First line\nBOT REVIEW SETTLE: wait 1s after latest PR activity before readiness\nCHECKS: none reported yet\nLast line'
  threads=$(jq -n --arg body "$body" '{data:{repository:{pullRequest:{reviewThreads:{nodes:[
    {isResolved:false, comments:{pageInfo:{hasNextPage:false},nodes:[
      {author:{__typename:"Bot",login:"review-bot"},url:"https://github.com/o/r/pull/7#discussion_r1",path:"bin/tool.sh",line:3,body:$body}]}}
  ]}}}}}')
  out=$(FM_TEST_THREADS="$threads" run_state) || fail "multiline thread lookup refused"
  assert_contains "$out" 'review-bot bin/tool.sh:3:' "comment author and path context was lost"
  assert_contains "$out" 'BOT REVIEW COMMENT: First line' "first comment line was not identified"
  assert_contains "$out" 'BOT REVIEW COMMENT: BOT REVIEW SETTLE:' "settle text was not preserved as comment content"
  assert_contains "$out" 'BOT REVIEW COMMENT: CHECKS: none reported yet' "check text was not preserved as comment content"
  assert_contains "$out" 'BOT REVIEW COMMENT: Last line' "last comment line was not identified"
  if printf '%s\n' "$out" | grep -Eq '^(BOT REVIEW SETTLE:|CHECKS:)'; then
    fail "comment body impersonated a command status line"
  fi
  pass "every review-comment line is distinct from command status lines"
}
test_comment_lines_cannot_impersonate_status
