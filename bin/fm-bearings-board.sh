#!/usr/bin/env bash
# fm-bearings-board.sh - build the /bearings lavish fleet board.
#
# The board is the captain-facing surface of /bearings lavish: the shipped
# template (.agents/skills/bearings/assets/board-template.html) plus one
# injected fm-bearings-board.v1 JSON payload. This script owns the mechanics so
# the invoking agent's per-run work stays "compose the JSON, run build" - the
# agent never authors board UI at invocation time.
#
# Usage:
#   fm-bearings-board.sh build <data.json> [--lavish <off|view|answers>]
#   fm-bearings-board.sh path
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
#            answers  view, plus answer controls on every decision card and the
#                     standard reconcile choice. The source is bound to the
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
TEMPLATE="${FM_BEARINGS_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/board-template.html}"
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

validate_payload() {  # <data.json>
  jq -e --arg schema "$BOARD_SCHEMA" '
    def nonempty_string: type == "string" and length > 0;
    def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
    def repo_marker: has("repo") and (.repo == null or (.repo | type == "string"));
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
    def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
    def optional_https_url($name):
      (has($name) | not)
      or (.[$name]
        | type == "string"
          and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$"));
    def version: type == "string" and test("^(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})$");
    def optional_subject:
      (has("subject") | not)
      or (.subject
        | type == "object"
          and (keys | sort) == ["artifact", "version"]
          and (.artifact | slug(128))
          and (.version | version));
    def call_item:
      type == "object"
      and (.key | slug(128))
      and (.type == "decision" or .type == "merge" or .type == "credential")
      and repo_marker
      and (.title | nonempty_string)
      and (.options | type == "array")
      and ((.options | length) > 0 or .allow_freeform == true)
      and ([.options[]
        | type == "object"
          and (.value | slug(128))
          and (.label | nonempty_string)
          and optional_string("hint")] | all)
      and (optional_string("about"))
      and (optional_string("decide"))
      and (optional_string("detail"))
      and (optional_https_url("pr_url"))
      and optional_subject
      and (if has("subject") then .type == "decision" else true end)
      and (optional_string("freeform_hint"))
      and ((has("close") | not) or (.close == "done" or .close == "release"))
      and ((has("allow_freeform") | not) or (.allow_freeform | type == "boolean"))
      and ((has("recommend_value") | not)
        or ((.recommend_value | slug(128))
          and (.recommend_value as $recommend
            | ([.options[].value] | index($recommend) != null))))
      and ([.options[].value] | index("reconcile") == null)
      and (if .type == "merge" then (.risk | nonempty_string) else true end);
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
# The build alone decides `interactive`: set true only in answers mode and
# removed otherwise, so an off board embeds the input payload unchanged. Answers
# mode is also the only mode that gives every surviving decision card the standard
# reconcile choice. The validator reserves that value, so no composer can
# author it; docs/captain-hold-lifecycle.md owns what it means.
effective_payload() {  # <data.json> <dest.json> <lavish-mode>
  local data=$1 dest=$2 mode=$3 landed_keys key reason drop='' tmp landed=0
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
    reason=$(decision_card_is_stale "$key" "$landed") || continue
    printf 'dropped-landed-card: %s (%s)\n' "$key" "$reason" >&2
    drop=$drop$key$'\n'
  done < <(jq -r '.captains_call[]? | select(.type == "decision") | .key' "$data")
  tmp=$(printf '%s' "$drop" | jq -R -s 'split("\n") | map(select(length > 0))') || return 1
  jq --argjson dropped "$tmp" --arg mode "$mode" '
    (if $mode == "answers" then .interactive = true else del(.interactive) end)
    | .captains_call = [
      .captains_call[]
      | . as $card
      | select($card.type != "decision" or (($dropped | index($card.key)) == null))
      | if $mode == "answers" and .type == "decision"
        then .options += [{
          value: "reconcile",
          label: "Reconcile",
          hint: "Re-check the latest state, then close this with evidence or keep it open with a note"
        }]
        else . end
    ]' "$data" > "$dest" || return 1
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
  if ! effective_payload "$data" "$effective" "$FM_LAVISH_MODE"; then
    rm -f -- "$effective"
    fail "cannot reconcile the board payload against landed work"
  fi
  json=$(jq -c . "$effective") || { rm -f -- "$effective"; fail "cannot compact the board data"; }
  rm -f -- "$effective"
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}

  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || fail "cannot create ${board%/*}"
  # The board's source id is its real path, so a board replaced by a symlink
  # would name some other source; refuse it rather than lose track of a listener.
  [ ! -L "$board" ] || fail "the board path is a symlink, which is never built: $board"
  [ "$FM_LAVISH_MODE" = answers ] || disarm_board_below_answers "$board" "$FM_LAVISH_MODE"
  page=$(stage_page "$board" "$json")
  if [ "$FM_LAVISH_MODE" = answers ]; then
    # Until the source is bound and listening, serve the same board without
    # its answer controls, so no answer can be queued with nothing consuming it.
    static_json=$(jq -c 'del(.interactive)
      | .captains_call |= map(.options |= map(select(.value != "reconcile")))' <<< "$json") \
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
    trap 'rm -f -- "$page"' EXIT
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
  path) board_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
