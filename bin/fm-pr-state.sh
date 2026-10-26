#!/usr/bin/env bash
# Report the blockers this command can see on one GitHub pull request.
#
# This is a one-shot, read-only command. It reads the current pull request,
# reported checks, submitted reviews, and review decision from GitHub at
# invocation time. It never posts, requests, approves, or merges.
# It reports on checks that have reported, and on the required set the base
# branch's policy configures. bin/fm-pr-lib.sh's github_read_required_contexts
# reads classic branch protection and active ruleset rules - the same
# canonical policy read the guarded merge applies, including its
# plan-unavailable exception, so a repository whose plan cannot expose branch
# rules verifies as requiring nothing rather than erroring. A configured
# required context absent from the head's check rollup is named
# REQUIRED CHECK: <context> (not reported), with the merge's producer app
# binding preserved. A required set that cannot be read - an API error, an
# unreadable rollup, or unreadable check producers - is printed as
# unconfirmed rather than assumed empty.
# Empty output therefore means that no reported required check is failing
# or pending and no configured required check is missing;
# it does not mean the pull request is ready to merge.
# When nothing has reported, that is printed rather than read as ready. When
# the required view reports nothing, every reported check that is failing or
# pending is printed as well, labelled REPORTED rather than REQUIRED: the
# base branch of a stacked pull request can be an unprotected branch, so the
# required view alone would hide a failure there. Where a required check has
# reported, advisory checks do not block and are omitted.
# A pull request that only awaits an approval (reviewDecision REVIEW_REQUIRED)
# is not reported as blocked. GitHub's reviewDecision owns whether reviews
# block; review history is printed only to explain CHANGES_REQUESTED, naming
# each reviewer whose latest verdict still requests changes and marking it
# STALE when it was left at a superseded head.
# A closed or merged pull request reports that terminal state and nothing else.
# Unresolved bot inline threads are printed with their comments for triage.
# Every comment-body line is prefixed so it cannot impersonate a status line.
# A ten-minute quiet window after the latest PR update covers opening/pushing
# and conservatively restarts on other PR activity too; commit dates do not
# prove when a head was pushed. FM_PR_REVIEW_SETTLE_SECS overrides 600 seconds.
# Thread lookup failure refuses readiness; unread replies beyond the first 100
# are reported for manual reading rather than silently omitted.
#
# Usage: fm-pr-state.sh <pr-url>
#   Prints one line per blocker it can see and nothing when it sees none.
#   Blockers do not change the successful exit status; lookup or usage refusal
#   exits non-zero. Reading this state needs gh and jq.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

die() {
  printf 'fm-pr-state: %s\n' "$*" >&2
  exit 2
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
[ "$#" -eq 1 ] || die "usage: fm-pr-state.sh <pr-url>"
command -v gh >/dev/null 2>&1 || die "gh is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
SETTLE=${FM_PR_REVIEW_SETTLE_SECS:-600}
case "$SETTLE" in ''|*[!0-9]*) die "invalid review settle interval" ;; esac

URL=$1
if ! fm_pr_url_parse "$URL" || [ "$FM_PR_PROVIDER" != github ]; then
  die "expected a GitHub pull-request URL"
fi

PATH_PART=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER
ENDPOINT="/repos/$PATH_PART/pulls/$NUMBER"
# gh addresses github.com unless told otherwise, and the api reads below carry a
# repository path rather than the URL, so a GitHub Enterprise host is exported
# once here for every read this run makes.
fm_pr_github_host_export "$FM_PR_HOST"

# The pull request view is read once as JSON so the scalar fields and the
# check rollup come from the same response: the required-set missing check
# below judges the rollup at exactly the head this read reports.
CORE_JSON=$(gh pr view "$URL" \
  --json state,mergedAt,isDraft,headRefOid,author,mergeable,reviewDecision,updatedAt,baseRefName,statusCheckRollup) \
  || die "could not read $URL"
