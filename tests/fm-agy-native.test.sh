#!/usr/bin/env bash
# Portable native-policy and exact-panel regressions through public CLIs.
# Vendor semantics and real keys remain owned by the credentialed live guard.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-native-unit)
SCREEN="$TMP_ROOT/screen"
POLICY="$TMP_ROOT/state/t1.agy-permission.json"
WT="$TMP_ROOT/worktree"
STATE="$TMP_ROOT/state"
mkdir -p "$WT" "$STATE" "$TMP_ROOT/data" "$TMP_ROOT/tmp" "$TMP_ROOT/config" "$TMP_ROOT/fakebin"
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" t1)
jq -n --arg wt "$WT" --arg root "$TMP_ROOT" --arg gen "$GEN" \
  '{task:"t1",posture:"native-auto",gen:$gen,worktree:$wt,status:($root+"/state/t1.status"),
    inbox:($root+"/state/t1.inbox"),data:($root+"/data"),tasktmp:($root+"/tmp"),
    brief:($root+"/data/brief.md"),log:($root+"/state/agy-permission-log.jsonl"),config:($root+"/config")}' > "$POLICY"
printf 'harness=agy\nbackend=tmux\nwindow=native:fm-t1\nbusy_gen=%s\nagy_posture=native-auto\n' "$GEN" > "$STATE/t1.meta"
PAYLOAD="$TMP_ROOT/payload.json"
COMMAND='/usr/bin/printf SAFE_NATIVE_CALL'
payload() {
  jq -n --arg wt "$WT" --arg cmd "$1" --argjson step "${2:-1}" \
    '{conversationId:"fixture",stepIdx:$step,workspacePaths:[$wt],
      toolCall:{name:"run_command",args:{CommandLine:$cmd,Cwd:$wt}}}' > "$PAYLOAD"
}
hook() { "$ROOT/bin/fm-agy-permission-policy.sh" "$1" "$POLICY" < "$PAYLOAD"; }
export FM_NATIVE_ROOT="$ROOT" FM_NATIVE_SCREEN="$SCREEN" FM_NATIVE_KEYS="$TMP_ROOT/keys"
export FM_NATIVE_POLICY="$POLICY" FM_NATIVE_PAYLOAD="$PAYLOAD"
export FM_NATIVE_CANCEL_STATE="$TMP_ROOT/cancel-state"
fixture() { python3 "$ROOT/tests/agy-native-terminal-fixture.py" "$@"; }
panel() { fixture panel "$COMMAND"; }
panel
python3 "$ROOT/bin/fm-agy-native.py" prompt < "$SCREEN" > "$TMP_ROOT/panel.json"
jq -e '.selected == 1' "$TMP_ROOT/panel.json" >/dev/null || fail 'wrapped panel was not recognized'
printf '%s\n' '────────────────────' '> Auto mode: edits & safe commands auto-approved (shift+tab to cycle)' \
  '────────────────────' '? for shortcuts' | python3 "$ROOT/bin/fm-agy-native.py" active
printf '%s\n' '? for shortcuts    auto · Gemini' | python3 "$ROOT/bin/fm-agy-native.py" active
if printf '%s\n' '? for shortcuts    accept-edits · Gemini' | python3 "$ROOT/bin/fm-agy-native.py" active 2>/dev/null; then fail 'fallback was credited as Auto'; fi
if printf '%s\n' 'Auto mode: edits & safe commands auto-approved' '? for shortcuts' \
  | python3 "$ROOT/bin/fm-agy-native.py" active 2>/dev/null; then fail 'transcript text was credited as active Auto'; fi
sed 's/esc to cancel/? for shortcuts/' "$SCREEN" > "$TMP_ROOT/stale"
if python3 "$ROOT/bin/fm-agy-native.py" prompt < "$TMP_ROOT/stale" 2>/dev/null; then fail 'inactive transcript panel was accepted'; fi
pass 'native viewport: independent Auto signals, fallback refusal, active panel and wrapped choices'

