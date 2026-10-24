#!/usr/bin/env bash
# Unit-only compatibility fixtures for fake agy executables. These model a
# completed proof for spawn tests; fm-agy-admission.test.sh tests orchestration,
# and the credentialed guards remain the authority for actual native behavior.
fm_agy_fixture_receipt() {  # <home> <binary> <model> <effective-effort> <tier> <judge-model> <judge-bin>
  local home=$1 binary=$2 model=$3 effort=$4 tier=$5 judge_model=$6 judge=$7
  local proof cache key guard evidence="$ROOT/bin/fm-agy-admission.py"
  [ -x "$judge" ] || return 0
  cache="$home/state/agy-compatibility"
  mkdir -p "$cache"
  chmod 700 "$cache"
  proof=$(mktemp -d "$cache/.fixture.XXXXXX") || return 1
  python3 "$evidence" snapshot "$binary" "$model" "$effort" "$tier" "$judge_model" "$judge" \
    > "$proof/binding.json" || return 1
  key=$(python3 "$evidence" key "$proof/binding.json") || return 1
  printf '{"tool":"unit-fixture"}\n' > "$proof/tools.jsonl"
  for guard in bypass observer signals; do
    FM_AGY_ADMISSION_BINDING="$proof/binding.json" python3 "$evidence" complete \
      "$proof" "$guard" 0 "$proof/tools.jsonl" || return 1
  done
  python3 "$evidence" publish "$cache/$key.json" "$proof/binding.json" "$proof" manual-baseline \
    "$binary" "$model" "$effort" "$tier" "$judge_model" "$judge"
}
