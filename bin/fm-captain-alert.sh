#!/usr/bin/env bash
# fm-captain-alert.sh - one-way captain alerts to a Discord webhook while away.
#
# Usage:
#   fm-captain-alert.sh [check]          watcher entry: post new captain outcomes while away
#   fm-captain-alert.sh arm              write and register state/captain-alert.check.sh
#   fm-captain-alert.sh disarm           remove the check shim, its trust binding, and the records
#   fm-captain-alert.sh status           print configuration and delivery state (never the URL)
#   fm-captain-alert.sh test             post one labelled test message (captain-authorized only)
#   fm-captain-alert.sh post <text>      post one message; usable as a wedge-alarm command: line
#   fm-captain-alert.sh reach            print `discord <last test>` when away entry may name the
#                                        channel, otherwise `none`
#   fm-captain-alert.sh brief-line --since <epoch>
#                                        one return-brief health line, or nothing when not armed
#   fm-captain-alert.sh --help
#
# SOURCE. The supervision branch's outcome store, state/branch-outcomes.jsonl
# (bin/fm-branch-outcome.sh owns its format), records every handled event with
# a routine or captain verdict before delivery. The Pi branch extension and the
# supervision host's report surface (bin/fm-branch-report.sh) both append to
# it. This notifier reads it only through `fm-branch-outcome.sh list` and keeps
# its own cursor; it never touches the store's read cursor or processed marker.
# A row is eligible when its verdict is captain, it is not silent, and it was
# recorded at or after the standing away record's entered_epoch.
#
# GATING. Rows are posted only while bin/fm-afk-contract.sh reports an away
# record; quiet mode and an attended home advance the cursor silently and drop
# anything waiting, so an attended day never floods the phone at the next
# /afk. A home whose away supervision is the away daemon records no captain
# outcomes, so while that daemon owns supervision `check` reports the home as
# unsupported once instead of staying silent.
#
# DELIVERY. Each sweep moves new eligible rows into a pending queue
# (state/.captain-alert-pending.jsonl) and then advances the cursor; a row
# leaves the pending queue only when Discord returns HTTP 2xx with a created
# message id (`?wait=true`). Delivery is at-least-once: a crash between the
# post and the record write can repeat one message, which carries its seq range
# so a repeat is recognizable. Coalescing:
#   - at most one post per sweep;
#   - a task headlined within FM_CAPTAIN_ALERT_COOLDOWN_SECS (default 3600) is
#     not re-headlined; its rows wait and are folded into a count on the next
#     post that headlines another task, or headlined again once its window ends;
#   - at most FM_CAPTAIN_ALERT_HOURLY_CAP (default 6) posts per rolling hour;
#     past the cap one volume notice is sent and the rest wait for the window;
#   - the pending queue keeps at most 200 rows; older ones are counted, not listed;
#   - one sweep takes at most 1000 rows past its cursor, oldest first
#     (FM_CAPTAIN_ALERT_SCAN lowers it for tests); the rest wait their turn.
#
# FAILURES. The transport classifies each attempt: success (2xx and an id),
# transient (network error, timeout, 5xx, 2xx without an id, or 429 whose
# retry_after does not fit one short wait), or permanent (400, 401, 403, 404).
# A transient failure keeps the queue for the next sweep, which is the backoff.
# A permanent failure stops posting until a successful `test` or a changed
# webhook value; a 404 is never retried. Failures surface three ways, none of
# which depends on Discord: a check line printed only when the reported state
# changes (a transient failure is reported from its second consecutive sweep),
# a one-time fallback per failure episode while away through the away
# watchdog's alarm channels (`fm-afk-sentinel.sh notify`), and the return
# brief's health line (`brief-line`).
#
# SECRECY. The webhook URL is read from <FM_HOME>/.env with fmx_env_get and
# passed to curl only on stdin (`--config -`). It never appears in argv,
# output, records, or logs; curl's own stderr is discarded and failures are
# reported by exit code and HTTP status alone.
#
# CONFIGURATION (docs/configuration.md "Captain alerts to Discord (.env)"):
#   FM_DISCORD_ALERT_WEBHOOK          required to enable; https URL of the webhook
#   FM_DISCORD_ALERT_DETAIL           full (default) or brief
#   FM_DISCORD_ALERT_MENTION_USER_ID  optional numeric user id mentioned in each post
# Tunables from the environment: FM_CAPTAIN_ALERT_COOLDOWN_SECS,
# FM_CAPTAIN_ALERT_HOURLY_CAP, FM_CAPTAIN_ALERT_BUDGET (curl seconds, default
# 12, valid 3..20). The whole run also stays inside the watcher's per-check
# bound, FM_CHECK_TIMEOUT (default 30), less a reserve for saving its state:
# the lock wait, each transfer, and a 429 wait all draw on that one deadline,
# and an attempt that no longer fits is deferred to the next sweep without
# counting as a failure. Test seams: FM_CAPTAIN_ALERT_EXEC names a transport stub run
# as `<stub> <payload-file> <body-file>` with the curl config on stdin, which
# prints the HTTP status and exits with a curl-style code;
# FM_CAPTAIN_ALERT_SENTINEL replaces the fallback alarm command;
# FM_CAPTAIN_ALERT_NOW pins the clock.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ENV_FILE="$FM_HOME/.env"
RECORD="$STATE/.captain-alert"
PENDING="$STATE/.captain-alert-pending.jsonl"
LOG="$STATE/.captain-alert-log"
LOCK="$STATE/.captain-alert.lock"
CHECK_ID=captain-alert
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
OUTCOME_BIN="$SCRIPT_DIR/fm-branch-outcome.sh"
CONTRACT_BIN="$SCRIPT_DIR/fm-afk-contract.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"
RECORD_SCHEMA=fm-captain-alert-v1
MAX_LINE=240
MAX_PENDING=200
MAX_CONTENT=1900
LOG_KEEP=500

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^# SOURCE\./p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf 'fm-captain-alert: %s\n' "$1" >&2
  usage >&2
  exit 2
}

