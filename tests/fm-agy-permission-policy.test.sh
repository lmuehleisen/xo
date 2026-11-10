#!/usr/bin/env bash
# Native deterministic constraints, exact decisions and legacy retirement,
# exercised through public hook/management interfaces and audit artifacts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

POLICY_SH="$ROOT/bin/fm-agy-permission-policy.sh"
# shellcheck source=tests/credential-policy-helpers.sh
. "$ROOT/tests/credential-policy-helpers.sh"
HOOK_SH="$ROOT/bin/fm-agy-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-permission-policy)
# Credential identities normalize the macOS /private/var alias to /var.
case "$TMP_ROOT" in /private/var/*) TMP_ROOT=${TMP_ROOT#/private} ;; esac

# The shared publish policy (bin/fm-gh-publish-policy.mjs) runs inside this
# layer. A synthetic publish-guard config whose allowlist names the suite's
# fixture repositories keeps these cases exercising the adapter's own policy;
# a/b stays unlisted on purpose.
mkdir -p "$TMP_ROOT/config/publish-guard"
printf 'name=Fixture\nemail=fixture@example.invalid\n' >"$TMP_ROOT/config/publish-guard/identity"
printf 'synthetic-denylist-term\n' >"$TMP_ROOT/config/publish-guard/denylist"
printf 'public owner/name\npublic owner/other\npublic someone/name\n' >"$TMP_ROOT/config/publish-guard/allowlist"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

command -v jq >/dev/null 2>&1 || {
  printf 'skip - fm-agy-permission-policy: jq not installed\n'
  exit 0
}

# new_case <name> [grants-json]
new_case() {
  local name=$1 grants=${3-} dir wt
  # Shared credential fixtures retain their positional judge-body slot.
  # agy never executes that body; two-argument local fixtures pass grants.
  if [ "$#" = 2 ]; then case "$2" in '{'*) grants=$2 ;; esac; fi
  dir="$TMP_ROOT/$name"
  wt="$dir/wt"
  mkdir -p "$wt" "$dir/state/t1.inbox/handled" "$dir/data/t1" "$dir/tmp"
  dir=$(cd "$dir" && pwd -P)
  wt=$(cd "$wt" && pwd -P)
  printf 'g1\n' > "$dir/state/t1.busy-gen"
  cat > "$dir/data/t1/brief.md" <<'EOF'
# Task
## Captain's intent
Fix the flaky test.

## Firstmate spec
Keep the change narrow.
EOF
  if [ -n "$grants" ]; then
    local fence
    fence=$(printf '\140\140\140')
    printf '\n%sfirstmate-grants\n%s\n%s\n' "$fence" "$grants" "$fence" >> "$dir/data/t1/brief.md"
  fi
  cat >> "$dir/data/t1/brief.md" <<'EOF'

# Setup
Not part of the excerpt.
EOF
  local sha
  sha=$("$POLICY_SH" grants-digest "$dir/data/t1/brief.md" 2>/dev/null || true)
  jq -n --arg wt "$wt" --arg d "$dir" --arg sha "$sha" \
    '{task:"t1", worktree:$wt, status:($d+"/state/t1.status"), inbox:($d+"/state/t1.inbox"),
      data:($d+"/data/t1"), tasktmp:($d+"/tmp"), brief:($d+"/data/t1/brief.md"),
      log:($d+"/state/agy-permission-log.jsonl"), posture:"native-auto", gen:"g1",
      grants_sha:$sha}' \
    > "$dir/state/t1.agy-permission.json"
  printf '%s\n' "$dir/state/t1.agy-permission.json"
}

# hook <policy> <event> <tool> <arg> [step-idx] [extra-args-json]: sets OUT and
# RC. <arg> is the command line for run_command and the file path or query for
# the other tools.
hook() {
  local policy=$1 event=$2 tool=$3 arg=$4 step=${5:-1} extra=${6-} payload
  payload=$(jq -nc --arg t "$tool" --arg a "$arg" --argjson s "$step" \
    --argjson x "${extra:-null}" --arg wt "$(jq -r .worktree "$policy")" '
    {conversationId:"c1", stepIdx:$s, modelName:"fake-model",
     workspacePaths:[$wt],
     toolCall:{name:$t, args:(
       (if $t == "run_command" then {CommandLine:$a, Cwd:$wt}
        elif $t == "read_file" or $t == "write_file" or $t == "edit_file"
          then {Path:$a, Content:"x"}
        elif $t == "write_to_file" or $t == "replace_file_content" or $t == "view_file"
          then {AbsolutePath:$a, Content:"x"}
        elif $t == "search_web" or $t == "read_url_content" then {Query:$a}
        else {Input:$a} end)
       + (if $x == null then {} else $x end))}}')
  OUT=$(printf '%s' "$payload" | "$POLICY_SH" "$event" "$policy" 2>/dev/null)
  RC=$?
}

case_dir() { dirname "$(dirname "$1")"; }

denied() {  # <out> [reason-fragment]
  [ "$(printf '%s' "$1" | jq -r .decision 2>/dev/null)" = deny ] || return 1
  [ $# -lt 2 ] || printf '%s' "$1" | jq -r .reason 2>/dev/null | grep -qF "$2"
}

abstained() { [ -z "$1" ]; }

statically_approved() {  # <output> <policy>
  abstained "$1" && tail -1 "$(case_dir "$2")/state/agy-permission-log.jsonl" \
    | jq -e '.decision == "approve" and .decider == "policy"' >/dev/null
}

native_review() {  # <output> <policy> - residue must reach native review.
  abstained "$1" && tail -1 "$(case_dir "$2")/state/agy-permission-log.jsonl" \
    | jq -e '.decision == "native-review" and .decider == "native"' >/dev/null
}

test_worker_completion_home_binding() {
  local policy dir cmd step=0
  local POLICY_SH=$POLICY_SH
  policy=$(new_case completion-home)
  dir=$(case_dir "$policy")
  local -x FM_STATE_OVERRIDE="$dir/state"
  local -x FM_DATA_OVERRIDE="$dir/data"
  cp -R "$ROOT/bin" "$dir/bin"
  POLICY_SH="$dir/bin/fm-agy-permission-policy.sh"
  while IFS= read -r cmd; do
    step=$((step + 1))
    hook "$policy" pre-tool-use run_command "$cmd" "$step"
    if [ "$RC" != 0 ] || ! abstained "$OUT"; then
      fail "exact own-home completion must retain native review: $OUT"
    fi
    tail -1 "$dir/state/agy-permission-log.jsonl" \
      | jq -e '.decision == "approve" and .decider == "policy"' >/dev/null \
      || fail 'exact own-home completion must retain its static policy classification'
  done <<EOF
cd '$dir' && FM_HOME='$dir' bin/fm-captain-hold.sh complete t1 --none
FM_HOME='$dir' bash '$dir/bin/fm-captain-hold.sh' complete t1 --none
EOF
  [ -z "$(find "$dir/state/t1.agy-permission-pending" -maxdepth 1 -name '*.pending' -print 2>/dev/null)" ] \
    || fail 'static completion must not leave a held-call marker'
  while IFS= read -r cmd; do
    step=$((step + 1))
    hook "$policy" pre-tool-use run_command "$cmd" "$step"
    if [ "$RC" != 0 ] || ! native_review "$OUT" "$policy"; then
      fail "non-contract completion must reach native Auto review: $OUT"
    fi
  done <<EOF
FM_HOME='$dir/another-home' '$dir/bin/fm-captain-hold.sh' complete t1 --none
FM_HOME='$dir' '$dir/bin/fm-captain-hold.sh' complete t2 --none
FM_HOME='$dir' OTHER=value '$dir/bin/fm-captain-hold.sh' complete t1 --none
FM_HOME='$dir' bash -c "$dir/bin/fm-captain-hold.sh complete t1 --none"
'FM_HOME=$dir' '$dir/bin/fm-captain-hold.sh' complete t1 --none
FM_HOME\\='$dir' '$dir/bin/fm-captain-hold.sh' complete t1 --none
EOF
  step=$((step + 1))
  FM_STATE_OVERRIDE="$dir/state" hook "$policy" pre-tool-use run_command \
    "FM_HOME='$dir' '$dir/bin/fm-captain-hold.sh' complete t1 --none" "$step"
  if [ "$RC" != 0 ] || ! abstained "$OUT"; then
    fail "matching inherited state must preserve native Auto completion: $OUT"
  fi
  mkdir -p "$dir/other-state"
  step=$((step + 1))
  FM_STATE_OVERRIDE="$dir/other-state" hook "$policy" pre-tool-use run_command \
    "FM_HOME='$dir' '$dir/bin/fm-captain-hold.sh' complete t1 --none" "$step"
  if [ "$RC" != 0 ] || ! denied "$OUT" FM_STATE_OVERRIDE; then
    fail "redirected completion state must be refused before native Auto execution: $OUT"
  fi
  mkdir -p "$dir/other-data" "$dir/relocated/t1"
  step=$((step + 1))
  FM_DATA_OVERRIDE="$dir/other-data" hook "$policy" pre-tool-use run_command \
    "FM_HOME='$dir' '$dir/bin/fm-captain-hold.sh' complete t1 --none" "$step"
  if [ "$RC" != 0 ] || ! denied "$OUT" FM_DATA_OVERRIDE; then
    fail "redirected completion data must be refused before native Auto execution: $OUT"
  fi
  cp "$dir/data/t1/brief.md" "$dir/relocated/t1/brief.md"
  jq --arg data "$dir/relocated/t1" --arg brief "$dir/relocated/t1/brief.md" \
    '.data=$data | .brief=$brief' "$policy" > "$dir/state/t1.relocated.json"
  step=$((step + 1))
  FM_DATA_OVERRIDE="$dir/relocated" hook "$dir/state/t1.relocated.json" pre-tool-use run_command \
    "FM_HOME='$dir' '$dir/bin/fm-captain-hold.sh' complete t1 --none" "$step"
  if [ "$RC" != 0 ] || ! abstained "$OUT"; then
    fail "recorded relocated data must preserve native Auto completion: $OUT"
  fi
  tail -1 "$dir/state/agy-permission-log.jsonl" \
    | jq -e '.decision == "approve" and .decider == "policy"' >/dev/null \
    || fail 'recorded relocated data must retain static classification'
  cp "$dir/data/t1/brief.md" "$dir/brief.saved"
  printf '# Task\n## Firstmate spec\nDo not read file contents.\n# Setup\n' > "$dir/data/t1/brief.md"
  step=$((step + 1))
  hook "$policy" pre-tool-use run_command \
    "FM_HOME='$dir' bash '$dir/bin/fm-captain-hold.sh' complete t1 --none" "$step"
  statically_approved "$OUT" "$policy" \
    || fail "read exclusions must not hold the exact bound completion attestation: $OUT"
  step=$((step + 1))
  hook "$policy" pre-tool-use run_command \
    "FM_HOME='$dir/another-home' bash '$dir/bin/fm-captain-hold.sh' complete t1 --none" "$step"
  denied "$OUT" || fail "read exclusions must still hold a foreign-home completion: $OUT"
  mv "$dir/brief.saved" "$dir/data/t1/brief.md"
  jq 'del(.posture)' "$policy" > "$dir/state/t1.legacy.json"
  hook "$dir/state/t1.legacy.json" pre-tool-use run_command \
    "FM_HOME='$dir' '$dir/bin/fm-captain-hold.sh' complete t1 --none" 20
  if [ "$RC" != 0 ] || ! denied "$OUT" 'explicit recovery'; then
    fail "a completion binding must not reactivate a retired policy: $OUT"
  fi
  pass 'fm-agy-permission-policy: exact own-home completion is static; other bindings and quoted commands reach native Auto'
}

test_names_only_worktree_listing() {
  local policy dir wt cmd step=0
  policy=$(new_case names-only-listing)
  dir=$(case_dir "$policy")
  wt=$(jq -r .worktree "$policy")
  mkdir -p "$wt/bin" "$dir/outside"
  printf 'fixture\n' > "$wt/bin/fm-harness.sh"
  ln -s "$dir/outside" "$wt/escape"
  printf '# Task\n## Firstmate spec\nList repository names. Do not read file contents.\n# Setup\n' > "$dir/data/t1/brief.md"
  while IFS= read -r cmd; do
    step=$((step + 1))
    hook "$policy" pre-tool-use run_command "$cmd" "$step"
    statically_approved "$OUT" "$policy" || fail "a literal directory listing reads no file contents: $cmd => $OUT"
  done <<EOF
ls '$wt'
ls -1A -- '$wt/bin'
/bin/ls -la '$wt' '$wt/bin'
ls
EOF
  while IFS= read -r cmd; do
    step=$((step + 1))
    hook "$policy" pre-tool-use run_command "$cmd" "$step"
    denied "$OUT" || fail "a listing exemption must not carry another read or an unproved path: $cmd => $OUT"
  done <<EOF
ls '$wt' && cat '$wt/bin/fm-harness.sh'
ls '$wt' | xargs cat
ls '$wt'/*
ls '$wt/escape'
ls '$dir/outside'
ls -R '$wt'
cat '$wt/bin/fm-harness.sh'
EOF
  step=$((step + 1))
  hook "$policy" pre-tool-use read_file "$wt/bin/fm-harness.sh" "$step"
  denied "$OUT" || fail "the global file-content exclusion must still hold native reads: $OUT"
  pass 'fm-agy-permission-policy: literal worktree directory listings do not open excluded file contents'
}

test_own_tool_version_queries() {
  local policy dir cmd step=0
  policy=$(new_case own-tool-version)
  dir=$(case_dir "$policy")
  printf '# Task\n## Firstmate spec\nDo not read file contents.\n# Setup\n' > "$dir/data/t1/brief.md"
  for cmd in 'agy --version' 'agy -v'; do
    step=$((step + 1))
    hook "$policy" pre-tool-use run_command "$cmd" "$step"
    statically_approved "$OUT" "$policy" || fail "own-tool version metadata must be static: $cmd => $OUT"
  done
  for cmd in 'agy --version extra' 'agy run' 'agy --help' 'agy --version && cat README.md' './agy --version'; do
    step=$((step + 1))
    hook "$policy" pre-tool-use run_command "$cmd" "$step"
    denied "$OUT" || fail "another agy invocation must retain scope review: $cmd => $OUT"
  done
  policy=$(new_case own-tool-other-command)
  hook "$policy" pre-tool-use run_command 'agy run'
  native_review "$OUT" "$policy" || fail "other agy subcommands must not enter the read-and-build set: $OUT"
  pass 'fm-agy-permission-policy: only the exact own-tool version queries are static'
}

test_tracked_reads_respect_path_exclusions() {
  local policy dir wt tool step=0
  policy=$(new_case tracked-read-exclusions)
  dir=$(case_dir "$policy")
  wt=$(jq -r .worktree "$policy")
  mkdir -p "$wt/bin" "$wt/private"
  printf '# fixture\n' > "$wt/bin/fm-harness.sh"
  printf 'excluded\n' > "$wt/private/records.csv"
  printf 'untracked\n' > "$wt/untracked.txt"
  printf 'TOKEN=fixture\n' > "$wt/.env"
  printf 'outside\n' > "$dir/outside.txt"
  ln -s ../private/records.csv "$wt/bin/excluded-link"
  ln -s "$dir/outside.txt" "$wt/bin/outside-link"
  git -C "$wt" init -q
  git -C "$wt" add bin private .env
  # Without exclusions this script already reads normally; its basename is
  # not permission wiring. An unrelated exclusion must not change that.
  hook "$policy" pre-tool-use read_file "$wt/bin/fm-harness.sh" 0
  statically_approved "$OUT" "$policy" || fail "the tracked harness script must be readable: $OUT"
  # shellcheck disable=SC2016 # Backticks are literal Markdown in the brief.
  printf '# Task\n## Firstmate spec\nDo not read `private/`.\n# Setup\n' > "$dir/data/t1/brief.md"
  for tool in read_file view_file; do
    step=$((step + 1))
    hook "$policy" pre-tool-use "$tool" "$wt/bin/fm-harness.sh" "$step"
    statically_approved "$OUT" "$policy" || fail "an unrelated exact exclusion must not hold a tracked read: $OUT"
  done
  step=$((step + 1))
  hook "$policy" pre-tool-use run_command "cat '$wt/bin/fm-harness.sh'" "$step"
  statically_approved "$OUT" "$policy" || fail "the literal shell read must have the same scope: $OUT"
  for tool in "$wt/private/records.csv" "$wt/bin/excluded-link" "$wt/bin/outside-link" "$wt/untracked.txt" "$wt/.env"; do
    step=$((step + 1))
    hook "$policy" pre-tool-use read_file "$tool" "$step"
    denied "$OUT" || fail "an excluded, untracked, escaping or credential read must remain held: $tool => $OUT"
  done
  step=$((step + 1))
  hook "$policy" pre-tool-use run_command "cat '$wt/bin/'*" "$step"
  denied "$OUT" || fail "a glob cannot borrow an exact tracked-read exemption: $OUT"
  step=$((step + 1))
  hook "$policy" pre-tool-use view_file bin/fm-harness.sh "$step"
  denied "$OUT" || fail "a relative native path has no proven worktree base: $OUT"
  # shellcheck disable=SC2016 # Backticks are literal Markdown in the brief.
  printf '# Task\n## Firstmate spec\nDo not read `bin/fm-harness.sh`.\n# Setup\n' > "$dir/data/t1/brief.md"
  step=$((step + 1))
  hook "$policy" pre-tool-use read_file "$wt/bin/fm-harness.sh" "$step"
  denied "$OUT" || fail "an exact exclusion overrides tracked-file status: $OUT"
  pass 'fm-agy-permission-policy: exact path exclusions hold their targets and allow unrelated tracked reads'
}

test_tracked_read_symlink_dotdot_stays_held() {
  local policy dir wt tool step=0
  policy=$(new_case tracked-symlink-dotdot)
  dir=$(case_dir "$policy")
  wt=$(jq -r .worktree "$policy")
  mkdir -p "$wt/other/nested"
  printf 'allowed\n' > "$wt/privatefile"
  printf 'excluded\n' > "$wt/other/privatefile"
  ln -s other/nested "$wt/pivot"
  ln -s pivot/../privatefile "$wt/read"
  git -C "$wt" init -q
  git -C "$wt" add privatefile other/privatefile pivot read
  # The kernel follows pivot before ..; lexical normalization would instead
  # select the tracked, permitted file at the root and approve the wrong read.
  [ "$(cat "$wt/read")" = excluded ] || fail 'the fixture must actually read the excluded physical destination'
  # shellcheck disable=SC2016 # Backticks are literal Markdown in the brief.
  printf '# Task\n## Firstmate spec\nDo not read `other/privatefile`.\n# Setup\n' > "$dir/data/t1/brief.md"
  hook "$policy" pre-tool-use read_file "$wt/privatefile" 0
  statically_approved "$OUT" "$policy" || fail "an unrelated regular tracked file must retain its exemption: $OUT"
  for tool in read_file view_file; do
    step=$((step + 1))
    hook "$policy" pre-tool-use "$tool" "$wt/read" "$step"
    denied "$OUT" || fail "a final symlink must not exempt the wrong physical read: $OUT"
  done
  step=$((step + 1))
  hook "$policy" pre-tool-use run_command "cat '$wt/read'" "$step"
  denied "$OUT" || fail "a shell read must retain the same final-symlink boundary: $OUT"
  # shellcheck disable=SC2016 # Backticks are literal Markdown in the brief.
  printf '# Task\n## Firstmate spec\nDo not read `read`.\n# Setup\n' > "$dir/data/t1/brief.md"
  step=$((step + 1))
  hook "$policy" pre-tool-use read_file "$wt/other/privatefile" "$step"
  denied "$OUT" || fail "a final-symlink exclusion must not be normalized to a different file: $OUT"
  pass 'fm-agy-permission-policy: final symlinks in read targets or exclusions retain scope review'
}

test_listing_multiline_paths_stay_held() {
  local policy dir wt operand extra
  policy=$(new_case listing-multiline)
  dir=$(case_dir "$policy")
  wt=$(jq -r .worktree "$policy")
  mkdir -p "$wt/"$'\n' "$dir/outside"
  touch "$dir/outside/outside-marker"
  operand="$wt/"$'\n'"/../../outside"
  [ "$(ls "$operand")" = outside-marker ] || fail 'the complete newline operand must actually list the sibling directory'
  printf '# Task\n## Firstmate spec\nDo not read file contents.\n# Setup\n' > "$dir/data/t1/brief.md"
  hook "$policy" pre-tool-use run_command "ls '$wt'" 0
  statically_approved "$OUT" "$policy" || fail "an ordinary worktree listing must retain its exemption: $OUT"
  hook "$policy" pre-tool-use run_command "ls '$operand'" 1
  denied "$OUT" || fail "a multiline operand must not validate only its first line: $OUT"
  extra=$(jq -nc --arg cwd "$operand" '{Cwd:$cwd}')
  hook "$policy" pre-tool-use run_command ls 2 "$extra"
  denied "$OUT" || fail "a multiline working directory must not validate only its first line: $OUT"
  pass 'fm-agy-permission-policy: multiline listing operands and working directories retain scope review'
}

test_armed_heartbeat_proves_wiring() {
  local policy dir log
  policy=$(new_case armed)
  dir=$(case_dir "$policy")
  log="$dir/state/agy-permission-log.jsonl"
  jq -nc --arg wt "$(jq -r .worktree "$policy")" \
    '{conversationId:"c1",workspacePaths:[$wt]}' \
    | "$POLICY_SH" armed "$policy" >/dev/null 2>&1
  [ "$(jq -r 'select(.event == "armed") | .task' "$log" 2>/dev/null)" = t1 ] \
    || fail "the armed heartbeat must land on the observer log: $(cat "$log" 2>/dev/null)"
  [ "$(jq -r 'select(.event == "armed") | .gen' "$log" 2>/dev/null)" = g1 ] \
    || fail "the armed heartbeat must carry this launch's generation for the canary: $(cat "$log" 2>/dev/null)"
  jq -nc --arg wt "$(jq -r .worktree "$policy")" \
    '{conversationId:"c1",workspacePaths:[$wt]}' \
    | "$POLICY_SH" armed "$policy" >/dev/null 2>&1
  [ "$(jq -s 'map(select(.event == "armed")) | length' "$log")" = 1 ] \
    || fail "the armed heartbeat must write exactly once per generation: $(cat "$log")"
  pass "fm-agy-permission-policy: the armed heartbeat proves live wiring exactly once, stamped with the launch's generation"
}

test_refusal_list_denies() {
  local policy cmd
  policy=$(new_case refuse)
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    hook "$policy" pre-tool-use run_command "$cmd"
    denied "$OUT" || fail "pre-tool-use must deny '$cmd' even under bypass, got rc=$RC out=$OUT"
  done <<'EOF'
sudo ls
ls && sudo rm x
env FOO=1 sudo id
bash -c "sudo true"
echo $(sudo id)
launchctl list
git push origin --force
git push --force-with-lease origin fm/x
git push -fu origin fm/x
git push origin +HEAD:fm/x
rm -rf /tmp/elsewhere
rm -rf .
rm -r ../sibling
find . -exec rm -rf / \;
gh repo view
gh pr create --title x --body y
gh pr create --repo a/b --title x
git push --no-verify origin fm/x
git -c user.email=someone@example.com commit -m x
EOF
  pass "fm-agy-permission-policy: pre-tool-use denies the hard-refusal list"
}

test_refusal_leaves_safe_commands_alone() {
  local policy dir cmd
  policy=$(new_case not-refused)
  dir=$(case_dir "$policy")
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    hook "$policy" pre-tool-use run_command "$cmd"
    abstained "$OUT" || fail "pre-tool-use must abstain on '$cmd', got rc=$RC out=$OUT"
  done <<'EOF'
git push -u origin fm/x
command -v sudo
grep -n sudo README.md
cat README.md
git log --oneline -5
bin/fm-lint.sh
mkdir -p build/out
EOF
  pass "fm-agy-permission-policy: read-and-build commands abstain so the call reaches native review"
}

test_non_command_tool_mapping() {
  local policy dir wt
  policy=$(new_case tools)
  dir=$(case_dir "$policy")
  wt=$(jq -r .worktree "$policy")
  mkdir -p "$wt/sub" "$dir/data/t1"
  local tool arg
  while IFS='|' read -r tool arg; do
    [ -n "$tool" ] || continue
    hook "$policy" pre-tool-use "$tool" "$arg"
    abstained "$OUT" || fail "$tool on '$arg' must abstain, got rc=$RC out=$OUT"
  done <<EOF
view_file|$wt/README.md
view_file|README.md
list_dir|$wt/sub
search_web|firstmate agy permission hooks
read_url_content|https://example.com/docs
write_to_file|$wt/src/new.txt
write_to_file|src/relative.txt
replace_file_content|$wt/src/edit.txt
EOF
  # A write outside every write root is refused outright - under bypass no
  # native prompt survives to catch it.
  hook "$policy" pre-tool-use write_to_file "/etc/hosts"
  denied "$OUT" "outside the task write roots" \
    || fail "a write outside the task roots must be denied, got: $OUT"
  hook "$policy" pre-tool-use replace_file_content "/usr/bin/env"
  denied "$OUT" || fail "a replace outside the task roots must be denied, got: $OUT"
  # The task's own brief is refused to every writer.
  hook "$policy" pre-tool-use write_to_file "$dir/data/t1/brief.md"
  denied "$OUT" "own instructions" \
    || fail "writing the task's own brief must be denied, got: $OUT"
  # Credential material is never auto-approved.
  hook "$policy" pre-tool-use view_file "$HOME/.ssh/id_rsa"
  denied "$OUT" "held for firstmate" \
    || fail "a credential read must escalate to firstmate, got: $OUT"
  pass "fm-agy-permission-policy: non-command tools map onto the shared policy's file and read rules"
}

test_current_native_file_contract() {
  local policy dir wt tool target
  policy=$(new_case current-native)
  dir=$(case_dir "$policy")
  wt=$(jq -r .worktree "$policy")
  mkdir -p "$wt/src" "$wt/.agents" "$dir/state/t1.agy-hooks"
  printf 'PUBLIC\n' > "$wt/src/public.txt"
  printf 'HARMLESS_SENTINEL\n' > "$wt/vendor.env"
  ln -s /etc "$wt/escape"
  for tool in read_file write_file edit_file; do
    hook "$policy" pre-tool-use "$tool" "$wt/src/public.txt"
    abstained "$OUT" || fail "$tool must use its actual Path for an in-task operation: $OUT"
    jq -es --arg tool "$tool" 'last | .tool == $tool and .decision == "approve"' "$dir/state/agy-permission-log.jsonl" >/dev/null \
      || fail "$tool must retain its native name in the policy receipt"
    hook "$policy" pre-tool-use "$tool" "$wt/vendor.env"
    denied "$OUT" 'held for firstmate' || fail "$tool must retain the credential hold for Path: $OUT"
    hook "$policy" pre-tool-use "$tool" src/public.txt
    denied "$OUT" 'absolute Path' || fail "$tool must refuse an unproven relative Path base: $OUT"
    hook "$policy" pre-tool-use "$tool" '' 1 '{"AbsolutePath":"/etc/hosts","Path":null}'
    denied "$OUT" 'absolute Path' || fail "$tool must not substitute a legacy field for a missing Path: $OUT"
  done
  for tool in write_file edit_file; do
    for target in /etc/fm-agy-fixture "$wt/escape/fm-agy-fixture" "$wt/.agents/fixture" "$dir/state/t1.agy-hooks/fixture" "$dir/data/t1/brief.md"; do
      hook "$policy" pre-tool-use "$tool" "$target"
      denied "$OUT" || fail "$tool must refuse a forbidden Path under native review: $OUT"
    done
    hook "$policy" pre-tool-use "$tool" /etc/fm-agy-fixture 1 "{\"AbsolutePath\":\"$wt/src/public.txt\"}"
    denied "$OUT" 'outside the task write roots' || fail "$tool must check Path rather than a conflicting legacy field: $OUT"
  done
  pass 'fm-agy-permission-policy: current native Path tools preserve credential, physical-root, wiring and absolute-target guards'
}

test_file_tool_writes_resolve_physically() {
  local policy dir wt
  policy=$(new_case symlink)
  dir=$(case_dir "$policy")
  wt=$(jq -r .worktree "$policy")
  mkdir -p "$wt/real"
  # A symlink inside the worktree pointing at an outside directory must not
  # carry a file-tool write with it: the root check resolves the physical
  # path, so the write is refused as outside the roots, not judged. The
  # target must live outside every root - the scratch roots cover all of
  # /tmp, so /etc is the honest outside.
  ln -s /etc "$wt/out-link" || fail "could not create the escape symlink"
  hook "$policy" pre-tool-use write_to_file "$wt/out-link/payload.txt"
  denied "$OUT" "outside the task write roots" \
    || fail "a write through an in-worktree symlink to outside must be refused, got: $OUT"
  hook "$policy" pre-tool-use replace_file_content "out-link/payload.txt"
  denied "$OUT" "outside the task write roots" \
    || fail "a relative write through the escape symlink must be refused, got: $OUT"
  # The same symlink check stays transparent for a link that resolves inside.
  ln -s real "$wt/in-link" || fail "could not create the inside symlink"
  hook "$policy" pre-tool-use write_to_file "$wt/in-link/ok.txt"
  abstained "$OUT" || fail "a write through a symlink that resolves inside must abstain, got: $OUT"
  # A deep but legal chain resolves to its end and is judged by where it
  # lands; a chain that outruns the resolver's hop bound fails closed rather
  # than returning a partially resolved path that still reads as in-worktree.
  local i prev
  prev=/etc/hosts
  for i in 9 8 7 6 5 4 3 2 1; do
    ln -sfn "$prev" "$wt/chain-$i" || fail "could not create chain link $i"
    prev="$wt/chain-$i"
  done
  hook "$policy" pre-tool-use write_to_file "$wt/chain-1"
  denied "$OUT" "outside the task write roots" \
    || fail "a resolved deep chain must refuse by its physical end, got: $OUT"
  prev=/etc/hosts
  for i in $(seq 45 -1 1); do
    ln -sfn "$prev" "$wt/deep-$i" || fail "could not create deep link $i"
    prev="$wt/deep-$i"
  done
  hook "$policy" pre-tool-use write_to_file "$wt/deep-1"
  denied "$OUT" "unresolvable path" \
    || fail "a chain past the hop bound must fail closed, got: $OUT"
  pass "fm-agy-permission-policy: file-tool writes resolve the physical path before the root check"
}

test_fetch_dest_writes_resolve_physically() {
  local policy wt i prev
  policy=$(new_case fetch-symlink)
  wt=$(jq -r .worktree "$policy")
  # A curl or wget destination resolves through the same bounded resolver as
  # the file tools: a deep but legal chain is judged by where it physically
  # lands, and a chain that outruns the hop bound fails closed rather than
  # validating the lexical position of an intermediate link.
  prev=/etc/hosts
  for i in 9 8 7 6 5 4 3 2 1; do
    ln -sfn "$prev" "$wt/chain-$i" || fail "could not create chain link $i"
    prev="$wt/chain-$i"
  done
  hook "$policy" pre-tool-use run_command "curl -o $wt/chain-1 https://example.com/x"
  denied "$OUT" "outside the task write roots" \
    || fail "a fetch through a resolved deep chain must hold by its physical end, got: $OUT"
  hook "$policy" pre-tool-use run_command "wget -O $wt/chain-1 https://example.com/x"
  denied "$OUT" "outside the task write roots" \
    || fail "a wget through a resolved deep chain must hold by its physical end, got: $OUT"
  prev=/etc/hosts
  for i in $(seq 45 -1 1); do
    ln -sfn "$prev" "$wt/deep-$i" || fail "could not create deep link $i"
    prev="$wt/deep-$i"
  done
  hook "$policy" pre-tool-use run_command "curl -o $wt/deep-1 https://example.com/x"
  denied "$OUT" "outside the task write roots" \
    || fail "a fetch chain past the hop bound must fail closed, got: $OUT"
  pass "fm-agy-permission-policy: fetch destinations resolve the physical path before the root check"
}

test_file_tool_protected_and_config_paths() {
  local policy dir wt
  policy=$(new_case protected)
  dir=$(case_dir "$policy")
  wt=$(jq -r .worktree "$policy")
  mkdir -p "$wt/.agents" "$wt/.git" "$dir/state/t1.agy-hooks"
  local arg
  # The worktree's own agent wiring and git state are refused outright under
  # bypass - a hook file or git config written there disarms this layer or
  # the repository's controls, and no native prompt exists to catch it.
  while IFS= read -r arg; do
    [ -n "$arg" ] || continue
    hook "$policy" pre-tool-use write_to_file "$arg"
    denied "$OUT" "permission wiring" \
      || fail "write_to_file on '$arg' must be refused, got: $OUT"
  done <<EOF
$wt/.agents/hooks.json
$wt/.agents/skills/evil/SKILL.md
$wt/.git/config
$wt/.git/hooks/pre-commit
EOF
  # .devin and .claude stay held for firstmate rather than hard-refused.
  hook "$policy" pre-tool-use write_to_file "$wt/.devin/config.json"
  abstained "$OUT" || fail "a .devin write must reach native review: $OUT"
  # The adapter's own firstmate-owned wiring is refused to the file tools too:
  # the policy file, the pending and cache stores, the worker hook directory,
  # and the observer log carrying the armed line and decision record.
  while IFS= read -r arg; do
    [ -n "$arg" ] || continue
    hook "$policy" pre-tool-use write_to_file "$arg"
    denied "$OUT" "permission wiring" \
      || fail "write_to_file on wiring '$arg' must be refused, got: $OUT"
  done <<EOF
$dir/state/t1.agy-permission.json
$dir/state/t1.agy-permission-pending/held.pending
$dir/state/t1.agy-permission-cache/verdict
$dir/state/t1.agy-hooks/.agents/hooks.json
$dir/state/agy-permission-log.jsonl
EOF
  # Whether agy's file tools expand a leading ~ is unverified, so an ambiguous
  # target refuses under bypass rather than trusting a literal '~' directory.
  # shellcheck disable=SC2088 # the literal tilde IS the probe input
  hook "$policy" pre-tool-use write_to_file '~/.zshrc'
  denied "$OUT" "~ path" \
    || fail "a ~ file-tool path must be refused under bypass, got: $OUT"
  pass "fm-agy-permission-policy: file-tool writes refuse .agents/.git and the adapter's own wiring"
}

test_unlisted_tool_escalates_to_firstmate() {
  local policy dir
  policy=$(new_case residue)
  dir=$(case_dir "$policy")
  hook "$policy" pre-tool-use some_mcp_tool "do a thing" 5
  abstained "$OUT" || fail "ordinary residue must reach native review: $OUT"
  hook "$policy" pre-tool-use run_command "rm -rf build" 8
  abstained "$OUT" || fail "task-local residue must reach native review: $OUT"
  hook "$policy" pre-tool-use run_command "npm install" 9
  abstained "$OUT" || fail "ordinary commands must reach native review: $OUT"
  [ ! -e "$dir/state/t1.agy-permission-cache" ] || fail 'native residue created a reusable verdict'
  hook "$policy" pre-tool-use run_command "git push origin main" 10
  denied "$OUT" || fail "an outward action must deny, got: $OUT"
  grep -qF 'firstmate policy: git push names the default branch): git push origin main' "$dir/state/t1.status" \
    || fail "an outward action must name the policy reason, not the judge: $(cat "$dir/state/t1.status")"
  pass "fm-agy-permission-policy: ordinary residue reaches native review and outward actions retain keyed holds"
}

test_held_call_retry_dedupes() {
  local policy dir
  policy=$(new_case dedup)
  dir=$(case_dir "$policy")
  hook "$policy" pre-tool-use run_command "cat .env.example" 5
  denied "$OUT" "held for firstmate" || fail "the first hold must deny, got: $OUT"
  # The same call retried at a new stepIdx is denied against the existing
  # marker - no second marker, no second needs-decision line.
  hook "$policy" pre-tool-use run_command "cat .env.example" 7
  denied "$OUT" "still held for firstmate as agy-permission-c1-s5" \
    || fail "a retry of the held call must deny against the first marker, got: $OUT"
  [ "$(grep -c '^needs-decision ' "$dir/state/t1.status")" = 1 ] \
    || fail "a retried hold must not append a second needs-decision: $(cat "$dir/state/t1.status")"
  [ "$(find "$dir/state/t1.agy-permission-pending" -name '*.pending' | wc -l | tr -d ' ')" = 1 ] \
    || fail "a retried hold must not write a second marker"
  pass "fm-agy-permission-policy: a held call's retry is denied against its existing marker"
}

test_post_tool_use_closes_the_marker_that_ran() {
  local policy dir ckey
  policy=$(new_case closure)
  dir=$(case_dir "$policy")
  hook "$policy" pre-tool-use run_command "cat .env.example" 5
  [ -f "$dir/state/t1.agy-permission-pending/c1-s5.pending" ] || fail "the escalation must open"
  hook "$policy" post-tool-use run_command "ls" 6
  [ -f "$dir/state/t1.agy-permission-pending/c1-s5.pending" ] \
    || fail "an unrelated call must not close the marker"
  # A held call that runs WITHOUT firstmate's approval is an anomaly, not an
  # approval: the marker still closes - the call ran - but the status line
  # names the deny that was not honored so firstmate audits the pane.
  hook "$policy" post-tool-use run_command "cat .env.example" 5
  [ ! -e "$dir/state/t1.agy-permission-pending/c1-s5.pending" ] \
    || fail "the held call running must close its marker"
  grep -qF 'ran WITHOUT a firstmate approval' "$dir/state/t1.status" \
    || fail "an unapproved run must close as an anomaly: $(cat "$dir/state/t1.status")"
  [ -z "$(status_open_decisions "$dir/state/t1.status")" ] \
    || fail "a run call must close its decision: $(cat "$dir/state/t1.status")"
  pass "fm-agy-permission-policy: post-tool-use closes an unauthorized exact invocation as an anomaly"
}

test_stop_preserves_pending_for_firstmate() {
  local policy dir
  policy=$(new_case stop-keeps)
  dir=$(case_dir "$policy")
  hook "$policy" pre-tool-use run_command "cat .env.example" 5
  [ -n "$(status_open_decisions "$dir/state/t1.status")" ] || fail "the escalation must open"
  hook "$policy" stop run_command "" 6
  [ -f "$dir/state/t1.agy-permission-pending/c1-s5.pending" ] \
    || fail "Stop must NOT close a held marker - firstmate's decision is still owed"
  [ -n "$(status_open_decisions "$dir/state/t1.status")" ] \
    || fail "the decision must stay open across turn end: $(cat "$dir/state/t1.status")"
  pass "fm-agy-permission-policy: Stop keeps held markers open for firstmate's answer"
}

test_decline_denies_the_retry_without_reescalating() {
  local policy dir held
  policy=$(new_case decline-flow)
  dir=$(case_dir "$policy")
  hook "$policy" pre-tool-use run_command "cat .env.example" 5
  denied "$OUT" || fail "the residue call must first be held, got: $OUT"
  held="agy-permission-c1-s5"
  "$POLICY_SH" decline "$policy" "$held" </dev/null >/dev/null 2>&1 \
    || fail "decline must succeed for an open key"
  grep -qF "resolved [key=$held]: firstmate declined the held call" "$dir/state/t1.status" \
    || fail "decline must append its resolved line: $(cat "$dir/state/t1.status")"
  [ "$(find "$dir/state/t1.agy-permission-cache" -name '*.declined' | wc -l | tr -d ' ')" = 1 ] \
    || fail "decline must record the declined-call marker"
  # A retry of the declined call is denied outright - never cached, never
  # re-escalated.
  hook "$policy" pre-tool-use run_command "cat .env.example" 8
  denied "$OUT" "firstmate declined this call" \
    || fail "a retry of a declined call must be denied, got: $OUT"
  [ "$(grep -c '^needs-decision ' "$dir/state/t1.status")" = 1 ] \
    || fail "a declined retry must not open a second needs-decision: $(cat "$dir/state/t1.status")"
  pass "fm-agy-permission-policy: firstmate decline denies the exact retry without re-escalating"
}

test_exec_outroot_writes_refuse_not_judge() {
  local policy wt cmd
  policy=$(new_case outroot)
  wt=$(jq -r .worktree "$policy")
  # Under bypass there is no native prompt behind the judge, so a statically
  # visible write or removal outside every write root is refused outright.
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    hook "$policy" pre-tool-use run_command "$cmd"
    denied "$OUT" "refused under bypass" \
      || fail "pre-tool-use must refuse '$cmd' under bypass, got: $OUT"
  done <<EOF
cp README.md /etc/fm-out
install -m 644 README.md /etc/fm-out
mv README.md /etc/fm-out
rm -f /etc/fm-out
rm -rf /etc/fm-out-dir
ln README.md /etc/fm-out
dd if=/dev/zero of=/etc/fm-out bs=1 count=1
truncate -s 0 /etc/fm-out
echo hi | tee /etc/fm-out
echo hi > /etc/fm-out
echo hi >> /etc/fm-out
mkdir /etc/fm-out
EOF
  # Operands that are reads never bind the refusal: a cp whose outside
  # operand is read-only and whose write lands inside the roots is an
  # ordinary task-local file op, so it abstains.
  hook "$policy" pre-tool-use run_command "cp /etc/hosts $wt/copy"
  abstained "$OUT" \
    || fail "a cp whose outside operand is a READ must not be refused, got: $OUT"
  hook "$policy" pre-tool-use run_command "ln -s /etc/hosts $wt/host-link"
  native_review "$OUT" "$policy" || fail "an in-root symlink must receive native review: $OUT"
  hook "$policy" pre-tool-use run_command "split /etc/fm-big"
  native_review "$OUT" "$policy" || fail "split must reach native review: $OUT"
  hook "$policy" pre-tool-use run_command "cat /etc/hosts"
  abstained "$OUT" \
    || fail "a plain non-credential read must never be refused, got: $OUT"
  # A write made inside an interpreter program is held for firstmate rather
  # than refused, because only statically visible targets are refused.
  hook "$policy" pre-tool-use run_command "python3 -c 'open(\"/etc/fm-out\",\"w\").write(\"x\")'"
  native_review "$OUT" "$policy" || fail "opaque interpreter effects must reach native review: $OUT"
  pass "fm-agy-permission-policy: visible out-of-root writes refuse; opaque effects receive native review"
}

test_exec_wiring_writes_refuse() {
  local policy dir cmd
  policy=$(new_case wiring)
  dir=$(case_dir "$policy")
  # The same protected-wiring set binds run_command: a statically visible
  # write or removal of the policy file, its stores, the hook dir, or the
  # observer log is refused to every writer shape.
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    hook "$policy" pre-tool-use run_command "$cmd"
    denied "$OUT" "permission wiring" \
      || fail "pre-tool-use must refuse wiring write '$cmd', got: $OUT"
  done <<EOF
echo x > $dir/state/t1.agy-permission.json
echo x >> $dir/state/agy-permission-log.jsonl
rm -f $dir/state/agy-permission-log.jsonl
rm -f $dir/state/t1.agy-permission.json
rm -rf $dir/state/t1.agy-permission-cache
mv $dir/state/t1.agy-permission.json $dir/state/evil
cp README.md $dir/state/t1.agy-permission.json
echo x | tee $dir/state/agy-permission-log.jsonl
EOF
  # A file beside the brief inside the task's own data root is NOT wiring:
  # it stays held, proving the protection is file-precise rather than a
  # blanket on the directories wiring happens to share.
  hook "$policy" pre-tool-use run_command "rm -f $dir/data/t1/notes.txt"
  native_review "$OUT" "$policy" || fail "an in-root residue write must receive native review: $OUT"
  pass "fm-agy-permission-policy: run_command refuses writes and removals of the adapter's own wiring"
}

test_never_approve_uses_a_one_shot_token() {
  local policy dir held
  policy=$(new_case once)
  dir=$(case_dir "$policy")
  hook "$policy" pre-tool-use run_command "git push origin main" 5
  denied "$OUT" "held for firstmate" || fail "the outward call must first be held, got: $OUT"
  [ "$(sed -n '4p' "$dir/state/t1.agy-permission-pending/c1-s5.pending")" = never ] \
    || fail "an outward action must mark its marker never-class: $(cat "$dir/state/t1.agy-permission-pending/c1-s5.pending")"
  held="agy-permission-c1-s5"
  "$POLICY_SH" approve "$policy" "$held" </dev/null >/dev/null 2>&1 \
    || fail "approve must succeed for an open never-class key"
  grep -qF 'approved ONE run' "$dir/state/t1.status" \
    || fail "a never-class approval must record its one-shot bound: $(cat "$dir/state/t1.status")"
  [ "$(find "$dir/state/t1.agy-permission-cache" -name '*.once' | wc -l | tr -d ' ')" = 1 ] \
    || fail "a never-class approval must leave a one-shot token, not a verdict cache entry"
  [ "$(find "$dir/state/t1.agy-permission-cache" -type f ! -name '*.once' | wc -l | tr -d ' ')" = 0 ] \
    || fail "a never-class approval must not plant a reusable verdict"
  # The first retry consumes the token and runs.
  hook "$policy" pre-tool-use run_command "git push origin main" 8
  abstained "$OUT" || fail "the one-shot retry must abstain and run, got: $OUT"
  [ "$(find "$dir/state/t1.agy-permission-cache" -name '*.once-spent' | wc -l | tr -d ' ')" = 1 ] \
    || fail "the consumed token must be recorded as spent"
  # A further retry escalates again - the approval was one run, not a verdict.
  hook "$policy" pre-tool-use run_command "git push origin main" 9
  denied "$OUT" "held for firstmate" \
    || fail "a second retry after the one-shot must escalate again, got: $OUT"
  [ -f "$dir/state/t1.agy-permission-pending/c1-s9.pending" ] \
    || fail "the re-escalation must open a fresh marker"
  pass "fm-agy-permission-policy: a never-approve approval is a one-shot token one retry consumes"
}

test_sensitive_paths_hold_for_firstmate_once() {
  local policy dir held arg
  policy=$(new_case sensitive)
  dir=$(case_dir "$policy")
  # agy's own credential stores and the cloud CLIs' token material are
  # credential reads: held for firstmate, never sent to the judge.
  while IFS= read -r arg; do
    [ -n "$arg" ] || continue
    hook "$policy" pre-tool-use view_file "$arg"
    denied "$OUT" "held for firstmate" \
      || fail "view_file of credential material '$arg' must hold for firstmate, got: $OUT"
  done <<EOF
$HOME/.gemini/antigravity-cli/antigravity-oauth-token
$HOME/.gemini/oauth_creds.json
$HOME/.config/gcloud/application_default_credentials.json
$HOME/.config/gcloud/credentials.db
EOF
  hook "$policy" pre-tool-use run_command "cat ~/.config/gcloud/legacy_credentials"
  denied "$OUT" "held for firstmate" \
    || fail "an exec read of gcloud material must hold for firstmate, got: $OUT"
  hook "$policy" pre-tool-use run_command "cat ~/.gemini/oauth_creds.json"
  denied "$OUT" "held for firstmate" \
    || fail "an exec read of agy OAuth material must hold for firstmate, got: $OUT"
  # Firstmate's approval of a held credential read must take effect for
  # exactly one identical retry, including template-sensitive reads.
  hook "$policy" pre-tool-use view_file "$HOME/.ssh/id_rsa" 20
  denied "$OUT" "held for firstmate" || fail "the credential read must first be held, got: $OUT"
  held="agy-permission-c1-s20"
  "$POLICY_SH" approve "$policy" "$held" </dev/null >/dev/null 2>&1 \
    || fail "approve must succeed for the held credential read"
  hook "$policy" pre-tool-use view_file "$HOME/.ssh/id_rsa" 21
  abstained "$OUT" \
    || fail "a firstmate-approved credential read must abstain on retry, got: $OUT"
  hook "$policy" pre-tool-use view_file "$HOME/.ssh/id_rsa" 22
  denied "$OUT" || fail "credential approval must be consumed by one retry"
  pass "fm-agy-permission-policy: credential paths hold for firstmate and approval authorizes one retry"
}

test_spent_credential_token_binds_to_invocation() {
  local policy dir command spent ckey
  policy=$(new_case spent-credential)
  dir=$(case_dir "$policy")
  command='cat .env'
  hook "$policy" pre-tool-use run_command "$command" 5
  denied "$OUT" || fail "credential read must initially hold"
  "$POLICY_SH" approve "$policy" agy-permission-c1-s5 </dev/null >/dev/null 2>&1 || fail "approve credential read"
  hook "$policy" pre-tool-use run_command "$command" 8
  abstained "$OUT" || fail "authorized credential retry must run"
  spent=$(find "$dir/state/t1.agy-permission-cache" -name '*.once-spent')
  [ -f "$spent" ] || fail "authorized invocation needs its spent proof"
  # Keep the earlier post hook missing: its stale proof must not bless a
  # later retry that bypasses a fresh denial, including an old reusable cache.
  hook "$policy" pre-tool-use run_command "$command" 9
  denied "$OUT" || fail "later credential retry must hold"
  ckey=$(sed -n '3p' "$dir/state/t1.agy-permission-pending/c1-s9.pending")
  printf 'legacy reusable verdict\n' > "$dir/state/t1.agy-permission-cache/$ckey"
  hook "$policy" post-tool-use run_command "$command" 9
  jq -e 'select(.event == "post-tool-use" and .decision == "anomaly" and .reason == "escalation agy-permission-c1-s9")' "$dir/state/agy-permission-log.jsonl" >/dev/null \
    || fail "stale spent proof must not hide the later deny-bypass anomaly"
  [ -f "$spent" ] || fail "a different invocation must not remove the earlier run's proof"
  hook "$policy" post-tool-use run_command "$command" 8
  [ ! -e "$spent" ] || fail "authorized invocation completion must retire its proof"
  hook "$policy" pre-tool-use run_command "$command" 10
  denied "$OUT" || fail "completed one-shot cannot approve another attempt"
  "$POLICY_SH" approve "$policy" agy-permission-c1-s10 </dev/null >/dev/null 2>&1 || fail "approve next exact attempt"
  hook "$policy" pre-tool-use run_command "$command" 12
  abstained "$OUT" || fail "a fresh approval must authorize its next pre hook"
  hook "$policy" post-tool-use run_command "$command" 12
  [ -z "$(find "$dir/state/t1.agy-permission-cache" -name '*.once-spent')" ] || fail "completed credential proof must be removed"
  hook "$policy" pre-tool-use run_command "$command" 15
  denied "$OUT" || fail "new credential hold must open"
  "$POLICY_SH" approve "$policy" agy-permission-c1-s15 </dev/null >/dev/null 2>&1 || fail "approve overlapping invocation"
  hook "$policy" pre-tool-use run_command "$command" 18
  abstained "$OUT" || fail "overlapping authorized invocation must run"
  hook "$policy" pre-tool-use run_command "$command" 19
  denied "$OUT" || fail "later overlapping invocation must hold"
  hook "$policy" post-tool-use run_command "$command" 18
  [ -f "$dir/state/t1.agy-permission-pending/c1-s19.pending" ] || fail "earlier completion must not resolve the later held invocation"
  hook "$policy" post-tool-use run_command "$command" 19
  jq -e 'select(.event == "post-tool-use" and .decision == "anomaly" and .reason == "escalation agy-permission-c1-s19")' "$dir/state/agy-permission-log.jsonl" >/dev/null \
    || fail "later overlapping deny-bypass must record its own anomaly"
  pass "fm-agy-permission-policy: spent credential approval proves only its invocation and retires on completion"
}

test_retire_closes_open_escalations() {
  local policy dir
  policy=$(new_case retire)
  dir=$(case_dir "$policy")
  hook "$policy" pre-tool-use run_command "cat .env.example" 5
  [ -n "$(status_open_decisions "$dir/state/t1.status")" ] || fail "the escalation must open"
  "$POLICY_SH" retire "$policy" </dev/null >/dev/null 2>&1 || fail "retire must succeed"
  [ ! -e "$dir/state/t1.agy-permission-pending" ] || fail "retire must remove the pending directory"
  [ -z "$(status_open_decisions "$dir/state/t1.status")" ] \
    || fail "retire must close the orphaned decision: $(cat "$dir/state/t1.status")"
  "$POLICY_SH" retire "$policy" </dev/null >/dev/null 2>&1 \
    || fail "retire with nothing pending must be a no-op success"
  pass "fm-agy-permission-policy: retire closes escalations a dead worker left open"
}

test_grants_digest_pins_the_block() {
  local policy dir tampered
  policy=$(new_case grants '{"credential_env_files": ["~/.config/acme/acme.env"]}')
  dir=$(case_dir "$policy")
  hook "$policy" pre-tool-use run_command 'set -a; source ~/.config/acme/acme.env; set +a' 1
  abstained "$OUT" || fail "a granted credential env file must be sourceable, got: $OUT"
  hook "$policy" pre-tool-use run_command 'cat ~/.config/acme/acme.env' 2
  denied "$OUT" "held for firstmate" \
    || fail "the granted file must never be printed, got: $OUT"
  # A block the worker edits no longer matches the recorded digest.
  tampered=$(new_case grants-tampered '{"credential_env_files": ["~/.config/acme/acme.env"]}')
  local fence tdir
  tdir=$(case_dir "$tampered")
  fence=$(printf '\140\140\140')
  cat > "$tdir/data/t1/brief.md" <<EOF
# Task
## Captain's intent
Fix the flaky test.

## Firstmate spec
Keep the change narrow.

${fence}firstmate-grants
{"credential_env_files": ["~/.config/other/self.env"]}
${fence}
EOF
  hook "$tampered" pre-tool-use run_command 'set -a; source ~/.config/other/self.env; set +a' 1
  denied "$OUT" "held for firstmate" \
    || fail "a tampered grants block must grant nothing, got: $OUT"
  grep -qF 'grants block does not match the digest' "$tdir/state/agy-permission-log.jsonl" \
    || fail "the tampered block must be logged as ignored: $(cat "$tdir/state/agy-permission-log.jsonl")"
  pass "fm-agy-permission-policy: grants are honored only while their digest matches"
}

test_workspace_scope_and_unparseable_payloads() {
  local policy out
  policy=$(new_case scope)
  # A payload whose workspace does not include this task's worktree cannot be
  # judged here - and under a bypass launch abstaining would run it, so even
  # an otherwise safe command denies.
  out=$(jq -nc \
    '{conversationId:"c9", stepIdx:1, workspacePaths:["/somewhere/else"],
      toolCall:{name:"run_command", args:{CommandLine:"ls", Cwd:"/somewhere/else"}}}' \
    | "$POLICY_SH" pre-tool-use "$policy" 2>/dev/null)
  denied "$out" "not scoped to this task's workspace" \
    || fail "a foreign-workspace payload must deny, got: $out"
  [ ! -e "$(case_dir "$policy")/state/t1.status" ] \
    || fail "a foreign payload must never touch this task's status"
  # The refusal list still speaks first: a refused command is refused no
  # matter which workspace the call arrived under.
  out=$(jq -nc \
    '{conversationId:"c9", stepIdx:1, workspacePaths:["/somewhere/else"],
      toolCall:{name:"run_command", args:{CommandLine:"sudo true", Cwd:"/somewhere/else"}}}' \
    | "$POLICY_SH" pre-tool-use "$policy" 2>/dev/null)
  denied "$out" || fail "a refused command in a foreign workspace must deny, got: $out"
  # A payload that cannot be read cannot be judged; under bypass abstaining
  # would run it, so it denies.
  out=$(printf 'not json at all' | "$POLICY_SH" pre-tool-use "$policy" 2>/dev/null)
  denied "$out" "unparseable" \
    || fail "an unparseable payload must deny, got: $out"
  pass "fm-agy-permission-policy: foreign-workspace and unparseable payloads deny"
}

test_missing_policy_file_fails_closed() {
  local out
  out=$(jq -nc '{conversationId:"c1", stepIdx:1, workspacePaths:[],
      toolCall:{name:"run_command", args:{CommandLine:"rm -rf /tmp/x", Cwd:"/tmp"}}}' \
    | "$POLICY_SH" pre-tool-use "$TMP_ROOT/absent/t9.agy-permission.json" 2>/dev/null)
  denied "$out" || fail "without a policy file a recursive rm is unresolvable and must deny, got: $out"
  # Without a readable policy there is no judge, no cache, and no workspace
  # scope to trust - and under a bypass launch abstaining would run the call,
  # so even a safe read denies rather than emitting nothing.
  out=$(jq -nc '{conversationId:"c1", stepIdx:1, workspacePaths:[],
      toolCall:{name:"run_command", args:{CommandLine:"cat README.md", Cwd:"/tmp"}}}' \
    | "$POLICY_SH" pre-tool-use "$TMP_ROOT/absent/t9.agy-permission.json" 2>/dev/null)
  denied "$out" "missing or unreadable" \
    || fail "without a policy file even a safe read must deny, got: $out"
  pass "fm-agy-permission-policy: a missing policy file keeps the refusal list and denies the rest"
}

test_verified_versions_and_grants_digest_verbs() {
  local digest dir
  dir="$TMP_ROOT/verbs"
  mkdir -p "$dir"
  cat > "$dir/brief.md" <<'EOF'
# Task
```firstmate-grants
{"write_dirs": ["/tmp/x"]}
```
EOF
  digest=$("$POLICY_SH" grants-digest "$dir/brief.md" 2>/dev/null)
  case "$digest" in ''|*[!0-9a-f]*) fail "grants-digest must print a sha for a block, got: $digest" ;; esac
  [ ${#digest} -eq 64 ] || fail "grants-digest must print a 64-char sha, got: $digest"
  pass "fm-agy-permission-policy: the grants-digest query reports the grants pin"
}

test_install_worker_merges_and_validates() {
  local dir state id gen wt policy merged
  dir="$TMP_ROOT/install"; state="$dir/state"; id="agy-install-x1"; gen="g1"; wt="$dir/wt"
  mkdir -p "$state" "$wt"
  # Without a policy the install keeps the observer-only shape.
  "$HOOK_SH" install-worker "$state" "$id" "$gen" "$wt" >/dev/null 2>&1 \
    || fail "install-worker without a policy must succeed"
  merged="$state/$id.agy-hooks/.agents/hooks.json"
  [ "$(jq -r '."firstmate-worker".PreToolUse[0].hooks | length' "$merged")" = 1 ] \
    || fail "the observer-only install must carry one PreToolUse hook: $(cat "$merged")"
  # With a policy file the adapter rides beside the observer.
  mkdir -p "$dir/data/t1"
  cat > "$dir/data/t1/brief.md" <<'EOF'
# Task
## Captain's intent
x
EOF
  policy="$state/$id.agy-permission.json"
  jq -n --arg wt "$(cd "$wt" && pwd -P)" --arg d "$dir" \
    '{task:"t1", worktree:$wt, status:($d+"/state/t1.status"), inbox:($d+"/state/t1.inbox"),
      data:($d+"/data/t1"), tasktmp:($d+"/tmp"), brief:($d+"/data/t1/brief.md"),
      log:($d+"/state/agy-permission-log.jsonl"), agy:"/bin/true", judge_model:"x",
      judge_timeout:"60", grants_sha:""}' > "$policy"
  "$HOOK_SH" retire-worker "$state" "$id" >/dev/null 2>&1
  "$HOOK_SH" install-worker "$state" "$id" "$gen" "$wt" "$policy" >/dev/null 2>&1 \
    || fail "install-worker with a policy must succeed"
  # Eight commands total: open, close, observer pre, observer post, armed,
  # decide, policy stop, policy post.
  [ "$(jq -r '[."firstmate-worker" | .. | objects | select(has("command")) | .command] | length' "$merged")" = 8 ] \
    || fail "the policy install must carry eight hook commands: $(cat "$merged")"
  jq -e '."firstmate-worker".PreToolUse[0].hooks[1].command | test("fm-agy-permission-policy.*pre-tool-use")' \
    "$merged" >/dev/null \
    || fail "the decision hook must run second on PreToolUse: $(cat "$merged")"
  jq -e '."firstmate-worker".PreToolUse[0].hooks[1].timeout > 100' "$merged" >/dev/null \
    || fail "the decision hook retains its bounded execution budget: $(cat "$merged")"
  jq -e '."firstmate-worker".PreInvocation | map(.command) | any(test("armed"))' "$merged" >/dev/null \
    || fail "the armed heartbeat must join PreInvocation: $(cat "$merged")"
  jq -e '."firstmate-worker".Stop | map(.command) | any(test("fm-agy-permission-policy"))' "$merged" >/dev/null \
    || fail "the adapter must join Stop: $(cat "$merged")"
  jq -e '."firstmate-worker".PostToolUse[0].hooks[1].command | test("fm-agy-permission-policy.*post-tool-use")' \
    "$merged" >/dev/null \
    || fail "the marker-close hook must run second on PostToolUse: $(cat "$merged")"
  # A missing policy file refuses the install rather than writing dead wiring.
  rm -f "$policy"
  "$HOOK_SH" retire-worker "$state" "$id" >/dev/null 2>&1
  "$HOOK_SH" install-worker "$state" "$id" "$gen" "$wt" "$policy" >/dev/null 2>&1 \
    && fail "install-worker must refuse a missing policy file"
  pass "fm-agy-permission-policy: install-worker merges the adapter beside the observer and validates the result"
}

test_observer_and_turnend_survive_the_merge() {
  local dir state id gen wt log payload
  dir="$TMP_ROOT/observe"; state="$dir/state"; id="agy-observe-x1"; gen="g1"; wt="$dir/wt"
  mkdir -p "$state" "$wt" "$dir/data/$id"
  wt=$(cd "$wt" && pwd -P)
  printf 'g1\n' > "$state/$id.busy-gen"
  "$HOOK_SH" install-worker "$state" "$id" "$gen" "$wt" >/dev/null 2>&1 || fail "install must succeed"
  log="$state/agy-permission-log.jsonl"
  payload=$(jq -nc --arg wt "$(cd "$wt" && pwd -P)" \
    '{conversationId:"conv1", stepIdx:3, modelName:"m1", workspacePaths:[$wt],
      toolCall:{name:"run_command", args:{CommandLine:"ls -la", Cwd:"/tmp"}}}')
  printf '%s' "$payload" | "$HOOK_SH" worker PreToolUse "$state" "$id" "$gen" "$wt" >/dev/null 2>&1
  [ "$(jq -r 'select(.event == "pre-tool-use") | .input' "$log" 2>/dev/null)" = "ls -la" ] \
    || fail "the observer must still log the tool call: $(cat "$log" 2>/dev/null)"
  # The turn-end path: PreInvocation opens busy, a fullyIdle Stop closes it
  # and touches turn-ended.
  printf '%s' "$(jq -nc --arg wt "$(cd "$wt" && pwd -P)" \
    '{conversationId:"conv1", invocationNum:0, workspacePaths:[$wt]}')" \
    | "$HOOK_SH" worker PreInvocation "$state" "$id" "$gen" "$wt" >/dev/null 2>&1
  printf '%s' "$(jq -nc --arg wt "$(cd "$wt" && pwd -P)" \
    '{conversationId:"conv1", fullyIdle:true, executionNum:0, workspacePaths:[$wt]}')" \
    | "$HOOK_SH" worker Stop "$state" "$id" "$gen" "$wt" >/dev/null 2>&1
  [ -e "$state/$id.turn-ended" ] \
    || fail "a fullyIdle Stop must still close the turn through the worker hook"
  pass "fm-agy-permission-policy: the observer and turn-end supervision survive the merged install"
}

test_git_state_changes_are_not_read_and_build() {
  local policy wt cmd out class
  policy=$(new_case git-shapes)
  wt=$(jq -r .worktree "$policy")
  while IFS='|' read -r class cmd; do
    [ -n "$cmd" ] || continue
    hook "$policy" pre-tool-use run_command "$cmd"
    case "$class" in
      never-approve) denied "$OUT" || fail "outward command must hold: $cmd" ;;
      residue)
        abstained "$OUT" || fail "residue must reach native review: $cmd => $OUT"
        tail -1 "$(case_dir "$policy")/state/agy-permission-log.jsonl" | jq -e '.decision == "native-review"' >/dev/null \
          || fail "state-changing command escaped native review: $cmd" ;;
      read-and-build)
        abstained "$OUT" || fail "read-and-build must pass: $cmd"
        tail -1 "$(case_dir "$policy")/state/agy-permission-log.jsonl" | jq -e '.decider == "policy" and .decision == "approve"' >/dev/null \
          || fail "routine command was not classified as read-and-build: $cmd" ;;
    esac
  done <<'EOF'
residue|git remote -v add upstream https://example.invalid/x.git
residue|git remote --verbose set-url origin https://example.invalid/y.git
residue|git checkout -b fm/new -f
residue|git checkout -b fm/new --force origin/main
residue|git switch -c fm/new --discard-changes
residue|git fetch --upload-pack=true origin
never-approve|git push -vd origin fm/old
never-approve|git push origin HEAD:refs/tags/v1
read-and-build|git remote -v
read-and-build|git checkout -b fm/new origin/main
read-and-build|git switch -c fm/new
EOF
  pass "fm-agy-permission-policy: git remote and branch-creation forms that change state are never read-and-build"
}

test_exact_shell_inbox_acknowledgements() {
  local policy dir wt inbox cmd
  policy=$(new_case inbox-ack)
  dir=$(case_dir "$policy")
  wt=$(jq -r .worktree "$policy")
  inbox="$dir/state/t1.inbox"
  printf 'one\n' > "$inbox/001.msg"
  printf 'two\n' > "$inbox/002.msg"
  cmd="mkdir -p '$dir/data/t1' '$inbox/handled' && mv '$inbox'/001.msg '$inbox'/002.msg '$inbox'/handled/"
  hook "$policy" pre-tool-use run_command "$cmd"
  abstained "$OUT" || fail "compound multi-source inbox setup/ack must pass: $OUT"
  bash -c "$cmd" || fail "approved inbox acknowledgement must execute"
  [ -f "$inbox/handled/001.msg" ] && [ -f "$inbox/handled/002.msg" ] \
    || fail "both messages must actually be acknowledged"
  hook "$policy" pre-tool-use run_command "mkdir -p '$inbox/handled'; mv '$inbox/003.msg' '$inbox/handled/' 2>&1"
  abstained "$OUT" || fail "normal compound shell ack must pass: $OUT"
  mkdir -p "$dir/state/sibling.inbox/handled" "$dir/escape"
  while IFS= read -r cmd; do
    hook "$policy" pre-tool-use run_command "$cmd"
    denied "$OUT" || native_review "$OUT" "$policy" || fail "non-ack inbox operation must refuse or receive native review: $cmd => $OUT"
  done <<CASES
mv '$dir/state/sibling.inbox/001.msg' '$dir/state/sibling.inbox/handled/'
mv '$inbox/003.msg' '$inbox/../sibling.inbox/handled/'
mv '$inbox/not-numeric.msg' '$inbox/handled/'
mv '$inbox/'*.msg '$inbox/handled/'
mv '$inbox/003.msg' '$inbox/handled/renamed.msg'
mv '$inbox/001.msg' '$inbox/handled/002.msg'
CASES
  ln -s "$dir/escape" "$inbox/003.msg"
  hook "$policy" pre-tool-use run_command "mv '$inbox/003.msg' '$inbox/handled/'"
  denied "$OUT" || native_review "$OUT" "$policy" || fail "message symlink must refuse or receive native review: $OUT"
  rm "$inbox/003.msg"
  rm -r "$inbox/handled"
  ln -s "$dir/escape" "$inbox/handled"
  hook "$policy" pre-tool-use run_command "mkdir -p '$inbox/handled' && mv '$inbox/004.msg' '$inbox/handled/'"
  denied "$OUT" || native_review "$OUT" "$policy" || fail "handled symlink must refuse or receive native review: $OUT"
  pass "fm-agy-permission-policy: exact inbox acknowledgements pass; other moves require native review or refuse"
}

test_read_constraints_and_interpreter_routing() {
  local policy dir wt cmd
  # This fixture judge consumes the public prompt, not implementation bytes.
  # It tests routing/context transport; model agreement requires a live probe.
  # shellcheck disable=SC2016
  policy=$(new_case read-scope)
  dir=$(case_dir "$policy")
  wt=$(jq -r .worktree "$policy")
  export PROMPT_CAPTURE="$dir/prompt-capture"
  hook "$policy" pre-tool-use run_command 'node -v'
  abstained "$OUT" || fail "node -v must be static: $OUT"
  [ ! -e "$PROMPT_CAPTURE" ] || fail "node -v must not spend a judge call"
  hook "$policy" pre-tool-use run_command 'node -v extra' 2
  abstained "$OUT" || fail "extra node argv must reach native review"
  hook "$policy" pre-tool-use run_command 'node -e '\''console.log(require("fs").readdirSync("notes"))'\''' 3
  abstained "$OUT" || fail "read-only Node must reach effect review: $OUT"
  hook "$policy" pre-tool-use run_command 'node -e '\''console.log(require("fs").readFileSync(".env","utf8"))'\''' 4
  native_review "$OUT" "$policy" || fail "opaque interpreter effects must reach native review"
  # Put the independence constraint beyond the normal spec excerpt.
  python3 - "$dir/data/t1/brief.md" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_text("# Task\n## Captain's intent\nInspect permitted.csv.\n## Firstmate spec\n" + "Ordinary build instruction.\n"*250 + "DO NOT READ sibling data directories.\n# Setup\n")
PY
  mkdir -p "$dir/data/excluded"
  printf 'prohibited\n' > "$dir/data/excluded/records.csv"
  cmd="python3 -c 'import glob; [open(p).read() for p in glob.glob(\"$dir/data/**/records.csv\",recursive=True)]'"
  hook "$policy" pre-tool-use run_command "$cmd" 5
  denied "$OUT" || fail "broad excluded-directory glob must be held: $OUT"
  # Model an enforcing caller: only an abstention executes the read.
  # The fixture records file reads separately from the policy's logs.
  if abstained "$OUT"; then
    bash -c "$cmd" > "$dir/excluded-read-observed"
  fi
  [ ! -e "$dir/excluded-read-observed" ] || fail "prohibited matching fixture must not be read"
  hook "$policy" pre-tool-use run_command 'cat permitted.csv' 6
  denied "$OUT" || fail "shell source reads require explicit scope review: $OUT"
  hook "$policy" pre-tool-use view_file "$wt/permitted.csv" 7
  denied "$OUT" || fail "file-tool reads require the same scope review: $OUT"
  hook "$policy" pre-tool-use manage_task '' 8 '{"Action":"kill","TaskId":"other-session/task-40"}'
  denied "$OUT" || fail "unproved foreign native task kill must stay held"
  unset PROMPT_CAPTURE
  pass "fm-agy-permission-policy: Node effects and long-brief read exclusions reach judgment; unproved task kills stay held"
}

