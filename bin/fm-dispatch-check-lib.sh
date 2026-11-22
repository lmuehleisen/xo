# shellcheck shell=bash
# fm-dispatch-check-lib.sh - the guided top-lane check and its shadow lane pick.
# Usage: . bin/fm-dispatch-check-lib.sh
#
# This file is the single owner of the checker's guided prompt, its bounded
# harness invocation, its answer parsing, and the never-send matching that
# bin/fm-dispatch-resolve.sh also applies to its router request.
# docs/configuration.md "Top-lane check" owns the operator contract and the
# config/crew-dispatch.json lane_check fields (bin/fm-dispatch-lanes-lib.sh
# owns their structural checks); bin/fm-dispatch-resolve.sh decides when a
# pick acts on the dispatch.
#
# fm_dispatch_check_config <rules-file>
#   Prints the lane_check object as compact JSON, or nothing when it is absent.
#
# fm_dispatch_check_prompt <rules-file> <task-text-file> <project>
#   Prints the whole prompt: the fixed guided instructions below, every lane
#   rule's name, when text, model classes, and captain-approval flag in
#   configured order, a cost note naming lane_check.top_lanes, the project, and
#   the task text. Quota, routes, why text, and data policies are never sent.
#
# fm_dispatch_check_run <rules-file> <task-text-file> <project> <never-send-list> [<cache-file>]
#   Runs one check and prints one compact JSON object, always exiting 0:
#     {ran: true, pick, reason, checker, latency_ms, cached, digest}
#     {ran: false, not_run, checker, latency_ms, cached: false, digest}
#   checker is <harness>:<model>[:<effort>]. The pick is a declared lane name
#   and reason is one line of at most 300 characters. not_run names why no
#   pick exists: the harness is not installed on this host, the never-send list
#   matched or could not be read (nothing sent), the harness exited nonzero
#   (missing login or quota surface here), the timeout_seconds bound (default
#   FM_DISPATCH_CHECK_DEFAULT_TIMEOUT) was hit, or the answer named no
#   declared lane. The harness runs in an empty scratch directory with no tools,
#   no session persistence, no user settings or MCP servers (claude), or a
#   read-only ephemeral session that ignores user config (codex), the prompt
#   on stdin, and DISABLE_AUTOUPDATER=1. A cache file, when given, holds the
#   last successful pick keyed by a digest of the checker and the full prompt;
#   a matching digest is reused with cached: true and no model call, so a
#   rerun on an unchanged brief and lane text gets the same answer.
#
# fm_dispatch_never_send_scan <list-file> <text-file>
#   Matches every non-blank, non-# list line as a case-insensitive literal
#   against the text, trimming each entry and treating every whitespace run in
#   the entry as one space (the caller collapses the text the same way).
#   Returns 0 with no match, 1 on a match after printing its line number, and 2
#   when the check could not complete after printing the line number reached
#   (0 when the list itself could not be read). It never prints a value.

FM_DISPATCH_CHECK_DEFAULT_TIMEOUT=15
_FM_DISPATCH_CHECK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-timeout-lib.sh
declare -F fm_run_timed >/dev/null 2>&1 || . "$_FM_DISPATCH_CHECK_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
declare -F fm_timing_now_ms >/dev/null 2>&1 || . "$_FM_DISPATCH_CHECK_DIR/fm-timing-lib.sh"

# The guided instructions: the "primed" rater prompt of the routing study,
# kept here as the one tracked copy.
FM_DISPATCH_CHECK_INSTRUCTIONS=$(cat <<'TXT'
You are rating which dispatch lane a task should be routed to. Below are the lane definitions of the project's dispatch configuration and the text of one task brief. Pick the single lane this task should be dispatched to, ex ante, from the text alone. Apply each lane's own "When" text and its "Not ..." exclusions literally. Words such as "security", "auth", "permissions", safety fences, or long and detailed instructions do not by themselves make a task hard; judge the actual work required.
TXT
)
FM_DISPATCH_CHECK_ANSWER=$(cat <<'TXT'
Answer with a JSON object only: {"lane": "<one lane name from # Lanes>", "reason": "<one sentence>"}. Do not run any commands or read any files; everything you need is above.
TXT
)

fm_dispatch_check_config() {  # <rules-file>
  jq -c '.lane_check // empty | objects' "$1" 2>/dev/null || true
}

