# Focused branch of the V2 live guard, sourced after its first successful task.
# Uses that guard's isolated endpoint and production lifecycle commands only.
oc_model_live_checks() { # <independent-worktree>
  local wt=$1 receipt session other mode out
  receipt="/tmp/fm-$ID/opencode-plugin-$(cat "$FM_HOME/state/$ID.busy-gen")/model.json"
  jq -e --arg model "$MODEL" '.phase == "verified" and .expected == $model and .observed == $model and .source == "session.context"' \
    "$receipt" >/dev/null || fail "$VERSION: native model receipt absent or mismatched"
  cp "$receipt" "$LAB/model-matching.json"
  session=$(jq -er .sessionID "$receipt")
  (cd "$wt" && "$REAL_OPENCODE" session export --standalone "$session") > "$LAB/model-session.json"
  jq -e --arg model "$MODEL" 'any(.messages[]; .type == "assistant" and (.model.providerID + "/" + .model.id) == $model)' \
    "$LAB/model-session.json" >/dev/null || fail "$VERSION: native assistant export does not confirm the model"
  pass "$VERSION: launch receipt agrees with the native assistant model"
  bash "$ROOT/bin/fm-control.sh" "$ID" exit
  printf 'preserved work\n' > "$wt/progress.txt"
  other=${FM_OPENCODE_LIVE_OTHER_MODEL:-opencode/deepseek-v4.1-flash-free}
  [ "$other" != "$MODEL" ] || fail 'live mismatch requires two distinct models'
  # A task-local executable wrapper changes the actual launch, leaving the
  # generated checker and its requested identity intact. The vendor executable
  # and any preexisting wrapper are only invoked, never edited or replaced.
  cat > "$LAB/shim/opencode" <<SH
#!/usr/bin/env bash
if [ -n "\${OPENCODE_CONFIG_CONTENT:-}" ]; then
  case "\$(cat '$LAB/model-override')" in
    mismatch) OPENCODE_CONFIG_CONTENT=\$(jq -c --arg model '$other' '.model=\$model | .agents.build.model=\$model' <<<"\$OPENCODE_CONFIG_CONTENT") ;;
    missing-plugin) OPENCODE_CONFIG_CONTENT=\$(jq -c '.plugins=[]' <<<"\$OPENCODE_CONFIG_CONTENT") ;;
  esac
  export OPENCODE_CONFIG_CONTENT
fi
exec '$REAL_OPENCODE' "\$@"
SH
  chmod +x "$LAB/shim/opencode"
  for mode in mismatch missing-plugin; do
    printf '%s\n' "$mode" > "$LAB/model-override"
    if out=$(FM_OPENCODE_READY_POLLS=20 bash "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'Continue the trivial runtime check.' 2>&1); then
      fail "$VERSION: $mode launch was accepted"
    fi
    printf '%s\n' "$out" > "$LAB/model-$mode.txt"
    grep -Fq "expected=$MODEL" <<<"$out" || fail "$VERSION: $mode refusal lacks expected model"
    if [ "$mode" = mismatch ]; then
      grep -Fq "observed=$other" <<<"$out" || fail "$VERSION: mismatch refusal lacks actual model"
    else
      grep -Fq 'observed=unavailable' <<<"$out" || fail "$VERSION: missing plugin accepted without identity"
    fi
    [ "$(cat "$wt/progress.txt")" = 'preserved work' ] || fail "$VERSION: model refusal changed work"
    [ -f "$FM_HOME/state/$ID.meta" ] || fail "$VERSION: model refusal lost endpoint ownership"
    [ -n "$(sed -n 's/^opencode_launch_failure=//p' "$FM_HOME/state/$ID.meta")" ] || fail "$VERSION: model refusal lacks recovery marker"
    ! grep -q 'working: relaunched' "$FM_HOME/state/$ID.status" || fail "$VERSION: refused launch processed the task"
    bash "$ROOT/bin/fm-control.sh" "$ID" exit
    pass "$VERSION: $mode refuses task execution and preserves work and endpoint ownership"
  done
  rm "$LAB/shim/opencode"
}
