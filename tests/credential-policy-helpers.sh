#!/usr/bin/env bash
# Shared public-hook regressions; sourced by both permission-policy suites.
# Only synthetic policy/registry files and harmless sentinel material are used.

credential_hook() {  # <policy> <tool-kind> <fields-json> <step> [event override]
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
  OUT=$(printf '%s' "$payload" | env -u CWD "$POLICY_SH" "${5:-$event}" "$policy" 2>/dev/null)
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
  mkdir -p "$dir/config" "$wt/nested" "$wt/sub" "$wt/~" "$wt/src" "$wt/env/lib" "$dir/user-home"
  printf 'FIXTURE_KEY=HARMLESS_SENTINEL_VALUE\n' > "$wt/vendor.env"
  printf 'FIXTURE_KEY=HARMLESS_SENTINEL_VALUE\n' > "$wt/registered"
  printf 'FIXTURE_KEY=HARMLESS_SENTINEL_VALUE\n' > "$wt/secret material.env"
  printf 'FIXTURE_KEY=HARMLESS_SENTINEL_VALUE\n' > "$dir/user-home/login.env"
  printf 'FIXTURE_KEY=HARMLESS_SENTINEL_VALUE\n' > "$wt/nested/service.env"
  printf 'ordinary\n' > "$wt/README.md"
  printf 'ordinary\n' > "$wt/.editorconfig"
  printf 'fixture\n' > "$wt/sample.env.example"
  for command in service-credentials.json aws_credentials .npmrc.backup .git-credentials.backup .env .env.local; do
    printf 'FIXTURE_KEY=HARMLESS_SENTINEL_VALUE\n' > "$wt/$command"
  done
  for command in src/env.ts src/env.d.ts env.mjs env/lib/module.py; do
    printf 'ordinary\n' > "$wt/$command"
  done
  ln -s vendor.env "$wt/alias"
  ln -s "$wt/registered" "$wt/~/alias"
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
cat service-credentials.json
cat aws_credentials
cat .npmrc.backup
cat .git-credentials.backup
cat .env
cat .env.local
cat 'secret material.env'
cat ~/login.env
cat '~/alias'
cat ~/'$FILE'
cat ~/"$FILE"
cat -n vendor.env
head vendor.env
tail vendor.env
grep FIXTURE vendor.env
rg FIXTURE vendor.env
sed -n '1p' vendor.env
sed -f registered README.md
jq -f registered README.md
jq --from-file registered README.md
file registered
cat < registered
printf x > registered
printf x >> registered
printf x >| registered
printf x &> registered
printf x &>> registered
printf x >& registered
printf x <> registered
printf x 2> registered
printf x > alias
printf x > hard-alias
printf x > vendor.env
cat alias
cat hard-alias
cat sub/../vendor.env
cd nested; cat service.env
cat directory-alias/service.env
grep -R . nested
find nested -exec cat {} +
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
/usr/bin/env -u IGNORED
/usr/bin/env cat registered
/usr/bin/nohup cat "$FILE"
printf '%s' registered | /usr/bin/xargs cat
printenv
jq -n env
printf '%s' "$KEY"
stat --printf="$KEY" README.md
ps eww 123
gh auth status --show-token
source registered
set -x
set -v
cat sample.env.example
EOF
  [ ! -e "$CREDENTIAL_JUDGE_CALLS" ] || fail "credential/unknown-footprint calls must never reach the judge"
  for command in 'cat service-credentials.json' 'cat aws_credentials' 'cat .npmrc.backup' 'cat .git-credentials.backup' 'printf x > registered' 'printf x >> alias'; do
    fields=$(jq -nc --arg command "$command" --arg cwd "$wt" '{command:$command,CommandLine:$command,Cwd:$cwd}')
    credential_hook "$policy" exec "$fields" "$step" pre-tool-use; step=$((step + 1))
    case "${POLICY_SH##*/}" in
      fm-devin*) [ "$RC" = 2 ] && [ "$(printf '%s' "$OUT" | jq -r .decision)" = block ] || fail "Devin pre-tool-use did not veto $command" ;;
      *) credential_held || fail "agy pre-tool-use did not hold $command" ;;
    esac
  done
  for command in registered alias hard-alias vendor.env cycle-a broken service-credentials.json aws_credentials .npmrc.backup .git-credentials.backup .env .env.local; do
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
  for command in 'set -x; source registered' 'source registered; set -v' "bash -x -c 'source registered'" "env SHELLOPTS=xtrace bash -c 'source registered'" 'cat registered'; do
    credential_exec "$policy" "$command" "$step"; step=$((step + 1))
    credential_held || fail "a use grant must not permit disclosure: $command => $OUT"
  done
  for command in 'cat README.md' 'cat .editorconfig' 'cat src/env.ts' 'cat src/env.d.ts' 'cat env.mjs' 'cat env/lib/module.py' 'printf x > README.md' 'printf x 2>&1' "sed -n '1,5p' README.md" 'ls nested' 'ls vendor.env' 'stat registered' 'find nested -type f' "find nested -name '*.env'" "echo 'vendor.env'" 'jq .env README.md' "jq -n '\"env\"'"; do
    credential_exec "$policy" "$command" "$step"; step=$((step + 1))
    credential_allowed || fail "ordinary reads and metadata must stay usable: $command => $OUT"
  done
  for command in src/env.ts src/env.d.ts env.mjs env/lib/module.py; do
    fields=$(jq -nc --arg path "$command" '{file_path:$path,AbsolutePath:$path}')
    credential_hook "$policy" read "$fields" "$step"; step=$((step + 1))
    credential_allowed || fail "ordinary native environment modules must stay usable: $command => $OUT"
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

