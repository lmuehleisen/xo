#!/usr/bin/env bash
# Portable receipt/admission regressions. Synthetic guards exercise the real
# admission executable, lock and atomic publication, never vendor semantics.
# Real native semantics remain covered by the three credentialed live guards.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-admission)
CASE=
CODE=
BINARY=
HOME_DIR=
RECEIPT=

new_case() {
  CASE="$TMP_ROOT/$1"
  CODE="$CASE/code"
  BINARY="$CASE/agy"
  HOME_DIR="$CASE/home"
  mkdir -p "$CODE/tests" "$CODE/.agents" "$HOME_DIR/state"
  cp -R "$ROOT/bin" "$CODE/bin"
  cp "$ROOT/.agents/hooks.json" "$CODE/.agents/"
  cp "$ROOT/tests/"{lib.sh,agy-live-helpers.sh,git-config-helpers.sh,tmproot-guard.sh,fm-agy-native.test.sh,agy-native-terminal-fixture.py} "$CODE/tests/"
  for guard in bypass native observer signals; do
    cat > "$CODE/tests/fm-agy-$guard-live-e2e.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
guard=${0##*/fm-agy-}; guard=${guard%-live-e2e.test.sh}
printf '%s\n' "$guard" >> "$FM_ADMISSION_FIXTURE_LOG"
case "${FM_ADMISSION_FIXTURE_MODE:-}:$guard" in
  fail:bypass) exit 1 ;;
  fail:native) exit 1 ;;
  timeout:bypass) sleep 20 ;;
  incomplete:bypass) exit 0 ;;
  replace:bypass) printf '\n# replacement\n' >> "$FM_AGY_LIVE_BIN" ;;
  integration:bypass) printf '\n# integration change\n' >> "$root/bin/fm-agy-hook.sh" ;;
  slow:bypass) sleep 1 ;;
esac
printf '{"tool":"synthetic-attempt"}\n' > "$FM_AGY_ADMISSION_PROOF_DIR/$guard.log"
python3 "$root/bin/fm-agy-admission.py" complete "$FM_AGY_ADMISSION_PROOF_DIR" "$guard" 0 \
  "$FM_AGY_ADMISSION_PROOF_DIR/$guard.log"
SH
  done
  make_binary "${2:-1.4.4}"
}

make_binary() {
  cat > "$BINARY" <<SH
#!/usr/bin/env bash
[ "\${AGY_CLI_DISABLE_AUTO_UPDATE:-}" = 1 ] || exit 9
if [ "\${1:-}" = --version ]; then printf 'agy %s\\n' '$1'; exit 0; fi
printf '%s\\n' "\$*" >> '$CASE/real-task.log'
SH
  chmod +x "$BINARY"
}

admit() {  # [ensure|manual-baseline] [model]
  local tier=agy judge_model=fixture-judge judge_bin="$BINARY"
  if [ "${1:-}" = ensure-native ]; then tier=native-tmux; judge_model=''; judge_bin=''; fi
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_ADMISSION_FIXTURE_LOG="$CASE/attempts" \
    bash "$CODE/bin/fm-agy-admission.sh" "${1:-ensure}" "$BINARY" "${2-fixture-model}" '' \
    "$tier" "$judge_model" "$judge_bin" 2> "$CASE/admission.stderr"
}

assert_receipt() {
  python3 "$CODE/bin/fm-agy-admission.py" assert "$RECEIPT" "$BINARY" fixture-model '' \
    agy fixture-judge "$BINARY" 2> "$CASE/assert.stderr"
}

attempts() { wc -l < "$CASE/attempts" | tr -d ' '; }

new_case reuse
RECEIPT=$(admit)
[ "$(attempts)" = 3 ] || fail 'cold admission did not run all three guards'
assert_receipt || fail 'complete cold proof did not certify the exact executable/context'
[ "$(admit)" = "$RECEIPT" ] && [ "$(attempts)" = 3 ] || fail 'matching receipt reran guards'
pass 'agy admission: first complete certification and cheap unchanged reuse'

for value in null '[]' '"invalid"' missing; do
  if [ "$value" = missing ]; then
    jq 'del(.binding.context)' "$RECEIPT" > "$CASE/bad-receipt.json"
  else
    jq --argjson value "$value" '.binding.context=$value' "$RECEIPT" > "$CASE/bad-receipt.json"
  fi
  jq '.binding' "$CASE/bad-receipt.json" > "$CASE/bad-binding.json"
  if python3 "$CODE/bin/fm-agy-admission.py" match "$CASE/bad-receipt.json" "$CASE/bad-binding.json" \
    2> "$CASE/bad-context.stderr"; then fail 'malformed context inherited compatibility coverage'; fi
  grep -q 'requires an object context' "$CASE/bad-context.stderr" || fail 'malformed context did not fail with its binding diagnostic'
  ! grep -q Traceback "$CASE/bad-context.stderr" || fail 'malformed context crashed the receipt matcher'