cat > "$TMP_ROOT/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exec python3 "$FM_NATIVE_ROOT/tests/agy-native-terminal-fixture.py" "$@"
SH
chmod +x "$TMP_ROOT/fakebin/tmux"
export FM_NATIVE_ROOT="$ROOT" FM_NATIVE_SCREEN="$SCREEN" FM_NATIVE_KEYS="$TMP_ROOT/keys"
export FM_NATIVE_POLICY="$POLICY" FM_NATIVE_PAYLOAD="$PAYLOAD"
export PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$STATE"
manage() { "$ROOT/bin/fm-agy-permission-policy.sh" "$1" "$POLICY" "${2:-}" </dev/null; }
payload "$COMMAND"
[ -z "$(hook pre-tool-use)" ] || fail 'ordinary native call was held for a judge'
manage native-poll || fail 'native panel polling failed'
pending="$STATE/t1.agy-permission-pending/fixture-s1.pending"
[ -f "$pending" ] || fail 'native panel did not become a durable keyed decision'
manage native-poll
[ "$(grep -c '^needs-decision' "$STATE/t1.status")" = 1 ] || fail 'same panel created repeated decisions'
sed 's/SAFE_NATIVE_CALL/CHANGED_CALL/' "$SCREEN" > "$TMP_ROOT/changed"
mv "$TMP_ROOT/changed" "$SCREEN"
if manage approve agy-permission-fixture-s1; then fail 'changed live command was approved'; fi
[ ! -s "$TMP_ROOT/keys" ] || fail 'changed prompt received a key'
panel
FM_NATIVE_COMPLETE=1 manage approve agy-permission-fixture-s1 || fail 'exact native approval did not complete'
[ ! -e "$pending" ] || fail 'approved exact native invocation was not resolved by PostToolUse'
[ "$(grep -c Enter "$TMP_ROOT/keys")" = 1 ] || fail 'native one-shot approval sent more than one Enter'
[ ! -d "$STATE/t1.agy-permission-cache" ] || fail 'native approval created a reusable judge cache'
if manage approve agy-permission-fixture-s1; then fail 'completed native approval could be sent again'; fi
pass 'native decisions: exact binding, durable deduplication, changed-panel refusal and one-shot completion'

payload "$COMMAND" 2
hook pre-tool-use >/dev/null
payload "$COMMAND" 3
hook pre-tool-use >/dev/null
panel
manage native-poll
[ -f "$STATE/t1.agy-permission-pending/native-unbound.pending" ] || fail 'ambiguous concurrent calls were guessed'
if manage approve agy-permission-fixture-s2; then fail 'ambiguous native panel was approved'; fi
printf 'different-gen\n' > "$STATE/t1.busy-gen"
if manage native-poll; then fail 'stale generation was trusted'; fi
printf '%s\n' "$GEN" > "$STATE/t1.busy-gen"
pass 'native decisions: concurrent ambiguity and stale generations fail closed'

# Ordinary residue never invokes a Firstmate judge. Hard refusals and
# Firstmate-specific holds still apply through the same public hook.
payload 'custom-build --ordinary-flag' 10
[ -z "$(hook pre-tool-use)" ] || fail 'ordinary residue did not reach native review'
jq -es 'any(.decision == "native-review" and .judge_attempts == 0)' "$STATE/agy-permission-log.jsonl" >/dev/null \
  || fail 'native residue was not attributed to native review'
for command in 'git push --force origin main' "printf X > '$POLICY'" "printf X > '$WT/.agents/hooks.json'" \
  "printf X > '$WT/.git/config'" \
  "bash '$ROOT/bin/fm-agy-permission-policy.sh' approve '$POLICY' key" \
  "'$ROOT/bin/fm-busy-event.sh' apply '$STATE' t1 idle --current-gen"; do
  payload "$command" 11
  hook pre-tool-use | jq -e '.decision == "deny"' >/dev/null || fail "native route lost a deterministic refusal for: $command"
done
payload "cat '$WT/synthetic.env'" 12
hook pre-tool-use | jq -e '.decision == "deny" and (.reason | contains("held for firstmate"))' >/dev/null \
  || fail 'native review bypassed credential metadata policy'