whole_or_default() {  # <value> <default> <min> <max>
  case "$1" in
    ''|*[!0-9]*) printf '%s\n' "$2" ;;
    *) if [ "$1" -lt "$3" ] || [ "$1" -gt "$4" ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi ;;
  esac
}

COOLDOWN=$(whole_or_default "${FM_CAPTAIN_ALERT_COOLDOWN_SECS:-}" 3600 0 86400)
HOURLY_CAP=$(whole_or_default "${FM_CAPTAIN_ALERT_HOURLY_CAP:-}" 6 1 60)
BUDGET=$(whole_or_default "${FM_CAPTAIN_ALERT_BUDGET:-}" 12 3 20)
CHECK_TIMEOUT=$(whole_or_default "${FM_CHECK_TIMEOUT:-}" 30 1 3600)
DEADLINE_RESERVE=4
START_SECONDS=$SECONDS
MAX_SCAN=$(whole_or_default "${FM_CAPTAIN_ALERT_SCAN:-}" 1000 1 1000)
SCAN_SLACK=200

now_epoch() {
  case "${FM_CAPTAIN_ALERT_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_CAPTAIN_ALERT_NOW" ;;
  esac
}

iso_of() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || printf '%s\n' "$1"
}

# --- configuration ------------------------------------------------------------

# Read the webhook into WEBHOOK and report why it is unusable in CONFIG_PROBLEM.
# The value is checked for shape only, so it can go into a curl config line.
load_config() {
  WEBHOOK=$(fmx_env_get FM_DISCORD_ALERT_WEBHOOK "$ENV_FILE")
  DETAIL=$(fmx_env_get FM_DISCORD_ALERT_DETAIL "$ENV_FILE")
  MENTION=$(fmx_env_get FM_DISCORD_ALERT_MENTION_USER_ID "$ENV_FILE")
  CONFIG_PROBLEM=
  case "$DETAIL" in ''|full) DETAIL=full ;; brief) ;; *) DETAIL=full ;; esac
  case "$MENTION" in *[!0-9]*) MENTION= ;; esac
  if [ -z "$WEBHOOK" ]; then
    CONFIG_PROBLEM="FM_DISCORD_ALERT_WEBHOOK is not set in .env"
  else
    case "$WEBHOOK" in
      https://*[[:space:]\"\\]*) CONFIG_PROBLEM="FM_DISCORD_ALERT_WEBHOOK in .env is not a plain https URL" ;;
      https://?*) ;;
      *) CONFIG_PROBLEM="FM_DISCORD_ALERT_WEBHOOK in .env is not a plain https URL" ;;
    esac
  fi
  [ -z "$CONFIG_PROBLEM" ]
}

# A short fingerprint lets a changed webhook value clear a permanent failure
# without storing the credential itself.
webhook_fingerprint() {
  printf '%s' "$WEBHOOK" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-12
}

# --- record -------------------------------------------------------------------