fm_dispatch_check_prompt() {  # <rules-file> <task-text-file> <project>
  jq -r --arg head "$FM_DISPATCH_CHECK_INSTRUCTIONS" --arg tail "$FM_DISPATCH_CHECK_ANSWER" \
    --arg project "$3" --rawfile task "$2" '
    def class_names: [.classes[] | if type == "string" then . else .class end] | join(", ");
    [(.rules // [])[] | objects | select(has("classes"))] as $lanes |
    (.lane_check.top_lanes // []) as $top |
    $head, "", "# Lanes", "",
    ($lanes[] |
      "## \(.lane)", "When: \(.when)", "Model classes: \(class_names)",
      (if .approval == "captain" then "Requires captain approval." else empty end), ""),
    "## Cost and strength",
    "The top lanes, \($top | join(" and ")), use the strongest and scarcest models, and a lane that requires captain approval is the most expensive; the other lanes use cheaper models. A lane that is too high wastes scarce strong-model quota; a lane that is too low risks rework, review findings, stalls, or failure.",
    "", "# Task", "",
    (if $project != "" then "Project: \($project)" else empty end),
    ($task | sub("\\s+\\z"; "")), "", $tail
  ' "$1"
}

fm_dispatch_never_send_scan() {  # <list-file> <text-file>
  local list value n=0 rc
  list=$(jq -Rr 'gsub("\\s+"; " ")' "$1" 2>/dev/null) || { printf '0\n'; return 2; }
  while IFS= read -r value; do
    n=$((n + 1))
    value=${value# }
    value=${value% }
    case "$value" in
      ''|'#'*) continue ;;
    esac
    grep -qiF -e "$value" "$2" 2>/dev/null; rc=$?
    case "$rc" in
      0) printf '%s\n' "$n"; return 1 ;;
      1) ;;
      *) printf '%s\n' "$n"; return 2 ;;
    esac
  done <<<"$list"
  return 0
}

_fm_dispatch_check_sha256() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  fi
}

