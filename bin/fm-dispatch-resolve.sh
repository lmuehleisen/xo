#!/usr/bin/env bash
# fm-dispatch-resolve.sh - resolve one concrete crewmate or scout dispatch
# profile from a task brief with a configurable model provider, opt-in.
#
# Usage:
#   fm-dispatch-resolve.sh <brief-file> [--project <name>] [--completion-horizon <seconds>]
#                          [--lane <name>] [--exclude-family <family>] [--data-tag <tag>]...
#   fm-dispatch-resolve.sh --supports-credential-source <source>
#
# Opt-in gate: FM_DISPATCH_PROVIDER and FM_DISPATCH_MODEL select the provider
#   and model from the environment or $FM_HOME/.env (environment wins). With no
#   provider set, retain the original typesafe.ai/jev-latest key gate exactly.
#   OpenRouter and OpenAI require both their provider selection and a model.
#   The generic systemone provider requires a model and FM_DISPATCH_BASE_URL
#   (http:// or https://) and posts to <base>/v1/systemone; its optional
#   FM_DISPATCH_API_KEY, when absent, means no Authorization header. The openai
#   provider maps the System One request to OpenAI's Decisions API and maps its
#   answer back before validation. The typesafe and openrouter keys come from the
#   environment, else $FM_HOME/.env, else the credential source declared for that
#   provider (below); the openai and systemone keys come from the environment or
#   $FM_HOME/.env only. The selected key lives in a non-exported shell variable
#   and reaches curl through fd 3, never argv, logs, or child environments.
#
# Credential source declaration: the optional $CONFIG/dispatch-credential-sources.json
#   ($CONFIG is FM_CONFIG_OVERRIDE, else $FM_HOME/config) is a JSON object keyed
#   by provider (typesafe or openrouter). Each value says where that provider's
#   key lives and holds no key: {"source": "macos-keychain", "service": "<name>",
#   "account": "<name>"}, where account is optional and no other field is
#   accepted. bin/fm-credential-source-lib.sh owns the schema and its adapters;
#   macos-keychain reads the generic-password item with `security
#   find-generic-password -s <service> [-a <account>] -w`, so only the service
#   and account reach argv. The file is read only when neither the environment
#   nor .env supplied a key, and only the selected provider's entry is used.
#   With no entry for that provider and no key the tool is off as above. An
#   unreadable or invalid file exits 2 naming the problem, never a value. A
#   declared source this host cannot run, or that yields no key within
#   5 seconds, is an error outcome ending "nothing sent", with no network or
#   quota call, so it is not mistaken for an unconfigured resolver.
#
# Capability probe: --supports-credential-source <source> prints "supported"
#   and exits 0, or prints "unsupported" and exits 1, for a source name such as
#   macos-keychain on this host. It reads no declaration, retrieves no
#   credential, and runs no credential tool, so a configuration installer can
#   refuse an unsupported activation before it writes anything.
#
#   With no explicit provider, retain the TypeSafe-first gate and the home-only
#   OpenRouter fallback, which uses the legacy System One endpoint.
#
# What it does when on with at least one rule: one POST with the project name and the brief's
#   `## Captain's intent` and `## Firstmate spec` sections, tagged when it is a
#   scout brief (the whole brief when it has neither section), as state and
#   ONE Choice question whose options are every rule's `when` from
#   config/crew-dispatch.json plus one fixed generic none option. The provider
#   returns the matched rule, a probability per option, and a confidence. Everything
#   after that is jq: the confidence floor (0.6 on the answer confidence, or a
#   rule's declared `min_confidence` on that rule's probability, falling to the
#   most probable other option that clears its own floor), the rule's declared
#   `approval` and `floor`, each profile's declared `provider` and `floor`, the
#   quota rows from ONE quota-axi --json snapshot (schema 5 or 6; each
#   candidate binds to one row through quota_row in
#   bin/fm-quota-axi-lib.sh, so a Pi lane such as openai-codex-work/...
#   reads its own account's row and an expanded provider with no row for the
#   candidate is unmeasured, never blocked), then the optional preferred_provider
#   family restriction before the selected score ranks the remaining candidates.
#   An eligible but wholly unrankable preferred family escalates rather than
#   authorizing another family.
#   Completion-runway gates still apply before ranking.
#   The model never sees quota, catalogs, approvals, preferred_provider,
#   confidence floors, `why`, or `use`. With no rules, it returns a non-clear
#   result so firstmate keeps using the existing intake.
#
# Shared-quota opt-out: an optional top-level "shared_quota": true in the
#   rules file declares this home draws every provider's usage from one single
#   shared budget, so per-provider quota rows do not describe what is left.
#   With it set, this tool makes no quota-axi call, applies no quota floor or
#   runway gate, ranks nothing by spendPriority, and resolves the matched
#   rule's `use` profiles in declared order; preferred_provider still narrows
#   the pool for profiles and lanes; declared order then picks within it.
#   A lane also skips quota-derived pace gates, while its non-quota gates
#   (live caps, experiment admission and data policies) remain in force.
#   Every candidate line still
#   prints, stating quota ranking is off by home declaration. Without the
#   setting, behavior is unchanged. The declared value must be a boolean;
#   anything else is an actionable configuration error.
#   docs/configuration.md "Crew dispatch profiles" owns the declared fields and
#   "Typed dispatch resolution" owns this tool's operator contract.
#
# Lanes: a rule with `classes` is a lane (bin/fm-dispatch-lanes-lib.sh owns its
#   structural checks). Each class route is evaluated like a profile, except a
#   class declared unmetered receives its configured spend_priority (default 0)
#   as a synthetic selected score and skips provider quota evidence; its other
#   eligibility gates still apply.
#   Code picks: a sampled experiment class with a rankable route first; in
#   an `ordered` lane the first class with any eligible route, ranked inside
#   that class; in a `pool` lane the selected-score argmax over every class.
#   A class at its optional max_live cap or live_cap_group cap is not eligible.
#   Live counts read ordinary task records (kind not secondmate) from
#   $FM_HOME/state/*.meta
#   (FM_STATE_OVERRIDE replaces state), matching harness and model to any
#   class route, regardless of effort or model_family; model=default matches
#   a route with no model. Unreadable records
#   count as nothing; a finished task not yet cleaned up still counts.
#   A group counts each record once across all routes of all configured member
#   classes, including classes outside the selected lane and excluded classes.
#   These checks are advisory; fm-spawn.sh does not enforce live caps.
#   Exact selected-score ties across classes prefer fewer live workers;
#   ties that remain escalate, including ties between routes of one class.
#   Distinct unmetered spend_priority values avoid ties between those classes.
#   A class gated `others-ahead-of-pace` stays eligible only while every
#   rankable route of the lane's ungated classes is metered with a selected score
#   below 0 and its own best route is not ahead of pace. Unmetered routes
#   always count as pace-neutral, regardless of their configured score, so
#   changing spend_priority cannot change a pace gate. An experiment class is
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
#   Prefer additive spendPressure once per snapshot when any scope publishes it;
#   otherwise use legacy spendPriority. Missing selected scores stay unranked.
#   Candidate output labels name the selected metric; unmetered policy scores
#   retain their configured values. Planning overrides adjust whichever
#   metric the snapshot selects.
#
# Never-send check: when the optional $FM_HOME/config/dispatch-never-send list
#   exists, the endpoint URL and every string value of the final
#   provider-specific request body (and of any JSON text a string carries) are
#   checked against it before the POST. Each non-blank, non-# line is a literal matched
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
#     spend_metric: spendPressure   (omitted for legacy spendPriority)
#     model/latency_ms/tokens, rule (when excerpt) and confidence, probabilities
#     fallback: <runner-up rule taken when the picked rule missed its own floor>
#     reason: <why the status is not clear>
#     lane: <name> order=<ordered|pool>   (lane rules; exclude_family and data_tags when given)
#     experiment: <class> share=.. bucket=.. -> sampled | not sampled | excluded
#     candidate: <harness>:<model> [class=.. family=..] provider=.. scope=.. remaining=..% <spend_metric>=.. runway=.. -> eligible | eligible, unranked: <reason> | not eligible: <reason>
#     Unmetered class routes print quota=unmetered (declared), <spend_metric>=<configured score>, runway=unmetered; these are declared facts, not measured quota.
#     class: <name> family=<family> [experiment]   (lane rules, status clear only)
#     Lane candidate lines end with live=<count> [max_live=<cap>] and, for a
#     grouped class, live_cap_group=<name> group_live=<count> group_max_live=<cap>.
#     tie_break: <class> has fewest live workers (<count>) among <spend_metric> ties
#     preferred_provider: <family and preference or fallback decision, when applied>
#        (with the shared-quota opt-out: <harness>:<model> provider=.. -> eligible (quota ranking off: home declares a single shared quota))
#     profile: --harness <h> [--model <m>] [--effort <e>]     (status clear only)
#   clear     -> pass the profile line to fm-spawn.sh unless you state a reason to override
#   ambiguous -> confidence below the floor; decide as today from the probabilities
#   escalate  -> the rule requires captain approval, no candidate is rankable, or a genuine tie
#   error     -> API, network, response, quota-axi, or declared credential source failure; decide as today
#   Every outcome exits 0 so an intake is never blocked by this tool.
#   Exit 2 only for a usage or configuration error (unreadable brief, an
#   existing unreadable rules file, malformed rules, missing jq, an unknown
#   provider, invalid credential sources, a non-typesafe provider without a
#   model, systemone without a valid base URL, an unknown --lane, or an
#   undeclared --exclude-family or --data-tag), which is
#   actionable, never selected around.
#
# Private call history: bin/fm-dispatch-history-lib.sh owns the append-only
#   router/spawn JSONL log, including off and error calls.
#
# Runway gate: --completion-horizon is a positive number of seconds (default
#   3600, a conservative one-hour completion budget). The output discloses it
#   and each bound's usableRunwaySeconds; unknown runway remains unranked.
#
# Quota planning overrides: the optional local config/quota-planning.json
#   (docs/configuration.md owns the schema) may name a provider, account lane,
#   optional window, rolling horizonSeconds, and expiresAt. While the quota
#   snapshot's generatedAt precedes expiresAt, quota_plan_adjust in
#   bin/fm-quota-axi-lib.sh ranks a provably matched single-window scope by a
#   planning value of the selected metric (spendPriority or spendPressure)
#   that truncates the window's published pace horizon at generatedAt plus
#   the horizon, capped by the vendor reset; the native value, horizon, and
#   expiry print beside it. This is a consumer planning assumption, never
#   vendor evidence: vendor remaining, resetsAt, runway, and exhausted or
#   unknown states are unchanged, and absent, expired, or unprovable
#   overrides leave ranking exactly on the native selected metric.
#   A malformed planning file is a usage error, like malformed rules.
#
# Installed-tool gate: every candidate's harness must have a launch location on
#   this host. Each configured harness is probed once per resolve with a cheap
#   local lookup over every location the single-owner table
#   fm_control_harness_launch_candidates in bin/fm-control-lib.sh accepts: a
#   bare name on PATH, or an absolute resolver fallback path such as Kimi's
#   ~/.kimi-code/bin. Each must resolve to an executable file, exactly as
#   bin/fm-spawn.sh's resolvers require, so an installation the launcher would
#   accept is never excluded and an exported function, builtin, or alias of the
#   same name never counts. A harness with no executable launch location
#   anywhere prints "not eligible: <harness> tool not installed on this host",
#   because dispatch configuration is identical across homes while installed
#   tools are not, so a host without the tool must never pick a route that
#   cannot launch. The gate declines that route only: it never falls back to
#   another route by itself, every candidate is still printed with its
#   evidence, and an all-ineligible outcome keeps the ordinary escalate
#   result.
#
# Environment:
#   FM_DISPATCH_PROVIDER, FM_DISPATCH_MODEL, FM_DISPATCH_BASE_URL,
#   FM_DISPATCH_API_KEY, OPENAI_API_KEY, TYPESAFE_API_KEY, and
#   OPENROUTER_API_KEY are read from the environment or $FM_HOME/.env.
#   An environment-only OpenRouter key cannot activate the implicit fallback.
#
# Authority: this tool never replaces firstmate's judgment, quota-array-dispatch,
#   the captain-approval gate, or fm-spawn.sh validation; it publishes one
#   inspectable answer plus every candidate's evidence, in code.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY
OPENROUTER_API_KEY_PRIVATE=${OPENROUTER_API_KEY:-}
export -n OPENROUTER_API_KEY_PRIVATE 2>/dev/null || true
unset OPENROUTER_API_KEY
OPENAI_API_KEY_PRIVATE=${OPENAI_API_KEY:-}
export -n OPENAI_API_KEY_PRIVATE 2>/dev/null || true
unset OPENAI_API_KEY
DISPATCH_API_KEY_PRIVATE=${FM_DISPATCH_API_KEY:-}
export -n DISPATCH_API_KEY_PRIVATE 2>/dev/null || true
unset FM_DISPATCH_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

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
# shellcheck source=bin/fm-credential-source-lib.sh
. "$SCRIPT_DIR/fm-credential-source-lib.sh"