test_own_brain_and_directed_reads_skip_read_scope() {
  local policy dir wt saved_home=$HOME brain skill other
  # The fixture judge declines everything and keeps the prompt, so an
  # abstention below can only come from the static exemption.
  # shellcheck disable=SC2016
  policy=$(new_case own-reads)
  dir=$(case_dir "$policy")
  wt=$(jq -r .worktree "$policy")
  export PROMPT_CAPTURE="$dir/prompt-capture"
  skill=$(cd "$ROOT/.agents/skills/captain-hold-lifecycle" && pwd -P)/SKILL.md
  other=$(cd "$ROOT/.agents/skills/ship-landing" && pwd -P)/SKILL.md
  mkdir -p "$dir/data/excluded"
  printf 'prohibited\n' > "$dir/data/excluded/records.csv"
  python3 - "$dir/data/t1/brief.md" "$skill" "$dir/data/excluded/records.csv" "$other" <<'PY'
import sys
from pathlib import Path
skill, outside, other = sys.argv[2:]
Path(sys.argv[1]).write_text(
    "# Task\n## Captain's intent\nInspect permitted.csv.\n## Firstmate spec\n"
    "DO NOT READ sibling data directories.\n"
    "# Definition of done\n"
    f"Before reporting done, read and follow `{skill}`, but never read `{other}`.\n"
    f"Also read and follow `{outside}`.\n")
PY
  HOME="$dir/home"
  brain="$HOME/.gemini/antigravity-cli/brain/c1"
  mkdir -p "$brain/.system_generated/steps/22" "$HOME/.gemini/antigravity-cli/brain/c2"
  printf 'fetched page\n' > "$brain/.system_generated/steps/22/content.md"
  printf 'other conversation\n' > "$HOME/.gemini/antigravity-cli/brain/c2/content.md"
  ln -s "$HOME/.gemini/antigravity-cli/brain/c2/content.md" "$brain/escape.md"
  printf 'SECRET=1\n' > "$brain/.env"

  hook "$policy" pre-tool-use view_file "$brain/.system_generated/steps/22/content.md" 1
  abstained "$OUT" || fail "own brain read must run under read exclusions: $OUT"
  hook "$policy" pre-tool-use list_dir '' 2 "{\"DirectoryPath\":\"$brain/.system_generated/steps\"}"
  abstained "$OUT" || fail "own brain listing must run under read exclusions: $OUT"
  hook "$policy" pre-tool-use view_file "$skill" 3
  abstained "$OUT" || fail "brief-directed skill read must run under read exclusions: $OUT"
  hook "$policy" pre-tool-use read_file "$brain/.system_generated/steps/22/content.md" 40
  abstained "$OUT" || fail "current native own-brain read must retain the exemption: $OUT"
  hook "$policy" pre-tool-use read_file "$skill" 41
  abstained "$OUT" || fail "current native brief-directed read must retain the exemption: $OUT"
  [ ! -e "$PROMPT_CAPTURE" ] || fail "exempt reads must not spend a judge call"

  hook "$policy" pre-tool-use view_file "$HOME/.gemini/antigravity-cli/brain/c2/content.md" 4
  denied "$OUT" || fail "another conversation's brain must stay under read scope: $OUT"
  hook "$policy" pre-tool-use view_file "$brain/escape.md" 5
  denied "$OUT" || fail "a symlink out of the own brain must not carry the exemption: $OUT"
  hook "$policy" pre-tool-use view_file "$brain/.env" 6
  denied "$OUT" "held for firstmate" || fail "credential material in the own brain must still hold: $OUT"
  hook "$policy" pre-tool-use view_file "$other" 7
  denied "$OUT" || fail "a path the directing line excludes must stay under read scope: $OUT"
  hook "$policy" pre-tool-use view_file "$dir/data/excluded/records.csv" 8
  denied "$OUT" || fail "a directed read outside firstmate's skills tree must stay under read scope: $OUT"
  hook "$policy" pre-tool-use read_file "$HOME/.gemini/antigravity-cli/brain/c2/content.md" 42
  denied "$OUT" || fail "current native foreign-brain reads must retain read scope: $OUT"
  hook "$policy" pre-tool-use read_file "$brain/.env" 43
  denied "$OUT" 'held for firstmate' || fail "current native own-brain credentials must retain the veto: $OUT"

  rm -f "$PROMPT_CAPTURE"
  hook "$policy" pre-tool-use run_command "sed -n '1,5p' $brain/.system_generated/steps/22/content.md" 9
  denied "$OUT" || fail "a shell read of the own brain still reaches the judge: $OUT"
  HOME=$saved_home
  unset PROMPT_CAPTURE
  pass "fm-agy-permission-policy: own-brain and brief-directed reads skip read scope; foreign, escaping, credential and undirected reads do not"
}

