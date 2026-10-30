#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch-resolve.sh.
#
# Drives the public argv and environment interface with a fake curl on PATH
# that records argv, the request body it read from stdin, and the header it
# read from file descriptor 3, and answers with a canned provider response.
# A fake quota-axi serves the selected schema-5 fixture. A fake security and a
# fake uname stand in for the macOS Keychain, so no case reads the real one.
# No case touches the network, and the absent-key case proves the tool makes
# no call at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-dispatch-resolve.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-resolve)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
NO_CURL_BIN="$TMP_ROOT/no-curl-bin"
NO_SECURITY_BIN="$TMP_ROOT/no-security-bin"
NO_JQ_BIN="$TMP_ROOT/no-jq-bin"
LOG="$TMP_ROOT/log"
BRIEF="$TMP_ROOT/brief.md"
BASE_RULES="$TMP_ROOT/rules.json"
RULES="$HOME_DIR/config/crew-dispatch.json"
QUOTA="$TMP_ROOT/quota.json"
BASE_PATH=$PATH
mkdir -p "$HOME_DIR/config" "$LOG" "$NO_CURL_BIN" "$NO_SECURITY_BIN" "$NO_JQ_BIN"
for command_name in bash chmod cp date dirname jq mkdir mktemp rm; do
  ln -s "$(command -v "$command_name")" "$NO_CURL_BIN/$command_name"
  ln -s "$(command -v "$command_name")" "$NO_SECURITY_BIN/$command_name"
done
# Every verified harness's launch location is present here, so the resolver's
# installed-tool gate sees the harnesses its rules name as installed; the
# installed-tool cases below remove chosen executables on purpose. Names come
# from the single-owner table in bin/fm-control-lib.sh: cursor-agent for
# cursor, kiro-cli for kiro, the harness name otherwise. agy and devin keep the
# functional catalog fakes defined below.
fm_fake_exit0 "$FAKEBIN" claude codex opencode pi pi-signed grok kimi cursor-agent gemini muse rovo omp kiro-cli
# The minimal PATHs that simulate one missing command: no security, or no jq.
# Both keep the fake macOS uname, and the no-jq one keeps the fake security.
for command_name in bash chmod cp dirname mktemp rm; do
  ln -s "$(command -v "$command_name")" "$NO_JQ_BIN/$command_name"
done
ln -s "$FAKEBIN/uname" "$NO_SECURITY_BIN/uname"
ln -s "$FAKEBIN/uname" "$NO_JQ_BIN/uname"
ln -s "$FAKEBIN/security" "$NO_JQ_BIN/security"

cat > "$BRIEF" <<'MD'
# Task
Fix the off-by-one in the pager: root cause is the `<=` on line 40 of pager.sh, expected behavior is one page per call.
MD

cat > "$BASE_RULES" <<'JSON'
{
  "rules": [
    {
      "when": "New feature work on the app.",
      "floor": { "scope": "model:fable", "min_percent": 20, "provider": "claude" },
      "use": { "harness": "claude", "model": "fable", "effort": "xhigh" },
      "why": "SECRET-WHY-TEXT feature work wants the strongest model"
    },
    {
      "when": "The task generates images.",
      "use": [
        { "harness": "pi", "model": "openai-codex/gpt-5.6-sol", "provider": "codex" },
        { "harness": "codex", "model": "gpt-5.6-sol", "floor": { "scope": "all_models", "min_percent": 50 } }
      ]
    },
    {
      "when": "Genuinely very difficult design or planning work.",
      "approval": "captain",
      "use": { "harness": "claude", "model": "fable", "effort": "xhigh" }
    },
    {
      "when": "A simple bug fix with a stated root cause.",
      "use": [
        { "harness": "claude", "model": "sonnet", "effort": "high" },
        { "harness": "cursor", "model": "cursor-grok-4.6-medium" },
        { "harness": "kimi", "model": "kimi-code/k3" }
      ]
    }
  ],
  "default": [
    { "harness": "claude", "model": "opus" },
    { "harness": "cursor", "model": "cursor-grok-4.6-high" }
  ]
}
JSON
cp "$BASE_RULES" "$RULES"

write_quota() {  # <path> <cursor spendPriority> [<claude all_models spendPriority>]
  local path=$1 cursor=$2 claude=${3:--0.4627}
  cat > "$path" <<JSON
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    { "provider": "claude", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 79, "runway": { "status": "projected_exhaustion", "usableRunwaySeconds": 7200 }, "selection": { "status": "known", "spendPriority": $claude } },
      { "scope": "model:fable", "status": "known", "effectivePercentRemaining": 15, "runway": { "status": "projected_exhaustion", "usableRunwaySeconds": 7200 }, "selection": { "status": "known", "spendPriority": -0.79 } } ] } },
    { "provider": "codex", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 31, "runway": { "status": "projected_exhaustion", "usableRunwaySeconds": 7200 }, "selection": { "status": "known", "spendPriority": -0.1649 } } ] } },
    { "provider": "cursor", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 91, "runway": { "status": "through_reset" }, "selection": { "status": "known", "spendPriority": $cursor } } ] } },
    { "provider": "agy", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 64, "runway": { "status": "through_reset" }, "selection": { "status": "known", "spendPriority": 0.4 } } ] } },
    { "provider": "google", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 72, "runway": { "status": "through_reset" }, "selection": { "status": "known", "spendPriority": 0.3 } } ] } },
    { "provider": "kimi", "state": { "status": "unknown" }, "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } }
  ]
}
JSON
}
write_quota "$QUOTA" 0.7597

write_response() {  # <path> <choice> <confidence>
  cat > "$1" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "$2", "confidence": $3,
    "probabilities": { "rule_1": 0.01, "rule_2": 0.01, "rule_3": 0.01, "rule_4": 0.96, "default": 0.01 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
}

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: records argv (minus the -o target), the stdin body, and the header
# read from fd 3, then answers with FAKE_CURL_RESPONSE and FAKE_CURL_HTTP.
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ] ||
  [ -n "${OPENROUTER_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY_PRIVATE+x}" ] ||
  [ -n "${OPENAI_API_KEY+x}" ] || [ -n "${OPENAI_API_KEY_PRIVATE+x}" ] ||
  [ -n "${FM_DISPATCH_API_KEY+x}" ] || [ -n "${DISPATCH_API_KEY_PRIVATE+x}" ] ||
  [ -n "${KEY_PRIVATE+x}" ]; then
  printf 'curl:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'curl:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
# With a canary file named, also look for the canary's VALUE in this process's
# environment and in the directories the test lists, where the tool's own
# files live while the request is in flight.
if [ -n "${FAKE_CANARY_FILE:-}" ]; then
  canary=$(cat "$FAKE_CANARY_FILE")
  env | grep -qF -- "$canary" && printf 'curl:canary-in-env\n' >> "${CHILD_ENV_LOG:?}"
  for dir in ${FAKE_CANARY_DIRS:-}; do
    grep -rqF -- "$canary" "$dir" 2>/dev/null && printf 'curl:canary-in-file\n' >> "${CHILD_ENV_LOG:?}"
  done
fi
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "${FAKE_CURL_LOG:?}/argv"; shift ;;
  esac
done
cat > "$FAKE_CURL_LOG/body"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$FAKE_CURL_LOG/header"
if [ -n "${FAKE_CURL_MUTATE_SOURCE:-}" ]; then
  cp "$FAKE_CURL_MUTATE_SOURCE" "${FAKE_CURL_MUTATE_TARGET:?}"
fi
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 7
fi
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ] ||
  [ -n "${OPENROUTER_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY_PRIVATE+x}" ] ||
  [ -n "${OPENAI_API_KEY+x}" ] || [ -n "${OPENAI_API_KEY_PRIVATE+x}" ] ||
  [ -n "${FM_DISPATCH_API_KEY+x}" ] || [ -n "${DISPATCH_API_KEY_PRIVATE+x}" ] ||
  [ -n "${KEY_PRIVATE+x}" ]; then
  printf 'quota-axi:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'quota-axi:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
if [ -n "${FAKE_CANARY_FILE:-}" ] && env | grep -qF -- "$(cat "$FAKE_CANARY_FILE")"; then
  printf 'quota-axi:canary-in-env\n' >> "${CHILD_ENV_LOG:?}"
fi
printf '%s\n' "$*" >> "${QUOTA_AXI_CALLS:?}"
[ "${FAKE_QUOTA_FAIL:-0}" = 1 ] && exit 1
[ "${1:-}" = --json ] || exit 2
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/quota-axi"

cat > "$FAKEBIN/agy" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = models ] || exit 2
[ "${FAKE_AGY_FAIL:-0}" = 1 ] && exit 1
printf 'gemini-3.8-flash-high\tGemini 3.8 Flash (High)\nclaude-sonnet-4-6\tClaude Sonnet\ngpt-5-high\tGPT 5\nfuture-family\tFuture\n'
SH
chmod +x "$FAKEBIN/agy"

cat > "$FAKEBIN/devin" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = models ] && [ "${2:-}" = list ] || exit 2
[ "${FAKE_DEVIN_FAIL:-0}" = 1 ] && exit 1
cat <<'LIST'
Available models (3 families)

SWE-2 (swe-2)
  swe-2-high                     SWE-2 High  [262K context, Free]
  swe-2-max                      SWE-2 Max  [262K context, Free]

GPT-6.1 Sol (gpt-6.1-sol)
  gpt-6-1-sol-high               GPT-6.1 Sol High Thinking  [1M context, $2 / 1M Input · $0.1 / 1M Cached input · $10 / 1M Output]
  gpt-6-1-sol-max                GPT-6.1 Sol Max Thinking  [1M context, $2 / 1M Input · $0.1 / 1M Cached input · $10 / 1M Output]

GPT-6 Luna (gpt-6-luna)
  gpt-6-luna-max                 GPT-6 Luna Max Thinking  [1M context, $0.1 / 1M Input · $0.01 / 1M Cached input · $0.5 / 1M Output]
LIST
SH
chmod +x "$FAKEBIN/devin"

cat > "$FAKEBIN/security" <<'SH'
#!/usr/bin/env bash
# Fake security: the Keychain stand-in. It answers only an exact
# `find-generic-password -s <service> [-a <account>] -w` query, from the item
# file FAKE_SECURITY_STORE/<service>, and records argv and whether a key
# variable reached its environment. FAKE_SECURITY_EXIT fails the query after
# printing the item to stdout and stderr as a decoy, and FAKE_SECURITY_HANG
# names a file to receive its pid before it stops answering.
set -u
printf '%s\n' "$*" >> "${FAKE_SECURITY_LOG:?}"
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ] ||
  [ -n "${OPENROUTER_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY_PRIVATE+x}" ]; then
  printf 'security:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'security:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
[ "${1:-}" = find-generic-password ] || exit 2
shift
service='' wants_password=0
while [ $# -gt 0 ]; do
  case "$1" in
    -s) [ $# -ge 2 ] || exit 2; service=$2; shift 2 ;;
    -a) { [ $# -ge 2 ] && [ -n "$2" ]; } || exit 2; shift 2 ;;
    -w) wants_password=1; shift ;;
    *) exit 2 ;;
  esac
done
[ -n "$service" ] && [ "$wants_password" = 1 ] || exit 2
if [ -n "${FAKE_SECURITY_HANG:-}" ]; then
  printf '%s\n' "$$" > "$FAKE_SECURITY_HANG"
  exec sleep 60
fi
item="${FAKE_SECURITY_STORE:?}/$service"
if [ -n "${FAKE_SECURITY_EXIT:-}" ]; then
  if [ -r "$item" ]; then
    cat "$item"
    printf 'security: could not use the item holding %s\n' "$(cat "$item")" >&2
  fi
  exit "$FAKE_SECURITY_EXIT"
fi
[ -r "$item" ] || exit 44
cat "$item"
SH
chmod +x "$FAKEBIN/security"

cat > "$FAKEBIN/uname" <<'SH'
#!/usr/bin/env bash
# Fake uname: the host is macOS unless FAKE_UNAME names another system.
printf '%s\n' "${FAKE_UNAME:-Darwin}"
SH
chmod +x "$FAKEBIN/uname"

RESPONSE="$TMP_ROOT/response.json"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" QUOTA_AXI_CALLS="$LOG/quota-axi.calls" QUOTA_AXI_FIXTURE="$QUOTA" CHILD_ENV_LOG="$LOG/child-env" FAKE_SECURITY_LOG="$LOG/security.argv"

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

# run <exit-var> <out-var> <err-var> [args...]: the tool with fakebin first on
# PATH and an isolated FM_HOME; TYPESAFE_API_KEY comes from the caller's env.
run() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

run_without_curl() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$NO_CURL_BIN" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="$KEY" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

# run_on_path <path> <exit-var> <out-var> <err-var> [args...]: the tool on a
# caller-built PATH, for the cases that simulate a missing command.
run_on_path() {
  local __path=$1 __exit=$2 __out=$3 __err=$4 _out _code
  shift 4
  _out=$(PATH="$__path" FM_HOME="$HOME_DIR" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

unset TYPESAFE_API_KEY OPENROUTER_API_KEY OPENAI_API_KEY FM_DISPATCH_API_KEY
KEY='test-key-9f1c2d3e-never-on-argv'
code='' out='' err=''

# --- preferred family: public resolution across accounts of one family -----
test_preferred_provider() (
  local scenario=$1 expected="--harness 'pi' --model 'openai-codex/gpt-6-astra'"
  local decision='codex: prefer eligible family candidates' status=clear
  local rules_filter='.' quota_filter='.' override_dir=''
  write_response "$RESPONSE" rule_4 0.9
  jq '.preferred_provider = "codex" | .rules[3].use = [
    {harness:"claude",model:"opus"},
    {harness:"pi",model:"openai-codex/gpt-6-astra",provider:"codex"},
    {harness:"pi",model:"openai-codex-work/gpt-6-astra",provider:"codex"}]' "$BASE_RULES" > "$TMP_ROOT/preferred-rules.json"
  jq '.schemaVersion = 6 | .providers |= map(.accountKey = "default") |
    (.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[0]) |=
      (.effectivePercentRemaining = 26 | .selection.spendPriority = 0.8) |
    (.providers[] | select(.provider == "codex")) |=
      (.accountKey = "openai-codex" | .quotaSemantics.effectiveAvailability[0] |=
        (.effectivePercentRemaining = 82 | .runway.status = "through_reset" | .selection.spendPriority = 0.2)) |
    .providers += [(.providers[] | select(.provider == "codex") | .accountKey = "openai-codex-work" |
      .quotaSemantics.effectiveAvailability[0].selection.spendPriority = 0.1)]' "$QUOTA" > "$TMP_ROOT/preferred-quota.json"
  case "$scenario" in
    astra-82-claude-26) ;;
    work-account)
      quota_filter='(.providers[] | select(.accountKey == "openai-codex-work").quotaSemantics.effectiveAvailability[0].selection.spendPriority) = 0.3'
      expected="--harness 'pi' --model 'openai-codex-work/gpt-6-astra'" ;;
    exhausted)
      quota_filter='(.providers[] | select(.provider == "codex").quotaSemantics.effectiveAvailability[0].runway.status) = "exhausted_now"'
      expected="--harness 'claude' --model 'opus'"
      decision='codex: fall back; every matched family candidate is ineligible' ;;
    unknown)
      quota_filter='(.providers[] | select(.provider == "codex").quotaSemantics) = {status:"unknown",effectiveAvailability:[]}'
      status=escalate; expected='' ;;
    unknown-one-known-one)
      quota_filter='(.providers[] | select(.accountKey == "openai-codex").quotaSemantics) = {status:"unknown",effectiveAvailability:[]}'
      expected="--harness 'pi' --model 'openai-codex-work/gpt-6-astra'" ;;
    claude-only)
      rules_filter='.rules[3].use = [.rules[3].use[0]]'
      expected="--harness 'claude' --model 'opus'"
      decision='codex: not in matched profiles; preserve the selected rule' ;;
    config-override)
      override_dir="$TMP_ROOT/preferred-override"; mkdir -p "$override_dir"
      jq '.preferred_provider = "claude"' "$TMP_ROOT/preferred-rules.json" > "$override_dir/crew-dispatch.json"
      expected="--harness 'claude' --model 'opus'"
      decision='claude: prefer eligible family candidates' ;;
    prose-why)
      rules_filter='.rules[3].why = "Always choose Claude instead of OpenAI."' ;;
    absent)
      rules_filter='del(.preferred_provider)'
      expected="--harness 'claude' --model 'opus'"; decision='' ;;
    approval)
      rules_filter='.rules[3].approval = "captain"'
      status=escalate; expected=''; decision='' ;;
    tie)
      quota_filter='(.providers[] | select(.provider == "codex").quotaSemantics.effectiveAvailability[0].selection.spendPriority) = 0.2'
      status=escalate; expected='' ;;
    floor)
      rules_filter='(.rules[3].use[] | select(.provider == "codex").floor) = {scope:"all_models",min_percent:90}'
      expected="--harness 'claude' --model 'opus'"
      decision='codex: fall back; every matched family candidate is ineligible' ;;
  esac
  jq "$rules_filter" "$TMP_ROOT/preferred-rules.json" > "$RULES"
  jq "$quota_filter" "$TMP_ROOT/preferred-quota.json" > "$TMP_ROOT/preferred-case-quota.json"
  reset_log
  TYPESAFE_API_KEY=$KEY FM_CONFIG_OVERRIDE="${override_dir:-$HOME_DIR/config}" \
    QUOTA_AXI_FIXTURE="$TMP_ROOT/preferred-case-quota.json" \
    run code out err "$BRIEF"
  expect_code 0 "$code" "$scenario resolves"
  assert_contains "$out" "  status: $status" "$scenario status"
  if [ -n "$expected" ]; then
    assert_contains "$out" "  profile: $expected" "$scenario choice"
  else
    assert_not_contains "$out" '  profile:' "$scenario cannot authorize a profile"
  fi
  if [ -n "$decision" ]; then
    assert_contains "$out" "  preferred_provider: $decision" "$scenario explains the family decision"
  else
    assert_not_contains "$out" '  preferred_provider:' "$scenario does not apply preference"
  fi
  if [ "$scenario" = prose-why ]; then
    assert_not_contains "$(cat "$LOG/body")" 'Always choose Claude' 'rule why never reaches the rule matcher'
  fi
  pass "preferred provider: $scenario"
)
test_invalid_preferred_provider() (
  local value=$1
  jq --argjson value "$value" '.preferred_provider = $value' "$BASE_RULES" > "$RULES"
  reset_log
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 2 "$code" "invalid preferred_provider $value is refused"
  assert_contains "$err" 'preferred_provider must be a lowercase provider ID (for example codex)' 'actionable preference error'
  assert_absent "$LOG/argv" 'invalid preference never reaches the rule matcher'
  assert_absent "$LOG/quota-axi.calls" 'invalid preference never reads quota'
  pass "invalid preferred_provider: $value"
)
preferred_failures=0
for value in null false 42 '[]' '{}' '""' '"Codex"' '"codex\\n"' '" codex"'; do
  test_invalid_preferred_provider "$value" || preferred_failures=$((preferred_failures + 1))
done
for scenario in astra-82-claude-26 work-account exhausted unknown unknown-one-known-one claude-only config-override prose-why absent approval tie floor; do
  test_preferred_provider "$scenario" || preferred_failures=$((preferred_failures + 1))
done
[ "$preferred_failures" -eq 0 ] || fail "$preferred_failures preferred-provider cases failed"
cp "$BASE_RULES" "$RULES"
reset_log

# --- absent key: off, silent on stdout, no network, no quota read -----------
reset_log
write_response "$RESPONSE" rule_4 0.9
run code out err "$BRIEF" --project pager
expect_code 0 "$code" "absent key exits 0"
assert_equals '' "$out" "absent key prints nothing on stdout"
assert_contains "$err" 'dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and' "absent key explains itself on stderr"
assert_contains "$err" 'OPENROUTER_API_KEY absent from' "off line names the second provider"
assert_absent "$LOG/argv" "absent key never calls curl"
assert_absent "$LOG/quota-axi.calls" "absent key never reads quota-axi"
pass "absent key is off: one stderr line, exit 0, no network call"

# Early exits must not treat caller-exported paths as resolver-owned temporaries.
CALLER_TEMPS="$TMP_ROOT/caller-temps"
mkdir "$CALLER_TEMPS"
for temp_name in RULES RESP_FILE QUOTA TASK_TEXT SEND_TEXT; do
  printf 'caller-owned %s\n' "$temp_name" > "$CALLER_TEMPS/$temp_name"
done
for early_path in off usage no-rules; do
  case "$early_path" in
    off)
      early_args=("$BRIEF")
      early_key=''
      early_code=0
      ;;
    usage)
      early_args=("$BRIEF" --unknown)
      early_key=$KEY
      early_code=2
      ;;
    no-rules)
      early_args=("$BRIEF")
      early_key=$KEY
      mv "$RULES" "$TMP_ROOT/saved-rules.json"
      early_code=0
      ;;
  esac
  TYPESAFE_API_KEY=$early_key RULES="$CALLER_TEMPS/RULES" \
    RESP_FILE="$CALLER_TEMPS/RESP_FILE" QUOTA="$CALLER_TEMPS/QUOTA" \
    TASK_TEXT="$CALLER_TEMPS/TASK_TEXT" SEND_TEXT="$CALLER_TEMPS/SEND_TEXT" \
    run code out err "${early_args[@]}"
  expect_code "$early_code" "$code" "inherited cleanup paths preserve $early_path exit status"
  for temp_name in RULES RESP_FILE QUOTA TASK_TEXT SEND_TEXT; do
    assert_equals "caller-owned $temp_name" "$(cat "$CALLER_TEMPS/$temp_name")" \
      "$early_path must preserve caller-exported $temp_name"
  done
  if [ "$early_path" = no-rules ]; then
    mv "$TMP_ROOT/saved-rules.json" "$RULES"
  fi
done
pass "off, usage and no-rules exits preserve every caller-exported temporary path"

# --- .env key, and the environment wins over it ------------------------------
printf '%s\n' '# local secrets' 'FMX_PAIRING_TOKEN=abc' "export TYPESAFE_API_KEY=\"$KEY\"" > "$HOME_DIR/.env"
reset_log
run code out err "$BRIEF" --project pager
expect_code 0 "$code" ".env key resolves"
assert_contains "$out" '  status: clear' ".env key produces a clear result"
assert_contains "$(cat "$LOG/header")" "Authorization: Bearer $KEY" ".env key reaches curl on the fd header"
reset_log
TYPESAFE_API_KEY=env-wins run code out err "$BRIEF" --project pager
assert_equals 'Authorization: Bearer env-wins' "$(cat "$LOG/header")" "environment key wins over .env"
rm -f "$HOME_DIR/.env"
OVERRIDE_CONFIG="$TMP_ROOT/override-config"
mkdir -p "$OVERRIDE_CONFIG"
cp "$BASE_RULES" "$OVERRIDE_CONFIG/crew-dispatch.json"
reset_log
TYPESAFE_API_KEY=$KEY FM_CONFIG_OVERRIDE="$OVERRIDE_CONFIG" run code out err "$BRIEF" --project pager
assert_contains "$out" '  status: clear' "FM_CONFIG_OVERRIDE selects the canonical rules directory"
pass "TYPESAFE_API_KEY= in .env activates the tool; environment and config overrides work"

# --- OpenRouter is opt-in through the home .env only -------------------------
reset_log
OPENROUTER_API_KEY=environment-only run code out err "$BRIEF" --project pager
expect_code 0 "$code" "environment-only OpenRouter key exits 0"
assert_equals '' "$out" "environment-only OpenRouter key leaves resolution off"
assert_contains "$err" 'dispatch-resolve: off' "environment-only OpenRouter key is ignored"
assert_absent "$LOG/argv" "environment-only OpenRouter key never calls curl"
assert_absent "$LOG/quota-axi.calls" "environment-only OpenRouter key never reads quota"
printf 'OPENROUTER_API_KEY="%s"\n' "$KEY" > "$HOME_DIR/.env"
reset_log
OPENROUTER_API_KEY=environment-ignored run code out err "$BRIEF" --project pager
expect_code 0 "$code" "OpenRouter .env key resolves"
assert_contains "$out" '  status: clear' "OpenRouter uses unchanged answer handling"
assert_contains "$(cat "$LOG/argv")" 'https://openrouter.ai/api/v1/systemone' "OpenRouter endpoint is used"
assert_equals '~typesafe/jev-latest' "$(jq -r .model "$LOG/body")" "OpenRouter moving alias is used"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" "OpenRouter .env key reaches curl on fd 3"
assert_not_contains "$(cat "$LOG/argv")" "$KEY" "OpenRouter key never appears on argv"
assert_equals $'curl:clean\nquota-axi:clean' "$(cat "$LOG/child-env")" "OpenRouter key is absent from child environments"
openrouter_body=$(jq -c 'del(.model)' "$LOG/body")
reset_log
TYPESAFE_API_KEY=typesafe-wins run code out err "$BRIEF" --project pager
assert_contains "$(cat "$LOG/argv")" 'https://api.typesafe.ai/v1/systemone' "TypeSafe environment key wins over OpenRouter .env key"
assert_equals 'jev-latest' "$(jq -r .model "$LOG/body")" "TypeSafe model is preserved"
assert_equals 'Authorization: Bearer typesafe-wins' "$(cat "$LOG/header")" "TypeSafe key wins"
assert_equals "$openrouter_body" "$(jq -c 'del(.model)' "$LOG/body")" "only the model differs in the request body"
printf 'TYPESAFE_API_KEY=typesafe-file-wins\n' >> "$HOME_DIR/.env"
reset_log
run code out err "$BRIEF" --project pager
assert_contains "$(cat "$LOG/argv")" 'https://api.typesafe.ai/v1/systemone' "TypeSafe .env key wins over OpenRouter .env key"
assert_equals 'Authorization: Bearer typesafe-file-wins' "$(cat "$LOG/header")" "TypeSafe .env key wins"
rm -f "$HOME_DIR/.env"
pass "OpenRouter .env opt-in preserves the request, answer handling, and TypeSafe precedence"

# --- provider scope reaches the snapshot, including config overrides --------
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_equals '--json' "$(cat "$QUOTA_AXI_CALLS")" "absent scope preserves snapshot argv"
printf 'claude,codex\n' > "$HOME_DIR/config/quota-providers"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_equals '--json --provider claude,codex' "$(cat "$QUOTA_AXI_CALLS")" "scope reaches typed resolver snapshot"
printf 'cursor\n' > "$OVERRIDE_CONFIG/quota-providers"
reset_log
TYPESAFE_API_KEY=$KEY FM_CONFIG_OVERRIDE="$OVERRIDE_CONFIG" run code out err "$BRIEF"
assert_equals '--json --provider cursor' "$(cat "$QUOTA_AXI_CALLS")" "scope follows config override"
printf 'claude,unknown\n' > "$HOME_DIR/config/quota-providers"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'status: error' "malformed scope refuses resolver"
assert_contains "$err" 'malformed config/quota-providers' "malformed scope explains refusal"
assert_absent "$QUOTA_AXI_CALLS" "malformed scope never invokes quota-axi"
rm "$HOME_DIR/config/quota-providers" "$OVERRIDE_CONFIG/quota-providers"
pass "typed resolver respects home provider scope and refuses malformed lists"

# --- clear: request shape, secret handling, argmax --------------------------
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "clear exits 0"
assert_contains "$out" 'dispatch-resolve:' "TOON block header"
assert_contains "$out" '  status: clear' "clear status"
assert_contains "$out" '  rule: rule_4 (A simple bug fix with a stated root cause.)   confidence: 0.9' "rule and confidence line"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "argmax picks the highest spendPriority"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=79%  spendPriority=-0.4627  runway=projected_exhaustion  -> eligible' "every candidate is accounted for"
assert_contains "$out" 'candidate: kimi:kimi-code/k3  provider=kimi  -> eligible, unranked: provider kimi unmeasured (unknown): disclosed uncertainty' "unmeasured provider stays listed as eligible and unranked"
assert_contains "$out" '  note: 1 eligible candidate(s) unranked (kimi)' "clear results flag eligible unranked candidates once"
assert_not_contains "$out" '--effort' "cursor profile without effort emits no --effort"
argv=$(cat "$LOG/argv")
assert_not_contains "$argv" "$KEY" "the key never appears on curl argv"
assert_contains "$argv" 'https://api.typesafe.ai/v1/systemone' "the request uses the fixed typesafe.ai endpoint"
assert_contains "$argv" $'--max-time\n5' "the request uses the fixed five-second timeout"
assert_contains "$argv" '@/dev/fd/3' "the header is read from a file descriptor"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" "curl receives the bearer header on fd 3"
assert_equals $'curl:clean\nquota-axi:clean' "$(cat "$LOG/child-env")" "the API key is absent from every child environment"
body=$(cat "$LOG/body")
printf '%s\n' "$body" > "$TMP_ROOT/typesafe-body.json"
assert_equals 'jev-latest' "$(jq -r .model <<<"$body")" "default model is jev-latest"
assert_equals 'pager' "$(jq -r .state.task.project <<<"$body")" "project rides in the state"
assert_contains "$(jq -r .state.task.brief <<<"$body")" 'off-by-one in the pager' "a brief without task headings rides whole in the state"
assert_equals '["rule"]' "$(jq -c '.questions | keys' <<<"$body")" "only the rule Choice is asked"
assert_equals '["default","rule_1","rule_2","rule_3","rule_4"]' "$(jq -c '.questions.rule.criteria | keys' <<<"$body")" "one option per rule plus default"
assert_equals 'No listed rule applies to this task.' "$(jq -r '.questions.rule.criteria.default' <<<"$body")" "the fixed generic none criterion is the default option"
assert_equals 'A simple bug fix with a stated root cause.' "$(jq -r '.questions.rule.criteria.rule_4' <<<"$body")" "rule when text is the option verbatim"
assert_not_contains "$body" 'SECRET-WHY-TEXT' "why text never leaves the machine"
assert_not_contains "$body" 'spendPriority' "quota never leaves the machine"
assert_not_contains "$body" 'cursor-grok' "use profiles never leave the machine"
pass "clear: one rule Choice request, key on the fd header only, spendPriority argmax over every candidate"