# The record is key=value lines after a schema line; `sent` and `cool` repeat.
record_read() {
  R_CURSOR=; R_FAIL_KIND=; R_FAIL_REASON=; R_FAIL_SINCE=; R_FAIL_COUNT=0; R_FALLBACK=
  R_REPORTED=; R_LAST_OK=; R_LAST_TEST=; R_FP=; R_OVERFLOW=; R_DROPPED=0
  R_SENT=(); R_COOL=()
  [ -f "$RECORD" ] || return 1
  local line first=1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" -eq 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 1
      continue
    fi
    case "$line" in
      cursor=*) R_CURSOR=${line#cursor=} ;;
      fail_kind=*) R_FAIL_KIND=${line#fail_kind=} ;;
      fail_reason=*) R_FAIL_REASON=${line#fail_reason=} ;;
      fail_since=*) R_FAIL_SINCE=${line#fail_since=} ;;
      fail_count=*) R_FAIL_COUNT=${line#fail_count=} ;;
      fallback=*) R_FALLBACK=${line#fallback=} ;;
      reported=*) R_REPORTED=${line#reported=} ;;
      last_ok=*) R_LAST_OK=${line#last_ok=} ;;
      last_test=*) R_LAST_TEST=${line#last_test=} ;;
      fp=*) R_FP=${line#fp=} ;;
      overflow=*) R_OVERFLOW=${line#overflow=} ;;
      dropped=*) R_DROPPED=${line#dropped=} ;;
      sent=*) R_SENT+=("${line#sent=}") ;;
      cool=*) R_COOL+=("${line#cool=}") ;;
    esac
  done < "$RECORD"
  case "$R_CURSOR" in ''|*[!0-9]*) return 1 ;; esac
  case "$R_FAIL_COUNT" in ''|*[!0-9]*) R_FAIL_COUNT=0 ;; esac
  case "$R_DROPPED" in ''|*[!0-9]*) R_DROPPED=0 ;; esac
  return 0
}

record_write() {
  local tmp now cutoff entry
  now=$(now_epoch)
  cutoff=$((now - 3600))
  tmp=$(umask 077; mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'cursor=%s\n' "$R_CURSOR"
    [ -z "$R_FAIL_KIND" ] || printf 'fail_kind=%s\nfail_reason=%s\nfail_since=%s\nfail_count=%s\n' \
      "$R_FAIL_KIND" "$R_FAIL_REASON" "$R_FAIL_SINCE" "$R_FAIL_COUNT"
    [ -z "$R_FALLBACK" ] || printf 'fallback=%s\n' "$R_FALLBACK"
    [ -z "$R_REPORTED" ] || printf 'reported=%s\n' "$R_REPORTED"
    [ -z "$R_LAST_OK" ] || printf 'last_ok=%s\n' "$R_LAST_OK"
    [ -z "$R_LAST_TEST" ] || printf 'last_test=%s\n' "$R_LAST_TEST"
    [ -z "$R_FP" ] || printf 'fp=%s\n' "$R_FP"
    [ -z "$R_OVERFLOW" ] || [ "$R_OVERFLOW" -le "$cutoff" ] || printf 'overflow=%s\n' "$R_OVERFLOW"
    [ "$R_DROPPED" -eq 0 ] || printf 'dropped=%s\n' "$R_DROPPED"
    for entry in ${R_SENT[@]+"${R_SENT[@]}"}; do
      if [ "$entry" -gt "$cutoff" ] 2>/dev/null; then printf 'sent=%s\n' "$entry"; fi
    done
    for entry in ${R_COOL[@]+"${R_COOL[@]}"}; do
      if [ "${entry##* }" -gt "$((now - COOLDOWN))" ] 2>/dev/null; then printf 'cool=%s\n' "$entry"; fi
    done
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
}

log_event() {  # <kind> <detail>
  local tmp
  printf '%s\t%s\t%s\n' "$(now_epoch)" "$1" "$2" >> "$LOG" 2>/dev/null || return 0
  if [ "$(wc -l < "$LOG" | tr -d ' ')" -gt "$LOG_KEEP" ]; then
    tmp=$(mktemp "$LOG.XXXXXX" 2>/dev/null) || return 0
    if ! tail -n "$LOG_KEEP" "$LOG" > "$tmp" || ! mv -f -- "$tmp" "$LOG"; then
      rm -f -- "$tmp"
    fi
  fi
}

armed() {
  fm_custom_check_registered "$STATE" "$CHECK_ID"
}

# --- outcome store --------------------------------------------------------------

# Print the store's tail seq (0 for an empty store); 1 when the store refuses.
store_tail_seq() {
  local row
  row=$("$OUTCOME_BIN" list --recent 1 2>/dev/null) || return 1
  if [ -z "$row" ]; then
    printf '0\n'
  else
    printf '%s\n' "$row" | jq -r '.seq' 2>/dev/null
  fi
}

away_mode() {
  "$CONTRACT_BIN" mode 2>/dev/null || printf 'none\n'
}

# --- transport ----------------------------------------------------------------

# Seconds left before this run must stop to save its state in time.
time_left() {
  printf '%s\n' $((CHECK_TIMEOUT - DEADLINE_RESERVE - (SECONDS - START_SECONDS)))
}

# Post the JSON payload in <payload-file>. Sets T_KIND
# (ok|transient|permanent|deferred), T_REASON, T_ID. The URL travels to curl on
# stdin only.
transport_once() {  # <payload-file> <body-file>
  local payload=$1 body=$2 url code rc=0 max_time
  max_time=$(time_left)
  [ "$max_time" -le "$BUDGET" ] || max_time=$BUDGET
  if [ "$max_time" -lt 2 ]; then
    T_KIND=deferred; T_REASON="no time left in this run"; T_ID=
    return 0
  fi
  url=$WEBHOOK
  case "$url" in *\?*) url="$url&wait=true" ;; *) url="$url?wait=true" ;; esac
  : > "$body"
  if [ -n "${FM_CAPTAIN_ALERT_EXEC:-}" ]; then
    code=$(printf 'url = "%s"\n' "$url" | "$FM_CAPTAIN_ALERT_EXEC" "$payload" "$body" 2>/dev/null) || rc=$?
  else
    code=$(printf 'url = "%s"\n' "$url" | curl -sS --config - -o "$body" -w '%{http_code}' \
      --max-time "$max_time" -X POST -H 'Content-Type: application/json' \
      --data-binary "@$payload" 2>/dev/null) || rc=$?
  fi
  T_ID=
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      28) T_KIND=transient; T_REASON="request timed out" ;;
      *) T_KIND=transient; T_REASON="network error (curl exit $rc)" ;;
    esac
    return 0
  fi
  case "$code" in
    2??)
      T_ID=$(jq -r '.id // empty' "$body" 2>/dev/null)
      if [ -n "$T_ID" ]; then
        T_KIND=ok; T_REASON=
      else
        T_KIND=transient; T_REASON="Discord accepted the post without a message id"
      fi
      ;;
    429) T_KIND=ratelimited; T_REASON="rate limited by Discord" ;;
    400|401|403|404) T_KIND=permanent; T_REASON="webhook rejected: HTTP $code" ;;
    5??) T_KIND=transient; T_REASON="Discord server error (HTTP 5xx)" ;;
    *) T_KIND=transient; T_REASON="unexpected HTTP ${code:-status}" ;;
  esac
}

