#!/usr/bin/env bash
# Token-free live guard for Agy's catalog-backed quota bucket binding.
# Only `agy models` and --version are real; quota is synthetic and no prompt,
# provider quota, credential read, worker launch, or endpoint is involved.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
fm_live_gate default-on FM_QUOTA_AGY_CATALOG_LIVE agy jq
VERSION=$(fm_run_timed 5 agy --version </dev/null 2>/dev/null) || fail 'agy version query failed'
LISTING=$(fm_run_timed 5 agy models </dev/null 2>/dev/null) || fail "agy $VERSION catalog failed"
GEMINI=$(printf '%s\n' "$LISTING" | awk '$1 ~ /^gemini-[a-zA-Z0-9.-]+$/ {print $1; exit}')
OTHER=$(printf '%s\n' "$LISTING" | awk '$1 ~ /^(claude|gpt)-[a-zA-Z0-9.-]+$/ {print $1; exit}')
[ -n "$GEMINI" ] && [ -n "$OTHER" ] || fail "agy $VERSION catalog did not expose both reviewed families"
LAB=$(fm_test_tmproot fm-quota-agy-catalog-live)
cat > "$LAB/quota.json" <<'JSON'
{"schemaVersion":5,"providers":[{"provider":"agy","quotaSemantics":{"status":"known","effectiveAvailability":[
 {"scope":"gemini","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}},
 {"scope":"claude_gpt","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"}}
]}}]}
JSON
OUT=$("$ROOT/bin/fm-quota-choose.sh" --snapshot "$LAB/quota.json" --candidate "agy:$GEMINI" --candidate "agy:$OTHER") \
  || fail "agy $VERSION catalog families failed to bind"
assert_equals "agy $OTHER" "$OUT" "agy $VERSION catalog-listed Gemini veto and Claude/GPT eligibility"
printf 'ok - agy %s: catalog-backed quota buckets verified without model tokens\n' "$VERSION"
