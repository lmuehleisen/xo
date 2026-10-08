#!/usr/bin/env bash
# fm-dispatch-resolve.sh - resolve one concrete crewmate or scout dispatch
# profile from a task brief with typesafe.ai's System One model (Jev), opt-in.
#
# Usage:
#   fm-dispatch-resolve.sh <brief-file> [--project <name>] [--completion-horizon <seconds>]
#                          [--lane <name>] [--exclude-family <family>] [--data-tag <tag>]...
#
# Opt-in gate: TYPESAFE_API_KEY non-empty in this process environment, else a
#   TYPESAFE_API_KEY= line in $FM_HOME/.env read with fmx_env_get, the same
#   accessor as FMX_PAIRING_TOKEN (bin/fm-env-lib.sh). The environment wins.
#   TypeSafe wins when both keys exist; otherwise OPENROUTER_API_KEY is read
#   only from $FM_HOME/.env, never the environment, as deliberate opt-in.
#   Absent for both providers: one "dispatch-resolve: off" line on stderr, nothing on
#   stdout, exit 0, no network call, so firstmate dispatches exactly as today.
#   The key lives in one shell variable and reaches curl as a header read from
#   a file descriptor, never on argv; nothing logs or writes it.
#
# What it does when on with at least one rule: one POST to
#   https://api.typesafe.ai/v1/systemone (jev-latest), or
#   https://openrouter.ai/api/v1/systemone (~typesafe/jev-latest),
#   with the project name and the brief's
#   `## Captain's intent` and `## Firstmate spec` sections, tagged when it is a
#   scout brief (the whole brief when it has neither section), as state and
#   ONE Choice question whose options are every rule's `when` from
#   config/crew-dispatch.json plus one fixed generic none option. Jev returns
#   the matched rule, a probability per option, and a confidence. Everything
#   after that is jq: the confidence floor (0.6 on the answer confidence, or a
#   rule's declared `min_confidence` on that rule's probability, falling to the
#   most probable other option that clears its own floor), the rule's declared
#   `approval` and `floor`, each profile's declared `provider` and `floor`, the
#   quota rows from ONE quota-axi --json snapshot (schema 5 or 6; each
#   candidate binds to one row through quota_row in
#   bin/fm-quota-axi-lib.sh, so a Pi lane such as openai-codex-work/...
#   reads its own account's row and an expanded provider with no row for the
#   candidate is unmeasured, never blocked), and the spendPriority argmax over
#   the eligible candidates after the completion-horizon gate. The model never
#   sees quota, catalogs, approvals,
#   confidence floors, `why`, or `use`. With no rules, it returns a non-clear
#   result so firstmate keeps using the existing intake.
#   docs/configuration.md "Crew dispatch profiles" owns the declared fields and
#   "Typed dispatch resolution" owns this tool's operator contract.
#
# Lanes: a rule with `classes` is a lane (bin/fm-dispatch-lanes-lib.sh owns its
#   structural checks). Each class route is evaluated like a profile, except a
#   class declared unmetered receives a fixed neutral spendPriority of 0 and
#   skips provider quota evidence; its other eligibility gates still apply.
#   Code picks: a sampled experiment class with a rankable route first; in
#   an `ordered` lane the first class with any eligible route, ranked inside
#   that class; in a `pool` lane the spendPriority argmax over every class.
#   A class gated `others-ahead-of-pace` stays eligible only while every
#   rankable route of the lane's ungated classes has spendPriority below 0 and
#   its own best route has spendPriority of 0 or more. An experiment class is
#   sampled when the brief text's cksum modulo 100 is below share x 100, so a
#   rerun on the same brief gives the same answer. A class bound to a data
#   policy is not eligible unless --project is in its allow_projects or a
#   --data-tag is in its allow_tags, and never with a --data-tag in deny_tags.
#   --exclude-family drops every class of that family plus every experiment
#   class, for a second opinion; it needs a lane, so a `use` rule or the
#   default escalates.
#   --lane <name> resolves that lane rule directly: no Choice request, so no
#   API key, curl, or never-send check is needed; it still reads the
#   one quota snapshot.
#
# Never-send check: when the optional $FM_HOME/config/dispatch-never-send list
#   exists, every string value of the built request is checked against it
#   before the POST. Each non-blank, non-# line is a literal matched
#   case-insensitively, with surrounding whitespace trimmed and every run of
#   whitespace, on both sides, treated as one space. A match, or a list that
#   is not a readable regular file, prints one
#   "dispatch-resolve: off (...; nothing sent)" line on stderr naming at most
#   the list line number, never its value, prints nothing on stdout, and exits
#   0 with no network or quota call, exactly like the absent-key off path.
#
# Output (stdout, TOON-style block):
#   dispatch-resolve:
#     status: clear | ambiguous | escalate | error
#     model/latency_ms/tokens, rule (when excerpt) and confidence, probabilities
#     fallback: <runner-up rule taken when the picked rule missed its own floor>
#     reason: <why the status is not clear>
#     lane: <name> order=<ordered|pool>   (lane rules; exclude_family and data_tags when given)
#     experiment: <class> share=.. bucket=.. -> sampled | not sampled | excluded
#     candidate: <harness>:<model> [class=.. family=..] provider=.. scope=.. remaining=..% spendPriority=.. runway=.. -> eligible | eligible, unranked: <reason> | not eligible: <reason>
#     Unmetered class routes print quota=unmetered (declared), spendPriority=0, runway=unmetered; these are declared facts, not measured quota.
#     class: <name> family=<family> [experiment]   (lane rules, status clear only)
#     profile: --harness <h> [--model <m>] [--effort <e>]     (status clear only)
#   clear     -> pass the profile line to fm-spawn.sh unless you state a reason to override
#   ambiguous -> confidence below the floor; decide as today from the probabilities
#   escalate  -> the rule requires captain approval, no candidate is rankable, or a genuine tie
#   error     -> API, network, response, or quota-axi failure; decide as today
#   Every outcome exits 0 so an intake is never blocked by this tool.
#   Exit 2 only for a usage or configuration error (unreadable brief, an
#   existing unreadable rules file, malformed rules, missing jq, an unknown
#   --lane, an undeclared --exclude-family or --data-tag), which is
#   actionable, never selected around.
#
# Runway gate: --completion-horizon is a positive number of seconds (default
#   3600, a conservative one-hour completion budget). The output discloses it
#   and each bound's usableRunwaySeconds; unknown runway remains unranked.
#
# Environment:
#   TYPESAFE_API_KEY activates resolution; OPENROUTER_API_KEY is ignored here
#   and is accepted only from the home .env.
#
# Authority: this tool never replaces firstmate's judgment, quota-array-dispatch,
#   the captain-approval gate, or fm-spawn.sh validation; it publishes one
#   inspectable answer plus every candidate's evidence, in code.
set -u