test_retained_credential_identity() {
  local policy dir path grants step=3000 fields command
  path="$TMP_ROOT/retained-credential/wt/opaque"
  grants=$(jq -nc --arg path "$path" '{credential_env_files:[$path]}')
  policy=$(new_case retained-credential 'echo "APPROVE: synthetic judge"' "$grants")
  dir=$(case_dir "$policy")
  printf 'FIXTURE_KEY=HARMLESS_SENTINEL_VALUE\n' > "$path"
  "$POLICY_SH" register-credentials "$policy" </dev/null >/dev/null || fail "register source declarations at launch"
  jq -e --arg path "$path" '.entries | any(.path == $path and .kind == "credential")' \
    "$dir/config/declared-credentials.json" >/dev/null || fail "source declaration was not retained independently"
  credential_exec "$policy" 'source opaque' "$step"; step=$((step + 1))
  credential_allowed || fail "a retained source identity still requires and honors task use"
  printf '# Task\n## Synthetic verification\nNo source grant.\n' > "$dir/data/t1/brief.md"
  "$POLICY_SH" repin-grants "$policy" </dev/null >/dev/null || fail "revoke synthetic source authority"
  for command in 'cat opaque' 'source opaque'; do
    credential_exec "$policy" "$command" "$step"; step=$((step + 1))
    credential_held || fail "revoking a grant must not unprotect an extensionless credential: $command => $OUT"
  done
  fields='{"file_path":"opaque","AbsolutePath":"opaque"}'
  credential_hook "$policy" read "$fields" "$step"; step=$((step + 1))
  credential_held || fail "native reads must retain protection after source revocation"
  mkdir -p "$dir/no-node"
  printf '#!/bin/sh\nexit 1\n' > "$dir/no-node/node"
  chmod +x "$dir/no-node/node"
  PATH="$dir/no-node:$PATH" credential_hook "$policy" read "$fields" "$step"; step=$((step + 1))
  credential_held || fail "unavailable classifier must fail closed rather than statically approve"
  credential_exec "$policy" "bash $POLICY_SH repin-grants $policy" "$step"
  case "${POLICY_SH##*/}" in
    fm-devin*) [ "$RC" = 2 ] && [ "$(printf '%s' "$OUT" | jq -r .decision)" = block ] || fail "worker must not repin its own authority" ;;
    *) denied "$OUT" || fail "worker must not repin its own authority" ;;
  esac
  pass "shared credential access: launch declarations survive revocation and workers cannot repin authority"
}