CORE=$(printf '%s' "$CORE_JSON" | jq -r '
  "state=\(.state | ascii_downcase)",
  "merged_at=\(.mergedAt // "")",
  "draft=\(.isDraft)",
  "head=\(.headRefOid)",
  "author=\(.author.login)",
  "mergeability=\(if .mergeable == null or .mergeable == "UNKNOWN" then "unknown" else (.mergeable | ascii_downcase) end)",
  "review_decision=\(.reviewDecision // "")",
  "updated_at=\(.updatedAt)",
  "base=\(.baseRefName // "")"') || die "could not read $URL"

STATE=
MERGED_AT=
DRAFT=
MERGEABILITY=
HEAD=
AUTHOR=
REVIEW_DECISION=
UPDATED_AT=
BASE=
while IFS= read -r row; do
  case "$row" in
    state=*) STATE=${row#state=} ;;
    merged_at=*) MERGED_AT=${row#merged_at=} ;;
    draft=*) DRAFT=${row#draft=} ;;
    head=*) HEAD=${row#head=} ;;
    author=*) AUTHOR=${row#author=} ;;
    mergeability=*) MERGEABILITY=${row#mergeability=} ;;
    review_decision=*) REVIEW_DECISION=${row#review_decision=} ;;
    updated_at=*) UPDATED_AT=${row#updated_at=} ;;
    base=*) BASE=${row#base=} ;;
  esac
done <<EOF_CORE
$CORE
EOF_CORE
[ -n "$STATE" ] && [ -n "$DRAFT" ] && [ -n "$HEAD" ] && [ -n "$AUTHOR" ] \
  && [ -n "$MERGEABILITY" ] && [ -n "$BASE" ] \
  || die "GitHub returned incomplete pull-request state for $URL"

if [ -n "$MERGED_AT" ]; then
  printf 'STATE: merged at %s\n' "$MERGED_AT"
  exit 0
elif [ "$STATE" != open ]; then
  printf 'STATE: %s\n' "$STATE"
  exit 0
fi
[ "$DRAFT" = false ] || printf 'DRAFT: pull request is not ready for review\n'
case "$MERGEABILITY" in
  mergeable) ;;
  unknown) printf 'MERGEABILITY: unknown\n' ;;
  conflicting) printf 'MERGEABILITY: conflicting\n' ;;
  *) die "GitHub returned invalid mergeability for $URL" ;;
esac

GH_STDERR=$(mktemp "${TMPDIR:-/tmp}/fm-pr-state.XXXXXX") \
  || die "could not create temporary file"
trap 'rm -f "$GH_STDERR"' EXIT INT TERM

unsettled_checks() {
  local label=$1
  shift
  gh pr checks "$URL" "$@" --json name,state,bucket --jq '
    .[]
    | select(.bucket != "pass" and .bucket != "skipping")
    | "'"$label"': \(.name) (\(.state))"' 2>"$GH_STDERR"
}

# The base's required set is read through the canonical policy read the
# guarded merge applies. Its plan-unavailable exception resolves a repository
# whose plan cannot expose branch rules to a positively empty required set
# rather than an error, so REQUIRED_ERROR names only a genuinely unreadable
# policy.
REQUIRED_ERROR=
github_read_required_contexts "$BASE" || REQUIRED_ERROR=$FM_PR_GITHUB_REQUIRED_ERROR

