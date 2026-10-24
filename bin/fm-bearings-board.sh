#!/usr/bin/env bash
# fm-bearings-board.sh - build the /ops lavish fleet board.
#
# The board is the captain-facing surface of /ops lavish: the shipped
# template (.agents/skills/bearings/assets/board-template.html) plus one
# injected fm-bearings-board.v1 JSON payload. This script owns the mechanics so
# the invoking agent's per-run work stays "compose the JSON, run build" - the
# agent never authors board UI at invocation time.
#
# Usage:
#   fm-bearings-board.sh build <data.json> [--lavish <off|view|answers>]
#   fm-bearings-board.sh compose <dest.json>
#   fm-bearings-board.sh refresh
#   fm-bearings-board.sh path
#
# compose    Write a deterministic fm-bearings-board.v1 payload built from the
#            canonical snapshot (bin/fm-bearings-snapshot.sh --json): the fleet
#            rows, one card per open captain call, and nothing an agent would
#            have to judge. A call's card is a fallback carrying its durable
#            summary as the title, no options, freeform answers only, and the
#            snapshot's declared hold close mode, so answering a captain-gated
#            work item releases its hold instead of closing the task,
#            unless the durable store already holds that call's card: a stored
#            merge.<task> card replaces the fallback here, and build's
#            store-first merge supplies the raise-time record's real options
#            whenever one was written.
#            A Charted Next gate is composed dispatchable=false and only the
#            parenthesized sentinel ids are classified as warnings, because
#            the snapshot proves neither a cleared blocker-and-time gate nor a
#            richer kind, and prose is never read to guess either.
# refresh    compose to a temporary path, then build it. This is the scheduled
#            path that keeps the board current with no agent turn: a cron or
#            timer pass runs `refresh` and Lavish's live reload redraws every
#            open review, phone included. It never invents the richer copy or
#            the dispatch picker a /bearings lavish composition owns; re-run
#            that composition when the board needs them.
#
# build      Validate the payload, drop the Captain's Call cards whose subject
#            already landed, and inject the effective payload into a fresh copy
#            of the shipped template at the stable board path. What happens
#            next follows the effective Lavish mode that bin/fm-lavish-lib.sh
#            resolves from config/lavish, or from --lavish, the per-request
#            override that wins over the home toggle for this one board:
#
#            off      The static read-only board, exactly as without Lavish:
#                     the captain opens the HTML file and answers in chat.
#            view     The same read-only board, opened in Lavish so it can be
#                     viewed and annotated through a browser, including over
#                     an ssh port forward (docs/lavish.md). Its source is armed
#                     unbound, so annotations reach firstmate as ordinary
#                     review feedback and never feed the keyed-answer intake.
#            answers  view, plus answer controls and the standard reconcile
#                     choice on every decision card whose call this home's own
#                     backlog holds open (bin/fm-captain-hold.sh open); a
#                     secondmate's call, or one whose state cannot be read,
#                     stays display-only and is answered in chat. The source is bound to the
#                     keyed-answer intake (bin/fm-captain-hold.sh bind) BEFORE
#                     it is armed (bin/fm-procevent-lavish.sh arm), and the
#                     board is served without its answer controls until both
#                     succeed, so it can never take an answer that has nowhere
#                     to go; a failure leaves that read-only page. Merge and
#                     credential cards and Charted Next stay display-only;
#                     those answers stay in chat.
#
#            In view and answers, a failure to bind or arm ends the board's
#            Lavish session before the build fails, so the page never takes
#            feedback while nothing listens; a later build reopens it.
#
#            A wanted mode whose pinned lavish-axi is unavailable resolves to
#            off and says why. A mode below answers first unbinds an earlier
#            answers build's source, refusing the build when it cannot, so a
#            still-open answers page can no longer change a held task; an off
#            build then retires the board's listener, refusing when it cannot.
#            Output, in order (the first two only below answers, before the
#            new board is published):
#              unbound: <source-id>         (an earlier answer binding removed)
#              retired: <source-id>         (off: the board listener stopped)
#              board: <path>
#              lavish: off (<reason>)       (a wanted mode fell back to off)
#              session: live | reopened     (view and answers)
#              served: <path>
#              url: <session URL>           (view and answers)
#              open: <path or session URL>
#              bound: <source-id>           (answers)
#              armed: <source-id>           (view and answers, first registration)
#              already-armed: <source-id>   (view and answers, registration present)
#              still-listening: <source-id> (view and answers, an earlier listener holds it)
#              answers: open                (answers, controls now published)
#            Every dropped card is named on stderr as a `dropped-landed-card:`
#            line, so a rebuild states what it removed instead of quietly
#            shrinking Captain's Call.
# path       Print the stable board path for this home.
#
# A LIVE SESSION IS PROVED, NEVER ASSUMED. `lavish-axi <file>` exits 0 even
# when it refuses to reopen a session the captain ended from the browser,
# reporting `status: user-ended` with the same session id. build reads the
# status it reports and reopens such a session once - the captain asked for
# this board - and refuses rather than serving or arming one that stays ended.
# The session listing is not liveness evidence: it lists a session `open` even
# while the server is stopped, and re-running `lavish-axi <file>` is what
# restarts the server. lavish-axi's own instructions are not echoed, because
# they tell an agent to poll, which the armed source owns.
#
# CAPTAIN'S CALL HYGIENE. A decision card is dropped when its work item, PR, or
# structured artifact/version subject appears among the payload's own landed
# rows, or when `bin/fm-captain-hold.sh open` reports the task is no longer an
# open captain call. A newer published version also supersedes a version card.
# A task whose state cannot be established is kept, because a call wrongly
# hidden is worse than a card wrongly shown. Cleanup is therefore a normal
# rebuild effect rather than a committed migration or direct state mutation.
#
# THE RECONCILE CHOICE. Every decision card carries the standard `reconcile`
# option, injected here so the guarantee does not depend on the composer's
# memory, and the payload validator reserves that value across every card type.
# The validator's reservation scope must equal the adapter's reconcile
# classification scope, which is all card types because the captured payload
# carries no card type. Its meaning, and the reason it can never reach the
# keyed-answer intake as a blind close, are owned by
# docs/captain-hold-lifecycle.md.
#
# DURABLE DECISION CARDS. `build` also writes every surviving decision card to
# state/decision-cards/<task>.json (schema fm-decision-card.v1), because the
# board page is rebuilt from scratch and a card absent from the newest payload
# would otherwise be lost to later readers such as the captain's deck. The stored
# record is the EFFECTIVE card, reconcile choice included. A record whose task
# is definitely no longer an open captain call is pruned; an absent or
# unestablished task keeps its record, because a card wrongly hidden is worse
# than one wrongly shown.
#
# The store has a second writer: bin/fm-captain-hold.sh writes the same record
# when a call is RAISED with structured options, so the Deck shows the options,
# context, and recommendation the asking agent already had instead of waiting
# for a composition to re-derive them. The store is therefore a source for a
# key as well as a sink, and its precedence rule is STORE-FIRST: for a key the
# payload also carries, the stored record is the effective card, because it was
# authored where the question was raised and can be newer than the payload's
# snapshot; the payload's copy is used only for a key the store does not hold.
# Every merged record is re-validated in its stored form and a malformed record
# is reported and left out rather than failing the build, so a damaged file can
# never take the board down.
#
# Validation is fail-closed: the payload must be valid JSON with
# schema=fm-bearings-board.v1 and every renderer-consumed field must satisfy
# the fm-bearings-board.v1 types and item invariants below. Every fleet row and
# Captain's Call item explicitly carries `repo`; the composer fills it from the
# snapshot and task records wherever known, and uses null or an empty string
# only as the deliberate genuinely-no-repo marker. In that exceptional case
# the template may display the routing id. Anything else refuses before the
# existing board is touched.
#
# Every Underway row likewise carries a non-empty `name`: the durable task name
# when known, otherwise its durable identifier.
# A Charted Next row MAY carry `filed`, the durable filed date (YYYY-MM-DD, or
# that date with a UTC timestamp) the template orders the section by, newest
# first; a row with no comparable date keeps its payload order after every dated
# row. Anything else in that field refuses rather than sorting on garbage.
#
# The board path is stable - $FM_HOME/.lavish/bearings-board.html - so a
# re-invocation rebuilds the same file in place, which keeps the same Lavish
# session URL and the same canonical process-event source id.
# Injection escapes every `<` in the compact JSON as the \u003c string escape,
# so a payload string containing "</script>" can never terminate the data block
# early.
#
# FM_BEARINGS_BOARD_TEMPLATE overrides the shipped template path (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-decision-card-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-decision-card-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