# agy adds descriptive string arguments (toolAction, toolSummary) beside a
# file tool's path, so a credential path is rarely the last string argument.
test_credential_read_holds_beside_other_arguments() {
  local policy wt
  policy=$(new_case env-args)
  wt=$(jq -r .worktree "$policy")
  hook "$policy" pre-tool-use view_file "$wt/.env" 1 '{"toolAction":"Viewing file","toolSummary":"Read config"}'
  denied "$OUT" "held for firstmate" \
    || fail "a .env read followed by other string arguments must hold for firstmate: $OUT"
  hook "$policy" pre-tool-use view_file "$wt/app/.env.local" 2 '{"toolSummary":"Read config"}'
  denied "$OUT" "held for firstmate" \
    || fail "a .env.* read followed by other string arguments must hold for firstmate: $OUT"
  pass "fm-agy-permission-policy: a credential path holds whatever string arguments follow it"
}

# A literal inline Python program that only parses a fetched page is a
# read-only lookup for the judge; a download that can become code is not.
test_exact_template_batch_retry() {
  local policy dir batch
  policy=$(new_case template-batch)
  dir=$(case_dir "$policy")
  batch='cat .env.example && cat app/.env.example'
  hook "$policy" pre-tool-use run_command "$batch" 30
  denied "$OUT" || fail "template batch must hold before approval"
  "$POLICY_SH" approve "$policy" agy-permission-c1-s30 </dev/null >/dev/null 2>&1 || fail "batch approval failed"
  grep -q 'retry the identical command or batch' "$dir/state/t1.status" || fail "resolution must request identical retry"
  hook "$policy" pre-tool-use run_command "$batch" 31
  abstained "$OUT" || fail "identical approved template batch must run once: $OUT"
  hook "$policy" pre-tool-use run_command "$batch" 32
  denied "$OUT" || fail "credential-sensitive approval must remain one-shot"
  hook "$policy" pre-tool-use run_command 'cat .env.other' 33
  denied "$OUT" || fail "batch authority must not exempt .env wildcards"
  pass "fm-agy-permission-policy: exact template batch retry is explained, bound and one-shot"
}

