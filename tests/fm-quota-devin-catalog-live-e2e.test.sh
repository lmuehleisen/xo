#!/usr/bin/env bash
# Token-free live guard for Devin's catalog-backed included_quota binding.
# Only `devin models list` and --version are real; quota is synthetic and no
# prompt, provider quota, credential read, worker launch, or endpoint is
# involved. The binding reads which models the Devin catalog prices per token,
# so a vendor rename of the free tier or a change to its pricing display is
# caught here.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$ROOT/bin/fm-quota-axi-lib.sh"
fm_live_gate default-on FM_QUOTA_DEVIN_CATALOG_LIVE devin jq
VERSION=$(fm_run_timed 5 devin version </dev/null 2>/dev/null || fm_run_timed 5 devin --version </dev/null 2>/dev/null) \
  || fail 'devin version query failed'
VERSION=$(printf '%s\n' "$VERSION" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
[ -n "$VERSION" ] || fail 'devin version string had no parseable version'
IDS=$(fm_quota_devin_catalog)
printf '%s\n' "$IDS" | jq -e 'type == "array"' >/dev/null || fail "devin $VERSION catalog did not parse into a list"
# A paid per-token GPT model draws on the included allowance; find one in the
# catalog so a vendor change to that family's pricing display fails here.
PAID=$(printf '%s\n' "$IDS" | jq -r '.[]' | grep -E '^gpt-' | head -1) \
  || true
[ -n "$PAID" ] || fail "devin $VERSION catalog exposed no paid GPT model to bind included_quota"
# The paid model binds included_quota and a free SWE-2 model does not.
PAID_SCOPE=$(jq -rn --argjson ids "$IDS" --arg model "$PAID" "$FM_QUOTA_DEVIN_JQ"'quota_devin_scope($ids; $model)')
assert_equals included_quota "$PAID_SCOPE" "devin $VERSION paid model $PAID binds included_quota"
FREE_BOUND=$(printf '%s\n' "$IDS" | jq -r 'any(.[]; test("^swe-2-"))')
[ "$FREE_BOUND" = false ] || fail "devin $VERSION catalog bound a free SWE-2 model to the paid pool: $IDS"
LAB=$(fm_test_tmproot fm-quota-devin-catalog-live)
cat > "$LAB/quota.json" <<'JSON'
{"schemaVersion":5,"providers":[{"provider":"devin","quotaSemantics":{"status":"known","effectiveAvailability":[
 {"scope":"included_quota","status":"known","effectivePercentRemaining":96,"runway":{"status":"through_reset"}}
]}}]}
JSON
OUT=$(PATH="$(dirname "$(command -v devin)"):$PATH" "$ROOT/bin/fm-quota-choose.sh" \
  --snapshot "$LAB/quota.json" --candidate "devin:$PAID" --candidate devin:swe-2-max) \
  || fail "devin $VERSION paid model failed to bind the included pool"
assert_equals "devin $PAID" "$OUT" "devin $VERSION paid model selected over the unmetered free route"
printf 'ok - devin %s: catalog-backed included_quota binding verified without model tokens\n' "$VERSION"
