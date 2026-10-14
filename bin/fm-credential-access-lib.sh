#!/usr/bin/env bash
# fm-credential-access-lib.sh - shell transport for fm-credential-access.mjs.
# Sourced by fm-command-policy-lib.sh; adapters initialize credential_policy
# after loading their firstmate-owned policy, then call credential_native or
# evaluate_exec. classify_credential_access accepts structured JSON and sets
# CREDENTIAL_LAST_CATEGORY/REASON. credential_apply translates that metadata
# into the shared policy veto; unresolved footprints hold without a judge.
# Policy fields: credential_user_home (trusted launch HOME) and
# credential_registry_required (registry existed at launch). The only registry
# path is <policy config>/declared-credentials.json, never a tool/brief field.
# Registry schema, path identity, and the four categories are owned by the mjs
# classifier's header, not by adapter-specific text/filename heuristics.

CREDENTIAL_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CREDENTIAL_USER_HOME='' CREDENTIAL_REGISTRY_PATH='' CREDENTIAL_REGISTRY_REQUIRED=false
CREDENTIAL_TRACE=0 CREDENTIAL_HOLD='' CREDENTIAL_CATEGORY=ordinary
CREDENTIAL_LAST_CATEGORY=ordinary CREDENTIAL_LAST_REASON=''

credential_policy() {
  local config=${CONFIG_DIR:-} fields
  CREDENTIAL_USER_HOME=${HOME:-}
  if [ -n "${POLICY:-}" ] && [ -r "$POLICY" ]; then
    fields=$(jq -r '[.credential_user_home // "", (.credential_registry_required // false | tostring)] | .[]' "$POLICY" 2>/dev/null) || fields=''
    if [ -n "$fields" ]; then
      [ -z "${fields%%$'\n'*}" ] || CREDENTIAL_USER_HOME=${fields%%$'\n'*}
      CREDENTIAL_REGISTRY_REQUIRED=${fields#*$'\n'}
    fi
  fi
  if [ -z "$config" ] && [ -n "${STATUS:-}" ]; then
    config="${STATUS%/*}/../config"
  fi
  [ -z "$config" ] || CREDENTIAL_REGISTRY_PATH=$(norm_abs "$config/declared-credentials.json")
  # Also protects the registry from every statically visible writer already
  # covered by the existing wiring guard, including granted write directories.
  [ -z "$CREDENTIAL_REGISTRY_PATH" ] \
    || POLICY_PROTECTED="${POLICY_PROTECTED:-}"$'\n'"$CREDENTIAL_REGISTRY_PATH"
}

classify_credential_access() {  # <structured request JSON>
  local request output
  load_grants
  request=$(printf '%s' "$1" | jq -c --arg cwd "${CWD-$WORKTREE}" \
    --arg home "$CREDENTIAL_USER_HOME" --arg registry "$CREDENTIAL_REGISTRY_PATH" \
    --argjson required "$CREDENTIAL_REGISTRY_REQUIRED" --argjson trace "$CREDENTIAL_TRACE" \
    --arg grants "$GRANT_ENV_FILES" --arg roots "$WORKTREE"$'\n'"$DATA_DIR"$'\n'"$TASKTMP"$'\n'"$GRANT_WRITE_DIRS" \
    '. + {cwd:$cwd, userHome:$home, registryPath:$registry, registryRequired:$required,
      trace:($trace == 1), useGrants:($grants | split("\n") | map(select(. != ""))),
      writeRoots:($roots | split("\n") | map(select(. != "")))}' 2>/dev/null) || request=''
  output=$(printf '%s' "$request" | node "$CREDENTIAL_LIB_DIR/fm-credential-access.mjs" 2>/dev/null) || output=''
  CREDENTIAL_LAST_CATEGORY=$(printf '%s' "$output" | jq -r '.category // "unresolved"' 2>/dev/null) || CREDENTIAL_LAST_CATEGORY=unresolved
  CREDENTIAL_LAST_REASON=$(printf '%s' "$output" | jq -r '.reason // "classifier-unavailable"' 2>/dev/null) || CREDENTIAL_LAST_REASON=classifier-unavailable
}

credential_apply() {
  case "$CREDENTIAL_LAST_CATEGORY" in
    protected-disclosure|unresolved)
      CREDENTIAL_CATEGORY=$CREDENTIAL_LAST_CATEGORY CREDENTIAL_HOLD=1 SENSITIVE_HIT=1
      no_approve "credential access $CREDENTIAL_LAST_CATEGORY: $CREDENTIAL_LAST_REASON"
      # No script snapshot can accompany a call with a credential veto.
      JUDGE_SCRIPT_INPUT='' JUDGE_SCRIPT_HASHES=''
      ;;
  esac
}