test_audit_survives_runtime_cleanup() {
  local policy dir archive decision
  policy=$(new_case audit)
  dir=$(case_dir "$policy")
  printf 'harness=agy\nkind=scout\nmode=direct-PR\nagy_bypass=on\nagy_version=1.2.11\nagy_permission_mode=auto\nagy_judge=agy:fixture\n' > "$dir/state/t1.meta"
  jq 'del(.posture)' "$policy" > "$policy.old" && mv "$policy.old" "$policy"
  cat > "$dir/state/agy-permission-log.jsonl" <<'ROWS'
{"task":"t1","gen":"g1","event":"armed","session_id":"c1"}
{"task":"t1","gen":"g1","event":"pre-tool-use","session_id":"c1","decision":"approve","decider":"judge","judge_attempts":1,"judge_elapsed_seconds":1,"judge_timeouts":0}
{"task":"t1","gen":"g1","event":"pre-tool-use","decision":"escalate","tool_use_id":"c1-s2","ts":"2026-10-02T12:00:00Z"}
ROWS
  mkdir -p "$dir/state/t1.agy-permission-pending"
  printf 'agy-permission-c1-s2\ncat .env.example\nold-key\njudge\n' > "$dir/state/t1.agy-permission-pending/c1-s2.pending"
  printf 'needs-decision [key=agy-permission-c1-s2]: legacy hold\n' > "$dir/state/t1.status"
  decision=$(sed -n '1p' "$dir/state/t1.agy-permission-pending/c1-s2.pending")
  printf 'done [at=1700000000]: report delivered\n' >> "$dir/state/t1.status"
  # Exercise the teardown's public retire function without an endpoint.
  # shellcheck source=bin/fm-agy-lib.sh
  . "$ROOT/bin/fm-agy-lib.sh"
  local SCRIPT_DIR="$ROOT/bin"
  fm_agy_teardown_retire "$dir/state" t1 || fail "retire must archive successfully"
  archive="$dir/state/agy-permission-audit.jsonl"
  jq -e '.kind == "scout" and .mode == "direct-PR" and .agy_version == "1.2.11" and .confirmed_judge_coverage and .result == "done" and .judge_attempts == 1 and .judge_timeouts == 0 and (.resolution_timing | length) == 1 and .resolution_timing[0].elapsed_seconds >= 0 and (.armed_generations | length) == 1 and .judge_tier == null' "$archive" >/dev/null \
    || fail "archive must preserve outcome, coverage and metrics: $(cat "$archive")"
  fm_agy_teardown_retire "$dir/state" t1 || fail "repeat retire must converge"
  [ "$(wc -l < "$archive" | tr -d ' ')" = 1 ] || fail "archive must be idempotent"
  [ -z "$(status_open_decisions "$dir/state/t1.status")" ] || fail 'retirement dropped an open legacy decision'
  grep -qF "resolved [key=$decision]:" "$dir/state/t1.status" || fail 'retirement lost the exact legacy key'
  rm "$dir/state/t1.meta" "$dir/state/t1.status" "$policy" "$dir/state/agy-permission-log.jsonl"
  jq -e '.judge_attempts == 1 and .captain_timing_complete == false and (has("input") | not)' "$archive" >/dev/null || fail "summary must remain after runtime removal"
  policy=$(new_case manual-audit)
  dir=$(case_dir "$policy")
  printf 'harness=agy\nkind=ship\nagy_permission_mode=manual\n' > "$dir/state/t1.meta"
  fm_agy_teardown_retire "$dir/state" t1 || fail "manual task archive failed"
  jq -e '.confirmed_judge_coverage == false and .permission_mode == "manual"' "$dir/state/agy-permission-audit.jsonl" >/dev/null || fail "manual task must not count as judge coverage"
  # A historical armed line must not prove coverage for a new generation.
  printf 'harness=agy\nkind=ship\nagy_bypass=on\n' > "$dir/state/t1.meta"
  jq '.gen="g2"' "$policy" > "$policy.new" && mv "$policy.new" "$policy"
  hook "$policy" pre-tool-use run_command 'cat README.md' 9
  jq '.gen="g3"' "$policy" > "$policy.new" && mv "$policy.new" "$policy"
  jq -c 'if .event == "armed" then .gen="g3" else . end' "$dir/state/agy-permission-log.jsonl" > "$dir/log.new" && mv "$dir/log.new" "$dir/state/agy-permission-log.jsonl"
  fm_agy_teardown_retire "$dir/state" t1 || fail "stale generation archive failed"
  tail -1 "$dir/state/agy-permission-audit.jsonl" | jq -e '.confirmed_judge_coverage == false' >/dev/null || fail "stale armed evidence cannot prove this generation"
  policy=$(new_case corrupt-audit)
  dir=$(case_dir "$policy")
  printf 'harness=agy\nkind=scout\n' > "$dir/state/t1.meta"
  printf 'broken-json\n' > "$dir/state/agy-permission-log.jsonl"
  if fm_agy_teardown_retire "$dir/state" t1 >/dev/null 2>&1; then fail "corrupt audit input must stop cleanup"; fi
  [ -f "$dir/state/t1.meta" ] && [ -f "$policy" ] || fail "archive failure must preserve runtime evidence"
  pass "fm-agy-permission-policy: teardown archives coverage, timing and metrics before deleting runtime evidence"
}