DISPATCH_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n DISPATCH_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY OPENROUTER_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-dispatch-lanes-lib.sh
. "$SCRIPT_DIR/fm-dispatch-lanes-lib.sh"
# shellcheck source=bin/fm-agy-lib.sh
. "$SCRIPT_DIR/fm-agy-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-codex-catalog-lib.sh
. "$SCRIPT_DIR/fm-codex-catalog-lib.sh"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"

CONFIDENCE_FLOOR=0.6
TS_MODEL=jev-latest
TS_BASE=https://api.typesafe.ai
TS_TIMEOUT=5
DEFAULT_WHEN="No listed rule applies to this task."

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
no_rules() {
  printf 'dispatch-resolve:\n  status: escalate\n  reason: no rules to match\n'
  exit 0
}
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

COMPLETION_HORIZON=3600
BRIEF='' PROJECT='' RULES_PATH="$CONFIG/crew-dispatch.json" RULES=''
NEVER_SEND_PATH="$CONFIG/dispatch-never-send"
LANE='' EXCLUDE_FAMILY='' DATA_TAGS='[]'
while [ $# -gt 0 ]; do
  case "$1" in
    --lane) [ $# -ge 2 ] && [ -n "$2" ] || die "--lane needs a lane name"; LANE=$2; shift 2 ;;
    --exclude-family) [ $# -ge 2 ] && [ -n "$2" ] || die "--exclude-family needs a family"; EXCLUDE_FAMILY=$2; shift 2 ;;
    --data-tag)
      [ $# -ge 2 ] && [ -n "$2" ] || die "--data-tag needs a tag"
      command -v jq >/dev/null 2>&1 || die "jq required"
      DATA_TAGS=$(jq -c --arg t "$2" '. + [$t] | unique' <<<"$DATA_TAGS")
      shift 2 ;;
    --completion-horizon)
      [ $# -ge 2 ] || die "--completion-horizon needs seconds"
      COMPLETION_HORIZON=$2
      if ! [[ "$COMPLETION_HORIZON" =~ ^[0-9]+(\.[0-9]+)?$ ]] ||
          ! jq -en --arg n "$COMPLETION_HORIZON" '($n | tonumber) > 0 and ($n | tonumber | isinfinite | not)' >/dev/null 2>&1; then
        die "--completion-horizon needs finite positive seconds"
      fi
      shift 2 ;;
    --project) [ $# -ge 2 ] || die "--project needs a value"; PROJECT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$BRIEF" ] || die "one brief file only"; BRIEF=$1; shift ;;
  esac
done

# ---- opt-in gate ---------------------------------------------------------------
# A named --lane sends no Choice request, so it needs no key.
if [ -z "$LANE" ]; then
  if [ -z "$DISPATCH_API_KEY_PRIVATE" ]; then
    DISPATCH_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
  fi
  if [ -z "$DISPATCH_API_KEY_PRIVATE" ]; then
    DISPATCH_API_KEY_PRIVATE=$(fmx_env_get OPENROUTER_API_KEY "$FM_HOME/.env")
    TS_BASE=https://openrouter.ai/api
    TS_MODEL='~typesafe/jev-latest'
  fi
  if [ -z "$DISPATCH_API_KEY_PRIVATE" ]; then
    echo "dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env; OPENROUTER_API_KEY absent from $FM_HOME/.env)" >&2
    exit 0
  fi
fi

# ---- inputs --------------------------------------------------------------------
[ -n "$BRIEF" ] || die "brief file required (see --help)"
[ -r "$BRIEF" ] || die "brief file not readable: $BRIEF"
if [ -n "$LANE" ] && [ ! -e "$RULES_PATH" ] && [ ! -L "$RULES_PATH" ]; then
  die "--lane $LANE needs $RULES_PATH to declare that lane"
fi
[ -e "$RULES_PATH" ] || [ -L "$RULES_PATH" ] || no_rules
[ -r "$RULES_PATH" ] || die "rules file not readable: $RULES_PATH"
command -v jq >/dev/null 2>&1 || die "jq required"
RULES=$(mktemp) || die "mktemp failed"
trap 'rm -f "$RULES"' EXIT
cp "$RULES_PATH" "$RULES" || die "could not snapshot rules file: $RULES_PATH"
chmod 400 "$RULES" || die "could not protect rules snapshot"
VERIFIED_HARNESSES=$(fm_control_harnesses | jq -Rsc 'split("\n") | map(select(length > 0))')

# The fields this tool consumes must be well formed; bootstrap owns the wider
# schema diagnostic, but an intake never selects around a malformed file.
# effort_ok must accept exactly what bootstrap's crew_dispatch_validate accepts.
# Codex max follows the installed catalog (bin/fm-codex-catalog-lib.sh).
codex_max_ok=$({ jq -r '.. | objects | select(.harness == "codex" and .effort == "max") | .model | strings' "$RULES" 2>/dev/null || true; } | fm_codex_max_allowed_json)
rules_err=$(jq -r --argjson codex_max_ok "$codex_max_ok" --argjson verified_harnesses "$VERIFIED_HARNESSES" --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" "$FM_DISPATCH_LANES_JQ"'
  def verified($h): $verified_harnesses | index($h);
  def provider_id($p): ($p | type) == "string" and ($p | test($provider_re));
  def effort_ok($h; $m; $e):
    if $e == null then true
    elif ($e | type) != "string" then false
    elif $e == "ultra" then (($h == "pi" or $h == "pi-signed") and (($m | type) == "string") and ($m | startswith("codex-native/")) and ($m | length) > 13)
    elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "codex" then ((["low","medium","high","xhigh"] | index($e)) != null or ($e == "max" and ($codex_max_ok | any(. == $m))))
    elif $h == "grok" then (["low","medium","high"] | index($e)) != null
    elif $h == "agy" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "pi" or $h == "pi-signed" or $h == "omp" or $h == "muse" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "rovo" then (["low","medium","high","max"] | index($e)) != null
    elif $h == "opencode" or $h == "kimi" or $h == "cursor" or $h == "gemini" or $h == "devin" then false
    else true end;
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def floor_bad($f; $need_provider):
    ($f | type) != "object"
    or (($f.scope | type) != "string") or (($f.scope | length) == 0)
    or (($f.min_percent | type) != "number") or ($f.min_percent < 0) or ($f.min_percent > 100)
    or (if $need_provider
        then (provider_id($f.provider) | not)
        else ($f | has("provider"))
        end);
  def profile_bad($p):
    ($p | type) != "object"
    or (($p.harness | type) != "string") or (($p.harness | length) == 0)
    or ($p | has("model") and ((.model | type) != "string" or (.model | length) == 0))
    or ($p | has("effort") and ((.effort | type) != "string" or (.effort | length) == 0))
    or ($p | has("provider") and (provider_id(.provider) | not))
    or ($p | has("floor") and floor_bad(.floor; false));
  def duplicate_profiles($items):
    ($items | map([.harness, (.model // null), (.effort // null)] | @json)) as $keys
    | ($keys | length) != ($keys | unique | length);
  if type != "object" then "top-level value must be an object"
  elif has("rules") and (.rules | type) != "array" then "rules must be an array"
  elif any((.rules // [])[]; type != "object") then "each rule must be an object"
  elif any((.rules // [])[]; (.when | type) != "string" or (.when | length) == 0) then "each rule needs non-empty when"
  elif (dispatch_lanes_error // null) != null then dispatch_lanes_error
  elif any(([(.rules // [])[] | profiles(.use)[]] + profiles(.default // null))[]; type == "object" and has("unmetered")) then "unmetered must be declared on a lane class, not a profile"
  elif any((.rules // [])[]; (has("classes") | not) and (profiles(.use) | length) == 0) then "each rule needs at least one use profile"
  elif any((.rules // [])[]; has("approval") and .approval != "captain") then "approval must be \"captain\" when present"
  elif any((.rules // [])[]; has("min_confidence") and ((.min_confidence | type) != "number" or .min_confidence < 0 or .min_confidence > 1)) then "min_confidence must be a number from 0 through 1 when present"
  elif any((.rules // [])[]; has("select") and ((.select | type) != "string" or (.select | length) == 0)) then "select must be a non-empty string"
  elif any((.rules // [])[]; has("select") and .select != "quota-balanced") then
    "unknown select: " + ([.rules[] | select(has("select") and .select != "quota-balanced") | .select] | unique | join(", "))
  elif any((.rules // [])[]; has("floor") and floor_bad(.floor; true)) then "rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\\z"
  elif any((.rules // [])[] | profiles(.use)[]; profile_bad(.)) then "each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif any((.rules // [])[]; duplicate_profiles(profiles(.use))) then "each rule use must not contain duplicate harness, model, and effort profiles"
  elif any((.rules // [])[] | profiles(.use)[]; (verified(.harness) | not)) then "each use profile must name a verified harness"
  elif any((.rules // [])[] | profiles(.use)[]; (effort_ok(.harness; .model; .effort) | not)) then "each use profile effort must be supported by its harness and model"
  elif any(dispatch_class_routes[]; (verified(.harness) | not)) then "each class route must name a verified harness"
  elif any(dispatch_class_routes[]; (effort_ok(.harness; .model; .effort) | not)) then "each class route effort must be supported by its harness and model"
  elif has("default") and (profiles(.default) | length) == 0 then "default must be a profile object or non-empty profile array"
  elif has("default") and any(profiles(.default)[]; profile_bad(.)) then "each default profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif has("default") and duplicate_profiles(profiles(.default)) then "default must not contain duplicate harness, model, and effort profiles"
  elif has("default") and any(profiles(.default)[]; (verified(.harness) | not)) then "each default profile must name a verified harness"
  elif has("default") and any(profiles(.default)[]; (effort_ok(.harness; .model; .effort) | not)) then "each default profile effort must be supported by its harness and model"
  else empty end
' "$RULES" 2>/dev/null) || die "malformed rules file: $RULES_PATH (not JSON)"
[ -z "$rules_err" ] || die "malformed rules file: $RULES_PATH - $rules_err"

missing_provider=$(jq -r '
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  ((.rules // [])[] | profiles(.use)[] | select(has("provider") | not) | "use\t\(.harness)"),
  (profiles(.default // null)[] | select(has("provider") | not) | "default\t\(.harness)"),
  ((.classes // {}) | to_entries[] | .key as $class | .value.routes[] | select(has("provider") | not) | "class \($class)\t\(.harness)")
' "$RULES" | while IFS=$'\t' read -r location harness; do
  if ! fm_quota_single_provider_for_harness "$harness" >/dev/null; then
    printf '%s\t%s\n' "$location" "$harness"
  fi
done)
if [ -n "$missing_provider" ]; then
  missing_provider_detail=''
  while IFS=$'\t' read -r location harness; do
    missing_provider_detail="${missing_provider_detail:+$missing_provider_detail; }$location profiles whose harness lacks one authoritative provider family require provider: $harness"
  done <<< "$missing_provider"
  die "malformed rules file: $RULES_PATH - $missing_provider_detail"
fi

# ---- harness -> provider map, from the single owner in fm-quota-axi-lib.sh -----
PMAP='{}'
while IFS= read -r h; do
  [ -n "$h" ] || continue
  p=$(fm_quota_single_provider_for_harness "$h" 2>/dev/null) || p=''
  PMAP=$(jq -c --arg h "$h" --arg p "$p" '. + {($h): (if $p == "" then null else $p end)}' <<<"$PMAP")
done < <(jq -r "$FM_DISPATCH_LANES_JQ"'
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  ([((.rules // [])[]) | profiles(.use)[]] + profiles(.default // null) + dispatch_class_routes)
  | map(.harness) | unique | .[]' "$RULES")

RULE_COUNT=$(jq -r '(.rules // []) | length' "$RULES")

# Lane, second-opinion, and data-tag arguments must name what the rules declare;
# a typo is a usage error rather than a silently unapplied exclusion or policy.
DIRECT_CHOICE=''
if [ -n "$LANE" ]; then
  DIRECT_CHOICE=$(jq -r --arg lane "$LANE" '
    [(.rules // []) | to_entries[] | select(.value.lane == $lane) | "rule_" + ((.key + 1) | tostring)] | first // empty
  ' "$RULES")
  [ -n "$DIRECT_CHOICE" ] || die "unknown lane: $LANE (no rule in $RULES_PATH declares it)"
fi
if [ -n "$EXCLUDE_FAMILY" ]; then
  jq -e --arg f "$EXCLUDE_FAMILY" 'any((.classes // {})[]; .family == $f)' "$RULES" >/dev/null \
    || die "undeclared family: $EXCLUDE_FAMILY (no class in $RULES_PATH declares it)"
fi
undeclared_tags=$(jq -r --argjson tags "$DATA_TAGS" '
  ([(.data_policies // {})[] | (.allow_tags // []) + (.deny_tags // []) | .[]] | unique) as $declared |
  [$tags[] | select(. as $t | $declared | index($t) | not)] | join(", ")
' "$RULES")
[ -z "$undeclared_tags" ] || die "undeclared data tag: $undeclared_tags (no data policy in $RULES_PATH declares it)"

emit_error() {
  local reason=$1
  echo "dispatch-resolve: error ($reason)" >&2
  printf 'dispatch-resolve:\n  status: error\n  reason: %s\n' "$reason"
  exit 0
}

if [ "$RULE_COUNT" -eq 0 ] && [ -z "$LANE" ]; then
  no_rules
fi

RESP_FILE=$(mktemp) || die "mktemp failed"
QUOTA=$(mktemp) || { rm -f "$RESP_FILE"; die "mktemp failed"; }
TASK_TEXT=$(mktemp) || { rm -f "$RESP_FILE" "$QUOTA"; die "mktemp failed"; }
SEND_TEXT=$(mktemp) || { rm -f "$RESP_FILE" "$QUOTA" "$TASK_TEXT"; die "mktemp failed"; }
trap 'rm -f "$RULES" "$RESP_FILE" "$QUOTA" "$TASK_TEXT" "$SEND_TEXT"' EXIT

never_send_off() {
  echo "dispatch-resolve: off ($1; nothing sent)" >&2
  exit 0
}

# Checks every string the request carries, so no text reaches the network
# unchecked. grep's own stderr is discarded because it can echo the pattern.
never_send_check() {
  local list value n=0 rc
  [ -e "$NEVER_SEND_PATH" ] || [ -L "$NEVER_SEND_PATH" ] || return 0
  { [ -f "$NEVER_SEND_PATH" ] && [ -r "$NEVER_SEND_PATH" ]; } \
    || never_send_off "$NEVER_SEND_PATH is not a readable regular file"
  # Collapse whitespace runs on both sides so a value the brief wraps across
  # lines or spaces differently still matches
  jq -r '.. | strings | gsub("\\s+"; " ")' <<<"$REQUEST" > "$SEND_TEXT" 2>/dev/null \
    || never_send_off "could not extract the request text to check"
  list=$(jq -Rr 'gsub("\\s+"; " ")' "$NEVER_SEND_PATH" 2>/dev/null) \
    || never_send_off "could not read $NEVER_SEND_PATH"
  while IFS= read -r value; do
    n=$((n + 1))
    value=${value# }
    value=${value% }
    case "$value" in
      ''|'#'*) continue ;;
    esac
    grep -qiF -e "$value" "$SEND_TEXT" 2>/dev/null; rc=$?
    case "$rc" in
      0) never_send_off "brief text matches $NEVER_SEND_PATH line $n" ;;
      1) ;;
      *) never_send_off "could not check the request text against $NEVER_SEND_PATH line $n" ;;
    esac
  done <<<"$list"
}

# Send Jev only the task-specific sections bin/fm-brief.sh scaffolds, plus a
# scout tag from the scout contract line; the rest of a scaffolded brief is
# standard boilerplate whose safety language reads as high stakes on every task.
# A brief with neither section goes whole. Ship delivery mode is deliberately
# not sent: live runs showed it pushing routine ship briefs to the top tier.
brief_kind() {
  if grep -qxF 'This is a SCOUT task: the deliverable is a written report, not a PR.' "$BRIEF"; then
    printf 'Brief kind: scout (report only)\n\n'
  fi
}
task_sections() {
  local heading
  for heading in "## Captain's intent" "## Firstmate spec"; do
    fm_brief_task_heading_present "$BRIEF" "$heading" || continue
    printf '%s\n%s\n\n' "$heading" "$(fm_brief_task_heading_body "$BRIEF" "$heading")"
  done
}
SECTIONS=$(task_sections)
if [ -n "$SECTIONS" ]; then
  { brief_kind; printf '%s\n' "$SECTIONS"; } > "$TASK_TEXT" || die "could not read brief: $BRIEF"
else
  cp "$BRIEF" "$TASK_TEXT" || die "could not read brief: $BRIEF"
fi
LAT_MS=null
if [ -n "$LANE" ]; then
  jq -n --arg choice "$DIRECT_CHOICE" '{answers: {rule: {choice: $choice, confidence: 1, probabilities: {}}}}' > "$RESP_FILE" \
    || die "could not prepare the lane selection"
else
  command -v curl >/dev/null 2>&1 || emit_error "curl not installed"
  REQUEST=$(jq -n --rawfile brief "$TASK_TEXT" --arg project "$PROJECT" --arg model "$TS_MODEL" \
    --arg none_criterion "$DEFAULT_WHEN" --slurpfile rules "$RULES" '
    ($rules[0]) as $cfg |
    ($cfg.rules | to_entries | map({key: ("rule_" + ((.key + 1) | tostring)), value: .value.when}) | from_entries) as $criteria |
    {
      model: $model,
      state: {task: {project: $project, brief: $brief}},
      questions: {
        rule: {
          type: "choice",
          instructions: "Which ONE dispatch rule best fits `task` (read `task.brief` and `task.project`)? Each option is the rule'"'"'s own matching condition; pick `default` when no rule'"'"'s condition is met, including when a rule'"'"'s own exemption text excludes this task.",
          criteria: ($criteria + {default: $none_criterion})
        }
      }
    }')
  never_send_check
  T0=$(fm_timing_now_ms)
  HTTP=$(printf '%s' "$REQUEST" | curl -sS --max-time "$TS_TIMEOUT" -o "$RESP_FILE" -w '%{http_code}' \
    -X POST "$TS_BASE/v1/systemone" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$DISPATCH_API_KEY_PRIVATE") \
    --data-binary @- 2>/dev/null) || HTTP=000
  T1=$(fm_timing_now_ms)
  LAT_MS=$(( T1 - T0 ))
  [ "$HTTP" = 200 ] || emit_error "http $HTTP after ${LAT_MS} ms: $(head -c 200 "$RESP_FILE" 2>/dev/null | tr '\n' ' ')"
  jq -e --slurpfile rules "$RULES" '
    (($rules[0].rules | to_entries | map("rule_" + ((.key + 1) | tostring))) + ["default"] | sort) as $choices |
    (.answers.rule.choice | type) == "string" and
    (.answers.rule.confidence | type) == "number" and
    .answers.rule.confidence >= 0 and .answers.rule.confidence <= 1 and
    (.answers.rule.probabilities | type) == "object" and
    ((.answers.rule.probabilities | keys | sort) == $choices) and
    all(.answers.rule.probabilities[]; type == "number" and . >= 0 and . <= 1) and
    ((.answers.rule.probabilities | [.[]] | add) as $total | $total >= 0.99 and $total <= 1.01) and
    ((has("usage") | not) or
      ((.usage | type) == "object" and
       (.usage.input_tokens | type) == "number" and
       (.usage.output_tokens | type) == "number"))' \
    "$RESP_FILE" >/dev/null 2>&1 || emit_error "response is not a rule Choice answer"
fi

# Experiment sampling bucket, only when a class declares an experiment: the
# same task text always lands in the same bucket.
SAMPLE=0
if jq -e 'any((.classes // {})[]; has("experiment"))' "$RULES" >/dev/null; then
  command -v cksum >/dev/null 2>&1 || emit_error "cksum not installed for experiment sampling"
  read -r crc _ < <(cksum < "$TASK_TEXT") && [[ "$crc" =~ ^[0-9]+$ ]] || emit_error "could not sample the brief for experiments"
  SAMPLE=$((crc % 100))
fi

# ---- quota evidence: one quota-axi --json snapshot -----------------------------
command -v quota-axi >/dev/null 2>&1 || emit_error "quota-axi not installed"
"$SCRIPT_DIR/fm-quota-read.sh" --json > "$QUOTA" || emit_error "quota-axi --json failed"
fm_quota_json_valid < "$QUOTA" || emit_error "quota-axi --json returned an invalid snapshot"

# Agy family bindings come only from its own catalog, never another harness.
AGY_IDS='[]'
AGY_LEVELS='{}'
if jq -e "$FM_DISPATCH_LANES_JQ"'
  def profiles: if type == "array" then . elif type == "object" then [.] else [] end;
  any(([(.rules // [])[] | .use | profiles[]] + ((.default // []) | profiles) + dispatch_class_routes)[]; .harness == "agy")
' "$RULES" >/dev/null; then
  AGY_IDS=$(fm_quota_agy_catalog)
  while IFS= read -r candidate; do
    model=$(jq -r '.model // ""' <<< "$candidate")
    effort=$(jq -r '.effort // ""' <<< "$candidate")
    level=$(agy_effort_level "$effort" "$model")
    key=$(jq -c '[.model // "", .effort // ""]' <<< "$candidate")
    AGY_LEVELS=$(jq -c --arg key "$key" --arg level "$level" '. + {($key): $level}' <<< "$AGY_LEVELS")
  done < <(jq -c "$FM_DISPATCH_LANES_JQ"'
    def profiles: if type == "array" then . elif type == "object" then [.] else [] end;
    ([(.rules // [])[] | .use | profiles[]] + ((.default // []) | profiles) + dispatch_class_routes)[] | select(.harness == "agy")
  ' "$RULES")
fi

# Devin's included_quota binds only to its own catalog's paid per-token models,
# which draw on the plan allowance; its free SWE-2 family draws on no plan quota
# and stays unranked, never binding another harness, like the Agy buckets.
DEVIN_IDS='[]'
if jq -e "$FM_DISPATCH_LANES_JQ"'
  def profiles: if type == "array" then . elif type == "object" then [.] else [] end;
  any(([(.rules // [])[] | .use | profiles[]] + ((.default // []) | profiles) + dispatch_class_routes)[]; .harness == "devin")
' "$RULES" >/dev/null; then
  DEVIN_IDS=$(fm_quota_devin_catalog)
fi

# ---- resolution: declared gates + quota evidence + argmax, all in jq ------------
DIRECT=false
[ -z "$LANE" ] || DIRECT=true
RESULT=$(jq -n --arg floor "$CONFIDENCE_FLOOR" --argjson lat "$LAT_MS" --arg none_criterion "$DEFAULT_WHEN" --argjson pmap "$PMAP" --argjson agy_ids "$AGY_IDS" --argjson agy_levels "$AGY_LEVELS" --argjson devin_ids "$DEVIN_IDS" --argjson horizon "$COMPLETION_HORIZON" \
  --argjson direct "$DIRECT" --arg exclude "$EXCLUDE_FAMILY" --argjson tags "$DATA_TAGS" --arg project "$PROJECT" --argjson sample "$SAMPLE" \
  --slurpfile resp "$RESP_FILE" --slurpfile rules "$RULES" --slurpfile quota "$QUOTA" "$FM_QUOTA_ROW_JQ$FM_QUOTA_AGY_JQ$FM_QUOTA_DEVIN_JQ$FM_DISPATCH_LANES_JQ"'
  ($resp[0]) as $r | ($rules[0]) as $cfg | ($quota[0]) as $q | ($r.answers.rule) as $a |
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def prov($p; $lane): quota_row($q; $p; $lane);
  def rows($p; $lane): (prov($p; $lane) | .quotaSemantics.effectiveAvailability // []);
  def provider_of($c): ($c.provider // $pmap[$c.harness] // null);
  def lane_of($c): quota_lane($c.harness; $c.model);
  def measured($p; $lane):
    (prov($p; $lane) != null and (["known", "partial"] | index(prov($p; $lane).quotaSemantics.status)) != null);
  def applicable($p; $lane; $c):
    (if $c.harness == "agy" then quota_agy_scope($agy_ids; ($c.model // ""); ($agy_levels[([$c.model // "", $c.effort // ""] | @json)] // "")) else "" end) as $agy_scope |
    (if $c.harness == "devin" then quota_devin_scope($devin_ids; ($c.model // "")) else "" end) as $devin_scope |
    [rows($p; $lane)[] | select(quota_applicable($p; ($c.model // ""); $agy_scope; $devin_scope))];
  def floor_state($f; $p; $lane):
    if $f == null then "none"
    elif prov($p; $lane) == null or (measured($p; $lane) | not) then "unknown"
    else [rows($p; $lane)[] | select(.scope == $f.scope)] as $matches
      | if ($matches | length) == 0 or any($matches[]; .status != "known") then "unknown"
        elif any($matches[]; .effectivePercentRemaining < $f.min_percent) then "below"
        else "ok"
        end
    end;
  def evidence($rows):
    $rows | map({scope, status, pct: (.effectivePercentRemaining // null), runway: (.runway.status // null), usableRunwaySeconds: (.runway.usableRunwaySeconds // null), spendPriority: (.selection.spendPriority // null)});
  def evaluate_route($c; $unmetered):
    (provider_of($c)) as $p | (lane_of($c)) as $lane |
    if $p == null then {profile: $c, eligible: false, reason: "no provider family for harness \($c.harness); declare provider on the profile"}
    elif $unmetered then
      {profile: $c, provider: $p, unmetered: true, spendPriority: 0, eligible: true, reason: "unmetered (declared)"}
    elif prov($p; $lane) == null then
      {profile: $c, provider: $p, eligible: true, unranked: true,
       reason: (if any($q.providers[]; .provider == $p)
                then "provider \($p) has no quota row for account \(if $lane == "" then "default" else $lane end)"
                else "provider \($p) not in the quota snapshot" end)}
    else
      (applicable($p; $lane; $c)) as $rows |
      (evidence($rows)) as $bounds |
      (floor_state($c.floor; $p; $lane)) as $profile_floor_state |
      if any($rows[]; quota_hard_bound($p) and (.runway.status // "") == "exhausted_now") then
        ($rows | map(select(quota_hard_bound($p) and (.runway.status // "") == "exhausted_now")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: ($bad.effectivePercentRemaining // null), runway: $bad.runway.status, eligible: false, reason: "runway exhausted_now at \($bad.scope)"}
      elif any($rows[]; quota_hard_bound($p) and .status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0) then
        ($rows | map(select(quota_hard_bound($p) and .status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0)) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: false, reason: "0% remaining at \($bad.scope)"}
      elif any($rows[]; quota_hard_bound($p) and .runway.status == "projected_exhaustion" and
          (.runway.usableRunwaySeconds | type) == "number" and .runway.usableRunwaySeconds < $horizon) then
        ($rows | map(select(quota_hard_bound($p) and .runway.status == "projected_exhaustion" and
          (.runway.usableRunwaySeconds | type) == "number" and .runway.usableRunwaySeconds < $horizon)) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: $bad.effectivePercentRemaining,
         runway: $bad.runway.status, eligible: false,
         reason: "runway \($bad.runway.usableRunwaySeconds)s below completion horizon \($horizon)s at \($bad.scope)"}
      elif $profile_floor_state == "below" then
        ([rows($p; $lane)[] | select(
          .scope == $c.floor.scope and
          .effectivePercentRemaining < $c.floor.min_percent
        )] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, scope: ($floor_row.scope // $c.floor.scope), pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: false, reason: "profile floor \($c.floor.scope) below \($c.floor.min_percent)%"}
      elif (measured($p; $lane) | not) then
        ($rows | first) as $row |
        {profile: $c, provider: $p, bounds: $bounds, scope: ($row.scope // null), pct: ($row.effectivePercentRemaining // null), runway: ($row.runway.status // null), eligible: true, unranked: true, unknown: true, reason: "provider \($p) unmeasured (\(prov($p; $lane).quotaSemantics.status))"}
      elif ($rows | length) == 0 then
        {profile: $c, provider: $p, bounds: $bounds, eligible: true, unranked: true, unknown: true,
         reason: ("no applicable quota row for provider \($p)" +
           if $p == "agy" then "; catalog-backed family quota is unmeasured"
           elif $p == "devin" then "; no catalog-confirmed quota binding (a free route draws on no plan quota, and a paid route binds only when the catalog is read)"
           else "" end)}
      elif $profile_floor_state == "unknown" then
        ([rows($p; $lane)[] | select(.scope == $c.floor.scope)] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, scope: $c.floor.scope, pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: true, unranked: true, unknown: true, reason: "profile floor \($c.floor.scope) is unverifiable: not rankable"}
      elif any($rows[]; .status != "known") then
        ($rows | map(select(.status != "known")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, eligible: true, unranked: true, unknown: true, reason: "quota row \($bad.scope) unknown: not rankable"}
      elif any($rows[]; (quota_hard_bound($p) | not) and
          (.effectivePercentRemaining <= 0 or .runway.status == "exhausted_now" or
           (.runway.status == "projected_exhaustion" and (.runway.usableRunwaySeconds // 0) < $horizon))) then
        {profile: $c, provider: $p, bounds: $bounds, eligible: true, unranked: true,
         reason: "included pool cannot support completion; other pools or overage unmeasured, not whole-provider exhaustion"}
      elif any($rows[]; .runway.status != "through_reset" and
          (.runway.status != "projected_exhaustion" or (.runway.usableRunwaySeconds | type) != "number")) then
        {profile: $c, provider: $p, bounds: $bounds, eligible: true, unranked: true,
         reason: "runway feasibility unknown for completion horizon \($horizon)s"}
      elif any($rows[]; (quota_selection_known | not)) then
        ($rows | map(select(quota_selection_known | not)) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: true, unranked: true, reason: "spendPriority missing, non-numeric, or selection not known at \($bad.scope): not rankable"}
      else
        ($rows | min_by(.selection.spendPriority)) as $limiting |
        {profile: $c, provider: $p, bounds: $bounds, scope: $limiting.scope, pct: $limiting.effectivePercentRemaining,
         spendPriority: $limiting.selection.spendPriority, runway: $limiting.runway.status, eligible: true, reason: "ok"}
      end
    end;
  def evaluate($c): evaluate_route($c; false);
  def rule_at($c):
    if ($c | test("^rule_[1-9][0-9]*$")) then
      ($c | ltrimstr("rule_") | tonumber) as $n |
      if $n <= (($cfg.rules // []) | length) then $cfg.rules[$n - 1] else null end
    else null end;
  def declared_confidence($c): rule_at($c) as $x | $x != null and ($x | has("min_confidence"));
  def confidence_floor($c): if declared_confidence($c) then rule_at($c).min_confidence else ($floor | tonumber) end;
  def rankable: .eligible and ((.unranked // false) | not);
  def blocked($reason): . + {eligible: false, unranked: false, unknown: false, reason: $reason};
  # A data policy admits its class only for an allowed project or data tag, and
  # never with a denied tag.
  def policy_block($name):
    ($cfg.data_policies[$name]) as $p |
    ([$tags[] | . as $t | select(($p.deny_tags // []) | index($t))]) as $denied |
    if ($denied | length) > 0 then "data policy \($name) refuses data tag \($denied | join(", "))"
    elif $project != "" and (($p.allow_projects // []) | index($project)) != null then null
    elif any($tags[]; . as $t | ($p.allow_tags // []) | index($t)) then null
    else "data policy \($name) does not admit project \(if $project == "" then "(none given)" else $project end) without an allowed data tag (\(($p.allow_tags // []) | join(", ")))"
    end;
  def class_exclusion($k):
    if $exclude != "" and $k.family == $exclude then "second opinion excludes family \($k.family)"
    elif $exclude != "" and $k.experiment != null then "an experiment class never serves a second opinion"
    elif $k.experiment != null and $sample >= ($k.experiment.share * 100) then "experiment not sampled for this task"
    elif $k.data_policy != null then policy_block($k.data_policy)
    else null end;
  def lane_eval($rule):
    [dispatch_lane_refs($rule)[] | . as $ref | ($cfg.classes[$ref.class]) as $def |
      {name: $ref.class, gate: ($ref.gate // null), family: $def.family,
       experiment: ($def.experiment // null), data_policy: ($def.data_policy // null),
       unmetered: ($def.unmetered // false), routes: $def.routes}
      | . + {excluded: class_exclusion(.)}
      | . as $k
      | . + {candidates: [.routes[] |
          (if $k.excluded != null then {profile: ., eligible: false, reason: $k.excluded} else evaluate_route(.; $k.unmetered) end)
          + {class: $k.name, family: $k.family} + (if $k.experiment != null then {experiment: true} else {} end)]}
    ] as $classes0 |
    ([$classes0[] | select(.gate == null) | .candidates[] | select(rankable)]) as $others |
    [$classes0[] |
      if .gate == "others-ahead-of-pace" and .excluded == null then
        ([.candidates[] | select(rankable)] | max_by(.spendPriority)) as $own |
        (if ($others | length) == 0 then "pace gate closed: no ungated class in the lane has a rankable spendPriority"
         elif any($others[]; .spendPriority >= 0) then
           "pace gate closed: \([$others[] | select(.spendPriority >= 0) | .class] | unique | join(", ")) not spending ahead of pace"
         elif $own == null then "pace gate closed: this class has no rankable spendPriority"
         elif $own.spendPriority < 0 then "pace gate closed: this class is itself spending ahead of pace"
         else null end) as $closed |
        if $closed == null then . + {gate_open: true}
        else .candidates |= map(if .eligible then blocked($closed) else . end) end
      else . end] as $classes |
    {lane: $rule.lane, order: ($rule.order // "pool"), classes: $classes, candidates: [$classes[].candidates[]],
     experiments: [$classes[] | select(.experiment != null) |
       {class: .name, share: .experiment.share,
        bucket: $sample,
        state: (if $exclude != "" then "excluded" elif $sample < (.experiment.share * 100) then "sampled" else "not sampled" end)}]};
  def argmax_pick($cands; $where):
    ([$cands[] | select(rankable)]) as $ranked |
    if ($ranked | length) == 0 then {status: "escalate", reason: "no rankable eligible candidate\($where)"}
    else ($ranked | max_by(.spendPriority)) as $best |
      if ([$ranked[] | select(.spendPriority == $best.spendPriority)] | length) > 1
      then {status: "escalate", reason: "genuine spendPriority tie\($where)"}
      else {status: "clear", chosen: $best} end
    end;
  # A sampled experiment with a rankable route takes the task; an ordered lane
  # stops at its first class with any eligible route, ranked or not, so unknown
  # quota escalates instead of silently skipping to a later class.
  def lane_pick($le):
    ([$le.classes[] | select(.experiment != null and .excluded == null) | .candidates[] | select(rankable)]) as $sampled |
    if ($sampled | length) > 0 then argmax_pick($sampled; " among sampled experiment routes")
    elif $le.order == "ordered" then
      ([$le.classes[] | select(any(.candidates[]; .eligible))] | first) as $first |
      if $first == null then {status: "escalate", reason: "no class in the ordered lane has an eligible route"}
      else argmax_pick($first.candidates; " in first viable class \($first.name)") end
    else argmax_pick($le.candidates; "") end;
  ($a.choice) as $picked |
  (confidence_floor($picked)) as $picked_floor |
  # A declared floor is checked against the probability of that option whether
  # it is the pick or a runner-up, so a runner-up never needs weaker support
  # than it would as the pick. Only a rule that declares its own floor falls
  # through to a runner-up, so a file with no declared floors keeps the single
  # global floor on the answer confidence exactly.
  (if $direct then {below: false}
   elif declared_confidence($picked) | not then
     (if $a.confidence >= $picked_floor then {below: false} else {below: true, global: true} end)
   elif $a.probabilities[$picked] >= $picked_floor then {below: false}
   else
     ([$a.probabilities | to_entries[] | select(.key != $picked and .value >= confidence_floor(.key))]
       | sort_by(-.value)) as $ok |
     if ($ok | length) == 0 then {below: true, why: "no other option clears its own floor"}
     elif ($ok | length) > 1 and $ok[1].value == $ok[0].value then {below: true, why: "runner-up tie"}
     else {below: true, to: $ok[0].key, p: $ok[0].value, to_floor: confidence_floor($ok[0].key)} end
   end) as $fb |
  (if $fb.to then $fb.to else $picked end) as $choice |
  (rule_at($choice)) as $rule |
  (if $rule == null then "none" else floor_state($rule.floor; $rule.floor.provider; "") end) as $rule_floor_state |
  (if $choice != "default" and $rule == null then []
   elif $rule == null then profiles($cfg.default // null)
   else profiles($rule.use)
   end) as $answer_use |
  (if $rule != null and ($rule | has("classes")) then lane_eval($rule) else null end) as $answer_lane |
  (if $answer_lane != null then $answer_lane.candidates else ($answer_use | map(evaluate(.))) end) as $answer_cands |
  (if $choice != "default" and $rule == null then {invalid: "rule \($choice) is not in the rules file"}
   elif $rule == null then {source: "default", use: profiles($cfg.default // null), note: "no rule matched"}
   elif ($rule.approval // "") == "captain" then {source: $choice, escalate: "rule requires the captain'"'"'s explicit approval before dispatch"}
   elif $rule_floor_state == "unknown" then {source: $choice, escalate: "rule \($choice) floor \($rule.floor.provider)/\($rule.floor.scope) is unverifiable"}
   elif $rule_floor_state == "below"
     then {source: "default", use: profiles($cfg.default // null), note: "rule \($choice) floor \($rule.floor.scope) below \($rule.floor.min_percent)%: fall through to default"}
   elif $answer_lane != null then {source: $choice, lane: $answer_lane, note: "lane \($rule.lane) matched"}
   else {source: $choice, use: profiles($rule.use), note: "rule matched"} end) as $sel |
  def when_of($c): (if rule_at($c) == null then $none_criterion else rule_at($c).when end | .[0:60]);
  {
    completion_horizon_seconds: $horizon, model: $r.model, latency_ms: $lat, tokens: ($r.usage // null),
    direct: $direct,
    rule: $picked,
    rule_when: when_of($picked),
    confidence: $a.confidence, probabilities: $a.probabilities
  }
  + (if $answer_lane != null and $sel.source != "default" then
       {lane: $answer_lane.lane, order: $answer_lane.order, experiments: $answer_lane.experiments}
     else {} end)
  + (if $exclude != "" then {exclude_family: $exclude} else {} end)
  + (if ($tags | length) > 0 then {data_tags: $tags} else {} end)
  + (if $fb.to then {fallback: "\($choice) (\(when_of($choice))) probability \($fb.p) clears its floor \($fb.to_floor); \($picked) probability \($a.probabilities[$picked]) is below its floor \($picked_floor)"} else {} end)
  as $ev |
  if $sel.invalid then $ev + {status: "error", reason: $sel.invalid}
  elif $fb.below and $fb.global then
    $ev + {status: "ambiguous", reason: "confidence \($a.confidence) below floor \($floor)", candidates: $answer_cands}
  elif $fb.below and ($fb.to | not) then
    $ev + {status: "ambiguous", reason: "\($picked) probability \($a.probabilities[$picked]) below its floor \($picked_floor); \($fb.why)", candidates: $answer_cands}
  elif $sel.escalate then
    $ev + {status: "escalate", reason: $sel.escalate, candidates: $answer_cands}
  elif $sel.lane then
    ($sel.lane) as $le | (lane_pick($le)) as $pick |
    ([$le.candidates[] | select(.unranked)]) as $unranked |
    $ev + {status: $pick.status, note: $sel.note, candidates: $le.candidates}
    + (if $pick.status == "clear" then {chosen: $pick.chosen} else {reason: $pick.reason} end)
    + (if $pick.status == "clear" and ($unranked | length) > 0 then
         {unranked_note: "\($unranked | length) eligible candidate(s) unranked (\([$unranked[].provider] | unique | join(", ")))"}
       else {} end)
  elif $exclude != "" then
    $ev + {status: "escalate", reason: "a second opinion needs a lane whose classes declare model families; \($sel.source) has none",
      note: $sel.note, candidates: ($sel.use | map(evaluate(.)))}
  elif ($sel.use | length) == 0 then $ev + {status: "escalate", reason: "no profiles configured for \($sel.source)", note: $sel.note, candidates: []}
  else
    ($sel.use | map(evaluate(.))) as $cands |
    ([$cands[] | select(.eligible and ((.unranked // false) | not))]) as $elig |
    ([$cands[] | select(.unranked)]) as $unranked |
    if ($elig | length) == 0 then $ev + {status: "escalate", reason: "no rankable eligible candidate", note: $sel.note, candidates: $cands}
    else
      ($elig | max_by(.spendPriority)) as $best |
      ([$elig[] | select(.spendPriority == $best.spendPriority)] | length) as $ties |
      if $ties > 1 then $ev + {status: "escalate", reason: "genuine spendPriority tie", note: $sel.note, candidates: $cands}
      else $ev + {status: "clear", note: $sel.note, candidates: $cands, chosen: $best}
        + (if ($unranked | length) > 0 then
             {unranked_note: "\($unranked | length) eligible candidate(s) unranked (\([$unranked[].provider] | unique | join(", ")))"}
           else {} end)
      end
    end
  end') || emit_error "resolution failed"

TEXT=$(jq -r '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($value): ($value // "-") | flat;
  def shell_arg: flat | @sh;
  "dispatch-resolve:",
  "  status: \(.status | flat)",
  "  completion_horizon_seconds: \(.completion_horizon_seconds)",
  (if .direct then empty
   else "  model: \(show(.model))   latency_ms: \(show(.latency_ms))   tokens: \(show(.tokens.input_tokens))/\(show(.tokens.output_tokens))" end),
  (if .direct then "  rule: \(.rule | flat) (\(.rule_when | flat))   selected: by --lane"
   else "  rule: \(.rule | flat) (\(.rule_when | flat))   confidence: \(.confidence | flat)" end),
  (if .direct then empty
   else "  probabilities: \([.probabilities | to_entries[] | "\(.key | flat)=\(.value | flat)"] | join(" "))" end),
  (if .lane then "  lane: \(.lane | flat)  order=\(.order | flat)" else empty end),
  (if .exclude_family then "  exclude_family: \(.exclude_family | flat)" else empty end),
  (if .data_tags then "  data_tags: \(.data_tags | map(flat) | join(", "))" else empty end),
  (.experiments[]? | "  experiment: \(.class | flat)  share=\(.share)  bucket=\(.bucket) -> \(.state | flat)"),
  (if .fallback then "  fallback: \(.fallback | flat)" else empty end),
  (if .reason then "  reason: \(.reason | flat)" else empty end),
  (if .note then "  note: \(.note | flat)" else empty end),
  (if .unranked_note then "  note: \(.unranked_note | flat)" else empty end),
  (.candidates[]? | "  candidate: \(.profile.harness | flat):\(show(.profile.model))"
      + (if .class then "  class=\(.class | flat) family=\(.family | flat)" + (if .experiment then " experiment" else "" end) else "" end)
      + (if .provider then "  provider=\(.provider | flat)" else "" end)
      + (if .unmetered then "  quota=unmetered (declared)  spendPriority=0  runway=unmetered"
         elif .scope then "  scope=\(.scope | flat)  remaining=\(show(.pct))%  spendPriority=\(show(.spendPriority))  runway=\(show(.runway))" else "" end)
      + (if (.bounds // [] | length) > 1 then "  bounds=" + ([.bounds[] | "\(.scope | flat):\(show(.pct))%/\((.runway // .status) | flat)"] | join(",")) else "" end)
      + "  -> " + (if .unranked then "eligible, unranked: \(.reason | flat): disclosed uncertainty" elif .eligible then "eligible" else "not eligible: \(.reason | flat)" end)
      + (if (.bounds // [] | length) > 0 then "  runway_seconds=" + ([.bounds[] | "\(.scope | flat):\(if .runway == "exhausted_now" then "0" elif .runway == "through_reset" then "through_reset" else show(.usableRunwaySeconds // "unknown") end)"] | join(",")) else "" end)),
  (if .chosen.class then "  class: \(.chosen.class | flat)  family=\(.chosen.family | flat)" + (if .chosen.experiment then "  experiment" else "" end) else empty end),
  (if .chosen then "  profile: --harness \(.chosen.profile.harness | shell_arg)"
      + (if .chosen.profile.model then " --model \(.chosen.profile.model | shell_arg)" else "" end)
      + (if .chosen.profile.effort then " --effort \(.chosen.profile.effort | shell_arg)" else "" end) else empty end)' <<<"$RESULT") || emit_error "output rendering failed"
printf '%s\n' "$TEXT"
exit 0