TEMPLATE="${FM_BEARINGS_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/board-template.html}"
SNAPSHOT_BIN="${FM_BEARINGS_BOARD_SNAPSHOT:-$SCRIPT_DIR/fm-bearings-snapshot.sh}"
PLACEHOLDER='__FM_BEARINGS_BOARD_DATA__'
BOARD_SCHEMA=fm-bearings-board.v1

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-bearings-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/bearings-board.html\n' "$FM_HOME"; }

# shellcheck source=bin/fm-lavish-lib.sh
. "$SCRIPT_DIR/fm-lavish-lib.sh"
# --- deterministic refresh ---------------------------------------------------
# The floor under the agent composition: rows the snapshot proves, a fallback
# card per open call, and the durable store merged in by build. Nothing here
# reads prose to classify anything, and nothing here invents ranking judgment.
compose_payload() {  # <dest.json>
  local dest=$1 snapshot tmp file key extra='[]' card=''
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -x "$SNAPSHOT_BIN" ] || fail "the bearings snapshot is missing: $SNAPSHOT_BIN"
  snapshot=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-snapshot.XXXXXX") \
    || fail "cannot stage the snapshot"
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-composed.XXXXXX") \
    || { rm -f -- "$snapshot"; fail "cannot stage the composed payload"; }
  if ! "$SNAPSHOT_BIN" --json > "$snapshot" 2>/dev/null; then
    rm -f -- "$snapshot" "$tmp"
    fail "the bearings snapshot failed: $SNAPSHOT_BIN --json"
  fi
  if ! jq -e '.schema == "fm-bearings.v1"' "$snapshot" >/dev/null 2>&1; then
    rm -f -- "$snapshot" "$tmp"
    fail "the bearings snapshot is not fm-bearings.v1: $SNAPSHOT_BIN"
  fi
  if ! jq --slurpfile fleet "$snapshot" '
    def artifact_url: (.artifact // "") | select(test("^https://"));
    def artifact_repo:
      (.artifact // "")
      | if test("^https://github\\.com/[^/]+/[^/]+")
        then capture("^https://github\\.com/[^/]+/(?<repo>[^/]+)").repo
        else null end;
    def home_repo: if (.owner // "") == "(main)" then null else .owner end;
    $fleet[0] as $s
    | {
        schema: "fm-bearings-board.v1",
        home: $s.home,
        generated: $s.generated,
        prs_live: false,
        captains_call: [
          $s.decisions_open[]?
          | {key: (.key // .id), type: "decision", repo: null,
             title: (.summary // .id), options: [], allow_freeform: true,
             synthesized: true}
            + (if (.owner // "") == "" then {} else {owner: .owner} end)
            + (if .close == null then {} else {close: .close} end)
        ],
        underway: [
          $s.in_flight[]?
          | {id: .id, state: .state,
             doing: (if (.doing // "") == "" then "-" else .doing end),
             kind: .kind, name: .name, repo: (.repo // home_repo)}
        ],
        landed: [
          $s.landed[]?
          | {id: .id, what: .what, owner: .owner, repo: artifact_repo}
          + (if (artifact_url // "") == "" then {} else {pr_url: artifact_url} end)
        ],
        charted: [
          $s.gates[]?
          | {id: (.id | if test("^\\(") then gsub("[^A-Za-z0-9._-]"; "") else . end),
             title: .title, reason: (.reason // ""), repo: home_repo,
             dispatchable: false,
             kind: (if (.id | test("^\\(")) then "warning" else "queued" end)}
          + (if (.filed // null) == null then {} else {filed: .filed} end)
        ],
        charted_more: ([$s.omitted[]?
          | select(.surface | test("^gates showing [0-9]+ of [0-9]+$"))
          | .surface
          | capture("^gates showing (?<shown>[0-9]+) of (?<total>[0-9]+)$")
          | ((.total | tonumber) - (.shown | tonumber))] | add // 0),
        charted_warning_more: 0
      }' "$snapshot" > "$tmp"; then
    rm -f -- "$snapshot" "$tmp"
    fail "cannot compose the board payload from the snapshot"
  fi
  rm -f -- "$snapshot"
  # The durable store is a SOURCE for a card the composed payload cannot author
  # itself: an agent-authored `merge.<task>` card for a call the snapshot still
  # lists as live. A stored card for a blocked, dated, reconciling, or aged hold
  # must stay out of Captain's Call - those holds belong to the disclosed
  # Charted Next gates, and the durable record remains in the store until the
  # call is live again. Every merged record is re-validated in its stored form; a
  # malformed one is named on stderr and skipped rather than failing the whole
  # refresh. The injected reconcile choice is stripped before appending because
  # the authored contract reserves it and build injects exactly one itself.
  if [ -d "$DECISION_CARDS_DIR" ] && [ ! -L "$DECISION_CARDS_DIR" ]; then
    for file in "$DECISION_CARDS_DIR"/*.json; do
      [ -f "$file" ] && [ ! -L "$file" ] || continue
      key=$(basename "$file" .json)
      case "$key" in merge.*) ;; *) continue ;; esac
      jq -e --arg key "$key" '[.captains_call[]?.key] | index($key) != null' "$tmp" >/dev/null 2>&1 && continue
      jq -e --arg task "${key#merge.}" '
        [.captains_call[]? | select(.key == $task and (.owner // "(main)") == "(main)")]
        | length > 0' "$tmp" >/dev/null 2>&1 || continue
      if ! read_store_card "$file"; then
        printf 'ignored-store-card: %s (%s)\n' "$key" "$STORE_CARD_REASONS" >&2
        continue
      fi
      card=$STORE_CARD
      if [ "$(jq -r '.card.key? // empty' "$file" 2>/dev/null)" != "$key" ]; then
        printf 'ignored-store-card: %s (record key does not match its file name)\n' "$key" >&2
        continue
      fi
      card=$(printf '%s' "$card" | jq -c '
        .options = [(.options // [])[] | select(.value != "reconcile")]') || continue
      extra=$(printf '%s' "$extra" | jq -c --argjson card "$card" '. + [$card]') || continue
    done
  fi
  if [ "$extra" != '[]' ]; then
    if ! jq --argjson extra "$extra" '
      ($extra | map(.key | sub("^merge\\."; ""))) as $replaced
      | .captains_call = ([.captains_call[]
          | . as $card
          | select(($replaced | index($card.key)) == null
              or ((.owner // "(main)") != "(main)"))] + $extra)' \
        "$tmp" > "$tmp.next"; then
      rm -f -- "$tmp" "$tmp.next"
      fail "cannot add the durable decision cards to the composed payload"
    fi
    mv -f -- "$tmp.next" "$tmp" || { rm -f -- "$tmp" "$tmp.next"; fail "cannot publish the composed payload"; }
  fi
  if ! validate_payload "$tmp"; then
    rm -f -- "$tmp"
    fail "the composed payload does not satisfy $BOARD_SCHEMA"
  fi
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; fail "cannot write the composed payload: $dest"; }
}

command_compose() {  # <dest.json>
  local dest=${1-}
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  [ -n "$dest" ] || { usage >&2; exit 2; }
  compose_payload "$dest"
  printf 'composed: %s\n' "$dest"
}

command_refresh() {
  local data
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  data=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-refresh.XXXXXX") \
    || fail "cannot stage the refreshed payload"
  # A fail inside compose or build exits the process before the rm lines
  # below run; the EXIT trap owns the staged payload until it is cleared.
  REFRESH_DATA_TMP=$data
  if ! compose_payload "$data"; then
    rm -f -- "$data"
    REFRESH_DATA_TMP=
    fail "cannot refresh the board from the snapshot"
  fi
  if ! command_build "$data"; then
    rm -f -- "$data"
    REFRESH_DATA_TMP=
    fail "cannot build the refreshed board"
  fi
  rm -f -- "$data"
  REFRESH_DATA_TMP=
}

validate_payload() {  # <data.json>
  # The authored-card contract is shared with the raise-time writer
  # (bin/fm-captain-hold.sh) and owned once by bin/fm-decision-card-lib.sh, so
  # the payload validator and the CLI can never disagree about a valid card.
  jq -e --arg schema "$BOARD_SCHEMA" "$FM_DECISION_CARD_JQ_DEFS"'
    def name_marker: has("name") and (.name | nonempty_string);
    def valid_filed:
      . as $filed
      | type == "string"
      and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$")
      and (if test("T")
        then try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $filed) catch false
        else try (((. + "T00:00:00Z") | fromdateiso8601 | strftime("%Y-%m-%d")) == $filed) catch false
        end);
    def optional_filed:
      (has("filed") | not) or (.filed == null) or (.filed | valid_filed);
    # slug, repo_marker, optional_*, version, optional_subject, and call_item
    # are spliced in from bin/fm-decision-card-lib.sh above.
    def underway_item:
      type == "object" and repo_marker and name_marker and (.id | nonempty_string)
      and (.state | nonempty_string) and (.doing | nonempty_string) and (.kind | nonempty_string);
    def landed_item:
      type == "object" and repo_marker and (.id | nonempty_string)
      and (.what | nonempty_string) and (.owner | nonempty_string)
      and optional_https_url("pr_url")
      and optional_subject;
    def charted_item:
      type == "object" and repo_marker and (.id | slug(128))
      and (.title | nonempty_string) and (.reason | type == "string")
      and (.dispatchable | type == "boolean")
      and ((has("kind") | not) or (.kind == "queued" or .kind == "warning"))
      and optional_filed
      and (if .kind == "warning" then .dispatchable == false else true end);
    type == "object"
    and (.schema == $schema)
    and (.home | nonempty_string)
    and (.generated | nonempty_string)
    and (.prs_live | type == "boolean")
    and (.captains_call | type == "array")
    and (.underway | type == "array")
    and (.landed | type == "array")
    and (.charted | type == "array")
    and ((has("charted_more") | not)
      or ((.charted_more | type == "number") and (.charted_more >= 0) and (.charted_more | floor == .)))
    and ((has("charted_warning_more") | not)
      or ((.charted_warning_more | type == "number") and (.charted_warning_more >= 0) and (.charted_warning_more | floor == .)))
    and ([.captains_call[] | call_item] | all)
    and ([.underway[] | underway_item] | all)
    and ([.landed[] | landed_item] | all)
    and ([.charted[] | charted_item] | all)
  ' "$1" >/dev/null
}

# --- Lavish session -----------------------------------------------------------
# Every lavish-axi call goes through bin/fm-lavish.sh run, which pins the
# environment and refuses an off-pin binary.

lavish() { FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-lavish.sh" run "$@"; }

lavish_field() {  # <name> <lavish-axi output>
  printf '%s\n' "$2" | sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" | head -1 | tr -d '"'
}

# Establish the board session and set BOARD_URL and BOARD_SESSION_REOPENED. A
# session the captain ended is reopened once; one that is still not opened
# after that refuses the build.
establish_board_session() {  # <board>
  local board=$1 out status
  BOARD_SESSION_REOPENED=0
  out=$(lavish "$board") || fail "cannot establish the board Lavish session"
  status=$(lavish_field status "$out")
  if [ "$status" = user-ended ]; then
    out=$(lavish "$board" --reopen) || fail "cannot reopen the ended board Lavish session"
    status=$(lavish_field status "$out")
    BOARD_SESSION_REOPENED=1
  fi
  case "$status" in
    opened|open) ;;
    *) fail "the board Lavish session is not open (lavish-axi reported status ${status:-none}); refusing to serve or arm it" ;;
  esac
  BOARD_URL=$(lavish_field url "$out")
  case "$BOARD_URL" in
    http://*/session/*) ;;
    *) fail "lavish-axi did not report a session URL for the board" ;;
  esac
  if [ "$BOARD_SESSION_REOPENED" = 1 ]; then
    printf 'session: reopened\n'
  else
    printf 'session: live\n'
  fi
}

# The OWNER column bin/fm-procevent.sh publishes; empty means not registered.
# A listing that fails returns nonzero, so no caller mistakes an unreadable
# registry for an absent source.
source_owner() {  # <source-id>
  local listing
  listing=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -v id="$1" 'NR > 1 && $1 == id { print $3; exit }'
}

# Before a build below answers publishes, an earlier answers build's binding is
# removed. Unbinding is what stops a still-open answers page from changing a
# held task, so a failed unbind refuses the build and leaves the earlier board
# in place. An off build then retires the board's listener and likewise refuses
# when it cannot, so off really means nothing collects from the page. The source
# id is derived from the board file's real path, so a deleted board is recreated
# empty for the derivation; the build publishes over it at once, and a refused
# unbind removes it again.
disarm_board_below_answers() {  # <board> <mode>
  local board=$1 mode=$2 sid owner placeholder=0
  if [ ! -e "$board" ] && [ ! -L "$board" ]; then
    (umask 077; : > "$board") || fail "cannot recreate the missing board to find its source"
    placeholder=1
  fi
  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board" 2>/dev/null) \
    || fail "cannot derive the board source id to check for an earlier answer source"
  if "$SCRIPT_DIR/fm-captain-hold.sh" binding "$sid" >/dev/null 2>&1; then
    if ! "$SCRIPT_DIR/fm-captain-hold.sh" unbind "$sid" >/dev/null 2>&1; then
      [ "$placeholder" = 0 ] || rm -f -- "$board"
      fail "cannot unbind the earlier answer source $sid; refusing to drop below answers while it can still change held tasks"
    fi
    printf 'unbound: %s\n' "$sid"
  fi
  [ "$mode" = off ] || return 0
  if ! owner=$(source_owner "$sid"); then
    [ "$placeholder" = 0 ] || rm -f -- "$board"
    fail "cannot list process-event sources to check the board listener $sid; refusing an off build that could leave it collecting"
  fi
  [ -n "$owner" ] || return 0
  if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" retire "$sid" >/dev/null 2>&1; then
    [ "$placeholder" = 0 ] || rm -f -- "$board"
    fail "cannot retire the board listener $sid; refusing an off build while it can still collect feedback"
  fi
  printf 'retired: %s\n' "$sid"
}

# Stage one page from the template and a compact payload, verified to carry a
# readable payload, and print its staged path. publish_page makes it the board.
stage_page() {  # <board> <compact-json>
  local board=$1 json=$2 tmp extracted
  tmp=$(umask 077; mktemp "${board%/*}/.board.XXXXXX") || fail "cannot stage the board"
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{BOARD_JSON}/" "$TEMPLATE" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot inject the board data"
  fi
  if grep -qxF "$PLACEHOLDER" "$tmp"; then
    rm -f -- "$tmp"
    fail "the board data slot survived injection"
  fi
  # Round-trip the injected payload back out of the built page, so a board that
  # would fail to parse in the browser fails here instead.
  extracted=$(sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "the built board does not carry a readable $BOARD_SCHEMA payload"
  fi
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; fail "cannot stage the board"; }
  printf '%s\n' "$tmp"
}

publish_page() {  # <staged-page> <board>
  mv -f -- "$1" "$2" || { rm -f -- "$1"; fail "cannot publish the board"; }
}

# Arm the board so whatever the captain sends from the page reaches firstmate,
# binding it to the keyed-answer intake first only in answers mode, then make
# sure this generation is listening. A view board stays unbound, so its
# annotations arrive as ordinary review feedback and can never close a task.
# The session is already open by now, so any failure here ends it before the
# build fails: the page must not take feedback while nothing listens. A later
# build reopens an agent-ended session without asking.
arm_board_source() {  # <board> <bind: 0|1>
  local board=$1 bind=$2 sid out rc=0
  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board") \
    || arm_fail "$board" "cannot derive the board source id"
  if [ "$BOARD_SESSION_REOPENED" = 1 ] && [ -n "$(source_owner "$sid")" ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" retire "$sid" >/dev/null \
      || arm_fail "$board" "cannot retire the pre-reopen board source $sid"
  fi
  if [ "$bind" = 1 ]; then
    "$SCRIPT_DIR/fm-captain-hold.sh" bind "$sid" >/dev/null \
      || arm_fail "$board" "cannot bind the board source to the keyed-answer intake"
    printf 'bound: %s\n' "$sid"
  fi
  if [ -z "$(source_owner "$sid")" ]; then
    out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board") \
      || arm_fail "$board" "cannot arm the board as a process-event source"
    printf '%s\n' "$out" | grep -E '^(armed|still-listening): ' || true
    return 0
  fi
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" ensure-listening "$sid" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) printf 'already-armed: %s\n' "$sid" ;;
    3) printf 'still-listening: %s\n' "$sid" ;;
    *) arm_fail "$board" "board source $sid is registered but not listening (observed owner: $(source_owner "$sid"))" ;;
  esac
}

arm_fail() {  # <board> <message>
  if lavish end "$1" >/dev/null 2>&1; then
    fail "$2; ended the board session so it takes no feedback while nothing listens"
  fi
  fail "$2; could not end the board session either, so feedback sent from it waits until a later build arms it"
}

# --- Captain's Call hygiene ---------------------------------------------------
# A held decision whose subject already shipped is not a live call, so it is
# dropped here instead of being carded again. All checks use exact structured
# identities; unknown subject state keeps the card.

decision_card_is_stale() {  # <task-id> <landed-0-or-1>
  local task=$1 landed=$2 rc=0
  if [ "$landed" = 1 ]; then
    printf 'structured subject already landed\n'
    return 0
  fi
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$task" --distinguish-absent >/dev/null 2>&1 || rc=$?
  # 1 is a definite "no longer an open captain call". 2 is "cannot tell", 3 is
  # absent from this backlog, and a call wrongly hidden is worse than a card
  # wrongly shown, so both uncertain and absent cards stay.
  if [ "$rc" -eq 1 ]; then
    printf 'no longer an open captain call\n'
    return 0
  fi
  return 1
}

# Drop every stale decision card while preserving every surviving input field.
# The build alone decides `interactive` and each card's `answerable`: set true
# only in answers mode, for decision cards owned by this home whose call this
# home holds open, and removed otherwise. Every surviving decision card gets
# the standard reconcile choice; the validator reserves that value, so no
# composer can author it; docs/captain-hold-lifecycle.md owns what it means.
# Read one durable record in its stored form: an fm-decision-card.v1 envelope
# whose card passes `stored_call_item`, both owned by
# bin/fm-decision-card-lib.sh. Sets STORE_CARD to the compact card and returns
# 0, or sets STORE_CARD_REASONS for the caller's ignored-store-card line and
# returns 1, so an envelope that names another schema is never merged.
STORE_CARD=
STORE_CARD_REASONS=
read_store_card() {  # <file>
  STORE_CARD=
  STORE_CARD_REASONS=$(jq -r "$FM_DECISION_CARD_JQ_DEFS"'
    if (envelope_reasons | length) > 0 then envelope_reasons | join("; ")
    elif (.card | stored_call_item) then ""
    else .card | failure_reasons | join("; ") end' "$1" 2>/dev/null) \
    || STORE_CARD_REASONS='unreadable record'
  [ -z "$STORE_CARD_REASONS" ] || return 1
  STORE_CARD=$(jq -c '.card' "$1" 2>/dev/null) && [ -n "$STORE_CARD" ] && return 0
  STORE_CARD_REASONS='unreadable record'
  return 1
}

# Drop every stale decision card, then give every surviving decision card the
# standard reconcile choice. Injecting it here is what makes "every decision
# card offers reconcile" a property of the board rather than of the composer's
# memory; the validator prevents duplicate decision options.
merge_store_cards() {  # <data.json> <dest.json>
  # STORE-FIRST. A durable record written at raise time (or by an earlier
  # build) replaces the payload's card for the same key; the payload card is
  # used only where the store holds nothing. Order is preserved, and a record
  # that fails the stored form of the shared contract is named on stderr and
  # skipped rather than failing the build.
  local data=$1 dest=$2 key file staged owner
  cp -- "$data" "$dest" || return 1
  [ -d "$DECISION_CARDS_DIR" ] && [ ! -L "$DECISION_CARDS_DIR" ] || return 0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    file="$DECISION_CARDS_DIR/$key.json"
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    if ! read_store_card "$file"; then
      printf 'ignored-store-card: %s (%s)\n' "$key" "$STORE_CARD_REASONS" >&2
      continue
    fi
    if [ "$(jq -r '.card.synthesized // false' "$file" 2>/dev/null)" = 'true' ]; then
      continue
    fi
    # A record answers for its own key only: a file whose card names another
    # task would otherwise be merged into this key's slot.
    if [ "$(jq -r '.card.key? // empty' "$file" 2>/dev/null)" != "$key" ]; then
      printf 'ignored-store-card: %s (record key does not match its file name)\n' "$key" >&2
      continue
    fi
    # A card another home owns is display-only here: the local store must
    # never replace its content, or a later local card with the same key
    # would inherit the remote question.
    owner=$(jq -r --arg key "$key" 'first(.captains_call[] | select(.key == $key) | .owner // "")' "$dest" 2>/dev/null)
    if [ -n "$owner" ] && [ "$owner" != '(main)' ]; then
      continue
    fi
    staged=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-card.XXXXXX") || return 1
    if ! jq --arg key "$key" --slurpfile record "$file" '
          .captains_call = [.captains_call[]
            | if .key == $key
              then (. as $orig | $record[0].card | del(.answerable)
                    | if $orig | has("owner") then .owner = $orig.owner
                      else del(.owner) end)
              else . end]' "$dest" > "$staged"; then
      rm -f -- "$staged"
      return 1
    fi
    mv -f -- "$staged" "$dest" || { rm -f -- "$staged"; return 1; }
  done < <(jq -r '.captains_call[]?.key' "$data")
  return 0
}

effective_payload() {  # <data.json> <dest.json> <lavish-mode>
  local data=$1 dest=$2 mode=$3 merged rc=0
  merged=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-merged.XXXXXX") || return 1
  if ! merge_store_cards "$data" "$merged"; then
    rm -f -- "$merged"
    return 1
  fi
  landed_drop_and_inject "$merged" "$dest" "$mode" || rc=$?
  rm -f -- "$merged"
  return "$rc"
}

landed_drop_and_inject() {  # <data.json> <dest.json> <lavish-mode>
  local data=$1 dest=$2 mode=$3 landed_keys key reason drop='' tmp landed=0 here='' here_json
  landed_keys=$(jq -c '
    def version_parts: split(".") | map(tonumber);
    . as $payload
    | [$payload.captains_call[]
      | select(.type == "decision")
      | . as $card
      | select(
          ($payload.landed | any(.id == $card.key))
          or (($card.pr_url? != null) and ($payload.landed | any(.pr_url? == $card.pr_url)))
          or (($card.subject? != null) and ($payload.landed | any(
            (.subject? != null)
            and (.subject.artifact == $card.subject.artifact)
            and ((.subject.version | version_parts) >= ($card.subject.version | version_parts)))))
        )
      | .key]
  ' "$data") || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    landed=0
    if jq -e --arg key "$key" 'index($key) != null' <<< "$landed_keys" >/dev/null; then
      landed=1
    fi
    if reason=$(decision_card_is_stale "$key" "$landed"); then
      printf 'dropped-landed-card: %s (%s)\n' "$key" "$reason" >&2
      drop=$drop$key$'\n'
      continue
    fi
    # Only a call this home's own backlog holds open can take a board answer:
    # the binding feeds this home's intake, so a secondmate's call, or one whose
    # state cannot be read, stays display-only and is answered in chat. The
    # owner check below keeps a secondmate card that shares a local task id
    # display-only too.
    if [ "$mode" = answers ] \
      && "$SCRIPT_DIR/fm-captain-hold.sh" open "$key" --distinguish-absent >/dev/null 2>&1; then
      here=$here$key$'\n'
    fi
  done < <(jq -r '.captains_call[]? | select(.type == "decision") | .key' "$data")
  tmp=$(printf '%s' "$drop" | jq -R -s 'split("\n") | map(select(length > 0))') || return 1
  here_json=$(printf '%s' "$here" | jq -R -s 'split("\n") | map(select(length > 0))') || return 1
  jq --argjson dropped "$tmp" --argjson here "$here_json" --arg mode "$mode" '
    (if $mode == "answers" then .interactive = true else del(.interactive) end)
    | .captains_call = [
      .captains_call[]
      | . as $card
      | select($card.type != "decision" or (($dropped | index($card.key)) == null))
      | del(.answerable)
      | if $mode == "answers" and .type == "decision" and .owner? == "(main)"
          and (($here | index($card.key)) != null)
        then .answerable = true
        else . end
      | if .type == "decision"
          and ([.options[]? | select(type == "object" and .value == "reconcile")] | length == 0)
        then .options += [{
          value: "reconcile",
          label: "Reconcile",
          hint: "Re-check the latest state, then close this with evidence or keep it open with a note"
        }]
        else . end
    ]' "$data" > "$dest" || return 1
}

# --- durable decision cards ---------------------------------------------------
# The board is rebuilt from scratch on every composition, so a card that is not
# in the newest payload disappears with it. The Deck and any later reader still
# need the options the captain was shown, so every surviving card is persisted
# per task under state/decision-cards/. Exactly one card per key is written,
# the first payload entry for that key: a payload can list the same call twice,
# and a store file that carries two JSON documents makes a later reader refuse
# the whole record. A record whose task is definitely no longer an open captain
# call is pruned; a task whose state cannot be established is kept, because a
# card wrongly hidden is worse than one wrongly shown - the same asymmetry as
# the card hygiene above.

DECISION_CARDS_DIR="$STATE/decision-cards"
DECISION_CARD_LOCKS=()
DECISION_CARD_LOCK_COUNT=0

release_decision_card_locks() {
  local index lock rc=0
  index=$DECISION_CARD_LOCK_COUNT
  while [ "$index" -gt 0 ]; do
    index=$((index - 1))
    lock=${DECISION_CARD_LOCKS[$index]}
    fm_lock_release "$lock" || rc=1
    unset "DECISION_CARD_LOCKS[$index]"
    DECISION_CARD_LOCK_COUNT=$index
  done
  return "$rc"
}

REFRESH_DATA_TMP=
bearings_board_cleanup() {
  if [ -n "$REFRESH_DATA_TMP" ]; then
    rm -f -- "$REFRESH_DATA_TMP"
    REFRESH_DATA_TMP=
  fi
  release_decision_card_locks || true
}
trap bearings_board_cleanup EXIT

decision_card_key_valid() {  # <key>
  jq -ne --arg key "$1" "$FM_DECISION_CARD_JQ_DEFS"'$key | slug(128)' >/dev/null 2>&1
}

# Raw card keys on stdin become the deduplicated control-lock names on
# stdout: an out-of-contract name is named and skipped, and a merge.<task>
# card maps to its underlying task's lock, because every hold-side writer
# (answer, card, card merge.<task>) serializes on the task id - a
# merge-prefixed lock would let this read/write cycle race a refresh of the
# very card it persists. Normalizing before the caller's sort means two
# builds holding different key sets still take shared locks in the same
# order. Kept outside the process substitution: a parenthesis inside the
# message text defeats bash's runtime re-scan of the <( ) body.
emit_decision_card_lock_names() {
  local key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if ! decision_card_key_valid "$key"; then
      printf 'ignored-store-card: %s (file name is not a valid card key)\n' "$key" >&2
      continue
    fi
    printf '%s\n' "${key#merge.}"
  done
}

acquire_decision_card_locks() {  # <payload.json>
  local data=$1 file key lock lockname
  while IFS= read -r lockname; do
    [ -n "$lockname" ] || continue
    lock="$STATE/.control-$lockname.lock"
    fm_lock_acquire_wait "$lock" || return 1
    DECISION_CARD_LOCKS[DECISION_CARD_LOCK_COUNT]=$lock
    DECISION_CARD_LOCK_COUNT=$((DECISION_CARD_LOCK_COUNT + 1))
  done < <(
    {
      jq -r '.captains_call[]?.key' "$data"
      if [ -d "$DECISION_CARDS_DIR" ] && [ ! -L "$DECISION_CARDS_DIR" ]; then
        for file in "$DECISION_CARDS_DIR"/*.json; do
          [ -f "$file" ] && [ ! -L "$file" ] || continue
          key=$(basename "$file" .json)
          printf '%s\n' "$key"
        done
      fi
    } | emit_decision_card_lock_names | LC_ALL=C sort -u
  )
}

persist_decision_cards() {  # <effective-payload.json>
  local data=$1 key card tmp existing task live_task rc owner keep=''
  if [ -d "$DECISION_CARDS_DIR" ] && [ ! -L "$DECISION_CARDS_DIR" ]; then
    :
  elif ! (umask 077; mkdir -p "$DECISION_CARDS_DIR"); then
    return 1
  fi
  [ -d "$DECISION_CARDS_DIR" ] && [ ! -L "$DECISION_CARDS_DIR" ] || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    keep=$keep$key$'\n'
    # Another home's decision card is display-only here and stays out of
    # this home's durable store, so it can never be merged back as local.
    owner=$(jq -r --arg key "$key" 'first(.captains_call[] | select(.key == $key) | .owner // "")' "$data" 2>/dev/null)
    if [ -n "$owner" ] && [ "$owner" != '(main)' ]; then
      continue
    fi
    # A synthesized fallback tracks the snapshot, not the store: persisting
    # it would give a stale copy store-first precedence over the next one.
    if [ "$(jq -r --arg key "$key" 'first(.captains_call[] | select(.key == $key) | .synthesized // false)' "$data" 2>/dev/null)" = 'true' ]; then
      continue
    fi
    card=$(jq -c --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg key "$key" \
      'first(.captains_call[] | select(.key == $key)
       | {schema:"fm-decision-card.v1",generated:$generated,card:(. | del(.answerable))})' "$data") || return 1
    [ -n "$card" ] || return 1
    tmp=$(umask 077; mktemp "$DECISION_CARDS_DIR/.card.XXXXXX") || return 1
    if printf '%s\n' "$card" > "$tmp" \
      && chmod 0600 "$tmp" \
      && mv -f -- "$tmp" "$DECISION_CARDS_DIR/$key.json"; then
      continue
    fi
    rm -f -- "$tmp"
    return 1
  done < <(jq -r '.captains_call[]?.key' "$data")
  for existing in "$DECISION_CARDS_DIR"/*.json; do
    [ -f "$existing" ] && [ ! -L "$existing" ] || continue
    task=$(basename "$existing" .json)
    case $'\n'"$keep" in
      *$'\n'"$task"$'\n'*) continue ;;
    esac
    live_task=$task
    if jq -e '.card.type == "merge"' "$existing" >/dev/null 2>&1; then
      case "$live_task" in merge.*) live_task=${live_task#merge.} ;; esac
    fi
    rc=0
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$live_task" --distinguish-absent >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 1 ] || continue
    rm -f -- "$existing" || return 1
  done
  return 0
}

command_build() {
  local data='' request='' request_set=0 board json static_json page static_page='' effective
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lavish) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; request=$2; request_set=1; shift 2 ;;
      --lavish=*) request=${1#--lavish=}; request_set=1; shift ;;
      -*) usage >&2; exit 2 ;;
      *) [ -z "$data" ] || { usage >&2; exit 2; }; data=$1; shift ;;
    esac
  done
  [ -n "$data" ] || { usage >&2; exit 2; }
  [ "$request_set" = 0 ] || [ -n "$request" ] || fail "--lavish must be off, view, or answers (got an empty value)"
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "board data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "board data is not valid JSON: $data"
  validate_payload "$data" || fail "board data does not satisfy $BOARD_SCHEMA: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "board template does not carry exactly one data slot: $TEMPLATE"
  fm_lavish_resolve "$CONFIG" "$request" || fail "cannot resolve the board's Lavish mode"

  effective=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-payload.XXXXXX") \
    || fail "cannot stage the board payload"
  acquire_decision_card_locks "$data" \
    || { rm -f -- "$effective"; fail "cannot lock the decision-card store"; }
  if ! effective_payload "$data" "$effective" "$FM_LAVISH_MODE"; then
    rm -f -- "$effective"
    fail "cannot reconcile the board payload against landed work"
  fi
  persist_decision_cards "$effective" || {
    rm -f -- "$effective"
    fail "cannot persist the decision cards under $DECISION_CARDS_DIR"
  }
  release_decision_card_locks \
    || { rm -f -- "$effective"; fail "cannot unlock the decision-card store"; }
  json=$(jq -c . "$effective") || { rm -f -- "$effective"; fail "cannot compact the board data"; }
  rm -f -- "$effective"
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}

  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || fail "cannot create ${board%/*}"
  # The board's source id is its real path, so a board replaced by a symlink
  # would name some other source; refuse it rather than lose track of a listener.
  [ ! -L "$board" ] && [ ! -L "${board%/*}" ] \
    || fail "the board path or its .lavish directory is a symlink, which is never built: $board"
  [ "$FM_LAVISH_MODE" = answers ] || disarm_board_below_answers "$board" "$FM_LAVISH_MODE"
  page=$(stage_page "$board" "$json")
  if [ "$FM_LAVISH_MODE" = answers ]; then
    # Until the source is bound and listening, serve the same board without
    # its answer controls, so no answer can be queued with nothing consuming it.
    static_json=$(jq -c 'del(.interactive)
      | .captains_call |= map(del(.answerable) | .options |= map(select(.value != "reconcile")))' <<< "$json") \
      || { rm -f -- "$page"; fail "cannot stage the read-only board"; }
    static_json=${static_json//</\\u003c}
    static_page=$(stage_page "$board" "$static_json") || { rm -f -- "$page"; exit 1; }
  fi
  if [ -n "$static_page" ]; then
    publish_page "$static_page" "$board"
  else
    publish_page "$page" "$board"
  fi
  printf 'board: %s\n' "$board"
  [ -z "$FM_LAVISH_REASON" ] || printf 'lavish: off (%s)\n' "$FM_LAVISH_REASON"
  if [ "$FM_LAVISH_MODE" = off ]; then
    printf 'served: %s\n' "$board"
    printf 'open: %s\n' "$board"
    return 0
  fi
  if [ -n "$static_page" ]; then
    trap 'bearings_board_cleanup; rm -f -- "$page"' EXIT
  fi
  establish_board_session "$board"
  printf 'served: %s\n' "$board"
  printf 'url: %s\n' "$BOARD_URL"
  printf 'open: %s\n' "$BOARD_URL"
  if [ "$FM_LAVISH_MODE" = view ]; then
    arm_board_source "$board" 0
  else
    arm_board_source "$board" 1
    publish_page "$page" "$board"
    trap - EXIT
    printf 'answers: open\n'
  fi
}

case "${1-}" in
  build) shift; command_build "$@" ;;
  compose) shift; command_compose "$@" ;;
  refresh) shift; command_refresh "$@" ;;
  path) board_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