# One attempt plus at most one short wait on a 429 whose retry_after fits,
# leaving time for the retry itself inside the run's deadline.
transport() {  # <payload-file>
  local payload=$1 body wait_s
  body=$(mktemp "$STATE/.captain-alert-body.XXXXXX") || { T_KIND=transient; T_REASON="cannot create a scratch file"; return 0; }
  transport_once "$payload" "$body"
  if [ "$T_KIND" = ratelimited ]; then
    wait_s=$(jq -r '(.retry_after // 99) | ceil' "$body" 2>/dev/null)
    case "$wait_s" in ''|*[!0-9]*) wait_s=99 ;; esac
    if [ "$wait_s" -le 3 ] && [ $(($(time_left) - wait_s)) -ge 2 ]; then
      sleep "$wait_s"
      transport_once "$payload" "$body"
    fi
    [ "$T_KIND" != ratelimited ] || T_KIND=transient
  fi
  rm -f -- "$body"
}

# Build the payload for <content> into a new scratch file and print its path.
payload_file() {  # <content>
  local content=$1 file users='[]'
  if [ -n "$MENTION" ]; then
    content="<@$MENTION> $content"
    users=$(jq -cn --arg id "$MENTION" '[$id]')
  fi
  file=$(mktemp "$STATE/.captain-alert-payload.XXXXXX") || return 1
  # flags 4 is SUPPRESS_EMBEDS; SUPPRESS_NOTIFICATIONS (4096) is never set.
  # Truncate in jq, which counts characters; a bash slice here would count
  # bytes under LC_ALL=C and could split a multibyte character.
  jq -cn --arg content "$content" --argjson users "$users" \
    '{content: $content[0:2000], username: "XO", allowed_mentions: {parse: [], users: $users}, flags: 4}' \
    > "$file" || { rm -f -- "$file"; return 1; }
  printf '%s\n' "$file"
}

send_content() {  # <content>; sets T_KIND, T_REASON, T_ID
  local file
  file=$(payload_file "$1") || { T_KIND=transient; T_REASON="cannot build the message"; T_ID=; return 0; }
  transport "$file"
  rm -f -- "$file"
}

# --- composing ------------------------------------------------------------------