# shellcheck source=bin/fm-dispatch-history-lib.sh
. "$SCRIPT_DIR/fm-dispatch-history-lib.sh"

HISTORY_STATUS=error HISTORY_REASON=''
HISTORY_EVIDENCE='{}' HISTORY_MODEL=''
BRIEF='' LANE='' LAT_MS=null RESULT='{}'
# The exit handler owns only temporaries created by this invocation, never
# paths inherited from the caller through generic environment variable names.
RULES='' RESP_FILE='' QUOTA='' TASK_TEXT='' SEND_TEXT=''
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
dispatch_exit() {
  local rc=$?
  fm_dispatch_history_router "$FM_HOME" "$BRIEF" "$HISTORY_STATUS" "$HISTORY_REASON" \
    "$RESULT" "$HISTORY_EVIDENCE" "$LANE" "$LAT_MS" "$HISTORY_MODEL" || true
  if [ -n "${RULES:-}${RESP_FILE:-}${QUOTA:-}${TASK_TEXT:-}${SEND_TEXT:-}" ]; then
    rm -f "${RULES:-}" "${RESP_FILE:-}" "${QUOTA:-}" "${TASK_TEXT:-}" "${SEND_TEXT:-}"
  fi
  return "$rc"
}
trap dispatch_exit EXIT