done
pass 'agy admission: malformed and missing context rejects coverage without choosing a legacy fallback'

for corruption in malformed stale permissions symlink incomplete context; do
  case "$corruption" in
    malformed) printf '{bad json\n' > "$RECEIPT" ;;
    stale) jq '.binding.integration="stale"' "$RECEIPT" > "$CASE/changed"; cat "$CASE/changed" > "$RECEIPT" ;;
    permissions) chmod 644 "$RECEIPT" ;;
    symlink) mv "$RECEIPT" "$CASE/saved"; ln -s "$CASE/saved" "$RECEIPT" ;;
    incomplete) jq 'del(.proofs.signals)' "$RECEIPT" > "$CASE/changed"; cat "$CASE/changed" > "$RECEIPT" ;;
    context) jq '.proofs.bypass.context.model="untested"' "$RECEIPT" > "$CASE/changed"; cat "$CASE/changed" > "$RECEIPT" ;;
  esac
  if assert_receipt; then fail "$corruption receipt inherited approval"; fi
  before=$(attempts)
  RECEIPT=$(admit)
  [ "$(attempts)" = "$((before + 3))" ] || fail "$corruption receipt skipped recertification"
done
pass 'agy admission: malformed, stale, untrusted and incomplete receipts never confer approval'

before=$(attempts)
printf '\n# different executable, same version\n' >> "$BINARY"
if assert_receipt; then fail 'same-version binary change inherited proof'; fi
RECEIPT=$(admit)
[ "$(attempts)" = "$((before + 3))" ] || fail 'binary change did not reverify'
before=$(attempts)
printf '\n# changed policy\n' >> "$CODE/bin/fm-agy-permission-policy.sh"
if assert_receipt; then fail 'policy integration change inherited proof'; fi
RECEIPT=$(admit)
[ "$(attempts)" = "$((before + 3))" ] || fail 'integration change did not reverify'
pass 'agy admission: executable and relevant integration changes invalidate evidence'

before=$(attempts)
other_receipt=$(admit ensure different-model)
[ "$other_receipt" != "$RECEIPT" ] && [ "$(attempts)" = "$((before + 3))" ] \
  || fail 'an untested model inherited another model proof'
if python3 "$CODE/bin/fm-agy-admission.py" assert "$RECEIPT" "$BINARY" fixture-model high \
    agy fixture-judge "$BINARY" 2>/dev/null; then fail 'untested effort inherited proof'; fi
if python3 "$CODE/bin/fm-agy-admission.py" assert "$RECEIPT" "$BINARY" fixture-model '' \
    agy other-judge "$BINARY" 2>/dev/null; then fail 'untested judge inherited proof'; fi
if admit ensure ''; then fail 'mutable implicit model was certified'; fi
pass 'agy admission: model, effort and judge contexts are independently bound'

for version in 1.4.4 1.4.6 1.4.99; do
  new_case "eligible-$version" "$version"
  admit >/dev/null || fail "$version candidate was rejected before verification"
  [ "$(attempts)" = 3 ] || fail "$version was admitted without behavioral verification"
done
for version in 1.4.3 1.5.0 2.0.0; do
  new_case "outside-$version" "$version"
  if admit >/dev/null; then fail "$version escaped the candidate-family bound"; fi
  [ ! -e "$CASE/attempts" ] || fail 'outside-family executable reached synthetic prompts'
done
pass 'agy admission: compatible patch bounds are eligibility, never automatic certification'

new_case manual-baseline 1.4.0
if admit >/dev/null; then fail 'historical version text certified an arbitrary binary'; fi
RECEIPT=$(admit manual-baseline)
assert_receipt || fail 'explicitly refreshed manual baseline did not retain its proof'
[ "$(admit)" = "$RECEIPT" ] && [ "$(attempts)" = 3 ] || fail 'unchanged manual baseline did not reuse proof'
printf '\n# arbitrary different baseline binary\n' >> "$BINARY"
if admit >/dev/null; then fail 'different historical binary inherited the manual baseline'; fi
pass 'agy admission: historical manual baseline remains explicit and executable-bound'