manage retire
[ ! -e "$STATE/t1.agy-permission-pending" ] || fail 'native state was not retired by the policy owner'
pass 'native policy: residue goes to native review; force, wiring and credential constraints remain deterministic'

# Scope approvals are exact one-shot tokens, even without a legacy judge.
printf '# Task\n## Captain\047s intent\nDo not read excluded research files.\n' > "$TMP_ROOT/data/brief.md"
nonce=0123456789abcdef0123456789abcdef0123456789abcdef
payload "/usr/bin/printf '$nonce' > '$TMP_ROOT/tmp/agy-activation-$GEN-$nonce'" 18
[ -z "$(hook pre-tool-use)" ] || fail 'read exclusions blocked the source-free native activation canary'
payload "/usr/bin/printf '$nonce' > '$TMP_ROOT/tmp/ordinary-marker'" 19
hook pre-tool-use | jq -e '.decision == "deny"' >/dev/null || fail 'activation exception widened to ordinary commands'
manage retire
COMMAND="cat '$WT/ordinary.txt'"
payload "$COMMAND" 20
hook pre-tool-use | jq -e '.decision == "deny"' >/dev/null || fail 'native route lost explicit read exclusions'
manage approve agy-permission-fixture-s20
payload "$COMMAND" 21
[ -z "$(hook pre-tool-use)" ] || fail 'approved exact native scope retry was refused'
hook post-tool-use >/dev/null
payload "$COMMAND" 22
hook pre-tool-use | jq -e '.decision == "deny"' >/dev/null || fail 'native scope approval was reusable'
if hook judge-probe >/dev/null 2>&1; then fail 'native policy exposed a Firstmate model judge'; fi
manage retire
rm "$TMP_ROOT/data/brief.md"
pass 'native scope: explicit exclusions retain one-shot review without reusable judge state'

# Key delivery does not settle cancellation. Only the bound native Stop
# from a new reconciliation turn may clear the stale busy hook.
"$ROOT/bin/fm-agy-hook.sh" install-worker "$STATE" t1 "$GEN" "$WT" "$POLICY"
export FM_AGY_NATIVE_POLLS=3 FM_AGY_POLL_INTERVAL=0.1
COMMAND='/usr/bin/printf CHANGED_CONTEXT'
payload "$COMMAND" 25
panel
fixture event PreInvocation
hook pre-tool-use >/dev/null
manage native-poll
enters=$(grep -c Enter "$TMP_ROOT/keys")
if FM_NATIVE_MUTATE_CANDIDATE="$STATE/t1.agy-permission-pending/fixture-s25.candidate" \
  manage decline agy-permission-fixture-s25; then fail 'changed context was confirmed after navigating No'; fi
[ "$(grep -c Enter "$TMP_ROOT/keys")" = "$enters" ] || fail 'changed full hook input received a confirming Enter'
[ -f "$STATE/t1.agy-permission-pending/fixture-s25.pending" ] || fail 'changed context lost its durable decision'
manage retire
pass 'native decisions: a context change during navigation refuses confirmation and retains its key'