CONFIDENCE_FLOOR=0.6
TS_MODEL=jev-latest
TS_BASE=https://api.typesafe.ai
TS_TIMEOUT=5
OR_BASE=https://openrouter.ai/api
OR_TIMEOUT=10
SO_TIMEOUT=10
OA_BASE=https://api.openai.com
OA_TIMEOUT=10
DEFAULT_WHEN="No listed rule applies to this task."

die() { HISTORY_REASON='usage or configuration error'; printf 'error: %s\n' "$1" >&2; exit 2; }
no_rules() {
  HISTORY_STATUS=escalate HISTORY_REASON='no rules to match'
  printf 'dispatch-resolve:\n  status: escalate\n  reason: no rules to match\n'
  exit 0
}
emit_error() {
  local reason=$1
  # HTTP diagnostics may include an arbitrary response body; retain only the
  # error category in history so a server cannot echo secrets into the log.
  HISTORY_STATUS=error HISTORY_REASON=${reason%%: *} RESULT='{}'
  echo "dispatch-resolve: error ($reason)" >&2
  printf 'dispatch-resolve:\n  status: error\n  reason: %s\n' "$reason"
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
CRED_PATH="$CONFIG/dispatch-credential-sources.json"
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
    --supports-credential-source)
      trap - EXIT
      [ $# -ge 2 ] || die "--supports-credential-source needs a value"
      if fm_credsrc_supported "$2"; then echo supported; exit 0; fi
      echo unsupported; exit 1 ;;
    -h|--help) trap - EXIT; usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$BRIEF" ] || die "one brief file only"; BRIEF=$1; shift ;;
  esac
done