# --- OpenRouter uses the same Choice validation and resolution path ---------
OR_KEY='test-openrouter-key-never-in-child-env-or-argv'
OR_RESPONSE="$TMP_ROOT/openrouter-response.json"
write_openrouter_response() {
  write_response "$OR_RESPONSE" "$1" "$2"
  jq '.model = "typesafe/jev-1.13"' "$OR_RESPONSE" > "$TMP_ROOT/or-response.tmp"
  mv "$TMP_ROOT/or-response.tmp" "$OR_RESPONSE"
}
reset_log
write_openrouter_response rule_4 0.9
OPENROUTER_API_KEY=$OR_KEY run code out err "$BRIEF"
assert_equals '' "$out" "an OpenRouter key alone does not select the provider"
assert_contains "$err" 'TYPESAFE_API_KEY absent' "unset provider retains the typesafe off gate"
assert_absent "$LOG/argv" "an OpenRouter key alone sends nothing"
reset_log
FM_DISPATCH_PROVIDER=openrouter FM_DISPATCH_MODEL=typesafe/jev-1.13 \
  OPENROUTER_API_KEY=$OR_KEY FAKE_CURL_RESPONSE=$OR_RESPONSE run code out err "$BRIEF" --project pager
expect_code 0 "$code" "OpenRouter clear exits 0"
assert_contains "$out" '  status: clear' "OpenRouter clear status"
assert_contains "$out" '  probabilities: rule_1=0.01 rule_2=0.01 rule_3=0.01 rule_4=0.96 default=0.01' "OpenRouter preserves per-rule probabilities"
assert_contains "$out" '  profile: --harness '\''cursor'\'' --model '\''cursor-grok-4.6-medium'\''' "OpenRouter uses the shared quota argmax"
assert_contains "$(cat "$LOG/argv")" 'https://openrouter.ai/api/alpha/decisions' "OpenRouter endpoint"
assert_contains "$(cat "$LOG/argv")" $'--max-time\n10' "OpenRouter timeout"
assert_not_contains "$(cat "$LOG/argv")" "$OR_KEY" "OpenRouter key never appears in curl argv"
assert_equals "Authorization: Bearer $OR_KEY" "$(cat "$LOG/header")" "OpenRouter key reaches curl only through fd 3"
assert_equals $'curl:clean\nquota-axi:clean' "$(cat "$LOG/child-env")" "OpenRouter key is absent from child environments"
assert_equals 'typesafe/jev-1.13' "$(jq -r .model "$LOG/body")" "OpenRouter model is explicit"
assert_equals 'pager' "$(jq -r .state.task.project "$LOG/body")" "project reaches the model"
assert_equals 'choice' "$(jq -r .questions.rule.type "$LOG/body")" "OpenRouter uses the native Choice request"
assert_equals "$(jq -Sc 'del(.model)' "$TMP_ROOT/typesafe-body.json")" "$(jq -Sc 'del(.model)' "$LOG/body")" "providers send identical Choice inputs apart from model"
assert_not_contains "$(cat "$LOG/body")" 'SECRET-WHY-TEXT' "OpenRouter never sends rule why text"
pass "OpenRouter clear uses the same output contract and keeps its key out of argv and child environments"

printf '%s\n' 'FM_DISPATCH_PROVIDER=openrouter' 'FM_DISPATCH_MODEL=typesafe/jev-1.13' "OPENROUTER_API_KEY=$OR_KEY" > "$HOME_DIR/.env"
reset_log
FAKE_CURL_RESPONSE=$OR_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "OpenRouter provider, model, and key work from .env"
assert_equals "Authorization: Bearer $OR_KEY" "$(cat "$LOG/header")" ".env OpenRouter key uses fd 3"
reset_log
OPENROUTER_API_KEY=env-wins FAKE_CURL_RESPONSE=$OR_RESPONSE run code out err "$BRIEF"
assert_equals 'Authorization: Bearer env-wins' "$(cat "$LOG/header")" "OpenRouter environment key wins over .env"
rm -f "$HOME_DIR/.env"
reset_log
printf '%s\n' 'pager' > "$HOME_DIR/config/dispatch-never-send"
FM_DISPATCH_PROVIDER=openrouter FM_DISPATCH_MODEL=typesafe/jev-1.13 \
  OPENROUTER_API_KEY=$OR_KEY FAKE_CURL_RESPONSE=$OR_RESPONSE run code out err "$BRIEF" --project pager
assert_equals '' "$out" "OpenRouter never-send match withholds the request"
assert_contains "$err" 'nothing sent)' "OpenRouter never-send reports withholding"
assert_absent "$LOG/argv" "OpenRouter never-send makes no network call"
rm -f "$HOME_DIR/config/dispatch-never-send"

reset_log
write_openrouter_response rule_4 0.5
FM_DISPATCH_PROVIDER=openrouter FM_DISPATCH_MODEL=typesafe/jev-1.13 \
  OPENROUTER_API_KEY=$OR_KEY FAKE_CURL_RESPONSE=$OR_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "OpenRouter low confidence is ambiguous"
assert_not_contains "$out" '  profile:' "OpenRouter ambiguous response has no profile"
reset_log
printf '%s\n' '{"answers":{"rule":{"choice":"rule_4"}}}' > "$OR_RESPONSE"
FM_DISPATCH_PROVIDER=openrouter FM_DISPATCH_MODEL=typesafe/jev-1.13 \
  OPENROUTER_API_KEY=$OR_KEY FAKE_CURL_RESPONSE=$OR_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  status: error' "malformed OpenRouter response is an error"
assert_contains "$out" '  reason: response is not a rule Choice answer' "malformed OpenRouter response names the Choice contract"
reset_log
FM_DISPATCH_PROVIDER=openrouter FM_DISPATCH_MODEL=typesafe/jev-1.13 \
  OPENROUTER_API_KEY=$OR_KEY FAKE_CURL_RESPONSE=$OR_RESPONSE FAKE_CURL_HTTP=429 run code out err "$BRIEF"
assert_contains "$out" '  status: error' "OpenRouter HTTP error is reported"
assert_contains "$out" '  reason: http 429 after' "OpenRouter HTTP status is reported"
assert_not_contains "$out$err" "$OR_KEY" "OpenRouter HTTP error never includes the key"
reset_log
FM_DISPATCH_PROVIDER=openrouter OPENROUTER_API_KEY=$OR_KEY run code out err "$BRIEF"
expect_code 2 "$code" "OpenRouter missing model is a configuration error"
assert_contains "$err" 'FM_DISPATCH_MODEL required when FM_DISPATCH_PROVIDER=openrouter' "missing model is actionable"
assert_absent "$LOG/argv" "missing model makes no network call"
FM_DISPATCH_PROVIDER=unknown OPENROUTER_API_KEY=$OR_KEY run code out err "$BRIEF"
expect_code 2 "$code" "unknown provider is a configuration error"
assert_contains "$err" 'unknown FM_DISPATCH_PROVIDER' "unknown provider is actionable"
pass "OpenRouter ambiguous, malformed, HTTP, and missing-model paths are handled"

# --- additive steady-rate score: one metric for the complete snapshot --------
write_quota "$QUOTA" 0.7597
jq '(.providers[].quotaSemantics.effectiveAvailability[].selection.spendPressure) = 0.1 |
    (.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models") | .selection.spendPressure) = 0.8 |
    (.providers[] | select(.provider == "cursor") | .quotaSemantics.effectiveAvailability[].selection.spendPressure) = 0.3' "$QUOTA" > "$TMP_ROOT/pressure.json"
cp "$TMP_ROOT/pressure.json" "$QUOTA"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "additive pressure is rankable"
assert_contains "$out" '  spend_metric: spendPressure' "the snapshot metric is disclosed"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet'" "steady pressure reverses the legacy Cursor winner"
assert_contains "$out" 'remaining=79%  spendPressure=0.8' "candidate evidence labels the selected metric"
tail -n 1 "$HOME_DIR/state/dispatch-history.jsonl" | jq -e '
  .spendMetric == "spendPressure" and
  any(.candidates[]; .route == "claude:sonnet" and .spendPressure == 0.8 and
    .unmetered == false and (has("spendPriority") | not))
' >/dev/null || fail "history mislabeled pressure as legacy priority"

# Selection applies even when only an unrelated scope advertises the field.
jq 'del(.providers[].quotaSemantics.effectiveAvailability[].selection.spendPressure) |
    (.providers[] | select(.provider == "google") | .quotaSemantics.effectiveAvailability[].selection.spendPressure) = null' "$TMP_ROOT/pressure.json" > "$QUOTA"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  spend_metric: spendPressure' "a null property outside the candidate set selects pressure globally"
assert_contains "$out" '  status: escalate' "candidates cannot rank on legacy scores in a mixed snapshot"

# Provider-wide and exact-model bounds use the same metric and its minimum.
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability) +=
    [{scope:"model:sonnet",status:"known",effectivePercentRemaining:99,
      runway:{status:"through_reset"},selection:{status:"known",spendPriority:99,spendPressure:0.2}}]' "$TMP_ROOT/pressure.json" > "$QUOTA"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'cursor'" "the tightest pressure bound controls ranking"
assert_contains "$out" 'scope=model:sonnet  remaining=99%  spendPressure=0.2' "exact-model pressure is retained as limiting evidence"

jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.effectiveAvailability[].selection) |= (del(.spendPressure) | .spendPriority = 100)' "$TMP_ROOT/pressure.json" > "$QUOTA"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet'" "a missing pressure never falls back to a provider legacy score"
assert_contains "$out" 'spendPressure missing, non-numeric, or selection not known at all_models' "mixed-snapshot missing scores stay unranked"

jq '(.providers[].quotaSemantics.effectiveAvailability[].selection.spendPressure) = "unknown"' "$TMP_ROOT/pressure.json" > "$QUOTA"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "unknown pressure never falls back to legacy scores"
assert_contains "$out" '  reason: no rankable eligible candidate' "unknown pressure is not zero"

jq '(.providers[].quotaSemantics.effectiveAvailability[].selection.spendPressure) = 0.1' "$TMP_ROOT/pressure.json" > "$QUOTA"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "equal pressure never falls back to different legacy scores"
assert_contains "$out" '  reason: genuine spendPressure tie' "a pressure tie names the selected metric"

jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[].runway.usableRunwaySeconds) = 30' "$TMP_ROOT/pressure.json" > "$QUOTA"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "pressure cannot override a short completion runway"
assert_contains "$out" 'runway 30s below completion horizon 3600s' "the unchanged runway veto is disclosed"
pass "additive pressure: consistent snapshot metric, unknown handling, and runway veto"
write_quota "$QUOTA" 0.7597
# --- credential source declaration: where a key lives, never the key -----------
# $CONFIG/dispatch-credential-sources.json names a source per provider. It is
# read only when neither the environment nor .env supplied a key. The fake
# Keychain holds one item file per service name.
SECRET='kc-typesafe-4d7a1e90-never-on-argv'
KC_OR_SECRET='kc-openrouter-8b21f6c3-never-on-argv'
EFFECTIVE_SECRET='kc-effective-c07e5a12-never-on-argv'
STORE="$TMP_ROOT/keychain"
CRED="$HOME_DIR/config/dispatch-credential-sources.json"
mkdir -p "$STORE"
printf '%s\n' "$SECRET" > "$STORE/typesafe-svc"
printf '%s\n' "$KC_OR_SECRET" > "$STORE/openrouter-svc"
printf '%s\n' "$EFFECTIVE_SECRET" > "$STORE/effective-svc"
: > "$STORE/empty-svc"
export FAKE_SECURITY_STORE="$STORE"

# declare_source <file> <provider> <service> [<account>]: add or replace one
# provider's macos-keychain entry, keeping the other providers' entries.
declare_source() {
  local file=$1 provider=$2 service=$3 account=${4:-}
  [ -f "$file" ] || printf '{}\n' > "$file"
  jq --arg p "$provider" --arg s "$service" --arg a "$account" \
    '.[$p] = ({source: "macos-keychain", service: $s} + (if $a == "" then {} else {account: $a} end))' \
    "$file" > "$file.next" && mv "$file.next" "$file"
}

# mapping: the declared service and optional account become the lookup
reset_log
write_response "$RESPONSE" rule_4 0.9
declare_source "$CRED" typesafe typesafe-svc mike
run code out err "$BRIEF" --project pager
expect_code 0 "$code" "a declared source resolves"
assert_contains "$out" '  status: clear' "a declared source turns the tool on"
assert_equals 'find-generic-password -s typesafe-svc -a mike -w' "$(cat "$LOG/security.argv")" "the declared service and account are the whole Keychain lookup"
assert_equals "Authorization: Bearer $SECRET" "$(cat "$LOG/header")" "the declared key reaches curl on the fd header"
rm -f "$CRED"
declare_source "$CRED" typesafe typesafe-svc
reset_log
run code out err "$BRIEF" --project pager
assert_contains "$out" '  status: clear' "a declaration without an account resolves"
assert_equals 'find-generic-password -s typesafe-svc -w' "$(cat "$LOG/security.argv")" "an omitted account is omitted from the lookup"
pass "mapping: a declared macos-keychain service and optional account become the lookup, and the key rides the fd header"

# precedence: environment, then .env, then the declared source
reset_log
TYPESAFE_API_KEY=env-wins run code out err "$BRIEF" --project pager
assert_equals 'Authorization: Bearer env-wins' "$(cat "$LOG/header")" "the environment key wins over a declared source"
assert_absent "$LOG/security.argv" "the environment key wins before the declared source is read"
printf '%s\n' 'TYPESAFE_API_KEY=dotenv-wins' > "$HOME_DIR/.env"
reset_log
run code out err "$BRIEF" --project pager
assert_equals 'Authorization: Bearer dotenv-wins' "$(cat "$LOG/header")" ".env key wins over a declared source"
assert_absent "$LOG/security.argv" ".env key wins before the declared source is read"
rm -f "$HOME_DIR/.env" "$CRED"
printf '%s\n' '{"typesafe":' > "$CRED"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "a key from the environment never consults an invalid declaration"
assert_contains "$out" '  status: clear' "an unread declaration cannot break a configured resolver"
assert_absent "$LOG/security.argv" "an invalid declaration is not read when the environment has the key"
rm -f "$CRED"
pass "precedence: environment, then .env, then the declared source, which is read only when needed"

# provider isolation: each provider reads only its own entry, and an entry never selects a provider
rm -f "$CRED"
declare_source "$CRED" typesafe typesafe-svc
reset_log
write_openrouter_response rule_4 0.9
FM_DISPATCH_PROVIDER=openrouter FM_DISPATCH_MODEL=typesafe/jev-1.13 FAKE_CURL_RESPONSE=$OR_RESPONSE \
  run code out err "$BRIEF" --project pager
expect_code 0 "$code" "a typesafe declaration leaves OpenRouter off"
assert_equals '' "$out" "an OpenRouter run never uses a typesafe declaration"
assert_contains "$err" 'dispatch-resolve: off (OPENROUTER_API_KEY absent from the environment and' "OpenRouter without its own declaration is off"
assert_absent "$LOG/security.argv" "a typesafe declaration is never read for OpenRouter"
assert_absent "$LOG/argv" "OpenRouter without a key never calls curl"
rm -f "$CRED"
declare_source "$CRED" openrouter openrouter-svc
reset_log
run code out err "$BRIEF" --project pager
assert_equals '' "$out" "an OpenRouter declaration neither selects OpenRouter nor feeds typesafe"
assert_contains "$err" 'dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and' "typesafe without its own declaration is off"
assert_absent "$LOG/security.argv" "an OpenRouter declaration is never read for typesafe"
declare_source "$CRED" typesafe typesafe-svc
reset_log
FM_DISPATCH_PROVIDER=openrouter FM_DISPATCH_MODEL=typesafe/jev-1.13 FAKE_CURL_RESPONSE=$OR_RESPONSE \
  run code out err "$BRIEF" --project pager
assert_contains "$out" '  status: clear' "OpenRouter resolves from its own declared source"
assert_equals 'find-generic-password -s openrouter-svc -w' "$(cat "$LOG/security.argv")" "OpenRouter reads only its own declared service"
assert_equals "Authorization: Bearer $KC_OR_SECRET" "$(cat "$LOG/header")" "OpenRouter's declared key reaches curl, not typesafe's"
assert_contains "$(cat "$LOG/argv")" 'https://openrouter.ai/api/alpha/decisions' "OpenRouter's declared key goes to OpenRouter's endpoint"
reset_log
write_response "$RESPONSE" rule_4 0.9
FM_DISPATCH_PROVIDER=typesafe run code out err "$BRIEF" --project pager
assert_equals 'find-generic-password -s typesafe-svc -w' "$(cat "$LOG/security.argv")" "typesafe reads only its own declared service"
assert_equals "Authorization: Bearer $SECRET" "$(cat "$LOG/header")" "typesafe's declared key reaches curl, not OpenRouter's"
assert_contains "$(cat "$LOG/argv")" 'https://api.typesafe.ai/v1/systemone' "typesafe's declared key goes to the typesafe.ai endpoint"
rm -f "$CRED"
pass "provider isolation: each provider reads only its own declared service, and a declaration never selects a provider"

# effective-home isolation: the effective config directory's declaration, and no other
declare_source "$CRED" typesafe typesafe-svc
OTHER_HOME="$TMP_ROOT/other-home"
mkdir -p "$OTHER_HOME/config"
cp "$BASE_RULES" "$OTHER_HOME/config/crew-dispatch.json"
PRIMARY_HOME=$HOME_DIR
HOME_DIR=$OTHER_HOME
reset_log
run code out err "$BRIEF" --project pager
HOME_DIR=$PRIMARY_HOME
assert_equals '' "$out" "a declaration in another home is not consulted"
assert_contains "$err" "dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and $OTHER_HOME/.env)" "a home with no declaration is off"
assert_absent "$LOG/security.argv" "another home's declaration is never read"
EFFECTIVE_CONFIG="$TMP_ROOT/effective-config"
mkdir -p "$EFFECTIVE_CONFIG"
cp "$BASE_RULES" "$EFFECTIVE_CONFIG/crew-dispatch.json"
declare_source "$EFFECTIVE_CONFIG/dispatch-credential-sources.json" typesafe effective-svc
reset_log
FM_CONFIG_OVERRIDE=$EFFECTIVE_CONFIG run code out err "$BRIEF" --project pager
assert_contains "$out" '  status: clear' "an overridden config directory supplies its own declaration"
assert_equals 'find-generic-password -s effective-svc -w' "$(cat "$LOG/security.argv")" "only the effective directory's declaration is read"
assert_equals "Authorization: Bearer $EFFECTIVE_SECRET" "$(cat "$LOG/header")" "the effective directory's key is the one sent"
rm -f "$EFFECTIVE_CONFIG/dispatch-credential-sources.json"
reset_log
FM_CONFIG_OVERRIDE=$EFFECTIVE_CONFIG run code out err "$BRIEF" --project pager
assert_equals '' "$out" "the home's own config declaration is ignored when another directory is effective"
assert_absent "$LOG/security.argv" "a declaration outside the effective directory is never read"
rm -f "$CRED"
pass "effective-home isolation: only the effective config directory's declaration is consulted"

# failure distinctions: off, a configuration error, and an unavailable source are three different things
printf '{}\n' > "$CRED"
reset_log
run code out err "$BRIEF" --project pager
expect_code 0 "$code" "a declaration with no entries is off"
assert_equals '' "$out" "off prints nothing on stdout"
assert_contains "$err" 'dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and' "off says so on stderr"
assert_absent "$LOG/security.argv" "an empty declaration never reaches the Keychain"
assert_absent "$LOG/argv" "off never calls curl"

for bad in \
  '{"typesafe":|not JSON' \
  '|must hold exactly one JSON object' \
  '[]|top-level value must be an object keyed by provider' \
  '{"typsafe":{"source":"macos-keychain","service":"s"}}|unknown provider typsafe (expected typesafe or openrouter)' \
  '{"typesafe":"kc-planted-value"}|typesafe must be an object with a source' \
  '{"typesafe":{"service":"s"}}|typesafe needs a source' \
  '{"typesafe":{"source":"kc-planted-value","service":"s"}}|typesafe source must be one of macos-keychain' \
  '{"typesafe":{"source":"macos-keychain"}}|typesafe service must be a non-empty string without control characters' \
  '{"typesafe":{"source":"macos-keychain","service":""}}|typesafe service must be a non-empty string without control characters' \
  '{"typesafe":{"source":"macos-keychain","service":7}}|typesafe service must be a non-empty string without control characters' \
  '{"typesafe":{"source":"macos-keychain","service":"a\nb"}}|typesafe service must be a non-empty string without control characters' \
  '{"typesafe":{"source":"macos-keychain","service":"s","account":""}}|typesafe account must be a non-empty string without control characters when present' \
  '{"typesafe":{"source":"macos-keychain","service":"s","key":"kc-planted-value"}}|typesafe has unknown field key (allowed: source, service, account); credential values do not belong in this file' \
  '{"openrouter":{"source":"macos-keychain","service":"s","token":"kc-planted-value"}}|openrouter has unknown field token (allowed: source, service, account); credential values do not belong in this file'; do
  printf '%s\n' "${bad%%|*}" > "$CRED"
  reset_log
  run code out err "$BRIEF" --project pager
  expect_code 2 "$code" "an invalid declaration exits 2: ${bad#*|}"
  assert_contains "$err" "malformed credential source declaration: $CRED - ${bad#*|}" "the problem is named: ${bad#*|}"
  assert_not_contains "$err" 'kc-planted-value' "an invalid declaration never echoes a declared value"
  assert_equals '' "$out" "an invalid declaration prints nothing on stdout: ${bad#*|}"
  assert_equals '1' "$(grep -c . <<<"$err")" "an invalid declaration is one diagnostic line: ${bad#*|}"
  assert_absent "$LOG/security.argv" "an invalid declaration never reaches the Keychain: ${bad#*|}"
  assert_absent "$LOG/argv" "an invalid declaration never reaches the network: ${bad#*|}"
done
rm -f "$CRED"
ln -s "$TMP_ROOT/missing-declaration.json" "$CRED"
reset_log
run code out err "$BRIEF" --project pager
expect_code 2 "$code" "a broken declaration symlink exits 2"
assert_contains "$err" "credential source declaration not readable: $CRED" "an unreadable declaration is named"
rm -f "$CRED"
declare_source "$CRED" typesafe typesafe-svc
reset_log
run_on_path "$NO_JQ_BIN" code out err "$BRIEF" --project pager
expect_code 2 "$code" "a declaration cannot be read without jq"
assert_contains "$err" 'error: jq required' "missing jq is named"
assert_absent "$LOG/security.argv" "missing jq never reaches the Keychain"

# expect_unavailable <label> <reason>: a declared source that cannot supply the key
expect_unavailable() {
  local label=$1 reason=$2
  expect_code 0 "$code" "$label exits 0"
  assert_contains "$out" '  status: error' "$label is a structured error outcome"
  assert_contains "$out" "  reason: $reason" "$label names the source and why on stdout"
  assert_contains "$err" "dispatch-resolve: error ($reason)" "$label reports the same reason on stderr"
  assert_not_contains "$err" 'dispatch-resolve: off' "$label is not mistaken for an unconfigured resolver"
  assert_absent "$LOG/argv" "$label never calls curl"
  assert_absent "$LOG/quota-axi.calls" "$label never reads quota"
  assert_not_contains "$out$err" "$SECRET" "$label never prints a stored key"
}
UNAVAILABLE='credential source macos-keychain declared for typesafe is unavailable; nothing sent'
UNSUPPORTED='credential source macos-keychain declared for typesafe is not supported on this host; nothing sent'
declare_source "$CRED" typesafe absent-svc mike
reset_log
run code out err "$BRIEF" --project pager
expect_unavailable "a declared item that is not in the Keychain" "$UNAVAILABLE"
assert_equals 'find-generic-password -s absent-svc -a mike -w' "$(cat "$LOG/security.argv")" "the missing item was looked up once, by its declared identity"
declare_source "$CRED" typesafe empty-svc
reset_log
run code out err "$BRIEF" --project pager
expect_unavailable "a declared item with an empty secret" "$UNAVAILABLE"
declare_source "$CRED" typesafe typesafe-svc
reset_log
FAKE_SECURITY_EXIT=36 run code out err "$BRIEF" --project pager
expect_unavailable "a Keychain that refuses with the item in its output" "$UNAVAILABLE"
assert_not_contains "$out$err" 'could not use the item' "the tool's own output is never relayed"
reset_log
FAKE_UNAME=Linux run code out err "$BRIEF" --project pager
expect_unavailable "a declared macOS source on another system" "$UNSUPPORTED"
assert_absent "$LOG/security.argv" "an unsupported host never runs the credential tool"
reset_log
run_on_path "$NO_SECURITY_BIN" code out err "$BRIEF" --project pager
expect_unavailable "a declared source whose tool is missing" "$UNSUPPORTED"
reset_log
started=$SECONDS
FAKE_SECURITY_HANG="$LOG/hang.pid" run code out err "$BRIEF" --project pager
elapsed=$((SECONDS - started))
expect_unavailable "a declared source that never answers" 'credential source macos-keychain declared for typesafe did not answer in time; nothing sent'
[ "$elapsed" -lt 30 ] || fail "an unanswered Keychain read held the resolver for ${elapsed}s"
[ -s "$LOG/hang.pid" ] || fail "the fake security that never answers was not started"
hang_pid=$(cat "$LOG/hang.pid")
for _ in $(seq 1 50); do
  kill -0 "$hang_pid" 2>/dev/null || break
  sleep 0.1
done
! kill -0 "$hang_pid" 2>/dev/null || fail "the unanswered Keychain read was left running"
rm -f "$CRED"
declare_source "$CRED" openrouter absent-svc
reset_log
FM_DISPATCH_PROVIDER=openrouter FM_DISPATCH_MODEL=typesafe/jev-1.13 run code out err "$BRIEF" --project pager
expect_unavailable "OpenRouter's declared item that is not in the Keychain" 'credential source macos-keychain declared for openrouter is unavailable; nothing sent'
rm -f "$CRED"
pass "failure distinctions: off, a configuration error, and an unavailable source each read differently and send nothing"

# secret containment: the key lives in one private variable and reaches curl on fd 3 only
declare_source "$CRED" typesafe typesafe-svc mike
SCAN_TMP="$TMP_ROOT/scan-tmp"
mkdir -p "$SCAN_TMP"
printf '%s' "$SECRET" > "$TMP_ROOT/canary"
reset_log
TMPDIR=$SCAN_TMP FAKE_CANARY_FILE="$TMP_ROOT/canary" FAKE_CANARY_DIRS="$SCAN_TMP $HOME_DIR" \
  run code out err "$BRIEF" --project pager
assert_contains "$out" '  status: clear' "the containment run resolves"
assert_equals "Authorization: Bearer $SECRET" "$(cat "$LOG/header")" "the key arrives only as the bearer header on the descriptor"
assert_not_contains "$out" "$SECRET" "the key never reaches stdout"
assert_not_contains "$err" "$SECRET" "the key never reaches stderr"
assert_not_contains "$(cat "$LOG/argv")" "$SECRET" "the key never appears on curl argv"
assert_not_contains "$(cat "$LOG/security.argv")" "$SECRET" "the key never appears on security argv"
assert_not_contains "$(cat "$LOG/body")" "$SECRET" "the key never rides in the request body"
assert_equals $'security:clean\ncurl:clean\nquota-axi:clean' "$(cat "$LOG/child-env")" "the key is in no child environment, and in no file the tool holds while the request is in flight"
! grep -rqF -- "$SECRET" "$HOME_DIR" || fail "the key was written under the home"
! grep -rqF -- "$SECRET" "$SCAN_TMP" || fail "the key was left in the temporary directory"
rm -f "$CRED"
pass "secret containment: the declared key is on no argv, in no output, environment, or file, and only on the fd header"