# One result object; <fields> is a JSON object merged last.
_fm_dispatch_check_result() {  # <checker> <digest> <latency-ms|null> <fields>
  jq -cn --arg checker "$1" --arg digest "$2" --argjson latency "$3" --argjson f "$4" \
    '{ran: false, checker: $checker, latency_ms: $latency, cached: false,
      digest: ($digest | select(. != "") // null)} + $f'
}

fm_dispatch_check_run() {  # <rules-file> <task-text-file> <project> <never-send-list> [<cache-file>]
  local rules=$1 task=$2 project=$3 never=$4 cache=${5:-}
  local cfg harness='' model='' effort='' timeout=$FM_DISPATCH_CHECK_DEFAULT_TIMEOUT checker
  local dir='' digest='' exe rc n t0 latency=null answer='' lanes why=''
  cfg=$(fm_dispatch_check_config "$rules")
  if [ -n "$cfg" ]; then
    harness=$(jq -r '.harness // ""' <<<"$cfg")
    model=$(jq -r '.model // ""' <<<"$cfg")
    effort=$(jq -r '.effort // ""' <<<"$cfg")
    timeout=$(jq -r --argjson d "$FM_DISPATCH_CHECK_DEFAULT_TIMEOUT" '.timeout_seconds // $d' <<<"$cfg")
  fi
  checker="$harness:$model${effort:+:$effort}"
  if [ -z "$cfg" ]; then
    why="no lane_check configured"
  elif ! dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-dispatch-check.XXXXXX" 2>/dev/null) || ! mkdir "$dir/cwd"; then
    why="could not create a scratch directory"
  elif ! fm_dispatch_check_prompt "$rules" "$task" "$project" > "$dir/prompt" 2>/dev/null; then
    why="could not build the prompt"
  else
    { printf '%s\n' "$checker"; cat "$dir/prompt"; } > "$dir/prompt.key"
    digest=$(_fm_dispatch_check_sha256 "$dir/prompt.key")
    if [ -e "$never" ] || [ -L "$never" ]; then
      if ! { [ -f "$never" ] && [ -r "$never" ]; }; then
        why="the never-send list is not a readable regular file; nothing sent"
      elif ! jq -Rrs 'gsub("\\s+"; " ")' "$dir/prompt" > "$dir/flat" 2>/dev/null; then
        why="could not check the prompt against the never-send list; nothing sent"
      else
        n=$(fm_dispatch_never_send_scan "$never" "$dir/flat"); rc=$?
        case "$rc" in
          0) ;;
          1) why="task text matches the never-send list line $n; nothing sent" ;;
          *) why="could not check the prompt against the never-send list; nothing sent" ;;
        esac
      fi
    fi
    if [ -z "$why" ] && [ -n "$cache" ] && [ -n "$digest" ] && [ -f "$cache" ] \
      && answer=$(jq -cse --arg d "$digest" --slurpfile cfg "$rules" '
        select(length == 1) | .[0] |
        select(.digest == $d and .ran == true and (.reason | type == "string" and test("\\S")) and
          (.pick as $l | any($cfg[0].rules[]; has("classes") and .lane == $l))) |
        . + {cached: true, latency_ms: 0}' "$cache" 2>/dev/null); then
      printf '%s\n' "$answer"
      rm -rf "$dir"
      return 0
    fi
    if [ -z "$why" ] && ! exe=$(type -P -- "$harness"); then
      why="$harness not installed on this host"
    fi
  fi
  if [ -n "$why" ]; then
    _fm_dispatch_check_result "$checker" "$digest" null "$(jq -cn --arg why "$why" '{not_run: $why}')"
    [ -z "$dir" ] || rm -rf "$dir"
    return 0
  fi
  lanes=$(jq -c '[(.rules // [])[] | objects | select(has("classes")) | .lane]' "$rules")
  jq -cn --argjson lanes "$lanes" '{type: "object", additionalProperties: false, required: ["lane", "reason"],
    properties: {lane: {type: "string", enum: $lanes}, reason: {type: "string"}}}' > "$dir/schema.json"
  t0=$(fm_timing_now_ms)
  case "$harness" in
    claude)
      ( cd "$dir/cwd" && fm_run_timed "$timeout" env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT DISABLE_AUTOUPDATER=1 \
          "$exe" -p --model "$model" ${effort:+--effort "$effort"} --tools "" --no-session-persistence \
          --setting-sources "" --strict-mcp-config --output-format json --json-schema "$(cat "$dir/schema.json")" \
          < "$dir/prompt" > "$dir/out" 2> /dev/null )
      rc=$?
      answer=$(jq -c 'select(.is_error != true) | (.structured_output // (.result | strings | fromjson?)) | objects' \
        "$dir/out" 2>/dev/null) || answer=''
      ;;
    codex)
      ( cd "$dir/cwd" && fm_run_timed "$timeout" "$exe" exec -m "$model" ${effort:+-c "model_reasoning_effort=$effort"} \
          --disable shell_tool --disable unified_exec --disable apps --disable plugins --disable multi_agent \
          -c web_search=disabled \
          -s read-only --skip-git-repo-check --ephemeral --ignore-user-config -c project_doc_max_bytes=0 \
          --output-schema "$dir/schema.json" -o "$dir/out" - \
          < "$dir/prompt" > /dev/null 2>&1 )
      rc=$?
      answer=$(jq -c 'objects' "$dir/out" 2>/dev/null) || answer=''
      ;;
    *) rc=1 why="unsupported checker harness $harness" ;;
  esac
  latency=$(( $(fm_timing_now_ms) - t0 ))
  if [ -n "$why" ]; then
    :
  elif fm_timed_out "$rc"; then
    why="timed out after ${timeout}s"
  elif [ "$rc" -ne 0 ]; then
    why="$harness exited $rc"
  elif ! answer=$(jq -cse --argjson lanes "$lanes" '
      select(length == 1) | .[0] |
      select((.lane | type) == "string" and (.lane as $l | $lanes | index($l)) != null)
      | select(.reason | type == "string" and test("\\S"))
      | {ran: true, pick: .lane, reason: (.reason | gsub("[[:cntrl:]\\s]+"; " ") | .[0:300])}' \
      <<<"$answer" 2>/dev/null); then
    why="the answer named no declared lane"
  fi
  rm -rf "$dir"
  if [ -n "$why" ]; then
    _fm_dispatch_check_result "$checker" "$digest" "$latency" "$(jq -cn --arg why "$why" '{not_run: $why}')"
    return 0
  fi
  answer=$(_fm_dispatch_check_result "$checker" "$digest" "$latency" "$answer")
  if [ -n "$cache" ] && [ -n "$digest" ]; then
    ( umask 077; printf '%s\n' "$answer" > "$cache.tmp.$$" && mv -f -- "$cache.tmp.$$" "$cache" ) 2>/dev/null \
      || rm -f -- "$cache.tmp.$$" 2>/dev/null
  fi
  printf '%s\n' "$answer"
  return 0
}
