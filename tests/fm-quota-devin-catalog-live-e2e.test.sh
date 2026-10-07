#!/usr/bin/env bash
# Token-free live guard for Devin's catalog-backed included_quota binding.
# Only `devin models list` and --version are real; quota is synthetic and no
# prompt, provider quota, credential read, worker launch, or endpoint is
# involved. The binding reads which models the Devin catalog prices per token,
# so a parser regression or a change to the catalog's pricing display is
# caught here. Expectations are derived from the live catalog's current
# pricing, not a fixed assumption about any family, so a vendor repricing (for
# example SWE-2 losing its promotional free tier) reclassifies rather than
# falsely failing. `devin models list` is captured once and replayed through a
# stub so the function under test and the test's own parse see identical bytes;
# the live catalog has been observed to return different snapshots on repeated
# calls, so re-invoking it would compare two different catalogs.
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

LAB=$(fm_test_tmproot fm-quota-devin-catalog-live)
# Capture the live catalog exactly once, then replay it through a stub so every
# later read sees the same bytes.
fm_run_timed 5 devin models list </dev/null >"$LAB/listing.txt" 2>/dev/null \
  || fail "devin $VERSION catalog query failed"
[ -s "$LAB/listing.txt" ] || fail "devin $VERSION catalog listing was empty"
mkdir -p "$LAB/bin"
# Replay the captured listing for `models list` and nothing else; the live
# catalog has been observed to return different snapshots on repeated calls, so
# every read in this test must come from the one captured listing, never a
# fresh live call.
cat > "$LAB/bin/devin" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = models ] && [ "\${2:-}" = list ]; then exec cat "$LAB/listing.txt"; fi
echo "unexpected devin invocation in catalog guard: \$*" >&2
exit 2
SH
chmod +x "$LAB/bin/devin"
export PATH="$LAB/bin:$PATH"

# Parse the captured listing into {id, paid} pairs by the current pricing
# display: a bracket carrying a per-token "$" price is paid, a Free-only
# bracket is not. This mirrors fm_quota_devin_catalog but keeps the free rows
# too, so the guard derives both expectations from the one real snapshot.
ROWS=$(jq -Rsc '
  split("\n")
  | map(capture("^  (?<id>[a-zA-Z0-9][a-zA-Z0-9._-]*)[ \t].*(?<bracket>\\[[^]]*\\])\\s*$") // empty
        | {id, paid: (.bracket | test("\\$"))})' "$LAB/listing.txt")
printf '%s\n' "$ROWS" | jq -e 'type == "array" and length > 0' >/dev/null \
  || fail "devin $VERSION catalog did not parse into any priced rows"

IDS=$(fm_quota_devin_catalog)
printf '%s\n' "$IDS" | jq -e 'type == "array"' >/dev/null || fail "devin $VERSION catalog did not parse into a list"

# The catalog function must include exactly the paid rows and exclude the free
# ones, whatever the current pricing is.
PAID_IDS=$(printf '%s\n' "$ROWS" | jq -c '[.[] | select(.paid) | .id] | unique')
FREE_IDS=$(printf '%s\n' "$ROWS" | jq -c '[.[] | select(.paid | not) | .id] | unique')
assert_equals "$PAID_IDS" "$IDS" "devin $VERSION catalog function includes exactly the per-token priced models"
printf '%s\n' "$FREE_IDS" | jq -e --argjson ids "$IDS" 'all(.[]; . as $m | ($ids | index($m)) == null)' >/dev/null \
  || fail "devin $VERSION catalog function bound a Free-priced model to the paid pool: free=$FREE_IDS"

# A paid model (there is always at least one) binds included_quota; a free
# model, when the catalog still prices one free, does not.
PAID=$(printf '%s\n' "$PAID_IDS" | jq -r '.[0] // empty')
[ -n "$PAID" ] || fail "devin $VERSION catalog exposed no per-token priced model to bind included_quota"
PAID_SCOPE=$(jq -rn --argjson ids "$IDS" --arg model "$PAID" "$FM_QUOTA_DEVIN_JQ"'quota_devin_scope($ids; $model)')
assert_equals included_quota "$PAID_SCOPE" "devin $VERSION paid model $PAID binds included_quota"
FREE=$(printf '%s\n' "$FREE_IDS" | jq -r '.[0] // empty')
if [ -n "$FREE" ]; then
  FREE_SCOPE=$(jq -rn --argjson ids "$IDS" --arg model "$FREE" "$FM_QUOTA_DEVIN_JQ"'quota_devin_scope($ids; $model)')
  assert_equals "" "$FREE_SCOPE" "devin $VERSION free model $FREE draws on no plan quota"
fi

cat > "$LAB/quota.json" <<'JSON'
{"schemaVersion":5,"providers":[{"provider":"devin","quotaSemantics":{"status":"known","effectiveAvailability":[
 {"scope":"included_quota","status":"known","effectivePercentRemaining":96,"runway":{"status":"through_reset"}}
]}}]}
JSON
if [ -n "$FREE" ]; then
  OUT=$("$ROOT/bin/fm-quota-choose.sh" --snapshot "$LAB/quota.json" --candidate "devin:$PAID" --candidate "devin:$FREE") \
    || fail "devin $VERSION paid model failed to bind the included pool"
  assert_equals "devin $PAID" "$OUT" "devin $VERSION paid model selected over the unmetered free route"
else
  OUT=$("$ROOT/bin/fm-quota-choose.sh" --snapshot "$LAB/quota.json" --candidate "devin:$PAID") \
    || fail "devin $VERSION paid model failed to bind the included pool"
  assert_equals "devin $PAID" "$OUT" "devin $VERSION paid model binds the included pool"
fi
printf 'ok - devin %s: catalog-backed included_quota binding verified without model tokens\n' "$VERSION"