# Compose one message from the pending queue. Prints the content, or nothing
# when every waiting task is still inside its cooldown. Its last line is
# TASKS<tab> followed by the space-separated headlined tasks.
compose() {  # <now>
  local now=$1 cool_json
  # One jq turns the `task epoch` cooldown entries into a {task: epoch} map.
  cool_json=$(printf '%s\n' ${R_COOL[@]+"${R_COOL[@]}"} | jq -cnR '
    [inputs | capture("^(?<t>.+) (?<e>[0-9]+)$")? | {(.t): (.e | tonumber)}] | add // {}')
  jq -rs --argjson cool "$cool_json" --argjson now "$now" --argjson cd "$COOLDOWN" \
    --arg detail "$DETAIL" --argjson dropped "$R_DROPPED" --argjson max "$MAX_CONTENT" '
    def cut($n): if length > $n then .[0:$n - 3] + "..." else . end;
    def oneline: gsub("[\r\n\t]+"; " ");
    (group_by(.task) | map({task: .[0].task, n: length,
       summary: (max_by(.seq).summary // "" | oneline),
       last: (map(.seq) | max),
       hot: ((($cool[.[0].task] // 0) + $cd) <= $now)}) | sort_by(.last)) as $g
    | ($g | map(select(.hot))) as $hot
    | ($g | map(select(.hot | not))) as $cold
    | if ($hot | length) == 0 then empty else
      (map(.seq) | [min, max]) as $range
      | (length + $dropped) as $total
      | (if $detail == "brief" then
          "XO needs you: \($total) outcome\(if $total == 1 then "" else "s" end) across \($g | length) task\(if ($g | length) == 1 then "" else "s" end); details wait in XO."
        else
          ([ "XO needs you (\($total)):" ]
           + ($hot[0:5] | map("- \(.task): \(.summary | cut(350))" + (if .n > 1 then " (+\(.n - 1) more)" else "" end)))
           + (if ($hot | length) > 5 then ["- +\(($hot | length) - 5) more tasks"] else [] end)
           + ($cold[0:5] | map("- +\(.n) update\(if .n == 1 then "" else "s" end) on \(.task)"))
           + (if ($cold | length) > 5 then ["- +\(($cold | length) - 5) more tasks with updates"] else [] end)
           + (if $dropped > 0 then ["- +\($dropped) older outcomes not listed"] else [] end)
          ) | join("\n")
        end) as $body
      | ($body | cut($max - 24)) + "\n(outcomes \($range[0])-\($range[1]))"
      | ., ($hot | map(.task) | join(" ") | "TASKS\t" + .)
      end
  ' "$PENDING" 2>/dev/null
}

# --- reporting --------------------------------------------------------------------

# Print <line> as this check's one output line only when it differs from the
# last reported line; the record keeps it as the news key.
report_line() {  # <line or empty>
  local line=$1
  if [ -n "$line" ] && [ "$line" != "$R_REPORTED" ]; then
    fm_cap_line_var "captain alerts: $line" "$MAX_LINE"
    printf '%s\n' "$FM_LINE_CAP_LINE"
  fi
  R_REPORTED=$line
}

# Bounded by what is left of the run's deadline; callers save state first, so
# a slow or killed alarm cannot lose the failure it reports.
fallback_alarm() {  # <summary>
  local secs cmd
  secs=$(time_left)
  [ "$secs" -ge 1 ] || return 0
  cmd=${FM_CAPTAIN_ALERT_SENTINEL:-}
  _fm_wake_require_timeout
  if [ -n "$cmd" ]; then
    fm_run_timed "$secs" "$cmd" "$1" >/dev/null 2>&1 || true
  else
    fm_run_timed "$secs" "$SCRIPT_DIR/fm-afk-sentinel.sh" notify "$1" >/dev/null 2>&1 || true
  fi
}

# One failure episode runs from the first failed attempt to the next success,
# whatever mix of reasons it sees in between.
record_failure() {  # <now>
  local now=$1
  [ -n "$R_FAIL_KIND" ] && [ -n "$R_FAIL_SINCE" ] || R_FAIL_SINCE=$now
  R_FAIL_KIND=$T_KIND
  R_FAIL_REASON=$T_REASON
  R_FAIL_COUNT=$((R_FAIL_COUNT + 1))
  [ "$T_KIND" != permanent ] || R_FP=$(webhook_fingerprint)
  log_event fail "$T_REASON"
}

clear_failure() {
  R_FAIL_KIND=; R_FAIL_REASON=; R_FAIL_SINCE=; R_FAIL_COUNT=0; R_FALLBACK=
}

failure_line() {
  if [ -n "$R_FAIL_KIND" ] && { [ "$R_FAIL_KIND" = permanent ] || [ "$R_FAIL_COUNT" -ge 2 ]; }; then
    printf 'Discord delivery failing since %s: %s\n' "$(iso_of "$R_FAIL_SINCE")" "$R_FAIL_REASON"
  fi
}

pending_count() {
  if [ -s "$PENDING" ]; then wc -l < "$PENDING" | tr -d ' '; else printf '0\n'; fi
}

# --- check --------------------------------------------------------------------------

# Move new eligible rows into the pending queue in sequence order, at most
# MAX_SCAN rows past the cursor and never past <tail>, then advance the cursor
# to the last sequence taken. Rows past that point wait for the next sweep, so
# the cursor never moves past a row that was not ingested. The read asks for
# SCAN_SLACK extra rows so rows appended after the tail read cannot push the
# cursor's successor out of the window; if they did, the sweep takes nothing.
ingest() {  # <tail> <entered-epoch>
  local tail=$1 entered=$2 rows tmp limit lowest
  limit=$((R_CURSOR + MAX_SCAN))
  [ "$limit" -le "$tail" ] || limit=$tail
  rows=
  if [ "$limit" -gt "$R_CURSOR" ]; then
    rows=$("$OUTCOME_BIN" list --recent "$((tail - R_CURSOR + SCAN_SLACK))" 2>/dev/null) || return 1
    lowest=$(printf '%s\n' "$rows" | head -n 1 | jq -r '.seq // empty' 2>/dev/null)
    case "$lowest" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$lowest" -gt $((R_CURSOR + 1)) ]; then
      rows=
      limit=$R_CURSOR
    fi
  else
    limit=$R_CURSOR
  fi
  tmp=$(mktemp "$PENDING.XXXXXX") || return 1
  {
    [ ! -s "$PENDING" ] || cat "$PENDING"
    printf '%s\n' "$rows" | jq -c --argjson c "$R_CURSOR" --argjson t "$limit" --argjson e "$entered" '
      select(type == "object" and .seq > $c and .seq <= $t and .verdict == "captain"
             and (.silent // false) != true and (.epoch // 0) >= $e)
      | {seq, epoch, task: (.task // "fleet"), summary: (.summary // "")}' 2>/dev/null
  } | jq -cs --argjson e "$entered" 'map(select(.epoch >= $e)) | unique_by(.seq) | .[]' > "$tmp" \
    || { rm -f -- "$tmp"; return 1; }
  if [ "$(wc -l < "$tmp" | tr -d ' ')" -gt "$MAX_PENDING" ]; then
    R_DROPPED=$((R_DROPPED + $(wc -l < "$tmp" | tr -d ' ') - MAX_PENDING))
    tail -n "$MAX_PENDING" "$tmp" > "$tmp.cut" && mv -f -- "$tmp.cut" "$tmp"
  fi
  mv -f -- "$tmp" "$PENDING" || { rm -f -- "$tmp"; return 1; }
  R_CURSOR=$limit
}

drop_pending() {
  rm -f -- "$PENDING"
  R_DROPPED=0
}

sent_last_hour() {
  local now=$1 count=0 entry
  for entry in ${R_SENT[@]+"${R_SENT[@]}"}; do
    [ "$entry" -gt $((now - 3600)) ] 2>/dev/null && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

# One delivery attempt from the pending queue; returns after recording.
deliver() {  # <now>
  local now=$1 out content tasks task oldest next_open waiting
  if [ "$R_FAIL_KIND" = permanent ]; then
    if [ "$R_FP" = "$(webhook_fingerprint)" ]; then
      return 0
    fi
    clear_failure
  fi
  [ -s "$PENDING" ] || return 0
  waiting=$(pending_count)
  if [ "$(sent_last_hour "$now")" -ge "$HOURLY_CAP" ]; then
    if [ -n "$R_OVERFLOW" ] && [ "$R_OVERFLOW" -gt $((now - 3600)) ]; then
      return 0
    fi
    oldest=$now
    for task in ${R_SENT[@]+"${R_SENT[@]}"}; do
      if [ "$task" -lt "$oldest" ] 2>/dev/null; then oldest=$task; fi
    done
    next_open=$((oldest + 3600))
    send_content "XO: alert volume is high; $((waiting + R_DROPPED)) more outcomes need you and further alerts pause until $(iso_of "$next_open"). Details wait in XO."
    if [ "$T_KIND" = ok ]; then
      R_OVERFLOW=$now
      R_LAST_OK=$now
      DELIVERED=1
      clear_failure
      log_event overflow "$T_ID"
    elif [ "$T_KIND" != deferred ]; then
      record_failure "$now"
    fi
    return 0
  fi
  out=$(compose "$now")
  [ -n "$out" ] || return 0
  tasks=$(printf '%s\n' "$out" | sed -n 's/^TASKS	//p' | tail -n 1)
  content=$(printf '%s\n' "$out" | sed '/^TASKS	/d')
  send_content "$content"
  if [ "$T_KIND" = ok ]; then
    for task in $tasks; do
      local kept=() entry
      for entry in ${R_COOL[@]+"${R_COOL[@]}"}; do
        [ "${entry% *}" = "$task" ] || kept+=("$entry")
      done
      R_COOL=(${kept[@]+"${kept[@]}"} "$task $now")
    done
    R_SENT+=("$now")
    R_LAST_OK=$now
    log_event ok "$T_ID $waiting"
    DELIVERED=1
    drop_pending
    clear_failure
  elif [ "$T_KIND" != deferred ]; then
    record_failure "$now"
  fi
}

lock_or_skip() {
  local wait_s
  wait_s=$(($(time_left) - 2))
  [ "$wait_s" -le 8 ] || wait_s=8
  [ "$wait_s" -ge 1 ] || return 1
  fm_lock_acquire_wait_bounded "$LOCK" "$wait_s" >/dev/null 2>&1
}

RECOVERED_LINE="Discord delivery is working again"
DELIVERED=0

action_check() {
  local now mode tail entered line='' alarm=''
  armed || return 0
  lock_or_skip || return 0
  now=$(now_epoch)
  mode=$(away_mode)
  if ! command -v jq >/dev/null 2>&1; then
    record_read || R_CURSOR=
    line="jq is not installed, so nothing can be posted"
  elif ! tail=$(store_tail_seq); then
    record_read || R_CURSOR=
    line="cannot read the outcome store, so nothing is posted"
  else
    case "$tail" in ''|*[!0-9]*) tail=0 ;; esac
    # A missing or unreadable record restarts at the store tail, never earlier.
    record_read || { R_CURSOR=$tail; drop_pending; }
    [ "$R_CURSOR" -le "$tail" ] || R_CURSOR=$tail
    if [ "$mode" != away ]; then
      R_CURSOR=$tail
      drop_pending
      R_OVERFLOW=
      [ "$R_FAIL_KIND" = permanent ] || clear_failure
      load_config || line=$CONFIG_PROBLEM
      [ -n "$line" ] || line=$(failure_line)
    elif fm_afk_daemon_owns_supervision "$STATE"; then
      R_CURSOR=$tail
      drop_pending
      line="this home's away daemon records no captain outcomes, so nothing is posted while it supervises"
    elif ! load_config; then
      R_CURSOR=$tail
      drop_pending
      line=$CONFIG_PROBLEM
    else
      entered=$("$CONTRACT_BIN" field entered_epoch 2>/dev/null)
      case "$entered" in ''|*[!0-9]*) entered=0 ;; esac
      if ingest "$tail" "$entered"; then
        deliver "$now"
        line=$(failure_line)
        if [ -n "$line" ] && [ "$R_FALLBACK" != "$R_FAIL_SINCE" ]; then
          alarm="XO Discord alerts failing: $R_FAIL_REASON"
          R_FALLBACK=$R_FAIL_SINCE
        fi
      else
        line="cannot queue new outcomes, so nothing is posted"
      fi
    fi
  fi
  if [ -n "$line" ]; then
    report_line "$line"
  else
    # Recovery is news only after a reported delivery failure ends in a post;
    # any other cleared condition returns to silence without a line.
    case "$R_REPORTED" in
      "Discord delivery failing"*) [ "$DELIVERED" -eq 0 ] || report_line "$RECOVERED_LINE" ;;
    esac
    R_REPORTED=
  fi
  # Without a cursor there is no safe starting point to record yet.
  [ -z "$R_CURSOR" ] || record_write || true
  fm_lock_release "$LOCK"
  # The alarm runs last, after the failure and its once-per-episode mark are saved.
  [ -z "$alarm" ] || fallback_alarm "$alarm"
  return 0
}

# --- arm / disarm -----------------------------------------------------------------

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-captain-alert.sh - captain alert notifier shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-captain-alert.sh") check"
}

# Write the shim the way fm-mail-check.sh writes its trusted shim: refuse a
# symlink at the path and arrive by rename so the watcher never reads half a shim.
shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-captain-alert.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

action_arm() {
  local home tail
  command -v jq >/dev/null 2>&1 || { printf 'fm-captain-alert: jq is required\n' >&2; return 1; }
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
         printf 'fm-captain-alert: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
         return 1
       } ;;
  esac
  tail=$(store_tail_seq) || { printf 'fm-captain-alert: the outcome store refused a read; not arming\n' >&2; return 1; }
  case "$tail" in ''|*[!0-9]*) tail=0 ;; esac
  lock_or_skip || { printf 'fm-captain-alert: another alert action holds the lock\n' >&2; return 1; }
  record_read || true
  R_CURSOR=$tail
  drop_pending
  if ! record_write; then
    fm_lock_release "$LOCK"
    printf 'fm-captain-alert: could not write %s\n' "$RECORD" >&2
    return 1
  fi
  fm_lock_release "$LOCK"
  if ! shim_write "$(shim_content "$home")"; then
    rm -f -- "$CHECK_SHIM"
    printf 'fm-captain-alert: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM"
    printf 'fm-captain-alert: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh (cursor at outcome %s; nothing earlier is posted)\n' "$CHECK_ID" "$tail"
  load_config || printf 'note: %s; nothing is posted until it is\n' "$CONFIG_PROBLEM"
}

action_disarm() {
  if [ -e "$CHECK_SHIM" ] || [ -e "$CHECK_TRUST" ]; then
    "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null || return 1
  fi
  rm -f -- "$RECORD" "$PENDING" "$LOG"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

# --- status, test, post, reach, brief-line ----------------------------------------

action_status() {
  local configured
  if load_config; then configured=yes; else configured="no ($CONFIG_PROBLEM)"; fi
  printf 'configured: %s\n' "$configured"
  printf 'detail: %s\n' "$DETAIL"
  printf 'mention: %s\n' "$( [ -n "$MENTION" ] && printf 'yes' || printf 'no')"
  if armed && record_read; then
    printf 'armed: yes\n'
    printf 'cursor: %s\n' "$R_CURSOR"
    printf 'waiting: %s\n' "$(pending_count)"
  else
    printf 'armed: no\n'
    record_read || true
  fi
  printf 'last post: %s\n' "$( [ -n "$R_LAST_OK" ] && iso_of "$R_LAST_OK" || printf 'never')"
  printf 'last test: %s\n' "$( [ -n "$R_LAST_TEST" ] && iso_of "$R_LAST_TEST" || printf 'never')"
  if [ -n "$R_FAIL_KIND" ]; then
    printf 'failure: %s since %s: %s\n' "$R_FAIL_KIND" "$(iso_of "$R_FAIL_SINCE")" "$R_FAIL_REASON"
  else
    printf 'failure: none\n'
  fi
}

action_test() {
  local now have_record=0
  load_config || { printf 'fm-captain-alert: %s\n' "$CONFIG_PROBLEM" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { printf 'fm-captain-alert: jq is required\n' >&2; return 1; }
  now=$(now_epoch)
  send_content "XO test alert ($(iso_of "$now")): this is a test of XO captain alerts. If it reached your phone, alerts work. Nothing needs you."
  if [ "$T_KIND" != ok ]; then
    printf 'fm-captain-alert: test post failed: %s\n' "$T_REASON" >&2
    return 1
  fi
  printf 'Discord accepted message %s; confirm it reached your phone\n' "$T_ID"
  if lock_or_skip; then
    record_read && have_record=1
    if [ "$have_record" -eq 1 ]; then
      R_LAST_TEST=$now
      R_LAST_OK=$now
      clear_failure
      record_write || true
    fi
    fm_lock_release "$LOCK"
  fi
  return 0
}

action_post() {
  [ "$#" -ge 1 ] && [ -n "$1" ] || die_usage "post needs the message text"
  load_config || { printf 'fm-captain-alert: %s\n' "$CONFIG_PROBLEM" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { printf 'fm-captain-alert: jq is required\n' >&2; return 1; }
  send_content "$1"
  if [ "$T_KIND" != ok ]; then
    printf 'fm-captain-alert: post failed: %s\n' "$T_REASON" >&2
    return 1
  fi
  printf 'Discord accepted message %s\n' "$T_ID"
}

action_reach() {
  if armed && record_read && load_config \
    && { [ "$R_FAIL_KIND" != permanent ] || [ "$R_FP" != "$(webhook_fingerprint)" ]; }; then
    printf 'discord %s\n' "$( [ -n "$R_LAST_TEST" ] && iso_of "$R_LAST_TEST" || printf 'never')"
  else
    printf 'none\n'
  fi
}

action_brief_line() {
  local since posted
  [ "${1:-}" = --since ] || die_usage "brief-line needs --since <epoch>"
  since=${2:-}
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  armed || return 0
  record_read || return 0
  posted=0
  if [ -s "$LOG" ]; then
    posted=$(awk -F '\t' -v s="$since" '$1 >= s && ($2 == "ok" || $2 == "overflow") { n++ } END { print n + 0 }' "$LOG")
  fi
  # Any persisted failure is a gap here, even one the check line has not
  # reported yet: the return is the last chance to show it.
  if [ -n "$R_FAIL_KIND" ]; then
    printf 'GAP: Discord alerts failing since %s (%s); %s outcomes not posted\n' \
      "$(iso_of "$R_FAIL_SINCE")" "$R_FAIL_REASON" "$(( $(pending_count) + R_DROPPED ))"
  elif ! load_config; then
    printf 'GAP: Discord alerts are armed but not configured (%s)\n' "$CONFIG_PROBLEM"
  else
    printf 'Discord alerts: %s posted during the away window\n' "$posted"
  fi
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  status) action_status ;;
  test) action_test ;;
  post) shift; action_post "$@" ;;
  reach) action_reach ;;
  brief-line) shift; action_brief_line "$@" ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