# capability probe: a supported/unsupported answer that reads no declaration and runs no credential tool
printf '%s\n' '{"typesafe":' > "$CRED"
reset_log
run code out err --supports-credential-source macos-keychain
expect_code 0 "$code" "macos-keychain is supported on a macOS host with security"
assert_equals 'supported' "$out" "the probe answers supported"
assert_equals '' "$err" "the probe prints nothing on stderr, and an invalid declaration does not matter to it"
assert_absent "$LOG/security.argv" "the probe never runs security, so it retrieves no credential"
assert_absent "$LOG/argv" "the probe never calls curl"
FAKE_UNAME=Linux run code out err --supports-credential-source macos-keychain
expect_code 1 "$code" "macos-keychain is unsupported on another system"
assert_equals 'unsupported' "$out" "the probe answers unsupported"
run_on_path "$NO_SECURITY_BIN" code out err --supports-credential-source macos-keychain
expect_code 1 "$code" "macos-keychain is unsupported without security"
assert_equals 'unsupported' "$out" "the probe answers unsupported without the tool"
run code out err --supports-credential-source vault
expect_code 1 "$code" "an unknown source is unsupported"
assert_equals 'unsupported' "$out" "the probe answers unsupported for an unknown source"
run_on_path "$NO_JQ_BIN" code out err --supports-credential-source macos-keychain
expect_code 0 "$code" "the probe needs no jq"
run code out err --supports-credential-source
expect_code 2 "$code" "the probe without a source is a usage error"
assert_contains "$err" '--supports-credential-source needs a value' "the usage error is named"
run code out err --help
assert_contains "$out" '--supports-credential-source <source>' "--help documents the probe"
assert_contains "$out" 'dispatch-credential-sources.json' "--help names the declaration file"
assert_absent "$LOG/security.argv" "no probe or help request ran security"
rm -f "$CRED"
pass "capability probe: supported or unsupported, with no declaration read and no credential tool run"

# --- off stays off: no provider and no typesafe key, whatever else is set ----
reset_log
FM_DISPATCH_BASE_URL=http://127.0.0.1:8080 FM_DISPATCH_API_KEY=unused OPENAI_API_KEY=unused \
  OPENROUTER_API_KEY=unused run code out err "$BRIEF" --project pager
expect_code 0 "$code" "config-absent off exits 0"
assert_equals '' "$out" "config-absent off prints nothing on stdout"
assert_equals "dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and $HOME_DIR/.env)" "$err" \
  "config-absent off is the original single stderr line, byte for byte"
assert_absent "$LOG/argv" "config-absent off makes no network call"
assert_absent "$LOG/quota-axi.calls" "config-absent off reads no quota"
pass "with no provider set, other providers' settings leave the original off line unchanged"

# --- systemone: any System One-compatible host at a base URL ----------------
SO_KEY='test-systemone-key-never-in-child-env-or-argv'
SO_RESPONSE="$TMP_ROOT/systemone-response.json"
write_response "$SO_RESPONSE" rule_4 0.9
reset_log
FM_DISPATCH_PROVIDER=systemone FM_DISPATCH_MODEL=clef-flash FM_DISPATCH_BASE_URL=http://127.0.0.1:8080/ \
  FAKE_CURL_RESPONSE=$SO_RESPONSE run code out err "$BRIEF" --project pager
expect_code 0 "$code" "systemone clear exits 0"
assert_contains "$out" '  status: clear' "systemone clear status"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "systemone uses the shared quota argmax"
assert_contains "$(cat "$LOG/argv")" 'http://127.0.0.1:8080/v1/systemone' "systemone posts to <base>/v1/systemone with a trailing slash trimmed"
assert_contains "$(cat "$LOG/argv")" $'--max-time\n10' "systemone timeout"
assert_not_contains "$(cat "$LOG/argv")" '@/dev/fd/3' "systemone without a key sends no Authorization header"
assert_equals 'fd3 unreadable' "$(cat "$LOG/header")" "systemone without a key opens no header descriptor"
assert_equals "$(jq -Sc 'del(.model)' "$TMP_ROOT/typesafe-body.json")" "$(jq -Sc 'del(.model)' "$LOG/body")" "systemone sends the unchanged System One request"
assert_equals 'clef-flash' "$(jq -r .model "$LOG/body")" "systemone model is explicit"
reset_log
FM_DISPATCH_PROVIDER=systemone FM_DISPATCH_MODEL=clef-flash FM_DISPATCH_BASE_URL=https://so.example.test \
  FM_DISPATCH_API_KEY=$SO_KEY FAKE_CURL_RESPONSE=$SO_RESPONSE run code out err "$BRIEF" --project pager
assert_contains "$out" '  status: clear' "systemone with a key is clear"
assert_contains "$(cat "$LOG/argv")" 'https://so.example.test/v1/systemone' "systemone https base URL"
assert_not_contains "$(cat "$LOG/argv")" "$SO_KEY" "systemone key never appears in curl argv"
assert_equals "Authorization: Bearer $SO_KEY" "$(cat "$LOG/header")" "systemone key reaches curl only through fd 3"
assert_equals $'curl:clean\nquota-axi:clean' "$(cat "$LOG/child-env")" "systemone key is absent from child environments"
printf '%s\n' 'FM_DISPATCH_PROVIDER=systemone' 'FM_DISPATCH_MODEL=clef' 'FM_DISPATCH_BASE_URL=http://10.0.0.5:8080' \
  "FM_DISPATCH_API_KEY=$SO_KEY" > "$HOME_DIR/.env"
reset_log
FAKE_CURL_RESPONSE=$SO_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "systemone provider, model, base URL, and key work from .env"
assert_contains "$(cat "$LOG/argv")" 'http://10.0.0.5:8080/v1/systemone' ".env base URL is used"
assert_equals "Authorization: Bearer $SO_KEY" "$(cat "$LOG/header")" ".env systemone key uses fd 3"
rm -f "$HOME_DIR/.env"
pass "systemone posts the unchanged request to its base URL with an optional fd-3 key"

reset_log
FM_DISPATCH_PROVIDER=systemone FM_DISPATCH_BASE_URL=http://127.0.0.1:8080 run code out err "$BRIEF"
expect_code 2 "$code" "systemone missing model is a configuration error"
assert_contains "$err" 'FM_DISPATCH_MODEL required when FM_DISPATCH_PROVIDER=systemone' "systemone missing model is actionable"
FM_DISPATCH_PROVIDER=systemone FM_DISPATCH_MODEL=clef run code out err "$BRIEF"
expect_code 2 "$code" "systemone missing base URL is a configuration error"
assert_contains "$err" 'FM_DISPATCH_BASE_URL required when FM_DISPATCH_PROVIDER=systemone' "systemone missing base URL is actionable"
FM_DISPATCH_PROVIDER=systemone FM_DISPATCH_MODEL=clef FM_DISPATCH_BASE_URL=127.0.0.1:8080 run code out err "$BRIEF"
expect_code 2 "$code" "systemone base URL without a scheme is a configuration error"
assert_contains "$err" 'FM_DISPATCH_BASE_URL must start with http:// or https://' "systemone bad base URL is actionable"
assert_absent "$LOG/argv" "systemone configuration errors make no network call"
reset_log
printf '%s\n' '10.0.0.5' > "$HOME_DIR/config/dispatch-never-send"
FM_DISPATCH_PROVIDER=systemone FM_DISPATCH_MODEL=clef FM_DISPATCH_BASE_URL=http://10.0.0.5:8080 \
  FAKE_CURL_RESPONSE=$SO_RESPONSE run code out err "$BRIEF"
assert_equals '' "$out" "a never-send base URL withholds the request"
assert_contains "$err" 'nothing sent)' "a never-send base URL reports withholding"
assert_absent "$LOG/argv" "a never-send base URL makes no network call"
rm -f "$HOME_DIR/config/dispatch-never-send"
reset_log
printf '%s\n' '{"answers":{"rule":{"choice":"rule_4","confidence":0.9}}}' > "$SO_RESPONSE"
FM_DISPATCH_PROVIDER=systemone FM_DISPATCH_MODEL=clef FM_DISPATCH_BASE_URL=http://127.0.0.1:8080 \
  FAKE_CURL_RESPONSE=$SO_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  reason: response is not a rule Choice answer' "systemone partial response is rejected"
reset_log
FM_DISPATCH_PROVIDER=systemone FM_DISPATCH_MODEL=clef FM_DISPATCH_BASE_URL=http://127.0.0.1:8080 \
  FAKE_CURL_FAIL=1 run code out err "$BRIEF"
expect_code 0 "$code" "systemone transport failure exits 0"
assert_contains "$out" '  status: error' "systemone transport failure returns to normal intake"
assert_contains "$out" '  reason: http 000 after' "systemone transport failure reads as http 000"
assert_not_contains "$out" '  profile:' "systemone transport failure never emits a profile"
assert_absent "$LOG/quota-axi.calls" "systemone transport failure reads no quota"
pass "systemone configuration errors, never-send base URL, partial response, and transport failure are handled"

# --- openai: Decisions API, mapped to and from the System One shape ----------
OA_KEY='test-openai-key-never-in-child-env-or-argv'
OA_RESPONSE="$TMP_ROOT/openai-response.json"
write_openai_response() {  # <choice> <confidence> [<rule_4 probability>]
  cat > "$OA_RESPONSE" <<JSON
{ "answers": [ { "type": "choice", "name": "rule", "choice": "$1", "confidence": $2,
    "probabilities": [ { "value": "rule_1", "probability": 0.01 }, { "value": "rule_2", "probability": 0.01 },
      { "value": "rule_3", "probability": 0.01 }, { "value": "rule_4", "probability": ${3:-0.96} },
      { "value": "default", "probability": 0.01 } ] } ],
  "usage": { "input_tokens": 700, "output_tokens": 5 } }
JSON
}
write_openai_response rule_4 0.9
reset_log
OPENAI_API_KEY=$OA_KEY run code out err "$BRIEF"
assert_contains "$err" 'TYPESAFE_API_KEY absent' "an OpenAI key alone does not select the provider"
assert_absent "$LOG/argv" "an OpenAI key alone sends nothing"
reset_log
FM_DISPATCH_PROVIDER=openai FM_DISPATCH_MODEL=gpt-6-luna run code out err "$BRIEF"
expect_code 0 "$code" "openai without a key exits 0"
assert_equals '' "$out" "openai without a key prints nothing on stdout"
assert_equals "dispatch-resolve: off (OPENAI_API_KEY absent from the environment and $HOME_DIR/.env)" "$err" "openai without a key is one off line"
assert_absent "$LOG/argv" "openai without a key makes no network call"
reset_log
FM_DISPATCH_PROVIDER=openai OPENAI_API_KEY=$OA_KEY run code out err "$BRIEF"
expect_code 2 "$code" "openai missing model is a configuration error"
assert_contains "$err" 'FM_DISPATCH_MODEL required when FM_DISPATCH_PROVIDER=openai' "openai missing model is actionable"
assert_absent "$LOG/argv" "openai missing model makes no network call"
reset_log
FM_DISPATCH_PROVIDER=openai FM_DISPATCH_MODEL=gpt-6-luna OPENAI_API_KEY=$OA_KEY \
  FAKE_CURL_RESPONSE=$OA_RESPONSE run code out err "$BRIEF" --project pager
expect_code 0 "$code" "openai clear exits 0"
assert_contains "$out" '  status: clear' "openai clear status"
assert_contains "$out" '  model: gpt-6-luna   latency_ms:' "openai answer without a model reports the configured model"
assert_contains "$out" 'tokens: 700/5' "openai usage is shown"
assert_contains "$out" '  probabilities: rule_1=0.01 rule_2=0.01 rule_3=0.01 rule_4=0.96 default=0.01' "openai probabilities map back to every option"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "openai uses the shared quota argmax"
assert_contains "$(cat "$LOG/argv")" 'https://api.openai.com/v1/decisions' "openai endpoint"
assert_contains "$(cat "$LOG/argv")" $'--max-time\n10' "openai timeout"
assert_not_contains "$(cat "$LOG/argv")" "$OA_KEY" "openai key never appears in curl argv"
assert_equals "Authorization: Bearer $OA_KEY" "$(cat "$LOG/header")" "openai key reaches curl only through fd 3"
assert_equals $'curl:clean\nquota-axi:clean' "$(cat "$LOG/child-env")" "openai key is absent from child environments"
body=$(cat "$LOG/body")
assert_equals 'gpt-6-luna' "$(jq -r .model <<<"$body")" "openai model is explicit"
assert_equals "$(jq -c .state "$TMP_ROOT/typesafe-body.json")" "$(jq -c '.input | fromjson' <<<"$body")" "openai input carries the same state as JSON text"
assert_equals '1 choice rule' "$(jq -r '"\(.questions | length) \(.questions[0].type) \(.questions[0].name)"' <<<"$body")" "openai asks one named choice question"
assert_equals "$(jq -r .questions.rule.instructions "$TMP_ROOT/typesafe-body.json")" "$(jq -r '.questions[0].instructions' <<<"$body")" "openai keeps the question instructions"
assert_equals "$(jq -Sc '.questions.rule.criteria' "$TMP_ROOT/typesafe-body.json")" \
  "$(jq -Sc '.questions[0].choices | map({key: .value, value: .description}) | from_entries' <<<"$body")" "openai choices are every rule plus the none option"
assert_equals 'input,model,questions' "$(jq -r 'keys | join(",")' <<<"$body")" "openai body carries nothing else"
assert_not_contains "$body" 'SECRET-WHY-TEXT' "openai never sends rule why text"
assert_not_contains "$body" 'spendPriority' "openai never sends quota"
pass "openai maps the Choice request to the Decisions API and its answer back, key on fd 3 only"

reset_log
printf '%s\n' 'off-by-one in the pager' > "$HOME_DIR/config/dispatch-never-send"
FM_DISPATCH_PROVIDER=openai FM_DISPATCH_MODEL=gpt-6-luna OPENAI_API_KEY=$OA_KEY \
  FAKE_CURL_RESPONSE=$OA_RESPONSE run code out err "$BRIEF"
assert_equals '' "$out" "a never-send match inside the serialized openai input withholds the request"
assert_contains "$err" 'nothing sent)' "openai never-send reports withholding"
assert_absent "$LOG/argv" "openai never-send makes no network call"
printf '%s\n' 'gpt-6-luna' > "$HOME_DIR/config/dispatch-never-send"
FM_DISPATCH_PROVIDER=openai FM_DISPATCH_MODEL=gpt-6-luna OPENAI_API_KEY=$OA_KEY \
  FAKE_CURL_RESPONSE=$OA_RESPONSE run code out err "$BRIEF"
assert_contains "$err" 'nothing sent)' "a never-send model name withholds the openai request"
assert_absent "$LOG/argv" "a never-send model name makes no network call"
rm -f "$HOME_DIR/config/dispatch-never-send"
pass "the never-send check runs on the final openai request body"

openai_rejects() {  # <response-json> <label>
  printf '%s\n' "$1" > "$OA_RESPONSE"
  reset_log
  FM_DISPATCH_PROVIDER=openai FM_DISPATCH_MODEL=gpt-6-luna OPENAI_API_KEY=$OA_KEY \
    FAKE_CURL_RESPONSE=$OA_RESPONSE run code out err "$BRIEF"
  expect_code 0 "$code" "$2 exits 0"
  assert_contains "$out" '  reason: response is not a rule Choice answer' "$2 is rejected"
  assert_not_contains "$out" '  profile:' "$2 never emits a profile"
  assert_absent "$LOG/quota-axi.calls" "$2 reads no quota"
}
openai_rejects '{"answers":[{"type":"refusal","name":"rule"}]}' "an openai refusal"
openai_rejects '{"answers":{"rule":{"choice":"rule_4"}}}' "an openai answers object"
openai_rejects '{"answers":[]}' "an openai response without the rule answer"
openai_rejects 'not json' "a non-JSON openai response"
openai_rejects '{"answers":[{"type":"choice","name":"rule","choice":"rule_4","confidence":0.9,"probabilities":[{"value":"rule_4","probability":0.5},{"value":"rule_4","probability":0.5}]}]}' "duplicate openai option values"
openai_rejects '{"answers":[{"type":"choice","name":"rule","choice":"rule_4","confidence":0.9,"probabilities":[{"value":"rule_4","probability":0.99},{"value":"default","probability":0.01}]}]}' "openai probabilities missing options"
openai_rejects '{"answers":[{"type":"choice","name":"rule","choice":"rule_4","probabilities":[{"value":"rule_1","probability":0.01},{"value":"rule_2","probability":0.01},{"value":"rule_3","probability":0.01},{"value":"rule_4","probability":0.96},{"value":"default","probability":0.01}]}]}' "an openai answer without confidence"
reset_log
write_openai_response rule_4 0.5
FM_DISPATCH_PROVIDER=openai FM_DISPATCH_MODEL=gpt-6-luna OPENAI_API_KEY=$OA_KEY \
  FAKE_CURL_RESPONSE=$OA_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "openai low confidence is ambiguous"
reset_log
FM_DISPATCH_PROVIDER=openai FM_DISPATCH_MODEL=gpt-6-luna OPENAI_API_KEY=$OA_KEY \
  FAKE_CURL_RESPONSE=$OA_RESPONSE FAKE_CURL_HTTP=401 run code out err "$BRIEF"
assert_contains "$out" '  reason: http 401 after' "openai HTTP error is reported"
assert_not_contains "$out$err" "$OA_KEY" "openai HTTP error never includes the key"
reset_log
FM_DISPATCH_PROVIDER=openai FM_DISPATCH_MODEL=gpt-6-luna OPENAI_API_KEY=$OA_KEY FAKE_CURL_FAIL=1 run code out err "$BRIEF"
expect_code 0 "$code" "openai transport failure exits 0"
assert_contains "$out" '  status: error' "openai transport failure returns to normal intake"
assert_not_contains "$out" '  profile:' "openai transport failure never emits a profile"
pass "openai malformed, partial, refused, ambiguous, HTTP, and transport paths return to normal intake"

# --- never-send list: a match or a bad list withholds the request -------------
NEVER_SEND="$HOME_DIR/config/dispatch-never-send"
PRIVATE_BRIEF="$TMP_ROOT/private-brief.md"
cat > "$PRIVATE_BRIEF" <<'MD'
# Task
## Captain's intent
Fix the pager for the Acme-Ledger account 4417-2290.

## Firstmate spec
- Keep the change small.
MD
expect_withheld() {  # <label> <stderr fragment> [<value that must not print>...]
  local label=$1 fragment=$2
  shift 2
  expect_code 0 "$code" "$label exits 0"
  assert_equals '' "$out" "$label prints nothing on stdout, so firstmate uses its existing intake"
  assert_contains "$err" "dispatch-resolve: off ($fragment" "$label names why on stderr"
  assert_contains "$err" 'nothing sent)' "$label says nothing was sent"
  assert_equals '1' "$(grep -c . <<<"$err")" "$label prints one diagnostic line"
  assert_absent "$LOG/argv" "$label never calls curl"
  assert_absent "$LOG/quota-axi.calls" "$label never reads quota"
  local value
  for value in "$@"; do
    assert_not_contains "$err" "$value" "$label never prints the listed value"
  done
}

printf '%s\n' '# private values' '' '   ' 'Unlisted-Value' > "$NEVER_SEND"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
assert_contains "$out" '  status: clear' "a list with no match leaves resolution unchanged"
assert_contains "$(jq -r .state.task.brief "$LOG/body")" 'Acme-Ledger' "a list with no match sends the task text"

printf '%s\n' '# private values' '' '  acme-ledger  ' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a case-insensitive literal match" "brief text matches $NEVER_SEND line 3" 'acme-ledger' 'Acme-Ledger'
printf 'OPENROUTER_API_KEY=%s\n' "$KEY" > "$HOME_DIR/.env"
reset_log
run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "an OpenRouter literal match" "brief text matches $NEVER_SEND line 3" 'acme-ledger' 'Acme-Ledger'
rm -f "$HOME_DIR/.env"

WRAPPED_BRIEF="$TMP_ROOT/wrapped-brief.md"
printf '# Task\n## Captain'"'"'s intent\nFix the pager for Example Client\nLtd before\tthe\xc2\xa0release.\n' > "$WRAPPED_BRIEF"
printf '%s\n' 'example  client ltd' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$WRAPPED_BRIEF" --project pager
expect_withheld "a literal the brief wraps across lines" "brief text matches $NEVER_SEND line 1" 'example' 'Example'

printf '%s\n' 'before the release' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$WRAPPED_BRIEF" --project pager
expect_withheld "a literal the brief spaces with a tab and a no-break space" "brief text matches $NEVER_SEND line 1" 'release'

printf '%s\n' 'orion-private' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project orion-private
expect_withheld "a project-name match" "brief text matches $NEVER_SEND line 1" 'orion-private'

printf '%s\n' 'stated root cause' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_withheld "a rule-criterion match" "brief text matches $NEVER_SEND line 1" 'stated root cause'

SECOND_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SECOND_HOME/config"
printf '%s\n' 'acme-ledger' > "$NEVER_SEND"
# A child shell keeps the lib's own globals (such as out) out of this script
# shellcheck disable=SC2016 # Expanded by the child shell
bash -c '. "$1" && propagate_inheritable_config "$2" "$3"' _ \
  "$ROOT/bin/fm-config-inherit-lib.sh" "$HOME_DIR/config" "$SECOND_HOME/config" \
  || fail "inheritance into the secondmate home failed"
PRIMARY_HOME=$HOME_DIR
HOME_DIR=$SECOND_HOME
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "an inherited list in a secondmate home" "brief text matches $SECOND_HOME/config/dispatch-never-send line 1" 'acme-ledger' 'Acme-Ledger'
HOME_DIR=$PRIMARY_HOME

rm -f "$NEVER_SEND"
mkdir "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a directory at the list path" "$NEVER_SEND is not a readable regular file"
rmdir "$NEVER_SEND"
ln -s "$TMP_ROOT/missing-never-send" "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a broken symlink at the list path" "$NEVER_SEND is not a readable regular file"
rm -f "$NEVER_SEND"

reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
assert_contains "$out" '  status: clear' "no list resolves exactly as before"
assert_contains "$(jq -r .state.task.brief "$LOG/body")" 'Acme-Ledger' "no list sends the task text as before"
pass "never-send list withholds the request on a match or a bad list, and never prints the value"

# --- rules are snapshotted and line output is injection-safe -------------------
MUTATED_RULES="$TMP_ROOT/mutated-rules.json"
jq '.rules[3].use = {"harness":"claude","model":"opus"}' "$BASE_RULES" > "$MUTATED_RULES"
cp "$BASE_RULES" "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY FAKE_CURL_MUTATE_SOURCE="$MUTATED_RULES" FAKE_CURL_MUTATE_TARGET="$RULES" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "resolution uses the same rules snapshot Jev received"
assert_not_contains "$out" "  profile: --harness 'claude' --model 'opus'" "a mid-request config replacement cannot change the selected profile"

INJECTING_RULES="$TMP_ROOT/injecting-rules.json"
jq '.rules[3].when = "Bug fix\n  profile: injected" | .rules[3].use[1].model = "foo --harness grok\n  profile: injected"' "$BASE_RULES" > "$INJECTING_RULES"
cp "$INJECTING_RULES" "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_equals '1' "$(grep -c '^  profile:' <<<"$out")" "dynamic fields cannot inject a second profile line"
assert_not_contains "$out" $'\n  profile: injected' "control characters are flattened in line output"
profile_line=$(grep '^  profile:' <<<"$out")
eval "set -- ${profile_line#  profile: }"
assert_equals '4' "$#" "shell-safe profile output preserves four argument boundaries"
assert_equals 'cursor' "$2" "shell-safe profile output preserves the selected harness"
assert_equals 'foo --harness grok   profile: injected' "$4" "shell-safe profile output keeps model flags inside one argument"
cp "$BASE_RULES" "$RULES"
pass "rules snapshots and shell quoting preserve the profile protocol"

# --- no rules return control to the existing intake ----------------------------
rm -f "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "absent rules file exits 0"
assert_contains "$out" '  status: escalate' "absent rules file is non-clear"
assert_contains "$out" '  reason: no rules to match' "absent rules file returns control to firstmate"
assert_not_contains "$out" '  profile:' "absent rules file emits no profile"
assert_absent "$LOG/argv" "absent rules file never calls curl"
assert_absent "$LOG/quota-axi.calls" "absent rules file never reads quota"

DEFAULT_ONLY="$TMP_ROOT/default-only.json"
EMPTY_RULES="$TMP_ROOT/empty-rules.json"
printf '%s\n' '{"default":[{"harness":"claude","model":"opus"},{"harness":"cursor","model":"cursor-grok-4.6-high"}]}' > "$DEFAULT_ONLY"
printf '%s\n' '{"rules":[],"default":[{"harness":"claude","model":"opus"},{"harness":"cursor","model":"cursor-grok-4.6-high"}]}' > "$EMPTY_RULES"
for direct_rules in "$DEFAULT_ONLY" "$EMPTY_RULES"; do
  cp "$direct_rules" "$RULES"
  reset_log
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 0 "$code" "no-rule resolution exits 0: $direct_rules"
  assert_contains "$out" '  status: escalate' "no-rule resolution is non-clear: $direct_rules"
  assert_contains "$out" '  reason: no rules to match' "no-rule resolution returns control to firstmate: $direct_rules"
  assert_not_contains "$out" '  profile:' "no-rule resolution emits no profile: $direct_rules"
  assert_absent "$LOG/argv" "no-rule resolution never calls curl: $direct_rules"
  assert_absent "$LOG/quota-axi.calls" "no-rule resolution never reads quota: $direct_rules"
done

AGY_RULE="$TMP_ROOT/agy-rule.json"
printf '%s\n' '{"rules":[{"when":"Agy work.","use":{"harness":"agy"}}]}' > "$AGY_RULE"
cp "$AGY_RULE" "$RULES"
cat > "$RESPONSE" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"rule_1","confidence":0.99,"probabilities":{"rule_1":0.99,"default":0.01}}},"usage":{"input_tokens":100,"output_tokens":60}}
JSON
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: agy:-  provider=agy' "agy uses its resolver-only authoritative quota provider"
assert_contains "$out" 'status: escalate' "implicit Agy model has no catalog-backed family relation"
assert_contains "$out" 'catalog-backed family quota is unmeasured' "unknown Agy family is disclosed"
assert_not_contains "$out" '  profile:' "implicit Agy model remains unranked"

GEMINI_RULE="$TMP_ROOT/gemini-rule.json"
printf '%s\n' '{"rules":[{"when":"Gemini work.","use":{"harness":"gemini","model":"gemini-3.8-flash-high","provider":"google"}}]}' > "$GEMINI_RULE"
cp "$GEMINI_RULE" "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: gemini:gemini-3.8-flash-high  provider=google  scope=all_models  remaining=72%  spendPriority=0.3  runway=through_reset  -> eligible' "Gemini resolves through its explicit provider"
assert_contains "$out" "  profile: --harness 'gemini' --model 'gemini-3.8-flash-high'" "Gemini is a typed verified dispatch harness"

cp "$ROOT/docs/examples/crew-dispatch.json" "$RULES"
cat > "$RESPONSE" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"default","confidence":0.9,"probabilities":{"rule_1":0.02,"rule_2":0.02,"rule_3":0.02,"default":0.94}}},"usage":{"input_tokens":812,"output_tokens":60}}
JSON
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "the documented example passes opted-in resolution"
assert_contains "$out" 'candidate: pi:anthropic/claude-sonnet-5  provider=claude' "the documented Pi default uses its declared Claude provider"
assert_not_contains "$err" 'malformed rules file' "the documented example reaches resolution"
cp "$BASE_RULES" "$RULES"
pass "no-rule fallback, Agy, Gemini, and documented configurations resolve"

# --- ambiguous: fixed confidence floor -----------------------------------------
reset_log
write_response "$RESPONSE" rule_4 0.41
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "ambiguous exits 0"
assert_contains "$out" '  status: ambiguous' "below the floor is ambiguous"
assert_contains "$out" '  reason: confidence 0.41 below floor 0.6' "ambiguous names the floor"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=79%  spendPriority=-0.4627  runway=projected_exhaustion  -> eligible' "ambiguous preserves matched candidate evidence"
assert_contains "$out" 'candidate: kimi:kimi-code/k3  provider=kimi  -> eligible, unranked: provider kimi unmeasured (unknown): disclosed uncertainty' "ambiguous preserves eligible unranked candidate evidence"
assert_not_contains "$out" '  profile:' "ambiguous emits no profile line"
pass "ambiguous: confidence below the fixed floor hands the decision back"