test_credential_registration_locking() {
  local policy other dir config lock grants first second dead_pid
  local path="$TMP_ROOT/registry-lock-first/wt/opaque" other_path="$TMP_ROOT/registry-lock-second/wt/opaque"
  grants=$(jq -nc --arg path "$path" '{credential_env_files:[$path]}')
  policy=$(new_case registry-lock-first 'echo "APPROVE: synthetic judge"' "$grants")
  grants=$(jq -nc --arg path "$other_path" '{credential_env_files:[$path]}')
  other=$(new_case registry-lock-second 'echo "APPROVE: synthetic judge"' "$grants")
  dir=$(case_dir "$policy") config="$dir/config" lock="$dir/config/declared-credentials.json.lock"
  printf 'FIXTURE_KEY=HARMLESS_SENTINEL_VALUE\n' > "$path"
  printf 'FIXTURE_KEY=HARMLESS_SENTINEL_VALUE\n' > "$other_path"
  jq --arg config "$config" '.config=$config' "$other" > "$other.new"
  mv "$other.new" "$other"
  mkdir -p "$lock"
  jq -n --argjson pid "$$" '{pid:$pid,token:"synthetic live holder"}' > "$lock/owner.json"
  touch -t 200001010000 "$lock"
  ("$POLICY_SH" register-credentials "$policy" </dev/null > "$dir/first.log" 2>&1; printf '%s\n' "$?" > "$dir/first.rc") &
  first=$!
  ("$POLICY_SH" register-credentials "$other" </dev/null > "$dir/second.log" 2>&1; printf '%s\n' "$?" > "$dir/second.rc") &
  second=$!
  sleep 0.3
  [ ! -e "$dir/first.rc" ] && [ ! -e "$dir/second.rc" ] || fail "contending registration must wait for the live holder"
  jq -e --argjson pid "$$" '.pid == $pid' "$lock/owner.json" >/dev/null || fail "lock age must not evict a live holder"
  rm -f "$lock/owner.json"
  rmdir "$lock"
  wait "$first" || fail "first registration process failed"
  wait "$second" || fail "second registration process failed"
  [ "$(cat "$dir/first.rc")" = 0 ] && [ "$(cat "$dir/second.rc")" = 0 ] || fail "contending registrations did not both finish"
  jq -e --arg first "$path" --arg second "$other_path" \
    '(.entries|length) == 2 and (.entries|any(.path==$first)) and (.entries|any(.path==$second))' \
    "$config/declared-credentials.json" >/dev/null || fail "concurrent registrations lost a credential identity"
  [ ! -e "$lock" ] || fail "successful registration left its lock behind"

  # A real exited fixture process supplies a provably dead owner PID.
  sleep 0.01 & dead_pid=$!
  wait "$dead_pid"
  ! kill -0 "$dead_pid" 2>/dev/null || fail "fixture lock owner did not exit"
  mkdir "$lock"
  jq -n --argjson pid "$dead_pid" '{pid:$pid,token:"synthetic dead holder"}' > "$lock/owner.json"
  "$POLICY_SH" register-credentials "$policy" </dev/null >/dev/null || fail "dead-owner lock was not recovered"
  [ ! -e "$lock" ] || fail "dead-owner recovery left a lock behind"
  credential_exec "$policy" 'cat opaque' 4000
  credential_held || fail "registration recovery must preserve protection"
  pass "shared credential registration: contention preserves both identities and dead-owner recovery keeps protection"
}