# One cheap local lookup: a harness counts as installed when ANY launch
# location the single-owner table in bin/fm-control-lib.sh accepts exists - a
# bare name on PATH, or an absolute resolver fallback path such as Kimi's
# ~/.kimi-code/bin. This mirrors bin/fm-spawn.sh's resolvers exactly, so a
# route is never excluded for an installation the launcher would accept, and
# never counted for one the launchers would refuse.
harness_installed() {  # <harness>
  local candidate resolved
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    case "$candidate" in
      */*) [ -x "$candidate" ] && return 0 ;;
      *)
        # A PATH candidate counts only when it resolves to an executable file,
        # the same requirement the spawn resolvers enforce: type -P searches
        # PATH alone, so an exported function, builtin, or alias of the same
        # name never stands in for the launcher.
        resolved=$(type -P -- "$candidate" 2>/dev/null) || continue
        [ -n "$resolved" ] && [ -x "$resolved" ] && return 0
        ;;
    esac
  done < <(fm_control_harness_launch_candidates "$1")
  return 1
}

# ---- opt-in gate ---------------------------------------------------------------
# declared_key <provider> <private variable>: set the variable from the source
# $CRED_PATH declares for <provider>. Returns 1 when none is declared, which
# leaves the off gate in charge. Past that point nothing is mistaken for an
# unconfigured resolver: an unreadable or invalid declaration is a
# configuration error, and a declared source this host cannot run or that
# yields no key is an error outcome. Nothing is sent in either case.
declared_key() {
  local provider=$1 src problem value rc
  [ -e "$CRED_PATH" ] || [ -L "$CRED_PATH" ] || return 1
  [ -r "$CRED_PATH" ] || die "credential source declaration not readable: $CRED_PATH"
  command -v jq >/dev/null 2>&1 || die "jq required"
  problem=$(fm_credsrc_check "$CRED_PATH" typesafe openrouter) \
    || die "malformed credential source declaration: $CRED_PATH - $problem"
  fm_credsrc_declares "$CRED_PATH" "$provider" || return 1
  src=$(fm_credsrc_field "$CRED_PATH" "$provider" source)
  fm_credsrc_supported "$src" \
    || emit_error "credential source $src declared for $provider is not supported on this host; nothing sent"
  value=$(fm_credsrc_read "$CRED_PATH" "$provider"); rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$value" ]; then
    if fm_timed_out "$rc"; then
      emit_error "credential source $src declared for $provider did not answer in time; nothing sent"
    fi
    emit_error "credential source $src declared for $provider is unavailable; nothing sent"
  fi
  printf -v "$2" '%s' "$value"
}

# select_key <provider> <KEY_NAME> <private variable>: the selected provider's
# key is the environment copy already in the variable, else KEY_NAME in
# $FM_HOME/.env, else the source declared for the provider. With none of them
# the tool is off, exactly as it was before declarations existed.
select_key() {
  local provider=$1 name=$2 var=$3
  [ -n "${!var}" ] || printf -v "$var" '%s' "$(fmx_env_get "$name" "$FM_HOME/.env")"
  [ -n "${!var}" ] || declared_key "$provider" "$var"
  if [ -z "${!var}" ]; then
    HISTORY_STATUS=off HISTORY_REASON='API key absent'
    echo "dispatch-resolve: off ($name absent from the environment and $FM_HOME/.env)" >&2
    exit 0
  fi
}

# A named lane sends no Choice request and needs no provider or credential.
DISPATCH_PROVIDER=typesafe
DISPATCH_MODEL=$TS_MODEL
if [ -z "$LANE" ]; then
DISPATCH_PROVIDER=${FM_DISPATCH_PROVIDER:-}
[ -n "$DISPATCH_PROVIDER" ] || DISPATCH_PROVIDER=$(fmx_env_get FM_DISPATCH_PROVIDER "$FM_HOME/.env")
DISPATCH_MODEL=${FM_DISPATCH_MODEL:-}
[ -n "$DISPATCH_MODEL" ] || DISPATCH_MODEL=$(fmx_env_get FM_DISPATCH_MODEL "$FM_HOME/.env")
case "$DISPATCH_PROVIDER" in
  '')
    DISPATCH_PROVIDER=typesafe
    DISPATCH_MODEL=$TS_MODEL
    [ -n "$TYPESAFE_API_KEY_PRIVATE" ] || TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
    [ -n "$TYPESAFE_API_KEY_PRIVATE" ] || declared_key typesafe TYPESAFE_API_KEY_PRIVATE
    if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
      TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get OPENROUTER_API_KEY "$FM_HOME/.env")
      TS_BASE=https://openrouter.ai/api
      DISPATCH_MODEL='~typesafe/jev-latest'
    fi
    if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
      HISTORY_STATUS=off HISTORY_REASON='API key absent'
      echo "dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and home .env; OPENROUTER_API_KEY absent from home .env for implicit fallback)" >&2
      exit 0
    fi
    ;;
  typesafe)
    [ -n "$DISPATCH_MODEL" ] || DISPATCH_MODEL=$TS_MODEL
    select_key typesafe TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE
    ;;
  openrouter)
    [ -n "$DISPATCH_MODEL" ] || die "FM_DISPATCH_MODEL required when FM_DISPATCH_PROVIDER=openrouter"
    select_key openrouter OPENROUTER_API_KEY OPENROUTER_API_KEY_PRIVATE
    ;;
  systemone)
    [ -n "$DISPATCH_MODEL" ] || die "FM_DISPATCH_MODEL required when FM_DISPATCH_PROVIDER=systemone"
    DISPATCH_BASE_URL=${FM_DISPATCH_BASE_URL:-}
    [ -n "$DISPATCH_BASE_URL" ] || DISPATCH_BASE_URL=$(fmx_env_get FM_DISPATCH_BASE_URL "$FM_HOME/.env")
    [ -n "$DISPATCH_BASE_URL" ] || die "FM_DISPATCH_BASE_URL required when FM_DISPATCH_PROVIDER=systemone"
    case "$DISPATCH_BASE_URL" in
      http://?*|https://?*) ;;
      *) die "FM_DISPATCH_BASE_URL must start with http:// or https://" ;;
    esac
    DISPATCH_BASE_URL=${DISPATCH_BASE_URL%/}
    # The key is optional: a local host may need none.
    [ -n "$DISPATCH_API_KEY_PRIVATE" ] || DISPATCH_API_KEY_PRIVATE=$(fmx_env_get FM_DISPATCH_API_KEY "$FM_HOME/.env")
    ;;
  openai)
    [ -n "$DISPATCH_MODEL" ] || die "FM_DISPATCH_MODEL required when FM_DISPATCH_PROVIDER=openai"
    [ -n "$OPENAI_API_KEY_PRIVATE" ] || OPENAI_API_KEY_PRIVATE=$(fmx_env_get OPENAI_API_KEY "$FM_HOME/.env")
    if [ -z "$OPENAI_API_KEY_PRIVATE" ]; then
      HISTORY_STATUS=off HISTORY_REASON='API key absent'
      echo "dispatch-resolve: off (OPENAI_API_KEY absent from the environment and $FM_HOME/.env)" >&2
      exit 0
    fi
    ;;
  *) die "unknown FM_DISPATCH_PROVIDER: $DISPATCH_PROVIDER (expected typesafe, openrouter, systemone, or openai)" ;;
esac
case "$DISPATCH_PROVIDER" in
  typesafe) ENDPOINT=$TS_BASE/v1/systemone TIMEOUT=$TS_TIMEOUT KEY_PRIVATE=$TYPESAFE_API_KEY_PRIVATE ;;
  openrouter) ENDPOINT=$OR_BASE/alpha/decisions TIMEOUT=$OR_TIMEOUT KEY_PRIVATE=$OPENROUTER_API_KEY_PRIVATE ;;
  systemone) ENDPOINT=$DISPATCH_BASE_URL/v1/systemone TIMEOUT=$SO_TIMEOUT KEY_PRIVATE=$DISPATCH_API_KEY_PRIVATE ;;
  openai) ENDPOINT=$OA_BASE/v1/decisions TIMEOUT=$OA_TIMEOUT KEY_PRIVATE=$OPENAI_API_KEY_PRIVATE ;;
esac
export -n KEY_PRIVATE 2>/dev/null || true
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
cp "$RULES_PATH" "$RULES" || die "could not snapshot rules file: $RULES_PATH"
chmod 400 "$RULES" || die "could not protect rules snapshot"
VERIFIED_HARNESSES=$(fm_control_harnesses | jq -Rsc 'split("\n") | map(select(length > 0))')

# The fields this tool consumes must be well formed; bootstrap owns the wider
# schema diagnostic, but an intake never selects around a malformed file.
# effort_ok must accept exactly what bootstrap's crew_dispatch_validate accepts.
# Codex max and ultra follow the installed catalog (bin/fm-codex-catalog-lib.sh).
codex_max_ok=$({ jq -r '.. | objects | select(.harness == "codex" and .effort == "max") | .model | strings' "$RULES" 2>/dev/null || true; } | fm_codex_max_allowed_json)
codex_ultra_ok=$({ jq -r '.. | objects | select(.harness == "codex" and .effort == "ultra") | .model | strings' "$RULES" 2>/dev/null || true; } | fm_codex_ultra_allowed_json)
rules_err=$(jq -r --argjson codex_max_ok "$codex_max_ok" --argjson codex_ultra_ok "$codex_ultra_ok" --argjson verified_harnesses "$VERIFIED_HARNESSES" --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" "$FM_DISPATCH_LANES_JQ"'
  def verified($h): $verified_harnesses | index($h);
  def provider_id($p): ($p | type) == "string" and ($p | test($provider_re));
  def effort_ok($h; $m; $e):
    if $e == null then true
    elif ($e | type) != "string" then false
    elif $e == "ultra" then
      ((($h == "pi" or $h == "pi-signed") and (($m | type) == "string") and ($m | startswith("codex-native/")) and ($m | length) > 13)
        or ($h == "codex" and ($codex_ultra_ok | any(. == $m))))
    elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "codex" then ((["low","medium","high","xhigh"] | index($e)) != null or ($e == "max" and ($codex_max_ok | any(. == $m))))
    elif $h == "grok" then (["low","medium","high"] | index($e)) != null
    elif $h == "agy" or $h == "kiro" then (["low","medium","high","xhigh","max"] | index($e)) != null
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
  elif has("preferred_provider") and (provider_id(.preferred_provider) | not) then "preferred_provider must be a lowercase provider ID (for example codex)"
  elif has("rules") and (.rules | type) != "array" then "rules must be an array"
  elif any((.rules // [])[]; type != "object") then "each rule must be an object"
  elif any((.rules // [])[]; (.when | type) != "string" or (.when | length) == 0) then "each rule needs non-empty when"
  elif (dispatch_lanes_error // null) != null then dispatch_lanes_error
  elif any(([(.rules // [])[] | profiles(.use)[]] + profiles(.default // null))[]; type == "object" and has("unmetered")) then "unmetered must be declared on a lane class, not a profile"
  elif any(([(.rules // [])[] | profiles(.use)[]] + profiles(.default // null))[]; type == "object" and has("spend_priority")) then "spend_priority must be declared on a lane class, not a profile"
  elif any((.rules // [])[]; (has("classes") | not) and (profiles(.use) | length) == 0) then "each rule needs at least one use profile"
  elif any((.rules // [])[]; has("approval") and .approval != "captain") then "approval must be \"captain\" when present"
  elif any((.rules // [])[]; has("min_confidence") and ((.min_confidence | type) != "number" or .min_confidence < 0 or .min_confidence > 1)) then "min_confidence must be a number from 0 through 1 when present"
  elif any((.rules // [])[]; has("select") and ((.select | type) != "string" or (.select | length) == 0)) then "select must be a non-empty string"
  elif any((.rules // [])[]; has("select") and .select != "quota-balanced") then
    "unknown select: " + ([.rules[] | select(has("select") and .select != "quota-balanced") | .select] | unique | join(", "))
  elif has("shared_quota") and (.shared_quota | type) != "boolean" then "shared_quota must be true or false when present"
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

# Optional quota planning overrides stay baseline-identical when absent.
PLANNING_PATH="$CONFIG/quota-planning.json"
PLANNING_JSON='{"overrides":[]}'
PLANNING_PRESENT=false
if [ -e "$PLANNING_PATH" ] || [ -L "$PLANNING_PATH" ]; then
  [ -f "$PLANNING_PATH" ] && [ -r "$PLANNING_PATH" ] || die "malformed planning file: $PLANNING_PATH - expected a readable regular file"
  planning_err=$(jq -sr --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" "$FM_QUOTA_PLANNING_JQ"'
    def nonblank_string: (type == "string") and (length > 0) and (test("\\s") | not);
    def override_bad:
      if type != "object" then true
      elif ((keys - ["provider", "accountKey", "windowId", "horizonSeconds", "expiresAt"]) | length) != 0 then true
      elif ((.provider | nonblank_string) | not) then true
      elif (.provider | test($provider_re) | not) then true
      elif ((.accountKey | nonblank_string) | not) then true
      elif (has("windowId") and ((.windowId | nonblank_string) | not)) then true
      elif (.horizonSeconds | type) != "number" then true
      elif (.horizonSeconds <= 0 or (.horizonSeconds | isinfinite)) then true
      elif ((.expiresAt | quota_ts) == null) then true
      else false end;
    if length != 1 then "expected exactly one JSON object"
    elif (.[0] | type) != "object" then "top-level value must be an object"
    elif ((.[0] | has("overrides")) | not) or ((.[0].overrides | type) != "array") then "overrides must be an array"
    elif any(.[0].overrides[]; override_bad) then "each override needs provider, accountKey, horizonSeconds above 0, an ISO expiresAt, and no other fields except optional windowId"
    elif ([.[0].overrides[] | [.provider, .accountKey, (.windowId // "")] | @json] | length) !=
         ([.[0].overrides[] | [.provider, .accountKey, (.windowId // "")] | @json] | unique | length)
    then "overrides must not duplicate provider, accountKey, and windowId"
    else empty end
  ' "$PLANNING_PATH" 2>/dev/null) || die "malformed planning file: $PLANNING_PATH (not JSON)"
  [ -z "$planning_err" ] || die "malformed planning file: $PLANNING_PATH - $planning_err"
  PLANNING_JSON=$(jq -sc '.[0]' "$PLANNING_PATH") || die "malformed planning file: $PLANNING_PATH (not JSON)"
  PLANNING_PRESENT=true
fi

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

# ---- harness -> provider map and installed-tool probe -------------------------
PMAP='{}'
INSTALLED='{}'
while IFS= read -r h; do
  [ -n "$h" ] || continue
  p=$(fm_quota_single_provider_for_harness "$h" 2>/dev/null) || p=''
  PMAP=$(jq -c --arg h "$h" --arg p "$p" '. + {($h): (if $p == "" then null else $p end)}' <<<"$PMAP")
  # Installed-tool gate input: one cheap local lookup per configured harness
  # over every launch location the single-owner table in fm-control-lib.sh
  # accepts, so a harness installed only at a resolver fallback stays
  # eligible. A harness with no launch location anywhere makes its route
  # not eligible rather than picked and then failed at launch.
  if harness_installed "$h"; then
    INSTALLED=$(jq -c --arg h "$h" '. + {($h): true}' <<<"$INSTALLED")
  else
    INSTALLED=$(jq -c --arg h "$h" '. + {($h): false}' <<<"$INSTALLED")
  fi
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



if [ "$RULE_COUNT" -eq 0 ] && [ -z "$LANE" ]; then
  no_rules
fi

RESP_FILE=$(mktemp) || die "mktemp failed"
QUOTA=$(mktemp) || { rm -f "$RESP_FILE"; die "mktemp failed"; }
TASK_TEXT=$(mktemp) || { rm -f "$RESP_FILE" "$QUOTA"; die "mktemp failed"; }
SEND_TEXT=$(mktemp) || { rm -f "$RESP_FILE" "$QUOTA" "$TASK_TEXT"; die "mktemp failed"; }

never_send_off() {
  HISTORY_STATUS=off HISTORY_REASON=$1
  echo "dispatch-resolve: off ($1; nothing sent)" >&2
  exit 0
}

# Checks the endpoint and every string the final request body carries,
# including strings inside JSON text such as OpenAI's serialized input, so no
# text reaches the network unchecked. grep's own stderr is discarded because
# it can echo the pattern.
never_send_check() {
  local list value n=0 rc
  [ -e "$NEVER_SEND_PATH" ] || [ -L "$NEVER_SEND_PATH" ] || return 0
  { [ -f "$NEVER_SEND_PATH" ] && [ -r "$NEVER_SEND_PATH" ]; } \
    || never_send_off "$NEVER_SEND_PATH is not a readable regular file"
  # Collapse whitespace runs on both sides so a value the brief wraps across
  # lines or spaces differently still matches
  jq -r --arg endpoint "$ENDPOINT" '
    $endpoint, (.. | strings | ., (try (fromjson | .. | strings) catch empty))
    | gsub("\\s+"; " ")' <<<"$BODY" > "$SEND_TEXT" 2>/dev/null \
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
  REQUEST=$(jq -n --rawfile brief "$TASK_TEXT" --arg project "$PROJECT" --arg model "$DISPATCH_MODEL" \
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
  # OpenAI's Decisions API takes text input and a named choices array, so the
  # same state and Choice question are rewritten into its shape.
  if [ "$DISPATCH_PROVIDER" = openai ]; then
    BODY=$(jq -c '{
      model,
      input: (.state | tojson),
      questions: [{
        type: "choice", name: "rule", instructions: .questions.rule.instructions,
        choices: [.questions.rule.criteria | to_entries[] | {value: .key, description: .value}]
      }]
    }' <<<"$REQUEST") || emit_error "could not build the OpenAI request"
  else
    BODY=$REQUEST
  fi
  never_send_check
  HISTORY_MODEL=$DISPATCH_MODEL
  T0=$(fm_timing_now_ms)
  if [ -n "$KEY_PRIVATE" ]; then
    HTTP=$(printf '%s' "$BODY" | curl -sS --max-time "$TIMEOUT" -o "$RESP_FILE" -w '%{http_code}' \
      -X POST "$ENDPOINT" -H 'Content-Type: application/json' \
      -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$KEY_PRIVATE") \
      --data-binary @- 2>/dev/null) || HTTP=000
  else
    HTTP=$(printf '%s' "$BODY" | curl -sS --max-time "$TIMEOUT" -o "$RESP_FILE" -w '%{http_code}' \
      -X POST "$ENDPOINT" -H 'Content-Type: application/json' \
      --data-binary @- 2>/dev/null) || HTTP=000
  fi
  T1=$(fm_timing_now_ms)
  LAT_MS=$(( T1 - T0 ))
  if [ "$DISPATCH_PROVIDER" = typesafe ]; then
    [ "$HTTP" = 200 ] || emit_error "http $HTTP after ${LAT_MS} ms: $(head -c 200 "$RESP_FILE" 2>/dev/null | tr '\n' ' ')"
  else
    [ "$HTTP" = 200 ] || emit_error "http $HTTP after ${LAT_MS} ms"
  fi
  # Map an OpenAI answer back to the System One shape the shared validation
  # below checks. A refusal, a missing or duplicated rule answer, or duplicated
  # option values is not a rule Choice answer. Usage is display-only, so it is
  # kept only when both token counts are numeric.
  if [ "$DISPATCH_PROVIDER" = openai ]; then
    jq -e '
      (.answers | type) == "array" and
      ([.answers[] | select(type == "object" and .name == "rule")]) as $rule |
      ($rule | length) == 1 and $rule[0].type == "choice" and
      ($rule[0].probabilities | type) == "array" and
      all($rule[0].probabilities[]; type == "object" and (.value | type) == "string") and
      ($rule[0].probabilities | map(.value) | length) == ($rule[0].probabilities | map(.value) | unique | length)' \
      "$RESP_FILE" >/dev/null 2>&1 || emit_error "response is not a rule Choice answer"
    if ! jq --arg model "$DISPATCH_MODEL" '
      ([.answers[] | select(type == "object" and .name == "rule")][0]) as $a |
      {
        model: (if (.model | type) == "string" then .model else $model end),
        answers: {rule: {
          choice: $a.choice, confidence: $a.confidence,
          probabilities: ($a.probabilities | map({key: .value, value: .probability}) | from_entries)
        }}
      }
      + (if (.usage.input_tokens | type) == "number" and (.usage.output_tokens | type) == "number"
         then {usage: {input_tokens: .usage.input_tokens, output_tokens: .usage.output_tokens}} else {} end)' \
      "$RESP_FILE" > "$RESP_FILE.mapped" 2>/dev/null || ! mv "$RESP_FILE.mapped" "$RESP_FILE"; then
      rm -f "$RESP_FILE.mapped"
      emit_error "response is not a rule Choice answer"
    fi
  fi
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

# Retain only validated score/usage fields for errors after the API succeeded.
HISTORY_EVIDENCE=$(jq -c '{model, tokens: (.usage // null),
  rule: .answers.rule.choice, confidence: .answers.rule.confidence,
  probabilities: .answers.rule.probabilities}' "$RESP_FILE" 2>/dev/null) || HISTORY_EVIDENCE='{}'

# Experiment sampling bucket, only when a class declares an experiment: the
# same task text always lands in the same bucket.
SAMPLE=0
if jq -e 'any((.classes // {})[]; has("experiment"))' "$RULES" >/dev/null; then
  command -v cksum >/dev/null 2>&1 || emit_error "cksum not installed for experiment sampling"
  read -r crc _ < <(cksum < "$TASK_TEXT") && [[ "$crc" =~ ^[0-9]+$ ]] || emit_error "could not sample the brief for experiments"
  SAMPLE=$((crc % 100))
fi

# ---- quota evidence: one quota-axi --json snapshot, skipped entirely under the
# ---- shared-quota opt-out (a stub keeps the slurpfile contract intact) ---------
SQ=false
SHARED_QUOTA=$(jq -r '.shared_quota // false' "$RULES" 2>/dev/null) || SHARED_QUOTA=false
if [ "$SHARED_QUOTA" = true ]; then
  printf '{"providers":[]}\n' > "$QUOTA"
  SQ=true
else
  command -v quota-axi >/dev/null 2>&1 || emit_error "quota-axi not installed"
  "$SCRIPT_DIR/fm-quota-read.sh" --json > "$QUOTA" || emit_error "quota-axi --json failed"
  fm_quota_json_valid < "$QUOTA" || emit_error "quota-axi --json returned an invalid snapshot"
fi

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

# Snapshot readable ordinary task records without executing their contents.
# Last field wins, as in fm-spawn.sh's away spend cap; one record counts once
# per matching class or group even when routes share harness and model.
LIVE_TASKS=$(
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ -r "$meta" ] || continue
    meta_text=$(cat "$meta" 2>/dev/null) || continue
    jq -Rsc '
      [split("\n")[] | capture("^(?<key>kind|harness|model)=(?<value>.*)$")]
      | from_entries | select(.kind != "secondmate")
      | {harness, model: (if .model == "default" then "" else (.model // "") end)}
    ' <<<"$meta_text"
  done | jq -sc '.'
) || emit_error "live task snapshot failed"

# ---- resolution: declared gates + quota evidence + argmax, all in jq ------------
DIRECT=false
[ -z "$LANE" ] || DIRECT=true
RESULT=$(jq -n --arg floor "$CONFIDENCE_FLOOR" --argjson lat "$LAT_MS" --arg none_criterion "$DEFAULT_WHEN" --argjson pmap "$PMAP" --argjson sq "$SQ" --argjson installed "$INSTALLED" --argjson agy_ids "$AGY_IDS" --argjson agy_levels "$AGY_LEVELS" --argjson devin_ids "$DEVIN_IDS" --argjson horizon "$COMPLETION_HORIZON" \
  --argjson direct "$DIRECT" --arg exclude "$EXCLUDE_FAMILY" --argjson tags "$DATA_TAGS" --arg project "$PROJECT" --argjson sample "$SAMPLE" --argjson live_tasks "$LIVE_TASKS" \
  --argjson planning "$PLANNING_JSON" --argjson planning_present "$PLANNING_PRESENT" \
  --slurpfile resp "$RESP_FILE" --slurpfile rules "$RULES" --slurpfile quota "$QUOTA" "$FM_QUOTA_ROW_JQ$FM_QUOTA_PLANNING_JQ$FM_QUOTA_AGY_JQ$FM_QUOTA_DEVIN_JQ$FM_DISPATCH_LANES_JQ"'
  ($resp[0]) as $r | ($rules[0]) as $cfg | ($quota[0]) as $q | (quota_selection_metric($q)) as $metric | (($q.generatedAt // "") | quota_ts) as $now | ($r.answers.rule) as $a |
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
    $rows | map({scope, status, pct: (.effectivePercentRemaining // null), runway: (.runway.status // null), usableRunwaySeconds: (.runway.usableRunwaySeconds // null), spendScore: (.selection[$metric] // null)});
  def evaluate_route($c; $unmetered; $spend_priority):
    (provider_of($c)) as $p | (lane_of($c)) as $lane |
    if ($installed[$c.harness] // false) | not then
      {profile: $c, eligible: false, reason: "\($c.harness) tool not installed on this host"}
    elif $sq then
      {profile: $c, provider: $p, eligible: true, sq: true, reason: "ok"}
    elif $p == null then {profile: $c, eligible: false, reason: "no provider family for harness \($c.harness); declare provider on the profile"}
    elif $unmetered then
      {profile: $c, provider: $p, unmetered: true, spendScore: $spend_priority, eligible: true, reason: "unmetered (declared)"}
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
      elif any($rows[]; (quota_selection_known($metric) | not)) then
        ($rows | map(select(quota_selection_known($metric) | not)) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: true, unranked: true, reason: "\($metric) missing, non-numeric, or selection not known at \($bad.scope): not rankable"}
      else
        (prov($p; $lane)) as $prov_row |
        ($rows | map(quota_plan_adjust($prov_row; .; ($planning.overrides // []); $p; $lane; $now; $metric) as $row_plan
                     | . + {effectiveSpend: ($row_plan.value // .selection[$metric]), rowPlan: $row_plan})
               | min_by(.effectiveSpend)) as $limiting |
        {profile: $c, provider: $p, bounds: $bounds, scope: $limiting.scope, pct: $limiting.effectivePercentRemaining,
         spendScore: $limiting.effectiveSpend, runway: $limiting.runway.status, eligible: true, reason: "ok"}
        + (if $limiting.rowPlan != null then {planning: $limiting.rowPlan, nativeSpend: $limiting.rowPlan.native} else {} end)
      end
    end;
  def evaluate($c): evaluate_route($c; false; 0);
  # Apply the same family restriction before either profile or lane selection.
  def preferred_pool($cands):
    ([$cands[] | select($cfg.preferred_provider != null and (.provider // provider_of(.profile)) == $cfg.preferred_provider)]) as $family |
    ([$family[] | select(.eligible)]) as $preferred |
    {pool: (if ($preferred | length) > 0 then $preferred else $cands end),
     restricted: (($preferred | length) > 0)}
    + (if $cfg.preferred_provider == null then {}
       else {decision: ($cfg.preferred_provider + ": " +
         (if ($family | length) == 0 then "not in matched profiles; preserve the selected rule"
          elif ($preferred | length) > 0 then "prefer eligible family candidates"
          else "fall back; every matched family candidate is ineligible" end))} end);
  def rule_at($c):
    if ($c | test("^rule_[1-9][0-9]*$")) then
      ($c | ltrimstr("rule_") | tonumber) as $n |
      if $n <= (($cfg.rules // []) | length) then $cfg.rules[$n - 1] else null end
    else null end;
  def declared_confidence($c): rule_at($c) as $x | $x != null and ($x | has("min_confidence"));
  def confidence_floor($c): if declared_confidence($c) then rule_at($c).min_confidence else ($floor | tonumber) end;
  def rankable: .eligible and ((.unranked // false) | not);
  # Synthetic unmetered scores rank routes but never measure quota pace.
  def ahead_of_pace: .sq != true and .unmetered != true and .spendScore < 0;
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
  def live_count($routes):
    [$live_tasks[] | . as $task |
      select(any($routes[]; .harness == $task.harness and (.model // "") == $task.model))] | length;
  def class_exclusion($k):
    if $k.max_live != null and $k.live >= $k.max_live then "at live cap \($k.live)/\($k.max_live)"
    elif $k.group_max_live != null and $k.group_live >= $k.group_max_live then "at live cap group \($k.live_cap_group) \($k.group_live)/\($k.group_max_live)"
    elif $exclude != "" and $k.family == $exclude then "second opinion excludes family \($k.family)"
    elif $exclude != "" and $k.experiment != null then "an experiment class never serves a second opinion"
    elif $k.experiment != null and $sample >= ($k.experiment.share * 100) then "experiment not sampled for this task"
    elif $k.data_policy != null then policy_block($k.data_policy)
    else null end;
  def lane_eval($rule):
    (($cfg.live_cap_groups // {}) | with_entries(.key as $group |
      .value = live_count([$cfg.classes[] | select(.live_cap_group == $group) | .routes[]]))) as $group_counts |
    [dispatch_lane_refs($rule)[] | . as $ref | ($cfg.classes[$ref.class]) as $def |
      {name: $ref.class, gate: ($ref.gate // null), family: $def.family,
       experiment: ($def.experiment // null), data_policy: ($def.data_policy // null),
       unmetered: ($def.unmetered // false), spend_priority: ($def.spend_priority // 0), routes: $def.routes,
       max_live: ($def.max_live // null),
       live: live_count($def.routes), live_cap_group: ($def.live_cap_group // null),
       group_live: ($group_counts[$def.live_cap_group // ""] // null),
       group_max_live: ($cfg.live_cap_groups[$def.live_cap_group // ""].max_live // null)}
      | . + {excluded: class_exclusion(.)}
      | . as $k
      | . + {candidates: [.routes[] |
          (if $k.excluded != null then {profile: ., eligible: false, reason: $k.excluded} else evaluate_route(.; $k.unmetered; $k.spend_priority) end)
          + {class: $k.name, family: $k.family, live: $k.live, max_live: $k.max_live,
             live_cap_group: $k.live_cap_group, group_live: $k.group_live, group_max_live: $k.group_max_live}
          + (if $k.experiment != null then {experiment: true} else {} end)]}
    ] as $classes0 |
    ([$classes0[] | select(.gate == null) | .candidates[] | select(rankable)]) as $others |
    [$classes0[] |
      if ($sq | not) and .gate == "others-ahead-of-pace" and .excluded == null then
        ([.candidates[] | select(rankable)] | max_by(.spendScore)) as $own |
        (if ($others | length) == 0 then "pace gate closed: no ungated class in the lane has a rankable \($metric)"
         elif any($others[]; ahead_of_pace | not) then
           "pace gate closed: \([$others[] | select(ahead_of_pace | not) | .class] | unique | join(", ")) not spending ahead of pace"
         elif $own == null then "pace gate closed: this class has no rankable \($metric)"
         elif ($own | ahead_of_pace) then "pace gate closed: this class is itself spending ahead of pace"
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
    elif $sq then {status: "clear", chosen: $ranked[0]}
    else ($ranked | max_by(.spendScore)) as $best |
      ([$ranked[] | select(.spendScore == $best.spendScore)]) as $ties |
      (if ([$ties[].class] | unique | length) > 1 then
         ($ties | map(.live) | min) as $fewest | [$ties[] | select(.live == $fewest)]
       else $ties end) as $final |
      if ($final | length) > 1
      then {status: "escalate", reason: "genuine \($metric) tie\($where)"}
      else {status: "clear", chosen: $final[0]}
        + (if ($ties | length) > 1 then
             {tie_break: "\($final[0].class) has fewest live workers (\($final[0].live)) among \($metric) ties"}
           else {} end)
      end
    end;
  # A sampled experiment with a rankable route takes the task; an ordered lane
  # stops at its first class with any eligible route, ranked or not, so unknown
  # quota escalates instead of silently skipping to a later class.
  def lane_pick($le):
    preferred_pool($le.candidates) as $preference |
    (if $preference.restricted then
       $le | .candidates = $preference.pool |
       .classes |= map(.candidates |= map(select(.eligible and .provider == $cfg.preferred_provider)))
     else $le end) as $le |
    ([$le.classes[] | select(.experiment != null and .excluded == null) | .candidates[] | select(rankable)]) as $sampled |
    if ($sampled | length) > 0 then argmax_pick($sampled; " among sampled experiment routes")
    elif $le.order == "ordered" then
      ([$le.classes[] | select(any(.candidates[]; .eligible))] | first) as $first |
      if $first == null then {status: "escalate", reason: "no class in the ordered lane has an eligible route"}
      else argmax_pick($first.candidates; " in first viable class \($first.name)") end
    else argmax_pick($le.candidates; "") end
    | . + (if $preference.decision then {preferred_provider: $preference.decision} else {} end)
    | if $preference.restricted and .status == "escalate" then
        .reason += " in preferred provider \($cfg.preferred_provider); uncertainty does not authorize fallback"
      else . end;
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
  (if $sq or $rule == null then "none" else floor_state($rule.floor; $rule.floor.provider; "") end) as $rule_floor_state |
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
    planning: (if $planning_present | not then {present: false}
               else {present: true, active: [($planning.overrides // [])[]
                 | select((.expiresAt | quota_ts) != null and $now != null and $now < (.expiresAt | quota_ts))
                 | {provider, accountKey, windowId: (.windowId // null), horizonSeconds, expiresAt}]} end),
    direct: $direct, spendMetric: $metric,
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
    + (if $pick.preferred_provider then {preferred_provider: $pick.preferred_provider} else {} end)
    + (if $pick.status == "clear" then {chosen: $pick.chosen, tie_break: $pick.tie_break} else {reason: $pick.reason} end)
    + (if $pick.status == "clear" and ($unranked | length) > 0 then
         {unranked_note: "\($unranked | length) eligible candidate(s) unranked (\([$unranked[].provider] | unique | join(", ")))"}
       else {} end)
  elif $exclude != "" then
    $ev + {status: "escalate", reason: "a second opinion needs a lane whose classes declare model families; \($sel.source) has none",
      note: $sel.note, candidates: ($sel.use | map(evaluate(.)))}
  elif ($sel.use | length) == 0 then $ev + {status: "escalate", reason: "no profiles configured for \($sel.source)", note: $sel.note, candidates: []}
  else
    ($sel.use | map(evaluate(.))) as $cands |
    preferred_pool($cands) as $preference |
    ($preference.pool) as $pool |
    ($ev + (if $preference.decision then {preferred_provider: $preference.decision} else {} end)) as $ev |
    ([$pool[] | select(.eligible and ((.unranked // false) | not))]) as $elig |
    ([$cands[] | select(.unranked)]) as $unranked |
    if ($elig | length) == 0 then $ev + {status: "escalate",
      reason: ("no rankable eligible candidate" +
        (if $preference.restricted then " in preferred provider \($cfg.preferred_provider); uncertainty does not authorize fallback" else "" end)),
      note: $sel.note, candidates: $cands}
    else
      (if $sq then ($elig | first) else ($elig | max_by(.spendScore)) end) as $best |
      (if $sq then 1 else ([$elig[] | select(.spendScore == $best.spendScore)] | length) end) as $ties |
      if $ties > 1 then $ev + {status: "escalate", reason: "genuine \($metric) tie", note: $sel.note, candidates: $cands}
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
  (.spendMetric // "spendPriority") as $metric |
  "dispatch-resolve:",
  "  status: \(.status | flat)",
  "  completion_horizon_seconds: \(.completion_horizon_seconds)",
  (if .planning.present then
     (if (.planning.active | length) > 0
      then (.planning.active[] | "  planning: active provider=\(.provider | flat) account=\(.accountKey | flat)"
             + (if .windowId then " window=\(.windowId | flat)" else "" end)
             + " horizon_seconds=\(.horizonSeconds) expires_at=\(.expiresAt | flat) (rolling planning horizon, not a vendor reset)")
      else "  planning: inactive (no override active at the quota snapshot time; native \($metric) used)" end)
   else empty end),
  (if $metric == "spendPressure" then "  spend_metric: \($metric)" else empty end),
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
  (if .preferred_provider then "  preferred_provider: \(.preferred_provider | flat)" else empty end),
  (if .unranked_note then "  note: \(.unranked_note | flat)" else empty end),
  (if .tie_break then "  tie_break: \(.tie_break | flat)" else empty end),
  (.candidates[]? | "  candidate: \(.profile.harness | flat):\(show(.profile.model))"
      + (if .class then "  class=\(.class | flat) family=\(.family | flat)" + (if .experiment then " experiment" else "" end) else "" end)
      + (if .provider then "  provider=\(.provider | flat)" else "" end)
      + (if .unmetered then "  quota=unmetered (declared)  \($metric)=\(show(.spendScore))  runway=unmetered"
         elif .scope then "  scope=\(.scope | flat)  remaining=\(show(.pct))%  \($metric)=\(show(.spendScore))  runway=\(show(.runway))" else "" end)
      + (if .planning then "  native_\($metric)=\(show(.nativeSpend))  planning_horizon_seconds=\(.planning.horizonSeconds)  planning_window=\(.planning.windowId | flat)" else "" end)
      + (if (.bounds // [] | length) > 1 then "  bounds=" + ([.bounds[] | "\(.scope | flat):\(show(.pct))%/\((.runway // .status) | flat)"] | join(",")) else "" end)
      + "  -> " + (if .unranked then "eligible, unranked: \(.reason | flat): disclosed uncertainty" elif .sq and .eligible then "eligible (quota ranking off: home declares a single shared quota)" elif .eligible then "eligible" else "not eligible: \(.reason | flat)" end)
      + (if (.bounds // [] | length) > 0 then "  runway_seconds=" + ([.bounds[] | "\(.scope | flat):\(if .runway == "exhausted_now" then "0" elif .runway == "through_reset" then "through_reset" else show(.usableRunwaySeconds // "unknown") end)"] | join(",")) else "" end)
      + (if .class then "  live=\(.live)" + (if .max_live then " max_live=\(.max_live)" else "" end)
          + (if .live_cap_group then " live_cap_group=\(.live_cap_group | flat) group_live=\(.group_live) group_max_live=\(.group_max_live)" else "" end) else "" end)),
  (if .chosen.class then "  class: \(.chosen.class | flat)  family=\(.chosen.family | flat)" + (if .chosen.experiment then "  experiment" else "" end) else empty end),
  (if .chosen then "  profile: --harness \(.chosen.profile.harness | shell_arg)"
      + (if .chosen.profile.model then " --model \(.chosen.profile.model | shell_arg)" else "" end)
      + (if .chosen.profile.effort then " --effort \(.chosen.profile.effort | shell_arg)" else "" end) else empty end)' <<<"$RESULT") || emit_error "output rendering failed"
printf '%s\n' "$TEXT"
exit 0