# --- per-rule confidence floor ------------------------------------------------
write_floor_response() {  # <path> <choice> <confidence> <rule_1> <rule_2> <rule_3> <rule_4> <default>
  cat > "$1" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "$2", "confidence": $3,
    "probabilities": { "rule_1": $4, "rule_2": $5, "rule_3": $6, "rule_4": $7, "default": $8 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
}
FLOOR_RULES="$TMP_ROOT/floor-rules.json"
jq '.rules[1].min_confidence = 0.9 | .rules[3].min_confidence = 0.1' "$BASE_RULES" > "$FLOOR_RULES"
cp "$FLOOR_RULES" "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_2 0.76 0.02 0.76 0.02 0.18 0.02
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a top rule below its own floor falls to a runner-up that clears its floor"
assert_contains "$out" '  rule: rule_2 (The task generates images.)   confidence: 0.76' "the model's own pick stays visible"
assert_contains "$out" '  fallback: rule_4 (A simple bug fix with a stated root cause.) probability 0.18 clears its floor 0.1; rule_2 probability 0.76 is below its floor 0.9' "the fallback names both floors"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the runner-up rule's profiles are resolved"
assert_not_contains "$(cat "$LOG/body")" 'min_confidence' "the model never sees confidence floors"

reset_log
write_floor_response "$RESPONSE" rule_2 0.76 0.02 0.76 0.02 0.08 0.12
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "no runner-up clearing its own floor is ambiguous"
assert_contains "$out" '  reason: rule_2 probability 0.76 below its floor 0.9; no other option clears its own floor' "the undeclared default keeps the global floor as a runner-up"
assert_not_contains "$out" '  fallback:' "no fallback is reported when none is taken"
assert_not_contains "$out" '  profile:' "ambiguous per-rule floor emits no profile"

jq '.rules[0].min_confidence = 0.1' "$FLOOR_RULES" > "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_2 0.76 0.12 0.76 0.0 0.12 0.0
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "equally probable runner-ups never break by option order"
assert_contains "$out" '  reason: rule_2 probability 0.76 below its floor 0.9; runner-up tie' "a runner-up tie is named"

cp "$FLOOR_RULES" "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_4 0.45 0.01 0.01 0.01 0.45 0.52
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "a declared floor below the global floor lets the picked rule resolve"

# A declared floor needs the same support from a rule as the pick or as a runner-up
jq '.rules[3].min_confidence = 0.3' "$FLOOR_RULES" > "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_4 0.25 0.25 0.05 0.05 0.35 0.30
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a picked rule clears its declared floor on its own probability, not the answer confidence"
assert_not_contains "$out" '  fallback:' "a picked rule that clears its own floor takes no fallback"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the picked rule resolves at probability 0.35 over floor 0.3"

reset_log
write_floor_response "$RESPONSE" rule_2 0.95 0.05 0.55 0.05 0.30 0.05
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a high answer confidence does not lift a picked rule over its own floor"
assert_contains "$out" '  fallback: rule_4 (A simple bug fix with a stated root cause.) probability 0.30 clears its floor 0.3; rule_2 probability 0.55 is below its floor 0.9' "the runner-up clears the same floor it would need as the pick"

reset_log
write_floor_response "$RESPONSE" rule_2 0.55 0.05 0.55 0.05 0.25 0.10
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "a runner-up below its own floor is not taken"
assert_contains "$out" '  reason: rule_2 probability 0.55 below its floor 0.9; no other option clears its own floor' "the missed runner-up floor is named"
cp "$BASE_RULES" "$RULES"

reset_log
write_floor_response "$RESPONSE" rule_2 0.55 0.01 0.55 0.01 0.42 0.01
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "without declared floors a low pick stays ambiguous"
assert_contains "$out" '  reason: confidence 0.55 below floor 0.6' "without declared floors the global floor reason is unchanged"
assert_not_contains "$out" '  fallback:' "without declared floors no runner-up is taken"
pass "per-rule confidence floors fall to the most probable runner-up that clears its own floor"

# --- the model sees only the task-specific brief sections ----------------------
SCAFFOLD_BRIEF="$TMP_ROOT/scaffold-brief.md"
cat > "$SCAFFOLD_BRIEF" <<'MD'
# Task
## Captain's intent
Add a flag to the pager.

## Firstmate spec
Touch pager.sh only.
```sh
# Not a heading inside a fence
## Setup
```
### Out of scope
Anything else.

# Setup
BOILERPLATE-SETUP never push to the default branch.

## Captain intent authorized for --intent
BOILERPLATE-DUPLICATE
MD
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$SCAFFOLD_BRIEF"
sent=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent" $'## Captain\'s intent\nAdd a flag to the pager.' "the captain's intent section is sent"
assert_contains "$sent" $'## Firstmate spec\nTouch pager.sh only.' "the Firstmate spec section is sent"
assert_contains "$sent" $'# Not a heading inside a fence\n## Setup\n```\n### Out of scope\nAnything else.' "fenced lines and subheadings stay inside the section"
assert_not_contains "$sent" 'BOILERPLATE' "scaffold boilerplate after the task sections is not sent"
assert_not_contains "$sent" '# Task' "the enclosing Task heading is not sent"
assert_not_contains "$sent" 'Brief kind:' "a brief without a scout contract line gets no kind line"

SPEC_ONLY_BRIEF="$TMP_ROOT/spec-only-brief.md"
printf '%s\n' '# Task' '## Firstmate spec' 'Spec text.' '## Rules' 'RULES-TEXT' > "$SPEC_ONLY_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$SPEC_ONLY_BRIEF"
assert_equals $'## Firstmate spec\nSpec text.' "$(jq -r .state.task.brief "$LOG/body")" "one recognized section is enough"

printf '%s\n' '# Task' '## Firstmate spec   ' 'Spec text.' '## Rules' 'RULES-TEXT' > "$SPEC_ONLY_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$SPEC_ONLY_BRIEF"
assert_equals "$(cat "$SPEC_ONLY_BRIEF")" "$(jq -r .state.task.brief "$LOG/body")" "a heading with trailing blanks is not a section, matching spawn validation"

printf '%s\n' 'Preamble.' '## Firstmate spec' 'Spec text.' > "$SPEC_ONLY_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$SPEC_ONLY_BRIEF"
assert_equals "$(cat "$SPEC_ONLY_BRIEF")" "$(jq -r .state.task.brief "$LOG/body")" "a section outside the Task heading is not a task section"

KIND_BRIEF="$TMP_ROOT/kind-brief.md"
{ cat "$SCAFFOLD_BRIEF"; printf '%s\n' '# Definition of done' 'Delivery contract: mode=no-mistakes' 'Delivery contract: mode=direct-PR'; } > "$KIND_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$KIND_BRIEF"
sent=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent" $'## Captain\'s intent\nAdd a flag to the pager.' "a ship brief still sends its task sections"
assert_not_contains "$sent" 'Brief kind:' "a ship brief gets no kind line"
assert_not_contains "$sent" 'mode=' "a ship brief's delivery mode is not sent"

{ cat "$SCAFFOLD_BRIEF"; printf '%s\n' 'This is a SCOUT task: the deliverable is a written report, not a PR.'; } > "$KIND_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$KIND_BRIEF"
sent=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent" $'Brief kind: scout (report only)\n\n## Captain\'s intent' "a scout brief's contract line names its kind"
assert_not_contains "$sent" 'This is a SCOUT task' "the scout contract line itself is not sent"

reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_equals "$(cat "$BRIEF")" "$(jq -r .state.task.brief "$LOG/body")" "a brief with neither heading is sent whole"
pass "only the brief's task sections and scout tag reach the model, with a whole-brief fallback"

# --- escalate: captain approval ------------------------------------------------
reset_log
write_response "$RESPONSE" rule_3 0.95
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "escalate exits 0"
assert_contains "$out" '  status: escalate' "approval-gated rule escalates"
assert_contains "$out" "  reason: rule requires the captain's explicit approval before dispatch" "escalate names the approval gate"
assert_contains "$out" 'candidate: claude:fable  provider=claude  scope=model:fable  remaining=15%  spendPriority=-0.79  runway=projected_exhaustion  bounds=all_models:79%/projected_exhaustion,model:fable:15%/projected_exhaustion  -> eligible' "approval escalation preserves matched candidate evidence"
assert_not_contains "$out" '  profile:' "escalate emits no profile line"
pass "escalate: a rule declared approval: captain never yields a profile"

# --- rule floor fails: fall through to default -------------------------------
reset_log
write_response "$RESPONSE" rule_1 0.97
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "rule floor fall-through still resolves"
assert_contains "$out" '  note: rule rule_1 floor model:fable below 20%: fall through to default' "rule floor fall-through is explained"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "fall-through resolves among the default profiles"
assert_not_contains "$out" 'candidate: claude:fable' "the floored rule's own profile is not a candidate"

MISSING_RULE_FLOOR="$TMP_ROOT/missing-rule-floor.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability) |= map(select(.scope != "model:fable"))' "$QUOTA" > "$MISSING_RULE_FLOOR"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$MISSING_RULE_FLOOR" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "an unverifiable rule floor escalates"
assert_contains "$out" '  reason: rule rule_1 floor claude/model:fable is unverifiable' "the unverifiable rule floor names its provider and scope"
assert_not_contains "$out" '  profile:' "an unverifiable rule floor never authorizes default routing"
pass "rule floor: known shortfall falls through while unavailable evidence escalates"

# --- declared provider and profile floor --------------------------------------
reset_log
write_response "$RESPONSE" rule_2 0.99
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: pi:openai-codex/gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%' "declared provider routes a Pi profile to the codex row"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion  -> not eligible: profile floor all_models below 50%' "profile floor makes a candidate ineligible with its reason"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" "the remaining eligible candidate wins"

FLOOR_BOUNDS="$TMP_ROOT/floor-bounds.json"
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability) += [
  {"scope":"model:gpt-5.6-sol","status":"known","effectivePercentRemaining":10,"runway":{"status":"projected_exhaustion","usableRunwaySeconds":7200},"selection":{"status":"known","spendPriority":-0.9}}
]' "$QUOTA" > "$FLOOR_BOUNDS"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$FLOOR_BOUNDS" run code out err "$BRIEF"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion  bounds=all_models:31%/projected_exhaustion,model:gpt-5.6-sol:10%/projected_exhaustion  -> not eligible: profile floor all_models below 50%' "a failed profile floor reports its named row while retaining all bounds"

FLOOR_WITH_UNKNOWN="$TMP_ROOT/floor-with-unknown.json"
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:gpt-5.6-sol","status":"unknown","runway":{"status":"unknown"}}
])' "$QUOTA" > "$FLOOR_WITH_UNKNOWN"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$FLOOR_WITH_UNKNOWN" run code out err "$BRIEF"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion  bounds=all_models:31%/projected_exhaustion,model:gpt-5.6-sol:-%/unknown  -> not eligible: profile floor all_models below 50%' "a known profile-floor shortfall wins over unrelated unknown model evidence"

MISSING_PROFILE_FLOOR_RULES="$TMP_ROOT/missing-profile-floor-rules.json"
jq '.rules[1].use[1].floor.scope = "model:missing"' "$BASE_RULES" > "$MISSING_PROFILE_FLOOR_RULES"
cp "$MISSING_PROFILE_FLOOR_RULES" "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=model:missing  remaining=-%  spendPriority=-  runway=-  -> eligible, unranked: profile floor model:missing is unverifiable: not rankable: disclosed uncertainty' "a missing profile floor remains eligible but unranked"
assert_not_contains "$out" 'profile floor model:missing below' "missing profile evidence is not described as a shortfall"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" "another candidate may clear without misrepresenting missing floor evidence"
cp "$BASE_RULES" "$RULES"
pass "declared provider and profile floor evidence are applied in code"

# --- malformed ranking evidence is never ordered -------------------------------
reset_log
NONNUMERIC="$TMP_ROOT/nonnumeric-spend-priority.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models") | .selection.spendPriority) = "high"' "$QUOTA" > "$NONNUMERIC"
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NONNUMERIC" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=91%  spendPriority=-  runway=through_reset  -> eligible, unranked: spendPriority missing, non-numeric, or selection not known at all_models: not rankable: disclosed uncertainty' "a nonnumeric spendPriority remains eligible but unranked"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "numeric evidence wins without mixed-type ordering"
pass "nonnumeric spendPriority evidence is never ranked"

# --- partial providers retain their known row evidence --------------------------
reset_log
PARTIAL="$TMP_ROOT/partial.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.status) = "partial"' "$QUOTA" > "$PARTIAL"
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$PARTIAL" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=91%  spendPriority=0.7597  runway=through_reset  -> eligible' "a known row from a partial provider remains rankable"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "partial provider evidence can win the argmax"

PARTIAL_UNKNOWN="$TMP_ROOT/partial-unknown.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:cursor-grok-4.6-medium","status":"unknown","runway":{"status":"unknown"}}
])' "$QUOTA" > "$PARTIAL_UNKNOWN"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$PARTIAL_UNKNOWN" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=model:cursor-grok-4.6-medium  remaining=-%  spendPriority=-  runway=-  bounds=all_models:91%/through_reset,model:cursor-grok-4.6-medium:-%/unknown  -> eligible, unranked: quota row model:cursor-grok-4.6-medium unknown: not rankable: disclosed uncertainty' "an unknown exact-model row preserves partial known evidence without ranking"
assert_contains "$out" '  note: 2 eligible candidate(s) unranked (cursor, kimi)' "clear result lists every provider with unranked uncertainty"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "another measured candidate can clear"

PARTIAL_EXHAUSTED="$TMP_ROOT/partial-exhausted.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:cursor-grok-4.6-medium","status":"unknown","runway":{"status":"unknown"}}
] | .effectiveAvailability[] |= if .scope == "all_models" then .effectivePercentRemaining = 0 | .runway.status = "exhausted_now" else . end)' "$QUOTA" > "$PARTIAL_EXHAUSTED"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$PARTIAL_EXHAUSTED" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=0%  spendPriority=-  runway=exhausted_now  bounds=all_models:0%/exhausted_now,model:cursor-grok-4.6-medium:-%/unknown  -> not eligible: runway exhausted_now at all_models' "known exhaustion vetoes a candidate despite unknown exact-model evidence"
assert_contains "$out" '  note: 1 eligible candidate(s) unranked (kimi)' "an exhausted candidate is excluded from the unranked uncertainty note"

UNKNOWN_EXHAUSTED="$TMP_ROOT/unknown-exhausted.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) = {
  "status":"unknown","effectiveAvailability":[
    {"scope":"all_models","status":"unknown","runway":{"status":"exhausted_now"}}
  ]
}' "$QUOTA" > "$UNKNOWN_EXHAUSTED"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$UNKNOWN_EXHAUSTED" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=-%  spendPriority=-  runway=exhausted_now  -> not eligible: runway exhausted_now at all_models' "unknown provider semantics cannot mask concrete exhaustion"

NO_APPLICABLE="$TMP_ROOT/no-applicable.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.effectiveAvailability) = [
  {"scope":"model:other","status":"known","effectivePercentRemaining":91,"runway":{"status":"through_reset"},"selection":{"status":"known","spendPriority":0.8}}
]' "$QUOTA" > "$NO_APPLICABLE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NO_APPLICABLE" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  -> eligible, unranked: no applicable quota row for provider cursor: disclosed uncertainty' "a candidate without an applicable row remains eligible but unranked"
assert_contains "$out" '  note: 2 eligible candidate(s) unranked (cursor, kimi)' "no-applicable-row uncertainty appears in the clear-result note"
pass "partial and missing quota evidence remain eligible but unranked"

# --- provider-wide rows remain bounds beside exact model rows ------------------
reset_log
BOUNDED="$TMP_ROOT/bounded.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability) += [
  {"scope":"model:sonnet","status":"known","effectivePercentRemaining":99,"runway":{"status":"through_reset"},"selection":{"status":"known","spendPriority":0.9}}
]' "$QUOTA" > "$BOUNDED"
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$BOUNDED" run code out err "$BRIEF"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=79%  spendPriority=-0.4627' "the limiting provider-wide row drives ranking"
assert_contains "$out" 'bounds=all_models:79%/projected_exhaustion,model:sonnet:99%/through_reset' "all applicable quota bounds are disclosed"

EXHAUSTED_WIDE="$TMP_ROOT/exhausted-wide.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models")) |= (.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")' "$BOUNDED" > "$EXHAUSTED_WIDE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$EXHAUSTED_WIDE" run code out err "$BRIEF"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=0%' "the exhausted account-wide bound is the candidate evidence"
assert_contains "$out" '-> not eligible: runway exhausted_now at all_models' "a healthy exact row cannot bypass an exhausted account-wide bound"
pass "provider-wide and exact quota rows combine into one limiting candidate"

# --- default choice ------------------------------------------------------------
reset_log
write_response "$RESPONSE" default 0.88
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  rule: default (No listed rule applies to this task.)' "default names the fixed neutral none option"
assert_contains "$out" '  note: no rule matched' "default is explained"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "default resolves by argmax"
pass "default: no rule matched resolves among the default profiles"

# --- genuine tie escalates ---------------------------------------------------------
reset_log
TIE="$TMP_ROOT/tie.json"
write_quota "$TIE" 0.5 0.5
write_response "$RESPONSE" default 0.88
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TIE" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "tie escalates"
assert_contains "$out" '  reason: genuine spendPriority tie' "tie is named"
pass "tie: equal spendPriority never breaks by array order"

# --- nothing rankable escalates -------------------------------------------------
reset_log
NONE="$TMP_ROOT/none.json"
jq '.providers |= map(if .provider == "cursor" or .provider == "claude" then .quotaSemantics.effectiveAvailability |= map(.runway.status = "exhausted_now") else . end)' "$QUOTA" > "$NONE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NONE" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "no rankable candidate escalates"
assert_contains "$out" '  reason: no rankable eligible candidate' "no-candidate reason"
assert_contains "$out" '-> not eligible: runway exhausted_now' "exhausted candidates keep their reason"
pass "no rankable candidate: the tool escalates instead of guessing"

# --- schema 6: rows keyed by provider + accountKey bind per account ----------------
# quota-axi emits schema 6 once a provider expands to several accounts; every
# row then carries accountKey and one provider id may appear on several rows.
# Native Codex and Pi lanes bind to their own account rows, with no row
# chosen by position or summed across accounts.
LANE_RULES="$TMP_ROOT/lane-rules.json"
SCHEMA6="$TMP_ROOT/schema6.json"
SCHEMA5_PAIR="$TMP_ROOT/schema5-pair.json"
cat > "$LANE_RULES" <<'JSON'
{
  "rules": [
    {
      "when": "Codex work.",
      "use": [
        { "harness": "pi", "model": "openai-codex-work/gpt-5.6-terra", "provider": "codex" },
        { "harness": "pi", "model": "openai-codex/gpt-5.6-sol", "provider": "codex" },
        { "harness": "codex", "model": "gpt-5.6-sol" }
      ]
    }
  ]
}
JSON
cat > "$SCHEMA6" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 6,
  "providers": [
    { "provider": "claude", "accountKey": "default", "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } },
    { "provider": "codex", "accountKey": "openai-codex", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 0, "runway": { "status": "exhausted_now" }, "selection": { "status": "known", "spendPriority": -1.4788 } } ] } },
    { "provider": "codex", "accountKey": "openai-codex-work", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 11, "runway": { "status": "projected_exhaustion", "usableRunwaySeconds": 7200 }, "selection": { "status": "known", "spendPriority": -5.6819 } } ] } },
    { "provider": "cursor", "accountKey": "default", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 24, "runway": { "status": "projected_exhaustion", "usableRunwaySeconds": 7200 }, "selection": { "status": "known", "spendPriority": 0.3917 } } ] } }
  ]
}
JSON
cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "rule_1", "confidence": 0.9,
    "probabilities": { "rule_1": 0.97, "default": 0.03 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
cp "$LANE_RULES" "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6" run code out err "$BRIEF"
expect_code 0 "$code" "schema 6 snapshot exits 0"
assert_contains "$out" '  status: clear' "schema 6 snapshot resolves"
assert_contains "$out" 'candidate: pi:openai-codex-work/gpt-5.6-terra  provider=codex  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion  -> eligible' "a Pi lane binds to its own account row"
assert_contains "$out" 'candidate: pi:openai-codex/gpt-5.6-sol  provider=codex  scope=all_models  remaining=0%  spendPriority=-  runway=exhausted_now  -> not eligible: runway exhausted_now at all_models' "the sibling lane reads its own exhausted row"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  -> eligible, unranked: provider codex has no quota row for account codex-home: disclosed uncertainty' "native Codex never infers an account from a Pi lane"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex-work/gpt-5.6-terra'" "the lane with headroom is chosen"
assert_equals '--json' "$(cat "$LOG/quota-axi.calls")" "schema 6 needs one quota-axi --json read"

jq '(.providers[].quotaSemantics.effectiveAvailability[].selection.spendPressure) = 100 |
    (.providers[] | select(.accountKey == "openai-codex-work") | .quotaSemantics.effectiveAvailability[].selection.spendPressure) = 0' "$SCHEMA6" > "$TMP_ROOT/schema6-pressure.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-pressure.json" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex-work/gpt-5.6-terra'" "pressure preserves account binding and exhaustion vetoes"
assert_contains "$out" 'remaining=11%  spendPressure=0  runway=projected_exhaustion  -> eligible' "zero pressure is known, not missing"
assert_contains "$out" 'no quota row for account codex-home' "pressure cannot substitute a sibling account"

SCHEMA6_NATIVE="$TMP_ROOT/schema6-native.json"
jq '
  .providers |= map(if .provider == "codex" then
    .quotaSemantics.effectiveAvailability |= map(.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")
    else . end) |
  (.providers[] | select(.accountKey == "openai-codex-work")) as $account |
  .providers += [($account | .accountKey = "default"),
    ($account | .accountKey = "codex-home" |
      .quotaSemantics.effectiveAvailability |= map(
        .effectivePercentRemaining = 80 | .runway.status = "through_reset" | .selection.spendPriority = 0.8))]
' "$SCHEMA6" > "$SCHEMA6_NATIVE"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6_NATIVE" run code out err "$BRIEF"
expect_code 0 "$code" "native Codex schema 6 snapshot exits 0"
assert_contains "$out" '  status: clear' "native Codex headroom resolves despite exhausted Pi and default rows"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=80%  spendPriority=0.8  runway=through_reset  -> eligible' "native Codex reads codex-home"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "native Codex headroom is chosen"

jq '.providers |= reverse' "$SCHEMA6_NATIVE" > "$TMP_ROOT/schema6-reversed.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-reversed.json" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "native Codex selection ignores row order"

jq '.providers |= map(select(.provider != "codex" or .accountKey != "default") |
  if .accountKey == "codex-home" then .accountKey = "default" else . end)' "$SCHEMA6_NATIVE" > "$TMP_ROOT/schema6-default.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-default.json" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "native Codex falls back to the default row when codex-home is absent"
pass "native Codex binds to codex-home before default, independently of Pi accounts and row order"

jq '.schemaVersion = 5 | .providers |= map(select(.accountKey != "openai-codex")) | del(.providers[].accountKey)' "$SCHEMA6" > "$SCHEMA5_PAIR"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA5_PAIR" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "schema 5 keeps joining by provider alone"
assert_contains "$out" '  reason: genuine spendPriority tie' "every codex profile reads the one schema 5 codex row"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion  -> eligible' "a schema 5 row never needs accountKey"

SCHEMA6_PI_NATIVE="$TMP_ROOT/schema6-pi-native.json"
jq '.providers |= map(select(.provider != "codex" or .accountKey != "default"))' "$SCHEMA6_NATIVE" > "$SCHEMA6_PI_NATIVE"
for harness in pi pi-signed; do
  jq --arg harness "$harness" '.rules[0].use |= map(if .harness == "codex" then
    {harness: $harness, model: "codex-native/gpt-6-astra", provider: "codex", effort: "ultra"}
    else . end)' "$LANE_RULES" > "$RULES"
  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6_PI_NATIVE" run code out err "$BRIEF"
  expect_code 0 "$code" "$harness native adapter schema 6 exits 0"
  assert_contains "$out" '  status: clear' "$harness native adapter resolves with codex-home and no default row"
  assert_contains "$out" "candidate: $harness:codex-native/gpt-6-astra  provider=codex  scope=all_models  remaining=80%  spendPriority=0.8  runway=through_reset  -> eligible" "$harness native adapter reads codex-home"
  assert_contains "$out" "  profile: --harness '$harness' --model 'codex-native/gpt-6-astra' --effort 'ultra'" "$harness native adapter is chosen over exhausted Pi accounts"

  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-default.json" run code out err "$BRIEF"
  assert_contains "$out" "  profile: --harness '$harness' --model 'codex-native/gpt-6-astra' --effort 'ultra'" "$harness native adapter falls back to default"

  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6" run code out err "$BRIEF"
  assert_contains "$out" "candidate: $harness:codex-native/gpt-6-astra  provider=codex  -> eligible, unranked: provider codex has no quota row for account codex-home: disclosed uncertainty" "$harness native adapter never borrows a Pi account"

  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA5_PAIR" run code out err "$BRIEF"
  assert_contains "$out" "candidate: $harness:codex-native/gpt-6-astra  provider=codex  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion  -> eligible" "$harness native adapter still joins schema 5 by provider alone"
done
cp "$LANE_RULES" "$RULES"
pass "Pi native adapters bind to codex-home with existing fallbacks and schema 5 compatibility"

jq 'del(.providers[1].accountKey)' "$SCHEMA6" > "$TMP_ROOT/schema6-keyless.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-keyless.json" run code out err "$BRIEF"
assert_contains "$out" '  status: error' "a schema 6 row without accountKey is an error outcome"
assert_contains "$out" '  reason: quota-axi --json returned an invalid snapshot' "keyless schema 6 row is named as an invalid snapshot"
cp "$BASE_RULES" "$RULES"
pass "schema 6: each candidate binds to its account row; schema 5 is unchanged"

# --- quota-axi is read exactly once --------------------------------------------
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "quota-axi path exits 0"
assert_equals '--json' "$(cat "$LOG/quota-axi.calls")" "quota-axi --json is called exactly once"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "quota-axi snapshot drives the argmax"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_QUOTA_FAIL=1 run code out err "$BRIEF"
expect_code 0 "$code" "quota-axi failure exits 0"
assert_contains "$out" '  status: error' "quota-axi failure is an error outcome"
assert_contains "$out" '  reason: quota-axi --json failed' "quota-axi failure is named"
pass "quota evidence comes from one quota-axi --json read, and its failure is an error outcome"

# --- API and response failures are error outcomes, exit 0 ----------------------
reset_log
run_without_curl code out err "$BRIEF"
expect_code 0 "$code" "missing curl exits 0"
assert_contains "$out" '  status: error' "missing curl is a structured error outcome"
assert_contains "$out" '  reason: curl not installed' "missing curl is named in the TOON block"
assert_contains "$err" 'dispatch-resolve: error (curl not installed)' "missing curl is also reported on stderr"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_HTTP=429 run code out err "$BRIEF"
expect_code 0 "$code" "http 429 exits 0"
assert_contains "$out" '  status: error' "http 429 is an error outcome"
assert_contains "$out" '  reason: http 429 after' "http status is reported"
assert_contains "$err" 'dispatch-resolve: error (http 429' "error also goes to stderr"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_FAIL=1 run code out err "$BRIEF"
expect_code 0 "$code" "curl failure exits 0"
assert_contains "$out" '  reason: http 000 after' "transport failure reads as http 000"
reset_log
printf '%s\n' '{"model":"jev","answers":{}}' > "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  reason: response is not a rule Choice answer' "a malformed answer is an error outcome"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.usage = "bad"' "$RESPONSE" > "$TMP_ROOT/malformed-usage.json"
mv "$TMP_ROOT/malformed-usage.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "malformed usage is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "malformed usage cannot break text rendering silently"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq 'del(.answers.rule.probabilities.default)' "$RESPONSE" > "$TMP_ROOT/malformed-probabilities.json"
mv "$TMP_ROOT/malformed-probabilities.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "missing probability choice is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "probabilities must name every offered choice"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.answers.rule.probabilities.rule_4 = "high"' "$RESPONSE" > "$TMP_ROOT/malformed-probabilities.json"
mv "$TMP_ROOT/malformed-probabilities.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "nonnumeric probability is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "probabilities must be numeric and bounded"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.answers.rule.probabilities[] = 0' "$RESPONSE" > "$TMP_ROOT/malformed-probabilities.json"
mv "$TMP_ROOT/malformed-probabilities.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "a zero-mass probability distribution is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "probabilities must sum to approximately one"
reset_log
write_response "$RESPONSE" rule_4 2
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "out-of-range confidence is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "out-of-range confidence is a malformed answer"
reset_log
write_response "$RESPONSE" rule_9 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "an unknown rule id is an error outcome"
assert_contains "$out" '  reason: rule rule_9 is not in the rules file' "unknown rule id is named"
write_response "$RESPONSE" rule_0 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "rule zero is an error outcome"
assert_contains "$out" '  reason: rule rule_0 is not in the rules file' "rule zero cannot alias the final rule"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_HTTP=500 run code out err "$BRIEF"
assert_contains "$out" '  status: error' "http 500 is a TOON error outcome"
pass "API, transport, and response failures are error outcomes with exit 0"