credential_trace_context() {
  local i j base flag
  for ((i = 0; i < ${#T_TXT[@]}; i++)); do
    [ "${T_KIND[i]}" = w ] || continue
    base=${T_TXT[i]##*/}
    case "$base" in set|bash|sh|zsh|ksh|dash) ;; *) continue ;; esac
    for ((j = i + 1; j < ${#T_TXT[@]}; j++)); do
      [ "${T_KIND[j]}" = w ] || break
      flag=${T_TXT[j]}
      case "$flag" in
        -o) case "${T_TXT[j+1]-}" in xtrace|verbose) CREDENTIAL_TRACE=1 ;; esac; j=$((j + 1)) ;;
        --verbose|--xtrace) CREDENTIAL_TRACE=1 ;;
        -[^-]*) case "$flag" in *x*|*v*) CREDENTIAL_TRACE=1 ;; esac ;;
        +*) ;;
        *) break ;;
      esac
    done
  done
}

credential_segment() {
  local i words redirects request dynamic=false bare_env=false
  words=$({
    for ((i = 0; i < ${#E[@]}; i++)); do printf '%s\0%s\0%s\0' "${E[i]}" "${EV[i]}" "${EG[i]}"; done
  } | jq -Rsc 'split("\u0000") | .[:-1] | [range(0; length; 3) as $i | {value:.[$i], expanded:(.[$i+1] == "1"), glob:(.[$i+2] == "1")}]')
  redirects=$({
    for ((i = 0; i < ${#SRO[@]}; i++)); do printf '%s\0%s\0%s\0%s\0' "${SRO[i]}" "${SRT[i]}" "${SRV[i]}" "${SRG[i]-0}"; done
  } | jq -Rsc 'split("\u0000") | .[:-1] | [range(0; length; 4) as $i | {operator:.[$i], path:.[$i+1], role:"redirection", expanded:(.[$i+2] == "1"), glob:(.[$i+3] == "1")}]')
  for ((i = 0; i < ${#SW[@]}; i++)); do
    case "${SW[i]}" in xargs|-C|--chdir|--chdir=*) dynamic=true ;; esac
  done
  if [ "${#E[@]}" = 0 ] && [ "${SW[0]-}" = env ]; then
    bare_env=true words='[{"value":"env","expanded":false,"glob":false}]'
  fi
  request=$(jq -nc --argjson words "$words" --argjson redirects "$redirects" \
    --argjson dynamic "$dynamic" --argjson env "$bare_env" \
    '{operation:"exec-segment", words:$words, redirects:$redirects, dynamicSelection:$dynamic, bareEnvironment:$env}')
  classify_credential_access "$request"
  credential_apply
}

credential_native() {  # <sanitized path-role fields JSON> <effective cwd>
  CWD=$2 CREDENTIAL_TRACE=0 CREDENTIAL_HOLD='' CREDENTIAL_CATEGORY=ordinary
  local request
  request=$(jq -nc --arg tool "$TOOL" --argjson fields "$1" '{operation:"native",tool:$tool,fields:$fields}')
  classify_credential_access "$request"
  credential_apply
}

credential_context_safe() {  # <literal path> <cwd>: before any script snapshot
  local CWD=$2 request
  request=$(jq -nc --arg path "$1" '{operation:"read",operands:[{path:$path,role:"script-context"}]}')
  classify_credential_access "$request"
  [ "$CREDENTIAL_LAST_CATEGORY" = ordinary ]
}