test_review_read_boundaries_and_nonread_exclusions() {
  local policy dir cmd tool
  policy=$(new_case review-web)
  dir=$(case_dir "$policy")
  printf '# Task\n## Captain\047s intent\nInspect permitted.csv.\n## Firstmate spec\nDo not read external web sources.\n# Setup\n' > "$dir/data/t1/brief.md"
  for tool in search_web read_url_content; do
    hook "$policy" pre-tool-use "$tool" 'https://example.com/source'
    denied "$OUT" || fail "web read restrictions must reach scope review: $tool => $OUT"
  done
  # The identical web inputs normally pass when no restriction applies.
  policy=$(new_case review-unrestricted)
  for tool in search_web read_url_content; do
    hook "$policy" pre-tool-use "$tool" 'https://example.com/source'
    abstained "$OUT" || fail "unrestricted web reads should remain routine: $OUT"
  done
  policy=$(new_case review-diff-exclusions)
  dir=$(case_dir "$policy")
  printf '# Task\n## Captain\047s intent\nFix the build.\n## Firstmate spec\nExclude generated files from the diff output.\n# Setup\n' > "$dir/data/t1/brief.md"
  for cmd in 'git status' 'npm test' 'node -v'; do
    hook "$policy" pre-tool-use run_command "$cmd"
    abstained "$OUT" || fail "diff-only exclusions must not force scope review: $cmd => $OUT"
  done
  # Positive restrictions beyond the bounded excerpt must still reach a
  # judge, which can approve precisely named sources and hold broader reads.
  # shellcheck disable=SC2016
  policy=$(new_case review-positive)
  dir=$(case_dir "$policy")
  local boundary allowed forbidden
  mkdir -p "$dir/wt/permitted" "$dir/wt/outside"
  touch "$dir/wt/permitted.csv" "$dir/wt/permitted/permitted.csv" "$dir/wt/outside/permitted.csv"
  for boundary in 'only inspect permitted.csv' 'limit access to permitted/'; do
    allowed='cat permitted.csv'
    forbidden='cat broad-source.csv'
    if [ "$boundary" = 'limit access to permitted/' ]; then
      allowed='cat permitted/permitted.csv'
      forbidden='cat outside/permitted.csv'
    fi
    python3 - "$dir/data/t1/brief.md" "$boundary" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_text("# Task\n## Captain's intent\nInspect the source.\n## Firstmate spec\n" + "Ordinary build instruction.\n"*250 + sys.argv[2] + "\n# Setup\n")
PY
    hook "$policy" pre-tool-use run_command "$forbidden" 2
    denied "$OUT" || fail "positive read restriction must hold a broad read: $boundary => $OUT"
    "$POLICY_SH" decline "$policy" agy-permission-c1-s2 </dev/null >/dev/null 2>&1 || fail "close the fixture hold before changing its boundary"
    hook "$policy" pre-tool-use run_command "$allowed" 3
    denied "$OUT" || fail "positive restrictions require scope review: $boundary => $OUT"
  done
  # A judge that would approve any input must not authorize an unproved kill.
  policy=$(new_case review-unproved-kill)
  hook "$policy" pre-tool-use manage_task '' 4 '{"Action":"kill","TaskId":"other-session/task-40","toolSummary":"stop my own task"}'
  denied "$OUT" "verified ownership" || fail "unproved native cancellation must not depend on model labels: $OUT"
  pass "fm-agy-permission-policy: web/positive read boundaries hold, diff exclusions remain routine and native cancellation needs proof"
}