# --- configuration errors exit 2 and select nothing ----------------------------------
reset_log
TYPESAFE_API_KEY=$KEY run code out err
expect_code 2 "$code" "missing brief exits 2"
assert_contains "$err" 'brief file required' "missing brief is named"
rm -f "$RULES"
ln -s "$TMP_ROOT/missing-rules-target.json" "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "broken canonical rules symlink exits 2"
assert_contains "$err" "rules file not readable: $RULES" "broken rules symlink is actionable"
rm -f "$RULES"
printf '%s\n' '{"rules":[' > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "non-JSON rules exits 2"
assert_contains "$err" 'not JSON' "non-JSON rules is named"
for bad in \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"approval":"firstmate"}]}|approval must be "captain" when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"select":"mystery"}]}|unknown select: mystery' \
  '{"shared_quota":"yes","rules":[{"when":"x","use":{"harness":"claude"}}]}|shared_quota must be true or false when present' \
  '{"shared_quota":1,"rules":[{"when":"x","use":{"harness":"claude"}}]}|shared_quota must be true or false when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"min_confidence":"high"}]}|min_confidence must be a number from 0 through 1 when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"min_confidence":1.5}]}|min_confidence must be a number from 0 through 1 when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"floor":{"scope":"model:fable","min_percent":20}}]}|rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\z' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"floor":{"scope":"model:fable","min_percent":20,"provider":"CLAUDE"}}]}|rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\z' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":""}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":" claude"}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":"claude\n"}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"codex","floor":{"scope":"all_models","min_percent":20,"provider":"claude"}}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":[{"harness":"codex","model":"gpt-5.5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]}]}|each rule use must not contain duplicate harness, model, and effort profiles' \
  '{"rules":[{"when":"x","use":{"harness":"codex"}}],"default":[{"harness":"claude","model":"opus"},{"harness":"claude","model":"opus"}]}|default must not contain duplicate harness, model, and effort profiles' \
  '{"rules":[{"when":"x","use":{"harness":"spaceship"}}]}|each use profile must name a verified harness' \
  '{"rules":[{"when":"x","use":{"harness":"grok","effort":"max"}}]}|each use profile effort must be supported by its harness and model' \
  '{"rules":[{"when":"x","use":{"harness":"devin","provider":"devin","effort":"high"}}]}|each use profile effort must be supported by its harness and model' \
  '{"rules":[{"when":"x","use":{"harness":"gemini","provider":"google","effort":"high"}}]}|each use profile effort must be supported by its harness and model' \
  '{"rules":[{"when":"x","use":{"harness":"opencode","model":"anthropic/claude-sonnet-4-5"}}]}|use profiles whose harness lacks one authoritative provider family require provider: opencode' \
  '{"rules":[{"when":"x","use":{"harness":"rovo"}}]}|use profiles whose harness lacks one authoritative provider family require provider: rovo' \
  '{"rules":[{"when":"x","use":{"harness":"codex"}}],"default":{"harness":"pi","model":"anthropic/claude-sonnet-5"}}|default profiles whose harness lacks one authoritative provider family require provider: pi'; do
  printf '%s\n' "${bad%%|*}" > "$RULES"
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 2 "$code" "malformed rules exit 2: ${bad#*|}"
  assert_contains "$err" "malformed rules file: $RULES - ${bad#*|}" "malformed rules are named: ${bad#*|}"
done
printf '%s\n' '{"rules":[{"when":"x","use":[{"harness":"opencode"},{"harness":"rovo"},{"harness":"codex"}]}],"default":[{"harness":"pi"},{"harness":"claude"}]}' > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "multiple provider-less profiles exit 2"
assert_contains "$err" "malformed rules file: $RULES - use profiles whose harness lacks one authoritative provider family require provider: opencode; use profiles whose harness lacks one authoritative provider family require provider: rovo; default profiles whose harness lacks one authoritative provider family require provider: pi" "all provider-less profiles are reported together across use and default"
[ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" -eq 1 ] || fail "provider errors must use one diagnostic"
assert_absent "$LOG/argv" "configuration errors never reach the network"
# agy accepts the same effort levels here as bootstrap's schema check does.
for effort in xhigh max; do
  printf '{"rules":[{"when":"x","use":{"harness":"agy","effort":"%s"}}]}\n' "$effort" > "$RULES"
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  assert_not_contains "$err" 'malformed rules file' "agy effort $effort is well formed"
done
# Codex max follows the installed catalog, exactly as bootstrap's schema check does.
mkdir -p "$TMP_ROOT/codex-catalog"
printf '%s\n' '{"models":[{"slug":"gpt-6-luna","supported_reasoning_levels":[{"effort":"max"}]},{"slug":"gpt-5","supported_reasoning_levels":[{"effort":"high"}]}]}' > "$TMP_ROOT/codex-catalog/models_cache.json"
for case in advertised:gpt-6-luna:ok not-advertised:gpt-5:bad missing-catalog:gpt-6-luna:bad missing-catalog-luna:gpt-5.6-luna:ok; do
  IFS=: read -r label model verdict <<< "$case"
  codex_home=$TMP_ROOT/codex-catalog
  case "$label" in missing-catalog*) codex_home=$TMP_ROOT/codex-catalog-absent ;; esac
  printf '{"rules":[{"when":"x","use":{"harness":"codex","model":"%s","effort":"max"}}]}\n' "$model" > "$RULES"
  CODEX_HOME=$codex_home TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  if [ "$verdict" = ok ]; then
    expect_code 0 "$code" "codex max $label resolves without a configuration error"
    assert_not_contains "$err" 'malformed rules file' "codex max $label is well formed"
  else
    assert_contains "$err" 'each use profile effort must be supported by its harness and model' "codex max $label is refused"
  fi
done
# Codex ultra follows the installed catalog like max, but with no name-based
# fallback: an explicit model whose catalog advertises ultra is accepted, every
# other case is refused. This matches bin/fm-harness.sh validate-native-effort
# and bootstrap's crew_dispatch_validate.
mkdir -p "$TMP_ROOT/codex-ultra-catalog"
printf '%s\n' '{"models":[{"slug":"gpt-6.1-sol","supported_reasoning_levels":[{"effort":"ultra"},{"effort":"high"}]},{"slug":"gpt-5","supported_reasoning_levels":[{"effort":"high"}]}]}' > "$TMP_ROOT/codex-ultra-catalog/models_cache.json"
for case in advertised:gpt-6.1-sol:ok not-advertised:gpt-5:bad missing-catalog:gpt-6.1-sol:bad missing-catalog-luna:gpt-5.6-luna:bad; do
  IFS=: read -r label model verdict <<< "$case"
  codex_home=$TMP_ROOT/codex-ultra-catalog
  case "$label" in missing-catalog*) codex_home=$TMP_ROOT/codex-ultra-catalog-absent ;; esac
  printf '{"rules":[{"when":"x","use":{"harness":"codex","model":"%s","effort":"ultra"}}]}\n' "$model" > "$RULES"
  CODEX_HOME=$codex_home TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  if [ "$verdict" = ok ]; then
    expect_code 0 "$code" "codex ultra $label resolves without a configuration error"
    assert_not_contains "$err" 'malformed rules file' "codex ultra $label is well formed"
  else
    assert_contains "$err" 'each use profile effort must be supported by its harness and model' "codex ultra $label is refused"
  fi
done
# A codex-ultra profile with no explicit model is refused: ultra needs an
# explicit catalog-advertised model.
printf '%s\n' '{"rules":[{"when":"x","use":{"harness":"codex","effort":"ultra"}}]}' > "$RULES"
CODEX_HOME=$TMP_ROOT/codex-ultra-catalog TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$err" 'each use profile effort must be supported by its harness and model' "codex ultra without an explicit model is refused"
# Pi/Pi-signed codex-native ultra acceptance is unchanged.
for h in pi pi-signed; do
  printf '{"rules":[{"when":"x","use":{"harness":"%s","model":"codex-native/gpt-6-astra","effort":"ultra","provider":"codex"}}]}\n' "$h" > "$RULES"
  CODEX_HOME=$TMP_ROOT/codex-ultra-catalog-absent TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  assert_not_contains "$err" 'malformed rules file' "$h codex-native ultra remains accepted with no codex catalog"
done
pass "codex ultra config validation follows the installed catalog and leaves Pi native ultra unchanged"

# A resolved clear outcome naming codex ultra passes a launchable profile line
# through to fm-spawn. Use a quota fixture that makes the codex native row the
# single eligible candidate so the Choice collapses to one profile.
CODEX_ULTRA_RULES="$TMP_ROOT/codex-ultra-clear-rules.json"
printf '%s\n' '{"rules":[{"when":"A simple bug fix with a stated root cause.","use":{"harness":"codex","model":"gpt-6.1-sol","effort":"ultra","floor":{"scope":"all_models","min_percent":10}}}]}' > "$CODEX_ULTRA_RULES"
cp "$CODEX_ULTRA_RULES" "$RULES"
printf '%s\n' '{"model":"jev","answers":{"rule":{"type":"choice","choice":"rule_1","confidence":0.95,"probabilities":{"rule_1":0.99,"default":0.01}}},"usage":{"input_tokens":10,"output_tokens":5}}' > "$RESPONSE"
CODEX_HOME=$TMP_ROOT/codex-ultra-catalog TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "a codex ultra clear resolves with exit 0"
assert_contains "$out" '  status: clear' "a codex ultra profile resolves to a clear outcome"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-6.1-sol' --effort 'ultra'" "the clear codex ultra profile line is launchable by fm-spawn"
cp "$BASE_RULES" "$RULES"
write_response "$RESPONSE" rule_4 0.9
pass "a clear codex ultra profile passes a launchable --effort ultra line to fm-spawn"

for removed in --json --rules --quota; do
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" "$removed"
  expect_code 2 "$code" "removed option is rejected: $removed"
  assert_contains "$err" "unknown flag $removed" "removed option has no public path: $removed"
done
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --bogus
expect_code 2 "$code" "unknown flag exits 2"
run code out err --help
expect_code 0 "$code" "--help exits 0"
assert_contains "$out" 'Usage:' "--help prints usage"
pass "configuration errors exit 2 before any network call"

HARDENED_MUTATION="$TMP_ROOT/hardened-mutation.json"
# Adversarial consumer matrix: all outbound surfaces are PATH stubs.
cat > "$RULES" <<'JSON'
{"rules":[{"when":"Coding","use":[{"harness":"claude","model":"opus"},{"harness":"codex","model":"gpt-5"}]}]}
JSON
cat > "$RESPONSE" <<'JSON'
{"answers":{"rule":{"choice":"rule_1","confidence":1,"probabilities":{"rule_1":1,"default":0}}}}
JSON
HARDENED="$TMP_ROOT/hardened.json"
cat > "$HARDENED" <<'JSON'
{"schemaVersion":5,"providers":[
 {"provider":"claude","state":{"status":"fresh"},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"},"selection":{"status":"known","spendPriority":1}}]}},
 {"provider":"codex","state":{"status":"fresh"},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":1,"runway":{"status":"projected_exhaustion","usableRunwaySeconds":1},"selection":{"status":"known","spendPriority":100}}]}}
]}
JSON
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$HARDENED" run code out err "$BRIEF"
assert_contains "$out" "profile: --harness 'claude'" "one-second high scalar cannot beat viable runway"
assert_contains "$out" 'completion_horizon_seconds: 3600' "default horizon is inspectable"
assert_contains "$out" 'runway_seconds=all_models:1' "finite runway is disclosed"
assert_contains "$out" 'runway 1s below completion horizon 3600s' "runway failure is explained"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$HARDENED" run code out err "$BRIEF" --completion-horizon 1
assert_contains "$out" "profile: --harness 'codex'" "exact horizon boundary passes"
for mutation in '.providers[].quotaSemantics.effectiveAvailability[].runway = {status:"projected_exhaustion",usableRunwaySeconds:145}' '.providers[].quotaSemantics.effectiveAvailability[].runway = {status:"unknown"}' 'del(.providers[].quotaSemantics.effectiveAvailability[].runway.usableRunwaySeconds) | .providers[].quotaSemantics.effectiveAvailability[].runway.status = "projected_exhaustion"'; do
  jq "$mutation" "$HARDENED" > "$HARDENED_MUTATION"
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$HARDENED_MUTATION" run code out err "$BRIEF"
  assert_contains "$out" 'status: escalate' "insufficient or unknown runway cannot produce clear"
  assert_not_contains "$out" '  profile:' "no viable horizon emits no route"
done
for seconds in 0 -1 1e309 bogus; do
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --completion-horizon "$seconds"
  expect_code 2 "$code" "invalid horizon rejected: $seconds"
done
pass "completion horizon precedes argmax, with finite seconds and unknown uncertainty disclosed"

for mutation in '.providers[1].state.status = "stale"' '.providers[1].state.status = "auth_required"' '.providers[1].state.stale = true' '.providers[1].quotaSemantics.effectiveAvailability[0].selection.spendPriority = 101' '.providers[1].quotaSemantics.effectiveAvailability[0].selection.spendPriority = -101' '.providers[1].quotaSemantics.effectiveAvailability[0].selection.spendPriority = 1e309' '.providers[1].quotaSemantics.effectiveAvailability[0].selection.status = "unknown"' 'del(.providers[1].quotaSemantics.effectiveAvailability[0].selection.status)' '.providers[1].quotaSemantics.effectiveAvailability[0].runway.usableRunwaySeconds = -1' '.providers[1].quotaSemantics.effectiveAvailability[0].runway.usableRunwaySeconds = 1e309'; do
  jq "$mutation" "$HARDENED" > "$HARDENED_MUTATION"
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$HARDENED_MUTATION" run code out err "$BRIEF" --completion-horizon 1
  assert_contains "$out" 'status: error' "contradictory or unbounded snapshot refused: $mutation"
done
jq '.providers[1].quotaSemantics.effectiveAvailability[0].selection = {status:"unknown"}' "$HARDENED" > "$HARDENED_MUTATION"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$HARDENED_MUTATION" run code out err "$BRIEF" --completion-horizon 1
assert_contains "$out" "profile: --harness 'claude'" "unknown scalar stays unranked beside valid evidence"
pass "consumer validates state, scalar range, selection status, and finite runway"

jq '.schemaVersion = 6 | .providers[] |= (.accountKey = "default" | .accountKeys = ["default"]) |
  (.providers[] | select(.provider == "codex")) |= (.accountKey = "codex-home" | .accountKeys = ["codex-home","work-alias"] |
    .quotaSemantics.effectiveAvailability[0].runway = {status:"through_reset"})' "$HARDENED" > "$HARDENED_MUTATION"
jq '.rules[0].use[1] = {harness:"pi",model:"work-alias/gpt-5",provider:"codex"}' "$RULES" > "$TMP_ROOT/alias-rules"
cp "$TMP_ROOT/alias-rules" "$RULES"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$HARDENED_MUTATION" run code out err "$BRIEF"
assert_contains "$out" "profile: --harness 'pi' --model 'work-alias/gpt-5'" "folded alias uses membership before fallback"
jq '.providers += [.providers[1] | .accountKey = "other" | .accountKeys = ["other","work-alias"]]' "$HARDENED_MUTATION" > "$TMP_ROOT/ambiguous.json"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/ambiguous.json" run code out err "$BRIEF"
assert_contains "$out" 'status: error' "ambiguous membership refuses the snapshot"
pass "folded account alias binds only one published membership row"

cat > "$RULES" <<'JSON'
{"rules":[{"when":"Coding","use":[{"harness":"agy","model":"gemini-3.8-flash","effort":"high"},{"harness":"agy","model":"claude-sonnet-4-6"},{"harness":"agy","model":"future-family"}]}]}
JSON
jq '.providers = [.providers[0] | .provider = "agy" | .quotaSemantics.effectiveAvailability = [
  (.quotaSemantics.effectiveAvailability[0] | .scope = "gemini" | .runway.status = "exhausted_now" | .effectivePercentRemaining = 0),
  (.quotaSemantics.effectiveAvailability[0] | .scope = "claude_gpt")]]' "$HARDENED" > "$HARDENED_MUTATION"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$HARDENED_MUTATION" run code out err "$BRIEF"
assert_contains "$out" "profile: --harness 'agy' --model 'claude-sonnet-4-6'" "independent catalog-backed Agy bucket wins"
assert_contains "$out" 'runway exhausted_now at gemini' "Gemini bucket exhaustion is applied"
assert_contains "$out" 'no applicable quota row for provider agy' "unreviewed model family stays unranked"
TYPESAFE_API_KEY=$KEY FAKE_AGY_FAIL=1 QUOTA_AXI_FIXTURE="$HARDENED_MUTATION" run code out err "$BRIEF"
assert_contains "$out" 'status: escalate' "unavailable catalog does not guess Agy family"
# A healthy generic scope must not hide exhaustion in the capped family bucket.
for effort in high xhigh max; do
  printf '{"rules":[{"when":"Coding","use":{"harness":"agy","model":"gemini-3.8-flash","effort":"%s"}}]}\n' "$effort" > "$RULES"
  jq '.providers[0].quotaSemantics.effectiveAvailability += [
    (.providers[0].quotaSemantics.effectiveAvailability[1] | .scope = "all_models")
  ]' "$HARDENED_MUTATION" > "$TMP_ROOT/capped-agy.json"
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/capped-agy.json" run code out err "$BRIEF"
  assert_contains "$out" 'runway exhausted_now at gemini' "capped $effort binds and vetoes the Gemini bucket"
  assert_contains "$out" 'status: escalate' "capped $effort cannot rank healthy generic scope around exhausted bucket"
done
printf '{"rules":[{"when":"Coding","use":{"harness":"agy","model":"gemini-3.8-flash-high","effort":"max"}}]}\n' > "$RULES"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/capped-agy.json" run code out err "$BRIEF"
assert_contains "$out" 'runway exhausted_now at gemini' "catalog-listed suffixed model retains precedence"
# Missing family knowledge cannot be replaced by healthy generic/exact rows.
jq '.providers[0].quotaSemantics.effectiveAvailability += [
  (.providers[0].quotaSemantics.effectiveAvailability[1] | .scope = "model:gemini-3.8-flash-high"),
  (.providers[0].quotaSemantics.effectiveAvailability[1] | .scope = "product:gemini-3.8-flash-high")
]' "$TMP_ROOT/capped-agy.json" > "$TMP_ROOT/unknown-agy.json"
TYPESAFE_API_KEY=$KEY FAKE_AGY_FAIL=1 QUOTA_AXI_FIXTURE="$TMP_ROOT/unknown-agy.json" run code out err "$BRIEF"
assert_contains "$out" 'status: escalate' "failed catalog cannot rank generic or exact evidence around an unknown family bound"
assert_contains "$out" 'unranked' "catalog failure remains disclosed uncertainty"
printf '{"rules":[{"when":"Coding","use":{"harness":"agy","model":"future-family"}}]}\n' > "$RULES"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/unknown-agy.json" run code out err "$BRIEF"
assert_contains "$out" 'status: escalate' "catalog-listed unknown family cannot rank generic evidence"
pass "Agy catalog establishes the reviewed bucket mapping, including effort aliases"

cat > "$RULES" <<'JSON'
{"rules":[{"when":"Coding","use":{"harness":"pi","model":"kiro/claude-sonnet","provider":"kiro"}}]}
JSON
jq '.providers = [.providers[0] | .provider = "kiro" | .quotaSemantics.effectiveAvailability[0].scope = "included:credit_monthly"]' "$HARDENED" > "$HARDENED_MUTATION"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$HARDENED_MUTATION" run code out err "$BRIEF"
assert_contains "$out" "profile: --harness 'pi'" "explicit Pi Kiro provider binds the included pool"
jq '.providers[0].quotaSemantics.effectiveAvailability[0] |= (.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")' "$HARDENED_MUTATION" > "$TMP_ROOT/empty-pool.json"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/empty-pool.json" run code out err "$BRIEF"
assert_contains "$out" 'status: escalate' "depleted included pool is unranked"
assert_contains "$out" 'not whole-provider exhaustion' "included zero does not fabricate provider exhaustion"
assert_contains "$out" 'eligible, unranked:' "candidate with other unmeasured pools remains eligible"
pass "Kiro included pool is bound without summing pools or declaring whole-provider exhaustion"

# Devin's included_quota is the plan allowance its paid per-token models draw
# on, so the GPT routes bind and rank; its free SWE-2 model draws on nothing
# and stays disclosed uncertainty (free, draws on no plan quota).
cat > "$RULES" <<'JSON'
{"rules":[{"when":"Coding","use":[
  {"harness":"devin","model":"swe-2-max","provider":"devin"},
  {"harness":"devin","model":"gpt-6-1-sol-max","provider":"devin"},
  {"harness":"devin","model":"gpt-6-luna-max","provider":"devin"}]}]}
JSON
cat > "$RESPONSE" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"rule_1","confidence":0.99,"probabilities":{"rule_1":0.99,"default":0.01}}},"usage":{"input_tokens":100,"output_tokens":60}}
JSON
jq '.providers = [.providers[0] | .provider = "devin" | .quotaSemantics.effectiveAvailability = [
  (.quotaSemantics.effectiveAvailability[0] | .scope = "included_quota" | .effectivePercentRemaining = 96 | .runway = {status:"through_reset"} | .selection.spendPriority = 1.92)]]' "$HARDENED" > "$HARDENED_MUTATION"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$HARDENED_MUTATION" run code out err "$BRIEF"
assert_contains "$out" 'candidate: devin:gpt-6-1-sol-max  provider=devin  scope=included_quota  remaining=96%  spendPriority=1.92  runway=through_reset  -> eligible' "a paid Sol route binds the included_quota row"
assert_contains "$out" 'candidate: devin:gpt-6-luna-max  provider=devin  scope=included_quota  remaining=96%  spendPriority=1.92  runway=through_reset  -> eligible' "a paid Luna route binds the included_quota row"
assert_contains "$out" 'candidate: devin:swe-2-max  provider=devin  -> eligible, unranked: no applicable quota row for provider devin; no catalog-confirmed quota binding (a free route draws on no plan quota, and a paid route binds only when the catalog is read): disclosed uncertainty' "the free SWE-2 route stays disclosed uncertainty"
# Both paid routes draw on the one included_quota pool, so they share its
# spendPriority and genuinely tie; the resolver escalates rather than guessing.
assert_contains "$out" 'status: escalate' "two paid routes sharing one included pool tie and escalate"
assert_contains "$out" 'genuine spendPriority tie' "the tie between pooled paid routes is reported"
# A lane with a single paid Devin route ranks and chooses it off included_quota.
cat > "$RULES" <<'JSON'
{"rules":[{"when":"Coding","use":[
  {"harness":"devin","model":"swe-2-max","provider":"devin"},
  {"harness":"devin","model":"gpt-6-1-sol-max","provider":"devin"}]}]}
JSON
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$HARDENED_MUTATION" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'devin' --model 'gpt-6-1-sol-max'" "a paid route is ranked and chosen over the free route"
# An exhausted included_quota is not whole-provider exhaustion: the paid routes
# are unranked rather than blocked, and the free route keeps its own uncertainty.
jq '.providers[0].quotaSemantics.effectiveAvailability[0] |= (.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")' "$HARDENED_MUTATION" > "$TMP_ROOT/devin-empty.json"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/devin-empty.json" run code out err "$BRIEF"
assert_contains "$out" 'status: escalate' "an exhausted included pool leaves no rankable route"
assert_contains "$out" 'not whole-provider exhaustion' "a zeroed included_quota does not fabricate whole-provider exhaustion"
assert_contains "$out" 'candidate: devin:swe-2-max  provider=devin  -> eligible, unranked:' "the free route stays eligible beside the depleted paid pool"
# A failed catalog cannot fabricate a binding; every Devin route is unranked.
TYPESAFE_API_KEY=$KEY FAKE_DEVIN_FAIL=1 QUOTA_AXI_FIXTURE="$HARDENED_MUTATION" run code out err "$BRIEF"
assert_contains "$out" 'status: escalate' "a failed Devin catalog leaves no rankable route"
assert_contains "$out" 'candidate: devin:gpt-6-1-sol-max  provider=devin  -> eligible, unranked:' "a failed catalog never binds the paid pool"
cp "$BASE_RULES" "$RULES"
pass "Devin included_quota binds only catalog-confirmed paid models, free routes stay disclosed"

# --- lanes: model classes with provider routes ----------------------------------
LANE_CODEX_HOME="$TMP_ROOT/lane-codex-home"
mkdir -p "$LANE_CODEX_HOME"
cat > "$LANE_CODEX_HOME/models_cache.json" <<'JSON'
{"models":[
  {"slug":"gpt-6.1-sol","supported_reasoning_levels":[{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}]},
  {"slug":"gpt-6-luna","supported_reasoning_levels":[{"effort":"max"}]},
  {"slug":"gpt-6-astra","supported_reasoning_levels":[{"effort":"xhigh"},{"effort":"max"}]}]}
JSON
LANE_QUOTA="$TMP_ROOT/lane-quota.json"
# lane_quota <provider>=<spendPriority|exhausted>...: one all_models row each.
lane_quota() {
  local rows='' entry provider value row
  for entry in "$@"; do
    provider=${entry%%=*}
    value=${entry#*=}
    if [ "$value" = exhausted ]; then
      row='{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"},"selection":{"status":"known","spendPriority":-1}}'
    else
      row="{\"scope\":\"all_models\",\"status\":\"known\",\"effectivePercentRemaining\":60,\"runway\":{\"status\":\"through_reset\"},\"selection\":{\"status\":\"known\",\"spendPriority\":$value}}"
    fi
    rows="$rows${rows:+,}{\"provider\":\"$provider\",\"state\":{\"status\":\"fresh\"},\"quotaSemantics\":{\"status\":\"known\",\"effectiveAvailability\":[$row]}}"
  done
  printf '{"generatedAt":"2030-01-01T00:00:00Z","schemaVersion":5,"providers":[%s]}\n' "$rows" > "$LANE_QUOTA"
}
# run_lane <exit-var> <out-var> <err-var> [args...]: no key, the lane quota fixture.
run_lane() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" CODEX_HOME="$LANE_CODEX_HOME" QUOTA_AXI_FIXTURE="$LANE_QUOTA" \
    "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}
TEMPLATE="$ROOT/docs/examples/crew-dispatch-lanes.json"
cp "$TEMPLATE" "$RULES"

# A named lane needs no key and sends nothing; code picks the route.
reset_log
lane_quota claude=-0.3 codex=0.2 grok=-0.5 agy=0.4 devin=-0.1 kiro=-0.6
run_lane code out err "$BRIEF" --lane standard --project xo
expect_code 0 "$code" "--lane exits 0 without a key: $err"
assert_contains "$out" 'status: clear' "--lane resolves the template's standard lane"
assert_contains "$out" 'selected: by --lane' "--lane names how the rule was chosen"
assert_not_contains "$out" 'probabilities:' "--lane prints no Choice probabilities"
assert_contains "$out" 'lane: standard  order=pool' "--lane names the lane and its order"
[ ! -e "$LOG/argv" ] || fail "--lane must not call the network"
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6.1-sol' --effort 'high'" "pool argmax picks the highest spendPriority route"
assert_contains "$out" 'class: sol-high  family=gpt' "the chosen class and family are printed"
assert_contains "$out" 'class=muse-spark family=muse  provider=opencode  quota=unmetered (declared)  spendPriority=0  runway=unmetered  -> eligible' "the declared unmetered route is rankable and clearly distinguished from measured quota"
assert_contains "$out" 'class=swe-2 family=swe  provider=devin  quota=unmetered (declared)  spendPriority=0  runway=unmetered  -> eligible' "the Devin SWE-2 class in the example is declared unmetered"
pass "a named lane resolves in code with no key, picking a route by spendPriority"

lane_quota claude=-0.3 codex=0.2 grok=-0.5 agy=0.4 devin=exhausted kiro=-0.6 opencode=exhausted
run_lane code out err "$BRIEF" --lane standard --project xo
assert_contains "$out" 'class=muse-spark family=muse  provider=opencode  quota=unmetered (declared)  spendPriority=0  runway=unmetered  -> eligible' "provider quota rows do not override a class's unmetered declaration"
assert_contains "$out" 'class=swe-2 family=swe  provider=devin  quota=unmetered (declared)  spendPriority=0  runway=unmetered  -> eligible' "an exhausted Devin row does not override the SWE-2 unmetered declaration"
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6.1-sol' --effort 'high'" "a positive measured route still outranks the unmetered neutral score"

lane_quota claude=-0.3 codex=-0.2 grok=-0.5 agy=-0.1 devin=-0.4 kiro=-0.6
run_lane code out err "$BRIEF" --lane standard --project xo
assert_contains "$out" 'status: escalate' "multiple unmetered routes tie when every measured route is spending ahead of pace"
assert_contains "$out" 'genuine spendPriority tie' "unmetered ties do not break by class order"
assert_contains "$out" 'class=muse-spark family=muse  provider=opencode  quota=unmetered (declared)  spendPriority=0  runway=unmetered  -> eligible' "Muse remains rankable at neutral priority"
assert_contains "$out" 'class=swe-2 family=swe  provider=devin  quota=unmetered (declared)  spendPriority=0  runway=unmetered  -> eligible' "SWE-2 remains rankable at the same neutral priority"
lane_quota claude=-0.3 codex=0 grok=-0.5 agy=-0.1 devin=-0.4 kiro=-0.6
run_lane code out err "$BRIEF" --lane standard --project xo
assert_contains "$out" 'status: escalate' "a measured zero ties the unmetered neutral priority"
assert_contains "$out" 'genuine spendPriority tie' "unmetered ties use the normal explicit tie escalation"
pass "unmetered routes use the pace-neutral boundary without starving positive measured routes or breaking ties by class order"

