#!/usr/bin/env bash
# Shared public-hook regressions; sourced by both permission-policy suites.
# Only synthetic policy/registry files and harmless sentinel material are used.

credential_hook() {  # <policy> <tool-kind> <fields-json> <step>
  local policy=$1 kind=$2 fields=$3 step=$4 adapter payload tool event
  adapter=${POLICY_SH##*/}
  if [ "$adapter" = fm-devin-permission-policy.sh ]; then
    case "$kind" in exec) tool='exec' ;; read) tool='read' ;; search) tool='grep' ;; write) tool=edit ;; list) tool=glob ;; esac
    event=permission-request
    payload=$(jq -nc --arg tool "$tool" --argjson fields "$fields" --arg step "$step" \
      '{tool_name:$tool,tool_input:$fields,tool_use_id:$step,session_id:"fixture"}')
  else
    case "$kind" in exec) tool=run_command ;; read) tool=view_file ;; search) tool=grep_search ;; write) tool=replace_file_content ;; list) tool=list_dir ;; esac
    event=pre-tool-use
    payload=$(jq -nc --arg tool "$tool" --argjson fields "$fields" --argjson step "$step" \
      --arg wt "$(jq -r .worktree "$policy")" \
      '{conversationId:"fixture",stepIdx:$step,workspacePaths:[$wt],toolCall:{name:$tool,args:$fields}}')
  fi
  OUT=$(printf '%s' "$payload" | env -u CWD "$POLICY_SH" "$event" "$policy" 2>/dev/null)
  RC=$?
}

credential_exec() {  # <policy> <command> <step>
  local fields
  fields=$(jq -nc --arg command "$2" --arg cwd "$(jq -r .worktree "$1")" '{command:$command,CommandLine:$command,Cwd:$cwd}')
  credential_hook "$1" exec "$fields" "$3"
}

credential_held() {
  case "${POLICY_SH##*/}" in
    fm-devin*) [ -z "$OUT" ] && [ "$RC" = 0 ] ;;
    *) denied "$OUT" ;;
  esac
}

credential_allowed() {
  case "${POLICY_SH##*/}" in
    fm-devin*) [ "$(printf '%s' "$OUT" | jq -r .decision)" = approve ] ;;
    *) abstained "$OUT" ;;
  esac
}