test_complete_lists_and_source_use_prohibitions() {
  local policy dir restriction source step
  # This fixture approves unless the prompt carries the matching exclusion.
  # Missing entries therefore fail through the public decision interface.
  # shellcheck disable=SC2016
  policy=$(new_case review-complete-constraints)
  dir=$(case_dir "$policy")
  step=2
  for restriction in list source-use; do
    python3 - "$dir/data/t1/brief.md" "$restriction" <<'PY'
import sys
from pathlib import Path
boundary = ("Do not read any of these directories:\n- blocked-one/\n- blocked-two/\n- blocked-three/\n"
            if sys.argv[2] == "list" else "Do not use internal research data from source-use/.\n")
Path(sys.argv[1]).write_text("# Task\n## Captain's intent\nInspect the permitted source.\n## Firstmate spec\n" + "Ordinary build instruction.\n"*250 + boundary + "# Setup\n")
PY
    if [ "$restriction" = list ]; then
      for source in blocked-one blocked-two blocked-three; do
        hook "$policy" pre-tool-use run_command "cat $source/records.csv" "$step"
        denied "$OUT" || fail "every excluded list entry must be held: $source => $OUT"
        "$POLICY_SH" decline "$policy" "agy-permission-c1-s$step" </dev/null >/dev/null 2>&1 || fail "close the list fixture hold"
        step=$((step + 1))
      done
    else
      hook "$policy" pre-tool-use run_command 'cat source-use/records.csv' "$step"
      denied "$OUT" || fail "source-use prohibitions must retain scope review: $OUT"
      "$POLICY_SH" decline "$policy" "agy-permission-c1-s$step" </dev/null >/dev/null 2>&1 || fail "close the source-use fixture hold"
      step=$((step + 1))
    fi
    hook "$policy" pre-tool-use run_command 'cat permitted.csv' "$step"
    denied "$OUT" || fail "exclusions require scope review for other sources: $OUT"
    step=$((step + 1))
  done
  pass "fm-agy-permission-policy: complete exclusion lists and source-use prohibitions survive bounded brief excerpts"
}