# Configured unmetered scores rank alongside measured scores, with zero as the
# compatible default. Distinct scores decide before live-count tie-breaking.
PRIORITY_RULES="$TMP_ROOT/priority-rules.json"
jq '.rules = [{lane:"priority", when:"ordinary work", classes:["swe-2", "sol-high", "muse-spark"]}] |
  .classes["muse-spark"].spend_priority = 5' "$TEMPLATE" > "$PRIORITY_RULES"
cp "$PRIORITY_RULES" "$RULES"
lane_quota codex=0.84
run_lane code out err "$BRIEF" --lane priority --project xo
expect_code 0 "$code" "a configured unmetered priority resolves successfully"
assert_contains "$out" "profile: --harness 'opencode' --model 'opencode/muse-spark-1.3-contributor-free'" "unmetered priority 5 outranks paid priority 0.84"
assert_contains "$out" 'quota=unmetered (declared)  spendPriority=5  runway=unmetered  -> eligible' "the configured score is printed"
assert_contains "$out" 'scope=all_models  remaining=60%  spendPriority=0.84' "the measured score is unchanged"
assert_contains "$out" 'class=swe-2 family=swe  provider=devin  quota=unmetered (declared)  spendPriority=0' "an absent spend_priority still yields zero"

jq '.classes["swe-2"].spend_priority = 3' "$PRIORITY_RULES" > "$RULES"
run_lane code out err "$BRIEF" --lane priority --project xo
assert_contains "$out" 'class: muse-spark  family=muse' "the higher unmetered score wins regardless of class order"
jq '.classes["swe-2"].spend_priority = 6' "$PRIORITY_RULES" > "$RULES"
run_lane code out err "$BRIEF" --lane priority --project xo
assert_contains "$out" 'class: swe-2  family=swe' "reversing the unmetered score preference reverses the winner"
jq '.classes["swe-2"].spend_priority = 5' "$PRIORITY_RULES" > "$RULES"
run_lane code out err "$BRIEF" --lane priority --project xo
assert_contains "$out" 'genuine spendPriority tie' "equal positive unmetered scores retain tie escalation"
pass "unmetered spend_priority controls ranking and display without changing measured scores or ties"

# Live counts are home-local, count ordinary records regardless of status,
# and match harness/model rather than effort or a stale model_family.
LIVE_RULES="$TMP_ROOT/live-rules.json"
LIVE_STATE="$HOME_DIR/state"
mkdir -p "$LIVE_STATE"
jq '.rules = [{lane:"live", when:"ordinary work", classes:["muse-spark", "swe-2", "sol-high"]}]' "$TEMPLATE" > "$LIVE_RULES"
cp "$LIVE_RULES" "$RULES"
cat > "$LIVE_STATE/worker.meta" <<'META'
kind=scout
harness=opencode
model=opencode/muse-spark-1.3-contributor-free
model_family=wrong
effort=high
META
printf 'done: finished but not cleaned up\n' > "$LIVE_STATE/worker.status"
cat > "$LIVE_STATE/secondmate.meta" <<'META'
kind=secondmate
harness=devin
model=swe-2-max
META
printf 'kind=ship\nharness=opencode\nmodel=unrelated\n' > "$LIVE_STATE/unrelated.meta"
ln -s "$LIVE_STATE/absent" "$LIVE_STATE/unreadable.meta"
lane_quota codex=-0.2 devin=-0.4
run_lane code out err "$BRIEF" --lane live --project xo
expect_code 0 "$code" "live counting exits successfully"
assert_contains "$out" "profile: --harness 'devin' --model 'swe-2-max'" "an exact unmetered tie prefers the less busy class"
assert_contains "$out" 'tie_break: swe-2 has fewest live workers (0) among spendPriority ties' "the live-count tie-break is disclosed"
assert_contains "$out" 'class=muse-spark family=muse  provider=opencode  quota=unmetered (declared)  spendPriority=0  runway=unmetered  -> eligible  live=1' "without a cap a matching finished ordinary task leaves the class eligible"
assert_contains "$out" 'class=swe-2 family=swe  provider=devin  quota=unmetered (declared)  spendPriority=0  runway=unmetered  -> eligible  live=0' "secondmates and unreadable records do not count"

jq '.classes["muse-spark"].spend_priority = 5 | .classes["swe-2"].spend_priority = 5' "$LIVE_RULES" > "$RULES"
run_lane code out err "$BRIEF" --lane live --project xo
assert_contains "$out" 'tie_break: swe-2 has fewest live workers (0) among spendPriority ties' "equal positive unmetered scores still prefer fewer live workers"
jq '.classes["muse-spark"].spend_priority = 5 | .classes["muse-spark"].max_live = 1' "$PRIORITY_RULES" > "$RULES"
lane_quota codex=0.84
run_lane code out err "$BRIEF" --lane priority --project xo
assert_contains "$out" 'class=muse-spark family=muse  -> not eligible: at live cap 1/1' "a high unmetered score does not bypass max_live"
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6.1-sol' --effort 'high'" "the paid route wins when the preferred free class is capped"
jq '.classes["muse-spark"].live_cap_group = "shared" |
  .live_cap_groups = {shared:{max_live:1}}' "$PRIORITY_RULES" > "$RULES"
run_lane code out err "$BRIEF" --lane priority --project xo
assert_contains "$out" 'not eligible: at live cap group shared 1/1' "a high unmetered score does not bypass live_cap_group"
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6.1-sol' --effort 'high'" "the paid route wins when the preferred free group is capped"
lane_quota codex=-0.2 devin=-0.4

jq '.classes["muse-spark"].max_live = 1' "$LIVE_RULES" > "$RULES"
run_lane code out err "$BRIEF" --lane live --project xo
assert_contains "$out" 'class=muse-spark family=muse  -> not eligible: at live cap 1/1  live=1 max_live=1' "an at-cap class is excluded"
assert_contains "$out" "profile: --harness 'devin' --model 'swe-2-max'" "the pool picks the next eligible route"
assert_not_contains "$out" 'tie_break:' "excluding a capped class is not a tie-break"

jq '.classes["muse-spark"].max_live = 2' "$LIVE_RULES" > "$RULES"
run_lane code out err "$BRIEF" --lane live --project xo
assert_contains "$out" 'runway=unmetered  -> eligible  live=1 max_live=2' "an under-cap class remains eligible"
pass "class caps exclude only at-cap classes and uncapped exact ties prefer fewer live workers"

# Relaunch replaces this task record: its new route alone gets the count.
printf 'harness=devin\nmodel=swe-2-max\nmodel_family=muse\n' > "$LIVE_STATE/worker.meta"
run_lane code out err "$BRIEF" --lane live --project xo
assert_contains "$out" 'runway=unmetered  -> eligible  live=0 max_live=2' "the relaunched task no longer counts for its old class"
assert_contains "$out" 'class=swe-2 family=swe  provider=devin  quota=unmetered (declared)  spendPriority=0  runway=unmetered  -> eligible  live=1' "a record without kind counts for its new harness/model class"
assert_contains "$out" 'tie_break: muse-spark has fewest live workers (0) among spendPriority ties' "relaunch moves the exact-tie preference to the other class"
assert_contains "$out" "profile: --harness 'opencode' --model 'opencode/muse-spark-1.3-contributor-free'" "the preference is independent of class order"
printf 'kind=ship\nharness=opencode\nmodel=opencode/muse-spark-1.3-contributor-free\n' > "$LIVE_STATE/other.meta"
run_lane code out err "$BRIEF" --lane live --project xo
assert_contains "$out" 'status: escalate' "equal nonzero live counts still escalate"
assert_contains "$out" 'genuine spendPriority tie' "the surviving tie is named"
assert_not_contains "$out" 'tie_break:' "no deciding tie-break is claimed for an equal-count tie"

jq '.classes["muse-spark"].max_live = 1 | .classes["swe-2"].max_live = 1' "$LIVE_RULES" > "$RULES"
run_lane code out err "$BRIEF" --lane live --project xo
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6.1-sol' --effort 'high'" "when both neutral classes are capped the best metered route wins"
jq '.rules[0].order = "ordered" | .classes["muse-spark"].max_live = 1' "$LIVE_RULES" > "$RULES"
run_lane code out err "$BRIEF" --lane live --project xo
assert_contains "$out" "profile: --harness 'devin' --model 'swe-2-max'" "an ordered lane falls through an at-cap first class"
pass "relaunch updates live-class membership and surviving equal-count ties still escalate"

# Match every route of a class, counting one record only once even when effort
# routes overlap. Counts from a state override replace the effective home state.
jq '.rules[0].classes = ["opus-high", "sol-high"] | .classes["opus-high"].max_live = 2 |
  .classes["opus-high"].routes += [{harness:"claude", model:"claude-opus-5-5", effort:"medium"}]' "$LIVE_RULES" > "$RULES"
printf 'harness=claude\nmodel=claude-opus-5-5\neffort=xhigh\n' > "$LIVE_STATE/route-one.meta"
printf 'harness=pi\nmodel=kiro/claude-opus-5.5\n' > "$LIVE_STATE/route-two.meta"
lane_quota claude=0.4 kiro=0.3 codex=0.2 devin=-0.4
run_lane code out err "$BRIEF" --lane live --project xo
assert_contains "$out" 'class=opus-high family=claude  -> not eligible: at live cap 2/2  live=2 max_live=2' "both provider routes count and duplicate effort routes do not double-count"
assert_contains "$out" "profile: --harness 'codex'" "all routes of the capped class are excluded"
jq '.classes["opus-high"].routes |= .[:2]' "$RULES" > "$TMP_ROOT/no-duplicate-effort.json"
mv "$TMP_ROOT/no-duplicate-effort.json" "$RULES"
OVERRIDE_STATE="$TMP_ROOT/override-state"
mkdir -p "$OVERRIDE_STATE"
FM_STATE_OVERRIDE="$OVERRIDE_STATE" run_lane code out err "$BRIEF" --lane live --project xo
assert_contains "$out" "profile: --harness 'claude' --model 'claude-opus-5-5' --effort 'high'" "an empty state override ignores the home's records"
assert_contains "$out" 'live=0 max_live=2' "the override provides the live count"
lane_quota claude=0.4 kiro=0.4 codex=0.2 devin=-0.4
FM_STATE_OVERRIDE="$OVERRIDE_STATE" run_lane code out err "$BRIEF" --lane live --project xo
assert_contains "$out" 'genuine spendPriority tie' "tied routes within one class still escalate"
pass "class counts include all provider routes once and respect the effective state directory"

# Spawn writes model=default when a route omits the model.
jq '.classes["muse-spark"].routes[0] |= del(.model) |
  .classes["muse-spark"].max_live = 1' "$LIVE_RULES" > "$RULES"
printf 'kind=ship\nharness=opencode\nmodel=default\n' > "$LIVE_STATE/default-model.meta"
run_lane code out err "$BRIEF" --lane live --project xo
assert_contains "$out" 'candidate: opencode:-  class=muse-spark family=muse  -> not eligible: at live cap 1/1  live=1 max_live=1' "default-model metadata matches a route with no model"
pass "class caps count routes that use the harness default model"

for bad_cap in 0 -1 1.5 '"1"' null true '{}' '[]'; do
  jq --argjson cap "$bad_cap" '.classes["muse-spark"].max_live = $cap' "$LIVE_RULES" > "$RULES"
  run_lane code out err "$BRIEF" --lane live --project xo
  expect_code 2 "$code" "malformed max_live $bad_cap is a configuration error"
  assert_contains "$err" 'class max_live must be a positive integer' "the max_live schema error is explicit"
done
pass "max_live accepts only positive integers"

# Shared counts span every configured member, including classes outside this
# lane, and overlapping routes still count each ordinary task record once.
GROUP_RULES="$TMP_ROOT/group-rules.json"
jq '.live_cap_groups = {shared:{max_live:3}, independent:{max_live:2}} |
  .classes["muse-spark"] += {live_cap_group:"shared", max_live:2} |
  .classes["sol-high"].live_cap_group = "shared" |
  .classes["opus-high"].live_cap_group = "shared" |
  .classes["opus-shadow"] = (.classes["opus-high"] | .routes |= map(.effort = "medium")) |
  .classes["swe-2"].live_cap_group = "independent"' "$LIVE_RULES" > "$GROUP_RULES"
cp "$GROUP_RULES" "$RULES"
lane_quota claude=0.4 kiro=0.3 codex=-0.2 devin=-0.4
run_lane code out err "$BRIEF" --lane live --project xo
expect_code 0 "$code" "shared caps resolve successfully"
assert_contains "$out" 'class=muse-spark family=muse  -> not eligible: at live cap group shared 3/3  live=1 max_live=2 live_cap_group=shared group_live=3 group_max_live=3' "outside-lane routes count once across overlapping member classes"
assert_contains "$out" 'class=sol-high family=gpt  -> not eligible: at live cap group shared 3/3  live=0 live_cap_group=shared group_live=3 group_max_live=3' "the shared cap excludes every member, including an idle class"
assert_contains "$out" 'runway=unmetered  -> eligible  live=1 live_cap_group=independent group_live=1 group_max_live=2' "the other pool remains independent and ignores secondmates"
assert_contains "$out" "profile: --harness 'devin' --model 'swe-2-max'" "a pool lane skips the capped shared group"

jq '.rules[0].order = "ordered"' "$GROUP_RULES" > "$RULES"
run_lane code out err "$BRIEF" --lane live --project xo
assert_contains "$out" "profile: --harness 'devin' --model 'swe-2-max'" "an ordered lane falls through a group-capped class"

jq '.live_cap_groups.shared.max_live = 4' "$GROUP_RULES" > "$RULES"
run_lane code out err "$BRIEF" --lane live --project xo
assert_contains "$out" 'runway=unmetered  -> eligible  live=1 max_live=2 live_cap_group=shared group_live=3 group_max_live=4' "an under-cap shared group remains eligible"
jq '.live_cap_groups.shared.max_live = 4 | .classes["muse-spark"].max_live = 1' "$GROUP_RULES" > "$RULES"
run_lane code out err "$BRIEF" --lane live --project xo
assert_contains "$out" 'not eligible: at live cap 1/1  live=1 max_live=1 live_cap_group=shared group_live=3 group_max_live=4' "a class cap still applies when its group has room"
FM_STATE_OVERRIDE="$OVERRIDE_STATE" run_lane code out err "$BRIEF" --lane live --project xo
assert_contains "$out" 'runway=unmetered  -> eligible  live=0 max_live=1 live_cap_group=shared group_live=0 group_max_live=4' "shared counts respect the state override"

jq '.classes["muse-spark"].routes[0] |= del(.model)' "$GROUP_RULES" > "$RULES"
run_lane code out err "$BRIEF" --lane live --project xo
assert_contains "$out" 'candidate: opencode:-  class=muse-spark family=muse  -> not eligible: at live cap group shared 3/3  live=1 max_live=2 live_cap_group=shared group_live=3 group_max_live=3' "shared groups count default-model routes"
printf 'kind=ship\nharness=opencode\nmodel=unrelated\n' > "$LIVE_STATE/route-one.meta"
cp "$GROUP_RULES" "$RULES"
run_lane code out err "$BRIEF" --lane live --project xo
assert_contains "$out" 'runway=unmetered  -> eligible  live=1 max_live=2 live_cap_group=shared group_live=2 group_max_live=3' "relaunch removes the old route from the shared count"
pass "shared caps count all member routes once, remain independent, and combine with class caps"

for bad_cap in 0 -1 1.5 '"1"' null true '{}' '[]' 1e999; do
  jq --argjson cap "$bad_cap" '.live_cap_groups.shared.max_live = $cap' "$GROUP_RULES" > "$RULES"
  run_lane code out err "$BRIEF" --lane live --project xo
  expect_code 2 "$code" "malformed group max_live $bad_cap is a configuration error"
  assert_contains "$err" 'live cap group max_live must be a positive integer' "the group cap schema error is explicit"
done
for bad_group in '"missing"' '"Bad Name"' null true 1 '{}' '[]'; do
  jq --argjson group "$bad_group" '.classes["muse-spark"].live_cap_group = $group' "$GROUP_RULES" > "$RULES"
  run_lane code out err "$BRIEF" --lane live --project xo
  expect_code 2 "$code" "malformed group reference $bad_group is a configuration error"
  assert_contains "$err" 'class live_cap_group must name a declared live cap group' "the group reference schema error is explicit"
done
for bad_groups in null true '[]' '"shared"'; do
  jq --argjson groups "$bad_groups" '.live_cap_groups = $groups' "$GROUP_RULES" > "$RULES"
  run_lane code out err "$BRIEF" --lane live --project xo
  expect_code 2 "$code" "malformed group map $bad_groups is a configuration error"
  assert_contains "$err" 'live_cap_groups must be an object of named cap groups' "the group map schema error is explicit"
done
jq '.live_cap_groups = {"Bad Name":{max_live:1}}' "$GROUP_RULES" > "$RULES"
run_lane code out err "$BRIEF" --lane live --project xo
expect_code 2 "$code" "malformed group names are configuration errors"
assert_contains "$err" 'live cap group names must match' "the group name schema error is explicit"
for bad_definition in null 1 '[]' '{}' '{"max_live":1,"extra":true}'; do
  jq --argjson definition "$bad_definition" '.live_cap_groups.shared = $definition' "$GROUP_RULES" > "$RULES"
  run_lane code out err "$BRIEF" --lane live --project xo
  expect_code 2 "$code" "malformed group definition $bad_definition is a configuration error"
  assert_contains "$err" 'live cap group' "the group definition error is explicit"
