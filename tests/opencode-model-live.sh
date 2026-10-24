#!/usr/bin/env bash
# Focused branch of the V2 live guard, sourced after its first successful task.
# Uses that guard's isolated endpoint and production lifecycle commands only.
oc_model_live_prepare() {
  local other=${FM_OPENCODE_LIVE_OTHER_MODEL:-opencode/deepseek-v4.1-flash-free}
  [ "$other" != "$MODEL" ] || fail 'live mismatch requires two distinct models'
  printf 'matching\n' > "$LAB/model-override"
  mkdir -p "$LAB/model-observer"
  printf '{"type":"module","main":"./index.mjs"}\n' > "$LAB/model-observer/package.json"
  cat > "$LAB/model-observer/index.mjs" <<JS
import { writeFileSync } from "node:fs";
export default { id: "example.native-model-observer", async setup(ctx) {
  await ctx.session.hook("context", (event) => {
    writeFileSync("$LAB/model-observed.json", JSON.stringify({sessionID:event.sessionID,model:event.model}) + "\\n");
  });
}};
JS
  # Install before the first launch so a retained shell never caches the
  # original executable and bypasses the test wrapper on replacement.
  cat > "$LAB/shim/opencode" <<SH
#!/usr/bin/env bash
if [ -n "\${OPENCODE_CONFIG_CONTENT:-}" ]; then
  mode=\$(cat '$LAB/model-override')
  printf '%s\\n' "\$mode" >> '$LAB/model-wrapper.txt'
  case "\$mode" in
    mismatch) OPENCODE_CONFIG_CONTENT=\$(jq -c --arg model '$other' '.model=\$model | .agents.build.model=\$model' <<<"\$OPENCODE_CONFIG_CONTENT") ;;
    missing-plugin) OPENCODE_CONFIG_CONTENT=\$(jq -c '.plugins=[]' <<<"\$OPENCODE_CONFIG_CONTENT") ;;
  esac
  OPENCODE_CONFIG_CONTENT=\$(jq -c --arg observer '$LAB/model-observer' '.plugins=[\$observer]+.plugins' <<<"\$OPENCODE_CONFIG_CONTENT")
  export OPENCODE_CONFIG_CONTENT
fi
exec '$REAL_OPENCODE' "\$@"
SH
  chmod +x "$LAB/shim/opencode"
}

oc_model_live_checks() { # <independent-worktree>
  local wt=$1 receipt session other mode out rc
  receipt="/tmp/fm-$ID/opencode-plugin-$(cat "$FM_HOME/state/$ID.busy-gen")/model.json"
  jq -e --arg model "$MODEL" '.phase == "verified" and .expected == $model and .observed == $model and .source == "session.context" and .discovery == "supported"' \
    "$receipt" >/dev/null || fail "$VERSION: native model receipt absent or mismatched"
  cp "$receipt" "$LAB/model-matching.json"
  grep -qx matching "$LAB/model-wrapper.txt" || fail "$VERSION: matching wrapper was not invoked"
  jq -e --arg model "$MODEL" '(.model.providerID + "/" + .model.id) == $model' "$LAB/model-observed.json" >/dev/null \
    || fail "$VERSION: independent native observer did not confirm the matching launch"
  session=$(jq -er .sessionID "$receipt")
  (cd "$wt" && "$REAL_OPENCODE" session export --standalone "$session") > "$LAB/model-session.json"
  jq -e --arg model "$MODEL" '(.info.model.providerID + "/" + .info.model.id) == $model' \
    "$LAB/model-session.json" >/dev/null || fail "$VERSION: native session export does not confirm the selected model"
  pass "$VERSION: native session selection agrees with the resolved agent-loop request model"
  bash "$ROOT/bin/fm-control.sh" "$ID" interrupt
  if [ "${FM_OPENCODE_LIVE_BACKEND:-tmux}" = herdr ]; then wait_idle "$ID" "$TARGET"; else wait_idle; fi
  bash "$ROOT/bin/fm-control.sh" "$ID" exit
  printf 'preserved work\n' > "$wt/progress.txt"
  other=${FM_OPENCODE_LIVE_OTHER_MODEL:-opencode/deepseek-v4.1-flash-free}
  # A task-local executable wrapper changes the actual launch, leaving the
  # generated checker and its requested identity intact. The vendor executable
  # and any preexisting wrapper are only invoked, never edited or replaced.
  for mode in mismatch missing-plugin; do
    rm -f "$LAB/model-observed.json"
    printf '%s\n' "$mode" > "$LAB/model-override"
    rc=0
    out=$(FM_OPENCODE_READY_POLLS=20 bash "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'Continue the trivial runtime check.' 2>&1) || rc=$?
    printf '%s\n' "$out" > "$LAB/model-$mode.txt"
    [ "$rc" -ne 0 ] || fail "$VERSION: $mode launch was accepted"
    grep -qx "$mode" "$LAB/model-wrapper.txt" || fail "$VERSION: $mode wrapper did not run"
    grep -Fq "expected=$MODEL" <<<"$out" || fail "$VERSION: $mode refusal lacks expected model"
    if [ "$mode" = mismatch ]; then
      receipt="/tmp/fm-$ID/opencode-plugin-$(cat "$FM_HOME/state/$ID.busy-gen")/model.json"
      cp "$receipt" "$LAB/model-mismatch.json"
      jq -e --arg model "$other" '(.model.providerID + "/" + .model.id) == $model' "$LAB/model-observed.json" >/dev/null \
        || fail "$VERSION: mismatch injector did not produce its intended native request identity"
      cp "$LAB/model-observed.json" "$LAB/model-mismatch-observed.json"
      jq -e --arg expected "$MODEL" --arg observed "$other" '.phase == "refused" and .expected == $expected and .observed == $observed and .source == "session.context"' \
        "$receipt" >/dev/null || fail "$VERSION: gate refusal does not agree with the independent native observer"
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