test_common_negative_read_boundaries() {
  local policy dir boundary tool arg i=0
  export READ_BOUNDARY=''
  while IFS= read -r boundary; do
    i=$((i + 1))
    READ_BOUNDARY=$boundary
    # Missing constraints deliberately approve, exposing static/context gaps.
    # shellcheck disable=SC2016
    policy=$(new_case "negative-form-$i")
    dir=$(case_dir "$policy")
    python3 - "$dir/data/t1/brief.md" "$boundary" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_text("# Task\n## Captain's intent\nInspect the permitted source.\n## Firstmate spec\n" + "Ordinary build instruction.\n"*250 + sys.argv[2] + "\n# Setup\n")
PY
    tool=run_command
    arg='cat sibling/records.csv'
    case "$boundary" in *browse*|*browsing*) tool=search_web; arg='external research sources' ;; esac
    hook "$policy" pre-tool-use "$tool" "$arg" 2
    denied "$OUT" || fail "common negative boundary must hold a broad read: $boundary => $OUT"
    "$POLICY_SH" decline "$policy" agy-permission-c1-s2 </dev/null >/dev/null 2>&1 || fail "close the negative-boundary hold"
    hook "$policy" pre-tool-use run_command 'cat permitted.csv' 3
    denied "$OUT" || fail "negative read boundaries require explicit scope review: $OUT"
  done <<'BOUNDARIES'