done
pass "shared caps validate group maps, definitions, names, caps, and references"
# Clear only the live-count fixtures; preserve the append-only call history.
rm -f "$LIVE_STATE"/*.meta
cp "$TEMPLATE" "$RULES"
lane_quota claude=-0.3 codex=0 grok=-0.5 agy=-0.1 devin=-0.4 kiro=-0.6
run_lane code out err "$BRIEF" --lane standard --project xo

# Unmetered routes stay neutral for pace; they keep the shipped lane's gate closed.
# Removing both from this test fixture shows the gate can open when all remaining
# metered routes are ahead of pace and Gemini itself is not.
assert_contains "$out" 'class=gemini-flash-high family=gemini  provider=agy' "the gated class is evaluated"
assert_contains "$out" 'not eligible: pace gate closed: muse-spark, sol-high, swe-2 not spending ahead of pace' "unmetered routes remain part of the pace gate"
jq '.rules |= map(if .lane == "standard" then .classes |= map(select(. != "muse-spark" and . != "swe-2")) else . end)' "$TEMPLATE" > "$RULES"
lane_quota claude=-0.3 codex=-0.2 grok=-0.5 agy=0.4 devin=-0.1 kiro=-0.6
run_lane code out err "$BRIEF" --lane standard --project xo
assert_contains "$out" "profile: --harness 'agy' --model 'gemini-3.8-flash-high'" "the gate opens when every remaining route is ahead of pace"
lane_quota claude=-0.3 codex=-0.2 grok=-0.5 agy=-0.05 devin=-0.25 kiro=-0.6
run_lane code out err "$BRIEF" --lane standard --project xo
assert_contains "$out" 'pace gate closed: this class is itself spending ahead of pace' "the gate stays closed when the gated class is ahead of pace too"
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6.1-sol' --effort 'high'" "the pool falls back to the best ungated route"
cp "$TEMPLATE" "$RULES"
lane_quota claude=-0.3 codex=0.2 grok=-0.5 agy=0.4 devin=-0.1 kiro=-0.6
run_lane code out err "$BRIEF" --lane scoped --project xo
assert_contains "$out" "profile: --harness 'agy' --model 'gemini-3.8-flash-high'" "an ungated lane ranks the same class without the pace condition"
pass "the Gemini pace gate applies only where the lane declares it"

# Pace gates must use pressure even when legacy signs would close the gate.
jq '.rules = [{lane:"pressure",when:"ordinary work",classes:["sol-high",{class:"gemini-flash-high",gate:"others-ahead-of-pace"}]}]' "$TEMPLATE" > "$RULES"
lane_quota codex=0.2 agy=-0.4
jq '(.providers[].quotaSemantics.effectiveAvailability[].selection) |= (.spendPressure = (-.spendPriority))' "$LANE_QUOTA" > "$LANE_QUOTA.pressure"
mv "$LANE_QUOTA.pressure" "$LANE_QUOTA"
run_lane code out err "$BRIEF" --lane pressure --project xo
assert_contains "$out" "profile: --harness 'agy' --model 'gemini-3.8-flash-high'" "pressure signs open the pace gate despite opposite legacy signs"
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability[].selection.spendPressure) = 0' "$LANE_QUOTA" > "$LANE_QUOTA.pressure"
mv "$LANE_QUOTA.pressure" "$LANE_QUOTA"
run_lane code out err "$BRIEF" --lane pressure --project xo
assert_contains "$out" 'pace gate closed: sol-high not spending ahead of pace' "zero pressure closes the gate without consulting legacy priority"

jq '.classes["muse-spark"].spend_priority = 5 |
    .rules = [{lane:"pressure",when:"ordinary work",classes:["sol-high","muse-spark"]}]' "$TEMPLATE" > "$RULES"
run_lane code out err "$BRIEF" --lane pressure --project xo
assert_contains "$out" 'quota=unmetered (declared)  spendPressure=5  runway=unmetered' "configured unmetered scores keep their value under pressure"
assert_contains "$out" 'class: muse-spark' "the configured synthetic score still ranks alongside pressure"
tail -n 1 "$HOME_DIR/state/dispatch-history.jsonl" | jq -e '
  .spendMetric == "spendPressure" and
  any(.candidates[]; .class == "muse-spark" and .unmetered == true and .spendPressure == 5)
' >/dev/null || fail "history lost the synthetic pressure distinction"
pass "pressure controls lane pace gates and preserves synthetic scores"

# Changing a synthetic score never changes pace, on either side of the gate.
for priority in 0 5 -5; do
  jq --argjson priority "$priority" '.classes["muse-spark"].spend_priority = $priority |
    .rules = [{lane:"pace", when:"ordinary work", classes:["muse-spark", "sol-high", {class:"gemini-flash-high", gate:"others-ahead-of-pace"}]}]' "$TEMPLATE" > "$RULES"
  lane_quota codex=-0.2 agy=0.4
  run_lane code out err "$BRIEF" --lane pace --project xo
  assert_contains "$out" 'not eligible: pace gate closed: muse-spark not spending ahead of pace' "ungated unmetered priority $priority keeps the gate closed"

  jq --argjson priority "$priority" '.classes["swe-2"].spend_priority = $priority |
    .rules = [{lane:"pace", when:"ordinary work", classes:["sol-high", {class:"swe-2", gate:"others-ahead-of-pace"}]}]' "$TEMPLATE" > "$RULES"
  run_lane code out err "$BRIEF" --lane pace --project xo
  assert_contains "$out" "class=swe-2 family=swe  provider=devin  quota=unmetered (declared)  spendPriority=$priority  runway=unmetered  -> eligible" "gated unmetered priority $priority stays pace-neutral when others are ahead"
  lane_quota codex=0
  run_lane code out err "$BRIEF" --lane pace --project xo
  assert_contains "$out" 'not eligible: pace gate closed: sol-high not spending ahead of pace' "gated unmetered priority $priority cannot bypass a closed gate"
done
cp "$TEMPLATE" "$RULES"
lane_quota claude=-0.3 codex=0.2 grok=-0.5 agy=0.4 devin=-0.1 kiro=-0.6
pass "configured unmetered priorities leave pace gates unchanged"

# Ordered lanes stop at the first class with any eligible route.
run_lane code out err "$BRIEF" --lane judgment
assert_contains "$out" "profile: --harness 'claude' --model 'claude-opus-5-5' --effort 'xhigh'" "the first viable class wins over a higher-priority later class"
lane_quota claude=exhausted codex=0.2 kiro=-0.6
run_lane code out err "$BRIEF" --lane judgment
assert_contains "$out" "profile: --harness 'pi' --model 'kiro/claude-opus-5.5' --effort 'xhigh'" "another route of the first class serves before the fallback class"
lane_quota claude=exhausted codex=0.2
run_lane code out err "$BRIEF" --lane judgment
assert_contains "$out" 'status: escalate' "an unmeasured route keeps the first class viable instead of skipping to the fallback"
assert_contains "$out" 'no rankable eligible candidate in first viable class opus-xhigh' "the escalation names the first viable class"
lane_quota claude=exhausted codex=0.2 kiro=exhausted
run_lane code out err "$BRIEF" --lane technical-deep
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6.1-sol' --effort 'max'" "an exhausted first class falls to the next class in order"
pass "ordered lanes take the first viable class and rank only inside it"

cat > "$RULES" <<'JSON'
{"classes":{
  "free-first":{"family":"muse","unmetered":true,"routes":[{"harness":"opencode","model":"opencode/muse-spark-1.3-contributor-free","provider":"opencode"}]},
  "metered-second":{"family":"gpt","routes":[{"harness":"codex","model":"gpt-6.1-sol","effort":"high"}]}},
 "rules":[{"lane":"ordered-unmetered","order":"ordered","when":"Ordered quota selection.","classes":["free-first","metered-second"]}]}
JSON
lane_quota codex=0.9
run_lane code out err "$BRIEF" --lane ordered-unmetered
assert_contains "$out" "profile: --harness 'opencode' --model 'opencode/muse-spark-1.3-contributor-free'" "ordered lanes keep the first unmetered class ahead of a higher measured score"
jq '.rules[0].classes = ["metered-second", "free-first"]' "$RULES" > "$TMP_ROOT/reordered.json" && cp "$TMP_ROOT/reordered.json" "$RULES"
run_lane code out err "$BRIEF" --lane ordered-unmetered
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6.1-sol' --effort 'high'" "ordered lanes keep a higher measured class ahead when it is listed first"
pass "unmetered ranking preserves ordered lane semantics"
cp "$TEMPLATE" "$RULES"

# Long-horizon needs the captain's per-task word; candidates are still shown.
lane_quota claude=0.3 codex=0.2
run_lane code out err "$BRIEF" --lane long-horizon
assert_contains "$out" 'status: escalate' "an approval-gated lane never auto-dispatches"
assert_contains "$out" "rule requires the captain's explicit approval before dispatch" "the escalation names the approval gate"
assert_contains "$out" 'class=sol-ultra family=gpt' "the approval-gated lane still evaluates its classes"
assert_not_contains "$out" 'profile:' "an approval-gated lane prints no profile"
pass "Long-horizon resolves to the captain's per-task word"

# A second opinion excludes the originating family and every experiment.
lane_quota claude=0.5 codex=0.2 grok=-0.5 agy=0.4 devin=-0.1 kiro=0.9
run_lane code out err "$BRIEF" --lane standard --project xo --exclude-family claude
assert_contains "$out" 'exclude_family: claude' "the excluded family is printed"
assert_contains "$out" 'class=opus-medium family=claude  -> not eligible: second opinion excludes family claude' "the originating family is excluded"
assert_contains "$out" 'experiment: kiro-auto  share=0.25' "the experiment is reported"
assert_contains "$out" 'not eligible: an experiment class never serves a second opinion' "an experiment never serves a second opinion"
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6.1-sol' --effort 'high'" "the best other-family route serves the second opinion"
run_lane code out err "$BRIEF" --lane judgment --exclude-family claude
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6-astra' --effort 'xhigh'" "an ordered lane moves to its first other-family class"
run_lane code out err "$BRIEF" --lane standard --exclude-family cluade
expect_code 2 "$code" "an undeclared family is a usage error"
assert_contains "$err" 'undeclared family: cluade' "the typo is named"
pass "a second opinion keeps the lane and excludes the originating family"

# The data policy refuses a training-retaining route for disallowed data.
lane_quota codex=-0.2 devin=-0.1 agy=0.3
run_lane code out err "$BRIEF" --lane bulk --project acme
assert_contains "$out" 'class=muse-spark family=muse  -> not eligible: data policy may-train does not admit project acme without an allowed data tag' "an unlisted project is refused"
run_lane code out err "$BRIEF" --lane bulk --project acme --data-tag public-research
assert_contains "$out" 'class=muse-spark family=muse  provider=opencode  quota=unmetered (declared)  spendPriority=0  runway=unmetered  -> eligible' "an allowed data tag admits the unmetered route"
assert_contains "$out" 'data_tags: public-research' "the data tags are printed"
run_lane code out err "$BRIEF" --lane bulk --project xo --data-tag person-data
assert_contains "$out" 'not eligible: data policy may-train refuses data tag person-data' "a denied tag refuses even an allowed project"
run_lane code out err "$BRIEF" --lane bulk --project xo
assert_contains "$out" 'class=muse-spark family=muse  provider=opencode  quota=unmetered (declared)  spendPriority=0  runway=unmetered  -> eligible' "an allowed project admits the unmetered route"
run_lane code out err "$BRIEF" --lane bulk --data-tag publc
expect_code 2 "$code" "an undeclared data tag is a usage error"
assert_contains "$err" 'undeclared data tag: publc' "the typo is named"
pass "a data policy admits its class only for allowed projects or tags and never with a denied tag"

# Experiments: a sampled arm takes the task, the same brief always samples the same way.
cat > "$RULES" <<'JSON'
{"classes":{
  "sol-high":{"family":"gpt","routes":[{"harness":"codex","model":"gpt-6.1-sol","effort":"high"}]},
  "kiro-auto":{"family":"kiro-auto","experiment":{"share":1},"routes":[{"harness":"pi","model":"kiro/auto","provider":"kiro"}]}},
 "rules":[{"lane":"standard","when":"Ordinary work.","classes":["sol-high","kiro-auto"]}]}
JSON
lane_quota codex=0.5 kiro=-0.6
run_lane code out err "$BRIEF" --lane standard
assert_contains "$out" '-> sampled' "a share of 1 samples every task"
assert_contains "$out" "profile: --harness 'pi' --model 'kiro/auto'" "a sampled experiment takes the task over a higher-priority route"
assert_contains "$out" 'class: kiro-auto  family=kiro-auto  experiment' "the chosen experiment is marked"
lane_quota codex=0.5
run_lane code out err "$BRIEF" --lane standard
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6.1-sol' --effort 'high'" "an unranked sampled experiment yields to the ranked pool"
jq '.classes["kiro-auto"].experiment.share = 0.01' "$RULES" > "$TMP_ROOT/rare.json" && cp "$TMP_ROOT/rare.json" "$RULES"
lane_quota codex=0.5 kiro=0.9
EXP_BRIEF="$TMP_ROOT/exp-brief.md"
found=''
for variant in 1 2 3 4 5 6 7 8 9 10; do
  printf '# Task\nRename the pager helper, variant %s.\n' "$variant" > "$EXP_BRIEF"
  run_lane code out err "$EXP_BRIEF" --lane standard
  case "$out" in *'-> not sampled'*) found=$variant; break ;; esac
done
[ -n "$found" ] || fail "no brief variant was left unsampled at a 1% share"
assert_contains "$out" 'class=kiro-auto family=kiro-auto experiment  -> not eligible: experiment not sampled for this task' "an unsampled experiment is excluded"
assert_contains "$out" "profile: --harness 'codex'" "an unsampled experiment never takes the task"
first=$out
run_lane code out err "$EXP_BRIEF" --lane standard
[ "$out" = "$first" ] || fail "the same brief must sample the same way on every run"
pass "an experiment class is sampled per brief and marked when chosen"

cat > "$RULES" <<'JSON'
{"classes":{
  "sol-high":{"family":"gpt","routes":[{"harness":"codex","model":"gpt-6.1-sol","effort":"high"}]},
  "muse-trial":{"family":"muse","unmetered":true,"experiment":{"share":1},"routes":[{"harness":"opencode","model":"opencode/muse-spark-1.3-contributor-free","provider":"opencode"}]}},
 "rules":[{"lane":"unmetered-experiment","when":"Sampled free route.","classes":["sol-high","muse-trial"]}]}
JSON
lane_quota codex=0.5
run_lane code out err "$BRIEF" --lane unmetered-experiment
assert_contains "$out" 'experiment: muse-trial  share=1  ' "the unmetered experiment is sampled through the normal class gate"
assert_contains "$out" "profile: --harness 'opencode' --model 'opencode/muse-spark-1.3-contributor-free'" "a sampled unmetered experiment takes the task through the normal experiment rule"
jq '.classes["muse-trial"].experiment.share = 0.01' "$RULES" > "$TMP_ROOT/unmetered-rare.json" && cp "$TMP_ROOT/unmetered-rare.json" "$RULES"
EXP_BRIEF="$TMP_ROOT/unmetered-exp-brief.md"
found=''
for variant in 1 2 3 4 5 6 7 8 9 10; do
  printf '# Task\nRename the pager helper, unmetered variant %s.\n' "$variant" > "$EXP_BRIEF"
  run_lane code out err "$EXP_BRIEF" --lane unmetered-experiment
  case "$out" in *'-> not sampled'*) found=$variant; break ;; esac
done
[ -n "$found" ] || fail "no unmetered experiment brief variant was left unsampled at a 1% share"
assert_contains "$out" 'class=muse-trial family=muse experiment  -> not eligible: experiment not sampled for this task' "an unmetered route does not bypass experiment sampling"
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6.1-sol' --effort 'high'" "an unsampled unmetered route yields to the eligible measured pool"
pass "unmetered routes retain normal experiment sampling gates"

# Jev may pick a lane rule: the lane resolves exactly as with --lane.
cp "$TEMPLATE" "$RULES"
lane_quota claude=-0.3 codex=0.2 grok=-0.5 agy=0.4 devin=-0.1 kiro=-0.6
jq -n '{model: "jev-1.13.0", usage: {input_tokens: 9, output_tokens: 3},
  answers: {rule: {type: "choice", choice: "rule_6", confidence: 0.92,
    probabilities: ({default: 0.01, rule_1: 0.01, rule_2: 0.01, rule_3: 0.01, rule_4: 0.01, rule_5: 0.01, rule_6: 0.93, rule_7: 0.01, rule_8: 0})}}}' > "$RESPONSE"
reset_log
TYPESAFE_API_KEY=$KEY run_lane code out err "$BRIEF" --project xo
assert_contains "$out" 'confidence: 0.92' "the Choice answer is still reported"
assert_contains "$out" 'lane: scoped  order=pool' "a picked lane rule resolves its classes"
assert_contains "$out" "profile: --harness 'agy' --model 'gemini-3.8-flash-high'" "the picked lane chooses its route in code"
jq '.body = 1' "$LOG/body" >/dev/null 2>&1 || fail "the lane path still sent one Choice request"
pass "a lane rule chosen by the Choice answer resolves like a named lane"

# A second opinion on a profile rule escalates: it has no families to exclude.
printf '{"classes":{"x":{"family":"gpt","routes":[{"harness":"codex"}]}},"rules":[{"when":"Coding","use":{"harness":"claude"}}]}\n' > "$RULES"
jq -n '{model: "jev-1.13.0", answers: {rule: {type: "choice", choice: "rule_1", confidence: 0.9, probabilities: {rule_1: 0.9, default: 0.1}}}}' > "$RESPONSE"
lane_quota claude=0.3
TYPESAFE_API_KEY=$KEY run_lane code out err "$BRIEF" --exclude-family gpt
assert_contains "$out" 'status: escalate' "a second opinion on a profile rule escalates"
assert_contains "$out" 'a second opinion needs a lane whose classes declare model families' "the escalation explains why"
pass "a second opinion needs a lane"

# Usage and configuration errors stay actionable.
cp "$TEMPLATE" "$RULES"
run_lane code out err "$BRIEF" --lane nope
expect_code 2 "$code" "an unknown lane is a usage error"
assert_contains "$err" 'unknown lane: nope' "the unknown lane is named"
jq '.classes["muse-spark"].unmetered = "yes"' "$TEMPLATE" > "$RULES"
run_lane code out err "$BRIEF" --lane bulk
expect_code 2 "$code" "an invalid unmetered class value is refused"
assert_contains "$err" 'class unmetered must be a boolean' "the unmetered type error is explicit"
for bad_priority in '"5"' null true '{}' '[]' 1e309; do
  jq --argjson priority "$bad_priority" '.classes["muse-spark"].spend_priority = $priority' "$TEMPLATE" > "$RULES"
  run_lane code out err "$BRIEF" --lane bulk
  expect_code 2 "$code" "invalid spend_priority $bad_priority is refused"
  assert_contains "$err" 'class spend_priority must be a finite number' "the spend_priority type error is explicit"
done
for metered_flag in false null; do
  jq --argjson flag "$metered_flag" '.classes["muse-spark"].unmetered = $flag |
    (if $flag == null then del(.classes["muse-spark"].unmetered) else . end) |
    .classes["muse-spark"].spend_priority = 5' "$TEMPLATE" > "$RULES"
  run_lane code out err "$BRIEF" --lane bulk
  expect_code 2 "$code" "spend_priority without unmetered true is refused"
  assert_contains "$err" 'class spend_priority requires unmetered: true' "the unmetered requirement is explicit"
done
jq '.classes["muse-spark"].routes[0].spend_priority = 5' "$TEMPLATE" > "$RULES"
run_lane code out err "$BRIEF" --lane bulk
expect_code 2 "$code" "spend_priority on a route is refused"
assert_contains "$err" 'spend_priority belongs on the class, not on a route' "the priority belongs to the class"
for profile_config in '{"rules":[{"when":"Coding","use":{"harness":"codex","spend_priority":5}}]}' '{"default":{"harness":"codex","spend_priority":5}}'; do
  printf '%s\n' "$profile_config" > "$RULES"
  TYPESAFE_API_KEY=$KEY run_lane code out err "$BRIEF"
  expect_code 2 "$code" "spend_priority on an ordinary profile is refused"
  assert_contains "$err" 'spend_priority must be declared on a lane class, not a profile' "the priority is lane-only"
done
jq '.classes["muse-spark"].routes[0].floor = {scope:"all_models", min_percent:50}' "$TEMPLATE" > "$RULES"
run_lane code out err "$BRIEF" --lane bulk
expect_code 2 "$code" "an unmetered class cannot declare a quota floor"
assert_contains "$err" 'an unmetered class route must not have a quota floor' "the incompatible floor is named"
jq '.classes["muse-spark"].routes[0].unmetered = true' "$TEMPLATE" > "$RULES"
run_lane code out err "$BRIEF" --lane bulk
expect_code 2 "$code" "unmetered must be declared on a class, not its route"
assert_contains "$err" 'unmetered belongs on the class, not on a route' "the declaration location is explicit"
printf '{"rules":[{"when":"Coding","use":{"harness":"opencode","unmetered":true}}]}\n' > "$RULES"
TYPESAFE_API_KEY=$KEY run_lane code out err "$BRIEF"
expect_code 2 "$code" "an ordinary use profile cannot opt into lane-only unmetered handling"
assert_contains "$err" 'unmetered must be declared on a lane class, not a profile' "the lane-only declaration scope is explicit"
jq '.classes["muse-spark"].routes[0] |= del(.provider)' "$TEMPLATE" > "$RULES"
run_lane code out err "$BRIEF" --lane bulk
expect_code 2 "$code" "a multi-provider class route without provider is refused"
assert_contains "$err" 'class muse-spark profiles whose harness lacks one authoritative provider family require provider: opencode' "the class is named"
jq '.rules[0].classes += ["missing-class"]' "$TEMPLATE" > "$RULES"
run_lane code out err "$BRIEF" --lane judgment
expect_code 2 "$code" "an undeclared class is a configuration error"
assert_contains "$err" 'lane names an undeclared class: missing-class' "the undeclared class is named"
jq '.classes["grok-high"].routes[0].effort = "xhigh"' "$TEMPLATE" > "$RULES"
run_lane code out err "$BRIEF" --lane standard
expect_code 2 "$code" "an unsupported class route effort is refused"
assert_contains "$err" 'each class route effort must be supported by its harness and model' "the route effort error is explicit"
rm -f "$RULES"
run_lane code out err "$BRIEF" --lane standard
expect_code 2 "$code" "--lane without a rules file is a usage error"
pass "lane usage and configuration errors exit 2 with an actionable reason"
cp "$BASE_RULES" "$RULES"

# --- installed-tool eligibility gate -------------------------------------------
# Dispatch configuration is identical across homes while installed tools are
# not, so every resolve probes each configured harness's launch locations from
# the single-owner table bin/fm-control-lib.sh maps it to: a bare name on PATH,
# or an absolute resolver fallback path such as Kimi's ~/.kimi-code/bin.
# NO_TOOL_BIN is this host's whole toolchain with every launch location of the
# gated harnesses absent (kiro-cli and cursor-agent, plus kimi, rovo, and
# cursor's legacy agent alias so a host install cannot leak in), plus the
# FAKEBIN catalog fakes, so a resolve still runs end to end without the
# network. The empty gate HOME carries no fallback paths; the fallback gate
# HOME installs kimi, rovo, and cursor only at their resolver fallback paths.
GATE_HOME_EMPTY="$TMP_ROOT/gate-home-empty"
GATE_HOME_FALLBACK="$TMP_ROOT/gate-home-fallback"
ALIAS_BIN="$TMP_ROOT/gate-alias-bin"
mkdir -p "$GATE_HOME_EMPTY" "$ALIAS_BIN" \
  "$GATE_HOME_FALLBACK/.kimi-code/bin" "$GATE_HOME_FALLBACK/.local/bin"
fm_fake_exit0 "$GATE_HOME_FALLBACK/.kimi-code/bin" kimi
fm_fake_exit0 "$GATE_HOME_FALLBACK/.local/bin" rovo cursor-agent
fm_fake_exit0 "$ALIAS_BIN" agent
NO_TOOL_BIN="$TMP_ROOT/no-tool-bin"
mkdir -p "$NO_TOOL_BIN"
for stub in "$FAKEBIN"/*; do
  case "${stub##*/}" in kiro-cli | cursor-agent | kimi | rovo) continue ;; esac
  ln -s "$stub" "$NO_TOOL_BIN/${stub##*/}"
done
while IFS= read -r tool_dir; do
  [ -d "$tool_dir" ] || continue
  for entry in "$tool_dir"/*; do
    [ -f "$entry" ] && [ -x "$entry" ] || continue
    case "${entry##*/}" in kiro-cli | cursor-agent | kimi | rovo | agent) continue ;; esac
    [ -e "$NO_TOOL_BIN/${entry##*/}" ] || ln -s "$entry" "$NO_TOOL_BIN/${entry##*/}" 2>/dev/null || true
  done
done <<<"${BASE_PATH//:/$'\n'}"
run_without_tool() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$NO_TOOL_BIN" HOME="$GATE_HOME_EMPTY" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="$KEY" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}
run_gate_case() {  # <path> <home> <exit-var> <out-var> <err-var> [args...]
  local __path=$1 __home=$2 __exit=$3 __out=$4 __err=$5 _out _code
  shift 5
  _out=$(PATH="$__path" HOME="$__home" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="$KEY" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}
run_lane_without_tool() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$NO_TOOL_BIN" HOME="$GATE_HOME_EMPTY" FM_HOME="$HOME_DIR" CODEX_HOME="$LANE_CODEX_HOME" \
    QUOTA_AXI_FIXTURE="$LANE_QUOTA" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}
printf '%s\n' '{"model":"jev","answers":{"rule":{"type":"choice","choice":"rule_1","confidence":0.95,"probabilities":{"rule_1":0.99,"default":0.01}}},"usage":{"input_tokens":10,"output_tokens":5}}' > "$RESPONSE"
# A kiro route beside an installed one: the installed route is chosen and the
# kiro route keeps its evidence with the not-eligible reason.
printf '%s\n' '{"rules":[{"when":"Kiro work","use":[{"harness":"kiro","model":"auto"},{"harness":"claude","model":"sonnet"}]}]}' > "$RULES"
run_without_tool code out err "$BRIEF"
expect_code 0 "$code" "a host without kiro-cli still resolves"
assert_contains "$out" 'candidate: kiro:auto  -> not eligible: kiro tool not installed on this host' "a route whose tool is absent is not eligible with its reason"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet'" "the installed route is chosen without any fallback mechanism"
# The same configuration on a host with the executable keeps the route
# eligible: the gate reads host state, never the configuration.
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: kiro:auto' "the kiro route is still listed with its evidence"
assert_not_contains "$out" 'kiro tool not installed' "an installed executable keeps its route eligible"
# A single-route rule whose tool is absent keeps the ordinary escalate result.
printf '%s\n' '{"rules":[{"when":"Kiro work","use":{"harness":"kiro","model":"auto"}}]}' > "$RULES"
run_without_tool code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "an all-ineligible outcome escalates"
assert_contains "$out" '  reason: no rankable eligible candidate' "the escalate reason is unchanged"
assert_not_contains "$out" '  profile:' "an all-ineligible outcome emits no profile"
# cursor proves the name exception in the same owner: absent everywhere it is
# not eligible, and an installation only at its ~/.local/bin fallback - which
# fm_cursor_resolve_binary verifies and launches - stays eligible.
printf '%s\n' '{"rules":[{"when":"Cursor work","use":[{"harness":"cursor","model":"cursor-grok-4.6-medium"},{"harness":"claude","model":"sonnet"}]}]}' > "$RULES"
run_without_tool code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  -> not eligible: cursor tool not installed on this host' "cursor is gated when no launch location exists"
run_gate_case "$NO_TOOL_BIN" "$GATE_HOME_FALLBACK" code out err "$BRIEF"
expect_code 0 "$code" "a cursor installed only at its fallback path still resolves"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor' "the fallback-installed cursor route keeps its evidence"
assert_not_contains "$out" 'cursor tool not installed' "a resolver fallback install keeps the route eligible"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the fallback-installed route ranks and wins"
# The legacy agent alias on PATH is a launch location too: spawn accepts it
# after verifying identity, so the gate must not exclude it.
run_gate_case "$NO_TOOL_BIN:$ALIAS_BIN" "$GATE_HOME_EMPTY" code out err "$BRIEF"
assert_not_contains "$out" 'cursor tool not installed' "cursor's legacy agent alias on PATH keeps the route eligible"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the alias-installed route ranks and wins"
# kimi and rovo accept the same fallback locations their spawn resolvers do.
printf '%s\n' '{"rules":[{"when":"Kimi work","use":[{"harness":"kimi","model":"kimi-code/k3"},{"harness":"claude","model":"sonnet"}]}]}' > "$RULES"
run_gate_case "$NO_TOOL_BIN" "$GATE_HOME_FALLBACK" code out err "$BRIEF"
assert_not_contains "$out" 'kimi tool not installed' "a kimi installed only at ~/.kimi-code/bin stays eligible"
assert_contains "$out" 'candidate: kimi:kimi-code/k3  provider=kimi  -> eligible, unranked' "the fallback-installed kimi route keeps its evidence"
run_without_tool code out err "$BRIEF"
assert_contains "$out" 'candidate: kimi:kimi-code/k3  -> not eligible: kimi tool not installed on this host' "a kimi with no launch location anywhere is not eligible"
printf '%s\n' '{"rules":[{"when":"Rovo work","use":[{"harness":"rovo","model":"auto","provider":"rovo"},{"harness":"claude","model":"sonnet"}]}]}' > "$RULES"
run_gate_case "$NO_TOOL_BIN" "$GATE_HOME_FALLBACK" code out err "$BRIEF"
assert_not_contains "$out" 'rovo tool not installed' "a rovo installed only at ~/.local/bin stays eligible"
run_without_tool code out err "$BRIEF"
assert_contains "$out" 'candidate: rovo:auto  -> not eligible: rovo tool not installed on this host' "a rovo with no launch location anywhere is not eligible"
# A launch location counts only when it resolves to an executable file, the
# requirement bin/fm-spawn.sh's resolvers enforce: an exported function of the
# launch name is present to command -v but is not the tool, and spawn would
# refuse the launch, so the gate must not count the route installed.
printf '%s\n' '{"rules":[{"when":"Kimi work","use":[{"harness":"kimi","model":"kimi-code/k3"},{"harness":"claude","model":"sonnet"}]}]}' > "$RULES"
# shellcheck disable=SC2329 # Exported for indirect use by the resolver under test.
kimi() { :; }
export -f kimi
run_without_tool code out err "$BRIEF"
assert_contains "$out" 'candidate: kimi:kimi-code/k3  -> not eligible: kimi tool not installed on this host' "an exported function of the launch name is not an installed tool"
unset -f kimi
# The same rules with the real executable on PATH stay eligible, so the
# executable check does not reject a genuine install.
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: kimi:kimi-code/k3  provider=kimi  -> eligible' "a real PATH executable keeps the route eligible"
assert_not_contains "$out" 'kimi tool not installed' "the executable check does not reject a genuine install"
# The gate also covers lane class routes.
lane_quota kiro=-0.6 codex=0.2
printf '%s\n' '{"rules":[{"when":"Lane work","lane":"mix","order":"pool","classes":["k","c"]}],"classes":{"k":{"family":"kiro","routes":[{"harness":"kiro","model":"auto"}]},"c":{"family":"gpt","routes":[{"harness":"codex","model":"gpt-5"}]}}}' > "$RULES"
run_lane_without_tool code out err "$BRIEF" --lane mix
expect_code 0 "$code" "a lane resolve on a host without kiro-cli exits 0"
assert_contains "$out" 'class=k family=kiro  -> not eligible: kiro tool not installed on this host' "a lane route whose tool is absent is not eligible"
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-5'" "the lane ranks its installed route"
cp "$BASE_RULES" "$RULES"
write_response "$RESPONSE" rule_4 0.9
pass "an installed-tool gate marks routes with no launch location not eligible, keeps fallback-installed harnesses eligible, and all-ineligible outcomes escalate"

# Kiro shares the full effort vocabulary and its native provider is inferred.
jq -n '{model:"jev-1.13.0",answers:{rule:{type:"choice",choice:"rule_1",confidence:0.99,probabilities:{rule_1:0.99,default:0.01}}}}' > "$RESPONSE"
jq '.providers += [{provider:"kiro",state:{status:"fresh"},quotaSemantics:{status:"known",effectiveAvailability:[{scope:"all_models",status:"known",effectivePercentRemaining:80,runway:{status:"through_reset"},selection:{status:"known",spendPriority:0.5}}]}}]' "$QUOTA" > "$QUOTA.kiro"
mv "$QUOTA.kiro" "$QUOTA"
for effort in low medium high xhigh max; do
  printf '{"rules":[{"when":"Kiro work","use":{"harness":"kiro","model":"auto","effort":"%s"}}]}\n' "$effort" > "$RULES"
  reset_log
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 0 "$code" "native Kiro accepts effort $effort without an explicit provider"
  assert_contains "$out" "  profile: --harness 'kiro' --model 'auto' --effort '$effort'" "Kiro profile axes survive resolution"
done
printf '{"rules":[{"when":"Kiro work","use":{"harness":"kiro","model":"auto","effort":"ultra"}}]}\n' > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "native Kiro refuses ultra effort"
assert_contains "$err" 'each use profile effort must be supported by its harness and model' "Kiro refusal identifies an unsupported profile effort"
cp "$BASE_RULES" "$RULES"
pass "native Kiro provider inference and effort validation agree with bootstrap"

# --- quota planning overrides: expiring rolling horizon -----------------------
# A planning override recomputes nothing from raw windows: it truncates the
# one bounding window's published pace horizon at snapshot time plus the
# configured horizon, capped at the vendor reset, and ranks by the resulting
# selected metric. Native evidence stays printed beside it.
PLANNING="$HOME_DIR/config/quota-planning.json"
cat > "$RULES" <<'JSON'
{"classes":{
  "sol":{"family":"gpt","routes":[{"harness":"codex","model":"gpt-6.1-sol","provider":"codex"}]},
  "alt":{"family":"other","routes":[{"harness":"cursor","model":"cursor-grok-4.6-medium","provider":"cursor"}]},
  "solpi":{"family":"gpt","routes":[{"harness":"pi","model":"codex-native/gpt-6.1-sol","provider":"codex"}]},
  "workpi":{"family":"gpt","routes":[{"harness":"pi","model":"openai-codex-work/gpt-6.1-sol","provider":"codex"}]},
  "devinpaid":{"family":"gpt","routes":[{"harness":"devin","model":"gpt-6-1-sol-max","provider":"devin"}]}},
 "rules":[
  {"when":"Plan","lane":"plan","order":"pool","classes":["sol","alt"]},
  {"when":"Plan pi","lane":"planpi","order":"pool","classes":["solpi","alt"]},
  {"when":"Plan work","lane":"planwork","order":"pool","classes":["workpi","alt"]},
  {"when":"Plan devin","lane":"plandevin","order":"pool","classes":["devinpaid","alt"]}]}
JSON
plan_quota() {  # <generatedAt> <codex-effective-json> <codex-windows-json>
  cat > "$LANE_QUOTA" <<JSON
{"generatedAt":"$1","schemaVersion":5,"providers":[
 {"provider":"codex","accountKeys":["codex-home"],"state":{"status":"fresh"},"windows":$3,
  "quotaSemantics":{"status":"known","effectiveAvailability":[$2]}},
 {"provider":"cursor","state":{"status":"fresh"},"quotaSemantics":{"status":"known","effectiveAvailability":[
  {"scope":"all_models","status":"known","effectivePercentRemaining":91,"runway":{"status":"through_reset"},"selection":{"status":"known","spendPriority":-0.8}}]}},
 {"provider":"devin","state":{"status":"fresh"},"quotaSemantics":{"status":"known","effectiveAvailability":[
  {"scope":"included_quota","status":"known","effectivePercentRemaining":87,"runway":{"status":"through_reset"},"selection":{"status":"known","spendPriority":-0.5}}]}}]}
JSON
}
PLAN_CODEX_ROW='{"scope":"all_models","status":"known","effectivePercentRemaining":71,"boundedBy":["weekly"],"limitingWindowIds":["weekly"],"pace":{"status":"ahead","worstReservePercentPoints":-14.7143},"runway":{"status":"projected_exhaustion","usableRunwaySeconds":200000},"selection":{"status":"known","spendPriority":-1.2017}}'
PLAN_CODEX_WINDOWS='[{"id":"weekly","resetsAt":"2026-10-29T00:00:00Z","percentRemaining":71,"pace":{"status":"ahead","reservePercentPoints":-14.7143,"burnMultiple":2.03}}]'
rm -f "$PLANNING"
plan_quota '2026-10-23T00:00:00Z' "$PLAN_CODEX_ROW" "$PLAN_CODEX_WINDOWS"
run_lane code out err "$BRIEF" --lane plan --project xo
expect_code 0 "$code" "planning baseline without config exits 0: $err"
assert_contains "$out" "profile: --harness 'cursor'" "without a planning override the native spendPriority ranks cursor first"
assert_contains "$out" 'spendPriority=-1.2017' "without a planning override the native Codex spendPriority is printed"
assert_not_contains "$out" 'planning:' "absent planning config prints no planning line"

cat > "$PLANNING" <<'JSON'
{"overrides":[{"provider":"codex","accountKey":"codex-home","windowId":"weekly","horizonSeconds":302400,"expiresAt":"2026-11-01T04:00:00Z"}]}
JSON
run_lane code out err "$BRIEF" --lane plan --project xo
expect_code 0 "$code" "active planning override exits 0: $err"
assert_contains "$out" 'planning: active provider=codex account=codex-home window=weekly horizon_seconds=302400 expires_at=2026-11-01T04:00:00Z' "an active planning override is inspectable"
assert_contains "$out" 'spendPriority=-0.61' "the planning horizon raises the Codex spendPriority from the native pace"
assert_contains "$out" 'native_spendPriority=-1.2017' "the native spendPriority stays visible beside the planning value"
assert_contains "$out" "profile: --harness 'codex'" "the planning value visibly favours the direct Codex route on identical input"
planning_first=$out
run_lane code out err "$BRIEF" --lane plan --project xo
assert_equals "$planning_first" "$out" "a repeated intake after restart reproduces the planning result with no state"

# On a pressure snapshot the same horizon adjusts spendPressure, using the
# producer's steady full-utilization burn of 1 instead of the observed burn.
plan_pressure() {  # <generatedAt> <codex-effective-json> <codex-windows-json>
  plan_quota "$@"
  jq '(.providers[].quotaSemantics.effectiveAvailability[].selection) |= (if .status == "known" then .spendPressure = 0.1 else . end) |
      (.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability[].selection) |= (if .status == "known" then .spendPressure = -0.1717 else . end)' "$LANE_QUOTA" > "$TMP_ROOT/planning-pressure.json"
  mv "$TMP_ROOT/planning-pressure.json" "$LANE_QUOTA"
}
PLAN_CODEX_PRESSURE_WINDOWS_MULTI='[{"id":"weekly","resetsAt":"2026-10-29T00:00:00Z","percentRemaining":71,"pace":{"status":"ahead","reservePercentPoints":-14.7143,"burnMultiple":2.03}},{"id":"five_hour","resetsAt":"2026-10-23T05:00:00Z","percentRemaining":50,"pace":{"status":"ahead","reservePercentPoints":-10,"burnMultiple":1.5}}]'
plan_pressure '2026-10-23T00:00:00Z' "$PLAN_CODEX_ROW" "$PLAN_CODEX_WINDOWS"
run_lane code out err "$BRIEF" --lane plan --project xo
expect_code 0 "$code" "active planning override on a pressure snapshot exits 0: $err"
assert_contains "$out" 'spend_metric: spendPressure' "the pressure snapshot selects spendPressure"
assert_contains "$out" 'planning: active provider=codex account=codex-home window=weekly horizon_seconds=302400 expires_at=2026-11-01T04:00:00Z' "an active override is disclosed on a pressure snapshot"
assert_contains "$out" 'spendPressure=0.42' "the planning horizon raises the Codex spendPressure with a steady burn of 1"
assert_contains "$out" 'native_spendPressure=-0.1717' "the native spendPressure stays visible beside the planning value"
assert_contains "$out" 'planning_horizon_seconds=302400' "the pressure planning horizon is printed beside the value"
assert_not_contains "$out" 'native_spendPriority=' "pressure candidates carry pressure planning evidence only"
assert_contains "$out" "profile: --harness 'codex'" "the planning pressure favours the direct Codex route on identical input"

plan_pressure '2026-10-23T00:00:00Z' "$PLAN_CODEX_ROW" '[{"id":"weekly","resetsAt":"2026-10-29T00:00:00Z","percentRemaining":71,"pace":{"status":"ahead","reservePercentPoints":-14.7143}}]'
run_lane code out err "$BRIEF" --lane plan --project xo
assert_contains "$out" 'spendPressure=0.42' "planning spendPressure needs no observed burn"

plan_pressure '2026-11-01T04:00:00Z' "$PLAN_CODEX_ROW" "$PLAN_CODEX_WINDOWS"
run_lane code out err "$BRIEF" --lane plan --project xo
assert_contains "$out" 'planning: inactive (no override active at the quota snapshot time; native spendPressure used)' "an expired override is inactive on a pressure snapshot"
assert_contains "$out" 'spendPressure=-0.1717' "an expired override leaves the native spendPressure"
assert_not_contains "$out" 'native_spendPressure=' "an expired override prints no planning pressure"
assert_contains "$out" "profile: --harness 'cursor'" "native pressure ranking returns after expiry"

plan_pressure '2026-10-23T00:00:00Z' "$PLAN_CODEX_ROW" "$PLAN_CODEX_WINDOWS"
run_lane code out err "$BRIEF" --lane planwork --project xo
assert_contains "$out" 'spendPressure=-0.1717' "a different account lane keeps the native spendPressure"
assert_not_contains "$out" 'native_spendPressure=' "a different account lane is never pressure-adjusted"

plan_pressure '2026-10-23T00:00:00Z' '{"scope":"all_models","status":"known","effectivePercentRemaining":71,"boundedBy":["weekly","five_hour"],"limitingWindowIds":["weekly","five_hour"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":200000},"selection":{"status":"known","spendPriority":-1.2017}}' "$PLAN_CODEX_PRESSURE_WINDOWS_MULTI"
run_lane code out err "$BRIEF" --lane plan --project xo
assert_contains "$out" 'spendPressure=-0.1717' "a multi-window scope keeps the native spendPressure"
assert_not_contains "$out" 'native_spendPressure=' "multi-window scopes are never pressure-adjusted from one window"

plan_pressure '2026-10-23T00:00:00Z' "$PLAN_CODEX_ROW" '[{"id":"weekly","resetsAt":"2026-10-29T00:00:00Z","percentRemaining":71,"pace":{"status":"unknown"}}]'
run_lane code out err "$BRIEF" --lane plan --project xo
assert_contains "$out" 'spendPressure=-0.1717' "unknown pace keeps the native spendPressure"
assert_not_contains "$out" 'native_spendPressure=' "unknown pace is never pressure-adjusted"

plan_pressure '2026-10-23T00:00:00Z' "$PLAN_CODEX_ROW" "$PLAN_CODEX_WINDOWS"
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability[].selection) |= del(.spendPressure)' "$LANE_QUOTA" > "$TMP_ROOT/planning-pressure.json" && mv "$TMP_ROOT/planning-pressure.json" "$LANE_QUOTA"
run_lane code out err "$BRIEF" --lane plan --project xo
assert_contains "$out" 'eligible, unranked: spendPressure missing' "planning cannot fill in a missing pressure score"
assert_contains "$out" "profile: --harness 'cursor'" "a missing pressure score never falls back to a planning value"