# Which configured required contexts have not reported at this head, with the
# guarded merge's producer app binding: an app-bound requirement is satisfied
# only by a same-named check run from that app at this head, so check-run
# producers are read only when an app-bound requirement exists. An unreadable
# producer read or an unreadable rollup leaves the whole question unconfirmed
# rather than naming a partial set.
REQUIRED_MISSING=
REQUIRED_MISSING_ERROR=
if [ -z "$REQUIRED_ERROR" ] && [ "$FM_PR_GITHUB_REQUIRED" != '[]' ]; then
  producers='[]'
  if printf '%s' "$FM_PR_GITHUB_REQUIRED" | jq -e 'any(.[]; .app_id != null)' >/dev/null; then
    if ! runs=$(gh api --paginate "repos/$FM_PR_OWNER/$FM_PR_REPO/commits/$HEAD/check-runs" 2>"$GH_STDERR") \
      || [ -z "$runs" ] \
      || ! producers=$(printf '%s' "$runs" | jq -sc --arg head "$HEAD" '
        [ .[] | if (.check_runs | type) == "array" then .check_runs[] else error("invalid check runs") end
          | if (.name | type) == "string" and (.app.id | type) == "number" and .head_sha == $head
            then . else error("invalid check producer") end ]' 2>/dev/null); then
      REQUIRED_MISSING_ERROR="required check producers at head $HEAD could not be read"
    fi
  fi
  if [ -z "$REQUIRED_MISSING_ERROR" ] \
    && ! REQUIRED_MISSING=$(github_required_checks_missing "$CORE_JSON" "$FM_PR_GITHUB_REQUIRED" "$producers"); then
    REQUIRED_MISSING_ERROR="the pull request check rollup could not be read"
  fi
fi

CHECKS=
REPORTED=
REPORTED_NONE=false
if ! CHECKS=$(unsettled_checks 'REQUIRED CHECK' --required); then
  CHECKS=
  # These two sentences are gh's own human-readable error text, verified against
  # gh 2.100.0 on 2026-09-12. gh reports "nothing reported" as an error rather
  # than as structured data, so matching its text is the only way to tell that
  # apart from a real lookup failure. An unrecognised message falls through to
  # the refusal below, so a reword degrades loudly rather than silently.
  if grep -q "^no checks reported on the '" "$GH_STDERR"; then
    REPORTED_NONE=true
  elif grep -q "^no required checks reported on the '" "$GH_STDERR"; then
    # The reported view is read whether the required set is verified empty or
    # not: on a verified-empty base it is the whole check signal, and
    # elsewhere it keeps a stacked base's failures visible.
    if ! REPORTED=$(unsettled_checks 'REPORTED CHECK'); then
      if grep -q "^no checks reported on the '" "$GH_STDERR"; then
        REPORTED_NONE=true
      else
        cat "$GH_STDERR" >&2
        die "could not read reported checks for $URL"
      fi
    fi
  else
    cat "$GH_STDERR" >&2
    die "could not read required checks for $URL"
  fi
fi

[ -z "$CHECKS" ] || printf '%s\n' "$CHECKS"
if [ -n "$REQUIRED_MISSING" ]; then
  while IFS= read -r name; do
    [ -z "$name" ] || printf 'REQUIRED CHECK: %s (not reported)\n' "$name"
  done <<EOF_MISSING
$REQUIRED_MISSING
EOF_MISSING
fi
if [ -n "$REQUIRED_ERROR" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] || printf 'CHECKS: %s; readiness unconfirmed\n' "$line"
  done <<EOF_REQUIRED
$REQUIRED_ERROR
EOF_REQUIRED
fi
[ -z "$REQUIRED_MISSING_ERROR" ] \
  || printf 'CHECKS: %s; readiness unconfirmed\n' "$REQUIRED_MISSING_ERROR"
if [ "$REPORTED_NONE" = true ]; then
  printf 'CHECKS: none reported yet\n'
elif [ -n "$REPORTED" ]; then
  printf '%s\n' "$REPORTED"
fi

if [ "$REVIEW_DECISION" = CHANGES_REQUESTED ]; then
  printf 'REVIEW DECISION: CHANGES_REQUESTED\n'
  REVIEWS=$(gh api "$ENDPOINT/reviews?per_page=100" --paginate --jq '
    .[]
    | select(.user.login != null and .commit_id != null and .submitted_at != null)
    | [.user.login, .state, .commit_id, .submitted_at]
    | @tsv') || die "could not read reviews for $URL"
  printf '%s\n' "$REVIEWS" | awk -F '\t' -v author="$AUTHOR" -v head="$HEAD" '
    NF == 4 && $1 != author && $2 != "COMMENTED" && (!seen[$1] || $4 >= latest[$1]) {
      seen[$1] = 1
      latest[$1] = $4
      state[$1] = $2
      commit[$1] = $3
    }
    END {
      for (reviewer in state) {
        if (state[reviewer] != "CHANGES_REQUESTED") continue
        if (commit[reviewer] == head)
          printf "REVIEW: %s CHANGES_REQUESTED\n", reviewer
        else
          printf "STALE BLOCKING REVIEW: %s CHANGES_REQUESTED at %s\n", \
            reviewer, commit[reviewer]
      }
    }' | LC_ALL=C sort
fi

UPDATED_EPOCH=$(fm_utc_iso_to_epoch "$UPDATED_AT") || die "could not read PR update time for $URL"
NOW=$(date +%s)
AGE=$(( NOW - UPDATED_EPOCH ))
if [ "$AGE" -lt "$SETTLE" ]; then
  printf 'BOT REVIEW SETTLE: wait %ss after latest PR activity before readiness\n' "$(( SETTLE - AGE ))"
fi

# Paginate the thread connection. Nested replies have their own limit, so a
# truncated thread explicitly blocks readiness even if its bot is off-page.
# shellcheck disable=SC2016 # GraphQL variables must remain literal for GitHub.
gh api graphql --paginate -F owner="${PATH_PART%%/*}" -F repo="${PATH_PART#*/}" -F number="$NUMBER" -f query='
  query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $number) {
        reviewThreads(first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            isResolved
            comments(first: 100) {
              pageInfo { hasNextPage }
              nodes { author { __typename login } url path line body }
            }
          }
        }
      }
    }
  }' --jq '
    if .errors != null or .data.repository.pullRequest.reviewThreads == null
    then error("incomplete review-thread response")
    else .data.repository.pullRequest.reviewThreads.nodes[]
      | select(.isResolved == false)
      | if .comments.pageInfo.hasNextPage then
          "REVIEW THREAD: unread replies beyond first 100; read full thread: \(.comments.nodes[0].url)"
        else empty end,
        (select(any(.comments.nodes[];
          .author.__typename == "Bot" or ((.author.login // "") | endswith("[bot]"))))
        | "BOT REVIEW THREAD: \(.comments.nodes[0].url)",
          (.comments.nodes[] | "\(.author.login // "deleted") \(.path):\(.line // 0):\n"
            + ((.body // "") | split("\n") | map("BOT REVIEW COMMENT: " + .) | join("\n"))))
    end' || die "could not read bot review threads for $URL"