test_shared_credential_access() {
  local policy dir wt fields command kind step=1000 entry grants log judge_calls
  # shellcheck disable=SC2016 # This is the synthetic judge's script body.
  policy=$(new_case credential-classifier 'printf "%s\n" "$@" >> "$CREDENTIAL_JUDGE_PROMPT"
while [ $# -gt 0 ]; do
  if [ "$1" = --prompt-file ]; then cat "$2" >> "$CREDENTIAL_JUDGE_PROMPT"; shift; fi
  shift
done
printf "called\n" >> "$CREDENTIAL_JUDGE_CALLS"
echo "APPROVE: synthetic ordinary effect"')
  dir=$(case_dir "$policy") wt=$(jq -r .worktree "$policy")
  mkdir -p "$dir/config" "$wt/nested" "$wt/sub" "$dir/user-home"
  printf 'FIXTURE_KEY=HARMLESS_SENTINEL_VALUE\n' > "$wt/vendor.env"
  printf 'FIXTURE_KEY=HARMLESS_SENTINEL_VALUE\n' > "$wt/registered"
  printf 'FIXTURE_KEY=HARMLESS_SENTINEL_VALUE\n' > "$wt/secret material.env"
  printf 'FIXTURE_KEY=HARMLESS_SENTINEL_VALUE\n' > "$dir/user-home/login.env"
  printf 'FIXTURE_KEY=HARMLESS_SENTINEL_VALUE\n' > "$wt/nested/service.env"
  printf 'ordinary\n' > "$wt/README.md"
  printf 'ordinary\n' > "$wt/.editorconfig"
  printf 'fixture\n' > "$wt/sample.env.example"
  ln -s vendor.env "$wt/alias"
  ln -s nested "$wt/directory-alias"
  ln "$wt/registered" "$wt/hard-alias"
  ln -s cycle-b "$wt/cycle-a"; ln -s cycle-a "$wt/cycle-b"
  ln -s missing "$wt/broken"
  local hop
  for hop in $(seq 1 41); do ln -s "hop-$((hop + 1))" "$wt/hop-$hop"; done
  ln -s vendor.env "$wt/hop-42"
  entry=$(jq -nc --arg path "$wt/registered" '{path:$path,scope:"file",kind:"credential",use_modes:["source"],provenance:"synthetic registration"}')
  jq -n --argjson entry "$entry" '{version:1,revision:"fixture-1",entries:[$entry]}' > "$dir/config/declared-credentials.json"
  jq --arg config "$dir/config" --arg home "$dir/user-home" \
    '.config=$config | .credential_user_home=$home | .credential_registry_required=true' "$policy" > "$policy.new"
  mv "$policy.new" "$policy"
  export CREDENTIAL_JUDGE_PROMPT="$dir/judge-prompt" CREDENTIAL_JUDGE_CALLS="$dir/judge-calls"
  while IFS= read -r command; do
    credential_exec "$policy" "$command" "$step"; step=$((step + 1))
    credential_held || fail "credential effect must hold despite an always-approve judge: $command => $OUT"
  done <<'EOF'
cat vendor.env
cat 'secret material.env'
cat ~/login.env
cat -n vendor.env
head vendor.env
tail vendor.env
grep FIXTURE vendor.env
rg FIXTURE vendor.env
sed -n '1p' vendor.env
sed -f registered README.md
jq -f registered README.md
cat < registered
cat alias
cat hard-alias
cat sub/../vendor.env
cd nested; cat service.env
cat directory-alias/service.env
grep -R . nested
rg FIXTURE nested
cat nested/*
cat "$FILE"
printf '%s' registered | xargs cat
cat cycle-a
cat broken
cat hop-1
grep -f registered README.md
grep -fregistered README.md
jq --rawfile value registered -n '$value'
cp registered copied.txt
git show HEAD:registered
git cat-file -p HEAD:registered
git grep FIXTURE
set
env -0
command env -0
/usr/bin/env -0
printenv
jq -n env
printf '%s' "$KEY"
ps eww 123
gh auth status --show-token
source registered
set -x
set -v
cat sample.env.example
EOF
  [ ! -e "$CREDENTIAL_JUDGE_CALLS" ] || fail "credential/unknown-footprint calls must never reach the judge"
  for command in registered alias hard-alias vendor.env cycle-a broken; do
    fields=$(jq -nc --arg path "$command" '{file_path:$path,AbsolutePath:$path}')
    for kind in read write; do
      credential_hook "$policy" "$kind" "$fields" "$step"; step=$((step + 1))
      credential_held || fail "native $kind must use the same path identity with no ambient CWD: $command => $OUT"
    done
  done
  fields=$(jq -nc --arg path "$wt/nested" '{path:$path,SearchPath:$path,pattern:"FIXTURE",Query:"FIXTURE"}')
  credential_hook "$policy" search "$fields" "$step"; step=$((step + 1))
  credential_held || fail "native recursive search must hold an unproved content footprint"
  grants=$(jq -nc --arg path "$wt/registered" '{credential_env_files:[$path]}')
  local fence
  fence=$(printf '\140\140\140')
  printf '\n%sfirstmate-grants\n%s\n%s\n' "$fence" "$grants" "$fence" >> "$dir/data/t1/brief.md"
  "$POLICY_SH" repin-grants "$policy" >/dev/null || fail "repin synthetic grants"
  credential_exec "$policy" 'set -a; source registered; set +a' "$step"; step=$((step + 1))
  credential_allowed || fail "exact authorized loading must stay usable: $OUT"
  for command in 'set -x; source registered' 'source registered; set -v' "bash -x -c 'source registered'" 'cat registered'; do
    credential_exec "$policy" "$command" "$step"; step=$((step + 1))
    credential_held || fail "a use grant must not permit disclosure: $command => $OUT"
  done
  for command in 'cat README.md' 'cat .editorconfig' "sed -n '1,5p' README.md" 'ls nested' 'find nested -type f' "echo 'vendor.env'"; do
    credential_exec "$policy" "$command" "$step"; step=$((step + 1))
    credential_allowed || fail "ordinary reads and metadata must stay usable: $command => $OUT"
  done
  credential_exec "$policy" "python3 -c 'print(1)'" "$step"; step=$((step + 1))
  credential_allowed || fail "ordinary unresolved execution must still reach the judge"
  [ -s "$CREDENTIAL_JUDGE_CALLS" ] || fail "ordinary residue never reached the judge"
  fields='{"file_path":"new-resource","AbsolutePath":"new-resource"}'
  # Force a prior ordinary cacheable verdict through the public hook by
  # using a supported edit outside the task roots, then register that file.
  fields=$(jq -nc --arg path "$dir/new-resource" '{file_path:$path,AbsolutePath:$path}')
  if [ "${POLICY_SH##*/}" = fm-devin-permission-policy.sh ]; then
    credential_hook "$policy" write "$fields" "$step"; step=$((step + 1))
    credential_allowed || fail "ordinary fixture edit must reach the judge"
  fi
  judge_calls=$(wc -l < "$CREDENTIAL_JUDGE_CALLS")
  # A live addition must veto a prior ordinary judge approval immediately.
  jq --arg path "$dir/new-resource" '.revision="fixture-2" | .entries += [{path:$path,scope:"file",kind:"credential",use_modes:[],provenance:"synthetic addition"}]' \
    "$dir/config/declared-credentials.json" > "$dir/config/registry.new"
  mv "$dir/config/registry.new" "$dir/config/declared-credentials.json"
  credential_hook "$policy" write "$fields" "$step"; step=$((step + 1))
  credential_held || fail "new registry identity must take precedence over approval"
  [ "$(wc -l < "$CREDENTIAL_JUDGE_CALLS")" = "$judge_calls" ] || fail "newly protected access reached the judge"
  jq --arg path "$wt/sample.env.example" '.revision="fixture-3" | .entries += [{path:$path,scope:"file",kind:"nonsecret",use_modes:[],provenance:"synthetic nonsecret fixture"}]' \
    "$dir/config/declared-credentials.json" > "$dir/config/registry.new"
  mv "$dir/config/registry.new" "$dir/config/declared-credentials.json"
  credential_exec "$policy" 'cat sample.env.example' "$step"; step=$((step + 1))
  credential_allowed || fail "exact trusted nonsecret classification must allow the fixture"
  printf "# Task\n## Captain's intent\nSynthetic check.\n## Firstmate spec\nNo source grant.\n" > "$dir/data/t1/brief.md"
  "$POLICY_SH" repin-grants "$policy" >/dev/null || fail "remove synthetic use grant"
  credential_exec "$policy" 'cat registered' "$step"; step=$((step + 1))
  credential_held || fail "removing a use grant must not remove registry protection"
  ln -s "$dir/config" "$wt/config-alias"
  grants=$(jq -nc --arg path "$wt/config-alias" '{write_dirs:[$path]}')
  printf '\n%sfirstmate-grants\n%s\n%s\n' "$fence" "$grants" "$fence" >> "$dir/data/t1/brief.md"
  "$POLICY_SH" repin-grants "$policy" >/dev/null || fail "pin synthetic writable-registry alias"
  credential_exec "$policy" 'cat README.md' "$step"; step=$((step + 1))
  credential_held || fail "a registry under a granted physical write root must be rejected"
  # Removed/malformed expected registries fail closed for content, but leave
  # independently classified metadata usable.
  printf '{invalid\n' > "$dir/config/declared-credentials.json"
  credential_exec "$policy" 'cat README.md' "$step"; step=$((step + 1))
  credential_held || fail "malformed registry must hold content access"
  credential_exec "$policy" 'ls nested' "$step"
  credential_allowed || fail "malformed registry must leave ordinary metadata usable"
  step=$((step + 1))
  rm "$dir/config/declared-credentials.json"
  credential_exec "$policy" 'cat README.md' "$step"; step=$((step + 1))
  credential_held || fail "missing expected registry must hold content access"
  log=$(jq -r .log "$policy")
  if grep -qF HARMLESS_SENTINEL_VALUE "$log" "$CREDENTIAL_JUDGE_PROMPT" "$(jq -r .status "$policy")"; then
    fail "credential contents propagated into metadata evidence"
  fi
  pass "shared credential access: grants, identity, footprints, output, and registry authority through public hooks"
}