plan_quota '2026-11-01T04:00:00Z' "$PLAN_CODEX_ROW" "$PLAN_CODEX_WINDOWS"
run_lane code out err "$BRIEF" --lane plan --project xo
assert_contains "$out" "profile: --harness 'cursor'" "at the expiry instant the planning override is inactive and native ranking returns"
assert_contains "$out" 'planning: inactive' "expired planning is named as inactive rather than applied"
assert_not_contains "$out" 'native_spendPriority=' "expired planning prints no adjusted candidate value"
plan_quota '2026-11-02T00:00:00Z' "$PLAN_CODEX_ROW" "$PLAN_CODEX_WINDOWS"
run_lane code out err "$BRIEF" --lane plan --project xo
assert_contains "$out" "profile: --harness 'cursor'" "after expiry the planning override stays inactive"

plan_quota '2026-10-23T00:00:00Z' "$PLAN_CODEX_ROW" "$PLAN_CODEX_WINDOWS"
run_lane code out err "$BRIEF" --lane planpi --project xo
assert_contains "$out" 'spendPriority=-0.61' "a Pi codex-native route on the same subscription account receives the planning value"
run_lane code out err "$BRIEF" --lane planwork --project xo
assert_contains "$out" 'spendPriority=-1.2017' "a Pi route on a different account lane keeps the native value"
assert_not_contains "$out" 'native_spendPriority=' "a different account lane is never planning-adjusted by model name"
run_lane code out err "$BRIEF" --lane plandevin --project xo
assert_contains "$out" 'candidate: devin:gpt-6-1-sol-max  class=devinpaid family=gpt  provider=devin  scope=included_quota  remaining=87%  spendPriority=-0.5' "a Devin route keeps its native value under a Codex planning override"
assert_not_contains "$out" 'native_spendPriority=' "no non-Codex route is planning-adjusted"

plan_quota '2026-10-23T00:00:00Z' '{"scope":"all_models","status":"known","effectivePercentRemaining":0,"boundedBy":["weekly"],"limitingWindowIds":["weekly"],"runway":{"status":"exhausted_now","usableRunwaySeconds":0},"selection":{"status":"known","spendPriority":-5}}' "$PLAN_CODEX_WINDOWS"
run_lane code out err "$BRIEF" --lane plan --project xo
assert_contains "$out" 'runway exhausted_now at all_models' "planning never revives an exhausted Codex window"
assert_contains "$out" "profile: --harness 'cursor'" "an exhausted Codex route stays ineligible under planning"

plan_quota '2026-10-23T00:00:00Z' '{"scope":"all_models","status":"known","effectivePercentRemaining":71,"boundedBy":["weekly"],"limitingWindowIds":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":200000},"selection":{"status":"unknown"}}' "$PLAN_CODEX_WINDOWS"
run_lane code out err "$BRIEF" --lane plan --project xo
assert_contains "$out" 'eligible, unranked: spendPriority missing' "planning never turns unknown spendPriority into a healthy value"
assert_not_contains "$out" 'native_spendPriority=' "unknown spendPriority is never planning-adjusted"

plan_quota '2026-10-23T00:00:00Z' '{"scope":"all_models","status":"known","effectivePercentRemaining":71,"boundedBy":["weekly","five_hour"],"limitingWindowIds":["weekly","five_hour"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":200000},"selection":{"status":"known","spendPriority":-1.2017}}' '[{"id":"weekly","resetsAt":"2026-10-29T00:00:00Z","percentRemaining":71,"pace":{"status":"ahead","reservePercentPoints":-14.7143,"burnMultiple":2.03}},{"id":"five_hour","resetsAt":"2026-10-23T05:00:00Z","percentRemaining":50,"pace":{"status":"ahead","reservePercentPoints":-10,"burnMultiple":1.5}}]'
run_lane code out err "$BRIEF" --lane plan --project xo
assert_contains "$out" 'spendPriority=-1.2017' "a scope bounded by a short window beside the weekly window keeps the native value"
assert_not_contains "$out" 'native_spendPriority=' "multi-window scopes are never planning-adjusted from one window"

# The limiting scope is re-evaluated after planning: an unchanged second
# bound still caps the route even when the weekly bound rises.
plan_quota '2026-10-23T00:00:00Z' "$PLAN_CODEX_ROW,{\"scope\":\"model:gpt-6.1-sol\",\"status\":\"known\",\"effectivePercentRemaining\":60,\"boundedBy\":[\"weekly\",\"five_hour\"],\"limitingWindowIds\":[\"weekly\",\"five_hour\"],\"runway\":{\"status\":\"projected_exhaustion\",\"usableRunwaySeconds\":200000},\"selection\":{\"status\":\"known\",\"spendPriority\":-1}}" '[{"id":"weekly","resetsAt":"2026-10-29T00:00:00Z","percentRemaining":71,"pace":{"status":"ahead","reservePercentPoints":-14.7143,"burnMultiple":2.03}},{"id":"five_hour","resetsAt":"2026-10-23T05:00:00Z","percentRemaining":50,"pace":{"status":"ahead","reservePercentPoints":-10,"burnMultiple":1.5}}]'
run_lane code out err "$BRIEF" --lane plan --project xo
assert_contains "$out" 'scope=model:gpt-6.1-sol  remaining=60%  spendPriority=-1' "an unchanged bound still limits the route after the weekly bound is planning-adjusted"
assert_contains "$out" "profile: --harness 'cursor'" "the re-evaluated limiting bound keeps the competitor first"
assert_not_contains "$out" 'native_spendPriority=' "a route limited by an unchanged bound prints no planning value"

# Window matching happens before an override is selected: a window-specific
# entry wins over an earlier generic or wrong-window entry.
plan_quota '2026-10-23T00:00:00Z' "$PLAN_CODEX_ROW" "$PLAN_CODEX_WINDOWS"
cat > "$PLANNING" <<'JSON'
{"overrides":[
 {"provider":"codex","accountKey":"codex-home","windowId":"five_hour","horizonSeconds":302400,"expiresAt":"2026-11-01T04:00:00Z"},
 {"provider":"codex","accountKey":"codex-home","windowId":"weekly","horizonSeconds":302400,"expiresAt":"2026-11-01T04:00:00Z"}]}
JSON
run_lane code out err "$BRIEF" --lane plan --project xo
assert_contains "$out" 'spendPriority=-0.61' "the weekly override applies even when a wrong-window override is listed first"
cat > "$PLANNING" <<'JSON'
{"overrides":[
 {"provider":"codex","accountKey":"codex-home","horizonSeconds":86400,"expiresAt":"2026-11-01T04:00:00Z"},
 {"provider":"codex","accountKey":"codex-home","windowId":"weekly","horizonSeconds":302400,"expiresAt":"2026-11-01T04:00:00Z"}]}
JSON
run_lane code out err "$BRIEF" --lane plan --project xo
assert_contains "$out" 'spendPriority=-0.61' "a window-specific override takes precedence over an earlier generic override"
assert_not_contains "$out" 'spendPriority=2.94' "the generic override horizon never applies beside a window-specific one"
cat > "$PLANNING" <<'JSON'
{"overrides":[{"provider":"codex","accountKey":"codex-home","windowId":"weekly","horizonSeconds":302400,"expiresAt":"2026-11-01T04:00:00Z"}]}
JSON

# Account membership must be published: an unproven lane keeps native
# ranking, and a lane-less candidate resolves instead of erroring in jq.
jq 'del(.providers[0].accountKeys)' "$LANE_QUOTA" > "$TMP_ROOT/plan-no-keys.json" && mv "$TMP_ROOT/plan-no-keys.json" "$LANE_QUOTA"
run_lane code out err "$BRIEF" --lane plan --project xo
expect_code 0 "$code" "unknown account membership still resolves: $err"
assert_contains "$out" 'spendPriority=-1.2017' "a non-default lane without published account membership keeps the native value"
assert_not_contains "$out" 'native_spendPriority=' "unproven account membership is never planning-adjusted"
jq '.classes.soloc = {"family":"gpt","routes":[{"harness":"opencode","model":"gpt-6.1-sol","provider":"codex"}]} | .rules += [{"when":"Plan oc","lane":"planoc","order":"pool","classes":["soloc","alt"]}]' "$RULES" > "$TMP_ROOT/plan-oc-rules.json" && mv "$TMP_ROOT/plan-oc-rules.json" "$RULES"
plan_quota '2026-10-23T00:00:00Z' "$PLAN_CODEX_ROW" "$PLAN_CODEX_WINDOWS"
run_lane code out err "$BRIEF" --lane planoc --project xo
expect_code 0 "$code" "a lane-less Codex candidate resolves under a planning file: $err"
assert_contains "$out" 'spendPriority=-0.61' "a lane-less candidate on the published default account receives the planning value"

printf '%s\n' '{"overrides":[{"accountKey":"codex-home","horizonSeconds":302400,"expiresAt":"2026-11-01T04:00:00Z"}]}' > "$PLANNING"
run_lane code out err "$BRIEF" --lane plan --project xo
expect_code 2 "$code" "an override without provider refuses resolution"
assert_contains "$err" 'malformed planning file' "a missing provider is the documented malformed error"
printf '%s\n' '{"overrides":[{"provider":123,"accountKey":"codex-home","horizonSeconds":302400,"expiresAt":"2026-11-01T04:00:00Z"}]}' > "$PLANNING"
run_lane code out err "$BRIEF" --lane plan --project xo
expect_code 2 "$code" "an override with a non-string provider refuses resolution"
: > "$PLANNING"
run_lane code out err "$BRIEF" --lane plan --project xo
expect_code 2 "$code" "an empty planning file refuses resolution"
assert_contains "$err" 'malformed planning file' "an empty planning file is the documented malformed error"
printf '%s\n%s\n' '{"overrides":[]}' '{"overrides":[]}' > "$PLANNING"
run_lane code out err "$BRIEF" --lane plan --project xo
expect_code 2 "$code" "a planning file with multiple JSON values refuses resolution"

printf '%s\n' '{"overrides":[{"provider":"codex","accountKey":"codex-home","horizonSeconds":-5,"expiresAt":"2026-11-01T04:00:00Z"}]}' > "$PLANNING"
run_lane code out err "$BRIEF" --lane plan --project xo
expect_code 2 "$code" "a malformed planning override refuses resolution"
assert_contains "$err" 'malformed planning file' "malformed planning is an actionable configuration error"
printf '%s' '{' > "$PLANNING"
run_lane code out err "$BRIEF" --lane plan --project xo
expect_code 2 "$code" "unparseable planning config refuses resolution"
rm -f "$PLANNING"
cp "$BASE_RULES" "$RULES"
pass "quota planning overrides favour matched direct Codex routes only while active and never fabricate quota health"

# --- private call history, including early outcomes and write failures -------
HISTORY="$HOME_DIR/state/dispatch-history.jsonl"
# Every completed resolution above should have produced one parseable line;
# all outcome classes and both early error/off paths are already exercised.
jq -se 'all(.[]; .kind == "router" and (.time | type) == "number") and
  ([.[].status] | unique | sort) == ["ambiguous", "clear", "error", "escalate", "off"]' \
  "$HISTORY" >/dev/null || fail "history does not cover all router outcomes: $(jq -sc 'map(.status) | unique' "$HISTORY")"
assert_not_contains "$(cat "$HISTORY")" "$KEY" "history never stores the API key"
assert_not_contains "$(cat "$HISTORY")" 'SECRET-WHY-TEXT' "history omits config commentary"
assert_not_contains "$(cat "$HISTORY")" 'off-by-one in the pager' "history omits brief text"

# Use the standard brief layout and a path needing JSON escaping.
HISTORY_BRIEF="$HOME_DIR/data/history-task/brief \"quoted\".md"
mkdir -p "${HISTORY_BRIEF%/*}"
cp "$BRIEF" "$HISTORY_BRIEF"
write_response "$RESPONSE" rule_4 0.9
before=$(wc -l < "$HISTORY")
TYPESAFE_API_KEY=$KEY run code out err "$HISTORY_BRIEF"
expect_code 0 "$code" "logged clear resolution succeeds"
assert_equals "$((before + 1))" "$(wc -l < "$HISTORY" | tr -d ' ')" "one entry per call"
tail -n 1 "$HISTORY" | jq -e --arg brief "$HISTORY_BRIEF" '
  .task_id == "history-task" and .brief_path == $brief and .status == "clear" and
  .model == "jev-1.13.0" and (.latency_ms | type) == "number" and
  .tokens == {input_tokens: 812, output_tokens: 60} and
  .rule == "rule_4" and .confidence == 0.9 and .probabilities.rule_4 == 0.96 and
  .suggested_profile.harness == "cursor" and .spendMetric == "spendPriority" and
  any(.candidates[]; .route == "cursor:cursor-grok-4.6-medium" and
    .eligibility == "eligible" and .spendPriority == 0.7597)
' >/dev/null || fail "clear history lost score, input pointer or candidates"

# Errors after a valid answer still retain that answer's scores and counts.
TYPESAFE_API_KEY=$KEY FAKE_QUOTA_FAIL=1 run code out err "$HISTORY_BRIEF"
tail -n 1 "$HISTORY" | jq -e '.status == "error" and .rule == "rule_4" and
  .tokens.input_tokens == 812 and .reason == "quota-axi --json failed"' >/dev/null \
  || fail "post-answer errors lost available telemetry"

# A server error body is not trusted history content, even when it echoes a key.
printf '%s' "$KEY" > "$RESPONSE"
TYPESAFE_API_KEY=$KEY FAKE_CURL_HTTP=500 run code out err "$HISTORY_BRIEF"
assert_not_contains "$(tail -n 1 "$HISTORY")" "$KEY" "HTTP body cannot leak keys into history"

# Explicit lane output is deterministic, so compare complete stdout and stderr
# with a working log, an unwritable log destination, and a non-directory state.
printf '%s\n' '{"classes":{"local":{"family":"local","unmetered":true,"routes":[{"harness":"claude","model":"sonnet"}]}},"rules":[{"when":"Routine","lane":"routine","order":"ordered","classes":["local"]}]}' > "$RULES"
run_lane code out err "$HISTORY_BRIEF" --lane routine
expect_code 0 "$code" "baseline named lane succeeds"
baseline_out=$out baseline_err=$err
tail -n 1 "$HISTORY" | jq -e '.lane == "routine" and .candidates[0].class == "local" and
  .candidates[0].spendPriority == 0' >/dev/null || fail "lane history lost the class"
mv "$HISTORY" "$TMP_ROOT/saved-history"
mkdir "$HISTORY"
run_lane code out err "$HISTORY_BRIEF" --lane routine
expect_code 0 "$code" "unwritable history does not fail routing"
assert_equals "$baseline_out" "$out" "failed history write leaves stdout byte-for-byte unchanged"
assert_equals "$baseline_err" "$err" "failed history write stays silent"
rmdir "$HISTORY"
mv "$TMP_ROOT/saved-history" "$HISTORY"
mv "$HOME_DIR/state" "$HOME_DIR/saved-state"
printf 'not a directory\n' > "$HOME_DIR/state"
run_lane code out err "$HISTORY_BRIEF" --lane routine
expect_code 0 "$code" "unusable state directory does not fail routing"
assert_equals "$baseline_out" "$out" "unusable state leaves stdout unchanged"
assert_equals "$baseline_err" "$err" "unusable state leaves stderr unchanged"
# Nonzero configuration exits also survive a logging failure unchanged.
run_lane code out err "$HISTORY_BRIEF" --lane missing
expect_code 2 "$code" "logging failure preserves the configuration-error exit"
rm "$HOME_DIR/state"
mv "$HOME_DIR/saved-state" "$HOME_DIR/state"
good_out='' good_err=''
run_lane code good_out good_err "$HISTORY_BRIEF" --lane missing
expect_code 2 "$code" "working history preserves the configuration-error exit"
assert_equals "$good_out" "$out" "logging cannot alter error stdout"
assert_equals "$good_err" "$err" "logging cannot alter error stderr"
pass "private router history covers every outcome and silently tolerates write failures"
# --- shared-quota opt-out: no quota call, declared-order pick ----------------
cp "$BASE_RULES" "$RULES"
jq '.shared_quota = true' "$BASE_RULES" > "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "shared-quota clear exits 0"
assert_contains "$out" '  status: clear' "shared-quota clear status"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "shared-quota picks the first declared profile, not the argmax winner"
assert_not_contains "$out" 'spendPriority=' "shared-quota prints no quota evidence"
assert_not_contains "$out" '  remaining=' "shared-quota prints no remaining percentages"
assert_not_contains "$out" '  runway=' "shared-quota prints no runway gates"
assert_contains "$out" 'quota ranking off: home declares a single shared quota' "every candidate line states quota ranking is off"
assert_absent "$LOG/quota-axi.calls" "shared-quota never reads quota-axi"
[ "$(printf '%s\n' "$out" | grep -c 'quota ranking off')" -ge 3 ] || fail "shared-quota states the opt-out on every candidate line"
pass "shared-quota opt-out: no quota snapshot, deterministic declared-order pick, opt-out stated on every candidate"

# --- shared-quota: an unmet rule-level floor is bypassed too -----------------
# rule_1 declares floor model:fable >= 20% but the fixture has 15% there, so the
# quota-ranked path would fall through to default; the opt-out keeps the rule.
jq '.shared_quota = true' "$BASE_RULES" > "$RULES"
reset_log
write_response "$RESPONSE" rule_1 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "shared-quota unmet rule floor exits 0"
assert_contains "$out" '  status: clear' "shared-quota unmet rule floor status"
assert_contains "$out" '  note: rule matched' "shared-quota skips the unmet rule floor instead of falling through to default"
assert_not_contains "$out" 'fall through to default' "shared-quota unmet rule floor never falls through to default"
assert_contains "$out" "  profile: --harness 'claude' --model 'fable' --effort 'xhigh'" "shared-quota unmet rule floor picks the rule's own declared profile"
assert_contains "$out" 'quota ranking off: home declares a single shared quota' "unmet rule floor candidate states quota ranking is off"
assert_absent "$LOG/quota-axi.calls" "shared-quota unmet rule floor never reads quota-axi"
pass "shared-quota bypasses an unmet rule-level floor: the rule's own profile wins with no quota call"

# --- shared-quota: an unmet profile-level floor is bypassed too ---------------
# The codex profile declares floor all_models >= 50% but the fixture has 31%, so
# the quota-ranked path marks it not eligible; the opt-out resolves the declared
# order anyway. The use array is reversed so the floored profile is first.
jq '.shared_quota = true | .rules[1].use |= reverse' "$BASE_RULES" > "$RULES"
reset_log
write_response "$RESPONSE" rule_2 0.99
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "shared-quota unmet profile floor exits 0"
assert_contains "$out" '  status: clear' "shared-quota unmet profile floor status"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "shared-quota unmet profile floor picks the floored profile first in declared order"
assert_not_contains "$out" 'not eligible' "shared-quota unmet profile floor marks no candidate ineligible"
assert_contains "$out" 'quota ranking off: home declares a single shared quota' "unmet profile floor candidates state quota ranking is off"
assert_absent "$LOG/quota-axi.calls" "shared-quota unmet profile floor never reads quota-axi"
pass "shared-quota bypasses an unmet profile-level floor: the first declared profile wins with no quota call"

# --- shared-quota: preferred_provider still narrows the pool ------------------
# The matched rule declares claude first, then two codex-family profiles; the
# home prefers codex, so the first declared codex profile wins.
jq '.shared_quota = true | .preferred_provider = "codex" | .rules[3].use = [
  {harness:"claude",model:"sonnet",effort:"high"},
  {harness:"pi",model:"openai-codex/gpt-5.6-sol",provider:"codex"},
  {harness:"codex",model:"gpt-5.6-sol"}]' "$BASE_RULES" > "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "shared-quota preferred_provider exits 0"
assert_contains "$out" '  status: clear' "shared-quota preferred_provider status"
assert_contains "$out" '  preferred_provider: codex: prefer eligible family candidates' "shared-quota still applies the family preference"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" "shared-quota preferred_provider picks the first declared preferred-family profile"
assert_absent "$LOG/quota-axi.calls" "shared-quota preferred_provider never reads quota-axi"
[ "$(printf '%s\n' "$out" | grep -c '^  candidate: ')" -eq 3 ] || fail "shared-quota preferred_provider lists every candidate"
[ "$(printf '%s\n' "$out" | grep '^  candidate: ' | grep -c 'quota ranking off: home declares a single shared quota')" -eq 3 ] ||
  fail "shared-quota preferred_provider states the opt-out on every candidate line"
pass "shared-quota keeps preferred_provider narrowing: the preferred family wins in declared order with no quota call"

# restore the shared response fixture for the false-path test below
write_response "$RESPONSE" rule_4 0.9

# Shared quota composes with lane provider preference and skips quota pace
# gates without dropping class/data eligibility or candidate evidence.
cat > "$RULES" <<'JSON'
{"shared_quota":true,"preferred_provider":"codex","classes":{
 "luna":{"family":"claude","routes":[{"harness":"claude","model":"sonnet"}]},
 "sol":{"family":"gpt","routes":[{"harness":"codex","model":"gpt-6.1-sol"}]}},
 "rules":[{"lane":"shared","when":"Routine work","order":"pool","classes":["luna","sol"]}]}
JSON
reset_log
run_lane code out err "$BRIEF" --lane shared --project example
expect_code 0 "$code" "shared-quota lane resolves"
assert_contains "$out" "profile: --harness 'codex'" "lane preference wins over declared nonpreferred first class"
assert_contains "$out" 'preferred_provider: codex: prefer eligible family candidates' "lane preference is disclosed"
[ "$(printf '%s\n' "$out" | grep -c '^  candidate: ')" -eq 2 ] || fail "preferred lane hid candidate evidence"
assert_absent "$LOG/quota-axi.calls" "shared-quota lane never reads provider quota"
jq '.rules[0].order = "ordered"' "$RULES" > "$TMP_ROOT/shared-lane.json" && mv "$TMP_ROOT/shared-lane.json" "$RULES"
run_lane code out err "$BRIEF" --lane shared --project example
assert_contains "$out" "profile: --harness 'codex'" "ordered lane applies preference before class ordering"

jq 'del(.preferred_provider) | .rules[0].order = "pool" |
 .rules[0].classes = [{class:"luna",gate:"others-ahead-of-pace"},"sol"]' "$RULES" > "$TMP_ROOT/shared-lane.json" && mv "$TMP_ROOT/shared-lane.json" "$RULES"
run_lane code out err "$BRIEF" --lane shared --project example
assert_contains "$out" "profile: --harness 'claude'" "shared-quota lane skips the quota-derived pace gate"
assert_not_contains "$out" 'pace gate closed' "shared quota must not infer a pace gate from absent provider quota"
assert_absent "$LOG/quota-axi.calls" "shared-quota pace bypass never reads quota"

jq '.preferred_provider = "codex" | .data_policies = {restricted:{allow_projects:["other"]}} |
 .classes.sol.data_policy = "restricted"' "$RULES" > "$TMP_ROOT/shared-lane.json" && mv "$TMP_ROOT/shared-lane.json" "$RULES"
run_lane code out err "$BRIEF" --lane shared --project example
assert_contains "$out" "profile: --harness 'claude'" "shared quota retains non-quota data-policy exclusion"
assert_contains "$out" 'preferred_provider: codex: fall back; every matched family candidate is ineligible' "lane preference falls back only on concrete exclusion"
assert_contains "$out" 'not eligible: data policy restricted' "the excluded preferred route remains visible"

jq 'del(.shared_quota,.data_policies,.classes.sol.data_policy) |
 .rules[0].classes = ["luna","sol"]' "$RULES" > "$TMP_ROOT/shared-lane.json" && mv "$TMP_ROOT/shared-lane.json" "$RULES"
lane_quota claude=0.9 codex=0.2
run_lane code out err "$BRIEF" --lane shared --project example
assert_contains "$out" "profile: --harness 'codex'" "metered lanes also narrow the preferred pool before ranking"
lane_quota claude=0.9
run_lane code out err "$BRIEF" --lane shared --project example
assert_contains "$out" 'status: escalate' "an eligible unmeasured preferred lane cannot fall back"
assert_contains "$out" 'uncertainty does not authorize fallback' "preferred-lane uncertainty is disclosed"
assert_not_contains "$out" '  profile:' "unrankable preferred lane must not choose a different family"
pass "shared-quota lanes honor preference, bypass pace gates, and preserve non-quota eligibility"

# --- shared_quota false: byte-for-byte the quota-ranked path ------------------
jq '.shared_quota = false' "$BASE_RULES" > "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "shared_quota false exits 0"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "shared_quota false keeps the spendPriority argmax"
assert_not_contains "$out" 'quota ranking off' "shared_quota false prints no opt-out wording"
[ -f "$LOG/quota-axi.calls" ] || fail "shared_quota false still reads quota-axi"
assert_contains "$out" 'spendPriority=' "shared_quota false prints quota evidence"
pass "shared_quota false keeps the unchanged quota-ranked behavior"
cp "$BASE_RULES" "$RULES"

printf '# all fm-dispatch-resolve tests passed\n'