for stop_kind in valid foreign not-idle malformed missing stop-only; do
  COMMAND="/usr/bin/printf DECLINE_$stop_kind"
  payload "$COMMAND" 30
  panel
  fixture event PreInvocation
  hook pre-tool-use > /dev/null
  manage native-poll
  decision=agy-permission-fixture-s30
  before=$(wc -l < "$TMP_ROOT/keys" | tr -d ' ')
  if [ "$stop_kind" = valid ]; then
    FM_NATIVE_STOP_KIND=valid manage decline "$decision"
    grep -q 'state=busy .*event=pre-invocation' "$TMP_ROOT/cancel-state" || fail 'cancel key manufactured idle'
    grep -q 'state=idle .*source=agy-hook event=stop' "$STATE/t1.busy-state" || fail 'valid native Stop did not settle decline'
    grep -q "resolved .*\[key=$decision\].*accepted Stop" "$STATE/t1.status" || fail 'decline closed without a verified Stop'
    payload "$COMMAND" 31
    hook pre-tool-use | jq -e '.decision == "deny" and (.reason | contains("declined this native call"))' >/dev/null \
      || fail 'declined native command ran again at a shifted step'
  else
    if FM_NATIVE_STOP_KIND="$stop_kind" manage decline "$decision"; then fail "$stop_kind cancellation evidence manufactured idle"; fi
    [ -f "$STATE/t1.agy-permission-pending/fixture-s30.pending" ] || fail 'unverified decline lost its decision'
    if [ "$stop_kind" != stop-only ]; then
      grep -q 'state=busy' "$STATE/t1.busy-state" || fail "$stop_kind native Stop cleared busy"
    fi
    sent=$(wc -l < "$TMP_ROOT/keys" | tr -d ' ')
    if manage decline "$decision"; then fail 'uncertain decline was sent again'; fi
    [ "$(wc -l < "$TMP_ROOT/keys" | tr -d ' ')" = "$sent" ] || fail 'decline replay sent another key'
    if [ "$stop_kind" = stop-only ]; then fixture event PreInvocation; fi
    fixture event Stop
    manage resume "$decision"
    [ "$(wc -l < "$TMP_ROOT/keys" | tr -d ' ')" = "$sent" ] || fail 'resume repeated cancellation or the reconciliation message'
    grep -q 'state=idle .*source=agy-hook event=stop' "$STATE/t1.busy-state" || fail 'later valid Stop did not finish reconciliation'
  fi
  jq -e '.decision == "deny" and (.reason | contains("declined this native call"))' "$TMP_ROOT/screen.retry-verdict" >/dev/null \
    || fail 'a cancelled call could retry before the reconciliation turn'
  manage retire
  after=$(wc -l < "$TMP_ROOT/keys" | tr -d ' ')
  [ "$after" -gt "$before" ] || fail 'decline fixture never exercised key delivery'
done
"$ROOT/bin/fm-agy-hook.sh" retire-worker "$STATE" t1
pass 'native decline: key-only busy preservation, bound Stop reconciliation, durable retry denial and idempotent resume'

audit="$TMP_ROOT/audit"
mkdir -p "$audit"
printf 'harness=agy\nbusy_gen=g-native\nagy_posture=native-auto\nagy_permission_mode=auto\n' > "$audit/t1.meta"
cat > "$audit/agy-permission-log.jsonl" <<'JSON'
{"task":"t1","gen":"g-native","event":"native-activated","ts":"2026-10-26T12:00:00Z"}
{"task":"t1","gen":"g-native","event":"pre-tool-use","decision":"native-review","ts":"2026-10-26T12:00:01Z"}
{"task":"t1","gen":"g-native","event":"native-poll","decision":"escalate","tool_use_id":"c1-s1","ts":"2026-10-26T12:00:02Z"}
{"task":"t1","gen":"g-native","event":"resume","decision":"declined","reason":"escalation agy-permission-c1-s1","ts":"2026-10-26T12:00:05Z"}
JSON
bash "$ROOT/bin/fm-agy-audit.sh" "$audit" t1
jq -e '.posture == "native-auto" and .confirmed_native_coverage == true and .confirmed_judge_coverage == false
  and .native_review_calls == 1 and .native_prompts == 1
  and .resolution_timing[0].elapsed_seconds == 3 and .resolution_timing[0].result == "declined"' \
  "$audit/agy-permission-audit.jsonl" >/dev/null || fail 'native audit lost posture or resumed decision timing'
printf 'harness=agy\nbusy_gen=g-replacement\nagy_posture=native-auto\n' > "$audit/t1.meta"
bash "$ROOT/bin/fm-agy-audit.sh" "$audit" t1
tail -1 "$audit/agy-permission-audit.jsonl" | jq -e '.confirmed_native_coverage == false and .native_prompts == 0' >/dev/null \
  || fail 'replacement generation borrowed native activation evidence'
pass 'native audit: activation, review and resumed decision timing remain generation-bound and distinct from judges'