Don't read sibling data.
Don’t read sibling data.
No access to external sources.
Do not browse the web.
Without consulting external sources, inspect the local source.
Avoid browsing external sources.
BOUNDARIES
  unset READ_BOUNDARY
  policy=$(new_case negative-word-boundaries)
  dir=$(case_dir "$policy")
  printf '# Task\n## Captain\047s intent\nInspect local sources.\n## Firstmate spec\nNotes: read permitted.csv.\nNormal access to local data is allowed.\n# Setup\n' > "$dir/data/t1/brief.md"
  hook "$policy" pre-tool-use run_command 'cat permitted.csv'
  abstained "$OUT" || fail "negative words must not match inside notes or normal: $OUT"
  pass "fm-agy-permission-policy: common negative read forms reach review without matching unrelated word prefixes"
}

test_archive_scopes_reused_task_ids() {
  local policy dir archive
  policy=$(new_case reused-task-audit)
  dir=$(case_dir "$policy")
  printf 'harness=agy\nkind=scout\nagy_bypass=on\nbusy_gen=g1\n' > "$dir/state/t1.meta"
  cat > "$dir/state/agy-permission-log.jsonl" <<'OLD'
{"task":"t1","gen":"g1","event":"armed","session_id":"c1"}
{"task":"t1","gen":"g1","event":"pre-tool-use","session_id":"c1","decision":"approve","decider":"judge","judge_attempts":9,"judge_elapsed_seconds":90,"judge_timeouts":8}
OLD
  bash "$ROOT/bin/fm-agy-audit.sh" "$dir/state" t1 || fail "old incarnation archive failed"
  printf 'harness=agy\nkind=ship\nagy_bypass=on\nbusy_gen=g2\n' > "$dir/state/t1.meta"
  jq '.gen="g2"' "$policy" > "$policy.new" && mv "$policy.new" "$policy"
  cat >> "$dir/state/agy-permission-log.jsonl" <<'NEW'
{"task":"t1","gen":"g2","event":"armed","session_id":"c1"}
{"task":"t1","gen":"g2","event":"pre-tool-use","session_id":"c1","decision":"approve","decider":"judge","judge_attempts":2,"judge_elapsed_seconds":12,"judge_timeouts":1}
{"task":"t1","gen":"g1","event":"pre-tool-use","session_id":"c1","decision":"escalate","tool_use_id":"c1-s3","ts":"2026-10-02T12:00:00Z"}
{"task":"t1","gen":"g1","event":"decline","reason":"escalation agy-permission-c1-s3","ts":"2026-10-02T12:00:05Z"}
NEW
  bash "$ROOT/bin/fm-agy-audit.sh" "$dir/state" t1 || fail "new incarnation archive failed"
  archive="$dir/state/agy-permission-audit.jsonl"
  [ "$(wc -l < "$archive" | tr -d ' ')" = 2 ] || fail "each metadata incarnation needs its own archive"
  tail -1 "$archive" | jq -e '.generation == "g2" and .log_scope_complete and .kind == "ship" and .confirmed_judge_coverage and .judge_attempts == 2 and .judge_elapsed_seconds == 12 and .judge_timeouts == 1 and .decisions.approve == 1 and .decisions.escalate == 0 and (.resolution_timing | length) == 0 and (.armed_generations | length) == 1 and .armed_generations[0].gen == "g2"' >/dev/null \
    || fail "reused task ids must not combine earlier generations: $(tail -1 "$archive")"
  printf 'harness=agy\nkind=scout\nbusy_gen=g2\n' > "$dir/state/t1.meta"
  printf '{"task":"t1","event":"pre-tool-use","decision":"approve","decider":"judge"}\n' >> "$dir/state/agy-permission-log.jsonl"
  bash "$ROOT/bin/fm-agy-audit.sh" "$dir/state" t1 || fail "legacy row archive failed"
  tail -1 "$archive" | jq -e '.generation == "g2" and .log_scope_complete == false and .judge_metrics_complete == false and .judge_attempts == null' >/dev/null \
    || fail "unattributed historical rows must keep timing incomplete even with a known generation"
  printf 'harness=agy\nkind=scout\n' > "$dir/state/t1.meta"
  rm "$policy"
  bash "$ROOT/bin/fm-agy-audit.sh" "$dir/state" t1 || fail "unscoped legacy archive failed"
  tail -1 "$archive" | jq -e '.log_scope_complete == false and .judge_metrics_complete == false and .judge_attempts == null and .confirmed_judge_coverage == false and (.armed_generations | length) == 0' >/dev/null \
    || fail "unknown legacy incarnation must not claim historical coverage or metrics"
  pass "fm-agy-permission-policy: reused task ids retain only their generation; unscoped legacy timing stays unknown"
}

test_audit_counts_terminal_metrics_once() {
  local policy dir archive
  policy=$(new_case audit-terminal-metrics)
  dir=$(case_dir "$policy")
  printf 'harness=agy\nkind=scout\n' > "$dir/state/t1.meta"
  cat > "$dir/state/agy-permission-log.jsonl" <<'ROWS'
{"task":"t1","gen":"g1","event":"pre-tool-use","decision":"judge-retry","decider":"judge","judge_attempts":1,"judge_elapsed_seconds":4,"judge_timeouts":1}
{"task":"t1","gen":"g1","event":"pre-tool-use","decision":"judge-timeout-verdict","decider":"judge","judge_attempts":2,"judge_elapsed_seconds":4,"judge_timeouts":2}
{"task":"t1","gen":"g1","event":"pre-tool-use","decision":"approve","decider":"judge","judge_attempts":2,"judge_elapsed_seconds":12,"judge_timeouts":2}
ROWS
  bash "$ROOT/bin/fm-agy-audit.sh" "$dir/state" t1 || fail "metrics fixture archive failed"
  archive="$dir/state/agy-permission-audit.jsonl"
  jq -e '.judge_attempts == 2 and .judge_retries == 1 and .judge_timeouts == 2 and .judge_elapsed_seconds == 12 and .decisions.approve == 1' "$archive" >/dev/null \
    || fail "cumulative diagnostics must not inflate terminal metrics: $(cat "$archive")"
  pass "fm-agy-permission-policy: archive counts terminal metrics once despite cumulative diagnostic rows"
}


test_retired_policies_preserve_exact_decisions() {
  local policy dir posture marker decision
  for posture in missing legacy-bypass unknown; do
    policy=$(new_case "retired-$posture")
    dir=$(case_dir "$policy")
    if [ "$posture" = missing ]; then
      jq 'del(.posture)' "$policy" > "$policy.old"
    else
      jq --arg posture "$posture" '.posture=$posture' "$policy" > "$policy.old"
    fi
    mv "$policy.old" "$policy"
    mkdir -p "$dir/state/t1.agy-permission-pending" "$dir/state/t1.agy-permission-cache"
    marker="$dir/state/t1.agy-permission-pending/c1-s5.pending"
    printf 'agy-permission-c1-s5\nnpm install\nold-cache-key\njudge\n' > "$marker"
    printf 'needs-decision [key=agy-permission-c1-s5]: retained legacy hold\n' > "$dir/state/t1.status"
    printf 'approved legacy verdict\n' > "$dir/state/t1.agy-permission-cache/old-cache-key"
    cp "$marker" "$dir/marker.before"
    decision=$(sed -n '1p' "$dir/marker.before")
    hook "$policy" pre-tool-use run_command 'npm install' 5
    denied "$OUT" 'explicit recovery' || fail 'retired policy gained execution authority'
    for event in approve decline resume native-poll repin-grants register-credentials; do
      if "$POLICY_SH" "$event" "$policy" agy-permission-c1-s5 </dev/null > "$dir/out" 2> "$dir/error"; then
        fail "retired $event accepted a new decision"
      fi
      grep -q 'explicit recovery' "$dir/error" || fail 'retired management verb lacks recovery diagnostic'
      cmp -s "$marker" "$dir/marker.before" || fail 'recovery refusal changed the pending key'
    done
    # Missing policy and failed resolution writes must preserve the marker.
    mv "$policy" "$policy.saved"
    if "$POLICY_SH" retire "$policy" </dev/null >/dev/null 2>&1; then fail 'missing retirement policy dropped a hold'; fi
    [ -f "$marker" ] || fail 'missing policy erased the pending marker'
    mv "$policy.saved" "$policy"
    mv "$dir/state/t1.status" "$dir/status.saved"
    mkdir "$dir/state/t1.status"
    if "$POLICY_SH" retire "$policy" </dev/null >/dev/null 2>&1; then fail 'unwritable resolution retired the marker'; fi
    [ -f "$marker" ] || fail 'failed resolution erased the pending marker'
    rmdir "$dir/state/t1.status"
    mv "$dir/status.saved" "$dir/state/t1.status"
    "$POLICY_SH" retire "$policy" </dev/null >/dev/null || fail 'legacy pending decision could not retire'
    [ ! -e "$marker" ] || fail 'retired legacy decision remains pending'
    [ -z "$(status_open_decisions "$dir/state/t1.status")" ] || fail 'retirement lost the exact resolution key'
    grep -qF "resolved [key=$decision]:" "$dir/state/t1.status" || fail 'retirement changed the decision key'
  done
  pass 'retired and unknown policies refuse execution, retain decisions on failure and retire exact keys'
}

test_tracked_read_symlink_dotdot_stays_held
test_listing_multiline_paths_stay_held
test_names_only_worktree_listing
test_own_tool_version_queries
test_tracked_reads_respect_path_exclusions
test_worker_completion_home_binding
test_armed_heartbeat_proves_wiring
test_refusal_list_denies
test_refusal_leaves_safe_commands_alone
test_non_command_tool_mapping
test_current_native_file_contract
test_file_tool_writes_resolve_physically
test_fetch_dest_writes_resolve_physically
test_file_tool_protected_and_config_paths
test_unlisted_tool_escalates_to_firstmate
test_held_call_retry_dedupes
test_post_tool_use_closes_the_marker_that_ran
test_stop_preserves_pending_for_firstmate
test_decline_denies_the_retry_without_reescalating
test_exec_outroot_writes_refuse_not_judge
test_exec_wiring_writes_refuse
test_never_approve_uses_a_one_shot_token
test_sensitive_paths_hold_for_firstmate_once
test_git_state_changes_are_not_read_and_build
test_retire_closes_open_escalations
test_grants_digest_pins_the_block
test_workspace_scope_and_unparseable_payloads
test_missing_policy_file_fails_closed
test_verified_versions_and_grants_digest_verbs
test_install_worker_merges_and_validates
test_observer_and_turnend_survive_the_merge

test_exact_shell_inbox_acknowledgements
test_read_constraints_and_interpreter_routing
test_own_brain_and_directed_reads_skip_read_scope
test_credential_read_holds_beside_other_arguments
test_exact_template_batch_retry
test_audit_survives_runtime_cleanup

test_review_read_boundaries_and_nonread_exclusions
test_complete_lists_and_source_use_prohibitions
test_audit_counts_terminal_metrics_once

test_common_negative_read_boundaries
test_archive_scopes_reused_task_ids
test_spent_credential_token_binds_to_invocation
test_shared_credential_access
test_retained_credential_identity
test_credential_registration_locking
test_credential_registry_without_grants

test_retired_policies_preserve_exact_decisions