for mode in fail timeout incomplete replace integration; do
  new_case "$mode"
  limit=360
  [ "$mode" != timeout ] || limit=1
  if FM_ADMISSION_FIXTURE_MODE="$mode" FM_TEST_AGY_GUARD_SECONDS="$limit" admit >/dev/null; then
    fail "$mode guard path published approval"
  fi
  if compgen -G "$HOME_DIR/state/agy-compatibility/*.json" >/dev/null; then
    fail "$mode left an admissible receipt"
  fi
done
pass 'agy admission: failure, timeout, missing coverage and replacement during proof publish no receipt'

new_case contention
FM_ADMISSION_FIXTURE_MODE=slow admit > "$CASE/first" & first=$!
FM_ADMISSION_FIXTURE_MODE=slow admit > "$CASE/second" & second=$!
wait "$first" || fail 'first competing admission failed'
wait "$second" || fail 'second competing admission failed'
cmp -s "$CASE/first" "$CASE/second" && [ "$(attempts)" = 3 ] \
  || fail 'competing jobs accepted partial proof or duplicated certification'
pass 'agy admission: narrow locking and atomic publication reuse only a complete concurrent proof'

new_case launch-replacement
RECEIPT=$(admit)
prefix=$(bash -c '
  . "$1/bin/fm-agy-lib.sh"
  shell_quote() { printf "%q" "$1"; }
  SCRIPT_DIR="$1/bin" AGY_BYPASS=1 AGY_ADMISSION_RECEIPT="$2" AGY_BIN="$3"
  MODEL=fixture-model EFFORT= AGY_JUDGE_TIER=agy AGY_JUDGE_MODEL=fixture-judge AGY_JUDGE_BIN="$3"
  fm_agy_launch_guard
' _ "$CODE" "$RECEIPT" "$BINARY")
printf '\n# replaced after spawn admission\n' >> "$BINARY"
if bash -c "$prefix env AGY_CLI_DISABLE_AUTO_UPDATE=1 '$BINARY' -i REAL_TASK" >/dev/null 2>&1; then
  fail 'launch assertion accepted a replacement executable'
fi
[ ! -e "$CASE/real-task.log" ] || fail 'real task content reached an unverified replacement'
pass 'agy admission: pane-side launch comparison stops a post-admission replacement before task delivery'

new_case unknown
if admit ensure '' >/dev/null; then fail 'implicit default model was certified'; fi
mv "$BINARY" "$CASE/not-selected"
if admit >/dev/null; then fail 'unknown executable identity was certified'; fi
pass 'agy admission: missing identity and implicit model fail closed'

new_case native-context 1.4.7
RECEIPT=$(admit ensure-native)
[ "$(attempts)" = 3 ] || fail 'native admission omitted a guard'
python3 "$CODE/bin/fm-agy-admission.py" assert "$RECEIPT" "$BINARY" fixture-model '' native-tmux '' '' \
  || fail 'complete native evidence did not bind the native context'
if python3 "$CODE/bin/fm-agy-admission.py" assert "$RECEIPT" "$BINARY" fixture-model '' agy fixture-judge "$BINARY" 2>/dev/null; then
  fail 'native receipt certified a legacy judge context'
fi
if python3 "$CODE/bin/fm-agy-admission.py" assert "$RECEIPT" "$BINARY" fixture-model '' native-herdr '' '' 2>/dev/null; then
  fail 'native receipt certified another backend'
fi
[ "$(admit ensure-native)" = "$RECEIPT" ] && [ "$(attempts)" = 3 ] || fail 'matching native receipt did not reuse proof'
if FM_HOME="$HOME_DIR" bash "$CODE/bin/fm-agy-admission.sh" ensure-native "$BINARY" fixture-model '' agy fixture-judge "$BINARY" >/dev/null 2>&1; then
  fail 'native admission accepted a legacy judge context'
fi
pass 'agy admission: native receipts bind model, effort and backend independently of legacy judge proof'

new_case native-failure 1.4.7
if FM_ADMISSION_FIXTURE_MODE=fail admit ensure-native >/dev/null; then fail 'failed native guard published approval'; fi
new_case native-too-old 1.4.6
if admit ensure-native >/dev/null; then fail 'native route admitted an unproven pre-1.4.7 release'; fi
[ ! -e "$CASE/attempts" ] || fail 'unsupported native candidate reached model prompts'
pass 'agy admission: native guard failure and unsupported startup versions refuse certification'

printf '# all fm-agy-admission tests passed\n'
