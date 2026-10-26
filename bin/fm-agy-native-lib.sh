#!/usr/bin/env bash
# Native Auto launch and exact native-command approval transport for agy.
# Sourced by fm-agy-lib.sh and fm-agy-permission-policy.sh, never executed.
#
# fm_agy_native_activate <backend> <target> <state> <id> <gen> <scratch>
#   Completes a tool-free warm-up, selects Auto through a bounded Shift+Tab
#   cycle, and requires an actual random marker plus generation-bound Stop.
#   Only tmux and Herdr have live-proven key and viewport primitives. Every
#   other backend refuses before launch; no default-review/bypass fallback.
#   FM_AGY_NATIVE_POLLS (default 160), FM_AGY_POLL_INTERVAL (default 0.5)
#   bound each readiness/model phase. Never sends the task brief itself.
# fm_agy_native_decision <poll|approve|decline|resume> <policy> [key]
#   Uses the existing policy pending markers, keyed status lifecycle and
#   backend control primitives. No daemon or additional inbox is installed.
#   Poll binds a complete live panel to exactly one outstanding hook input.
#   Approve selects option 1 once; decline selects option 4 and resumes with
#   a tool-free reconciliation turn. Only a new accepted native Stop settles
#   cancellation. A sent-but-unconfirmed action remains open and cannot be
#   sent again. Unknown/clipped panels surface a durable unbound decision.
#   Never selects conversation-wide or persistent approval.

fm_agy_native_supported() {
  case "$1" in tmux|herdr) return 0 ;; *) return 1 ;; esac
}

fm_agy_native_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_agy_native_screen() { # <backend> <target> <id>
  fm_backend_visible_capture "$1" "$2" "fm-$3"
}

fm_agy_native_seq() { # <state> <id> [idle]
  local record
  record=$(fm_busy_record_read "$1" "$2") || return 1
  case "$record" in
    'idle agy-hook stop '*) ;;
    *) [ "${3:-}" != idle ] || return 1 ;;
  esac
  printf '%s' "${record##* }"
}

fm_agy_native_wait_stop() { # <state> <id> <after-seq>
  local i seq gen
  gen=$(cat "$1/$2.busy-gen") || return 1
  for ((i=0; i<${FM_AGY_NATIVE_POLLS:-160}; i++)); do
    [ "$(cat "$1/$2.busy-gen" 2>/dev/null)" = "$gen" ] || return 1
    seq=$(fm_agy_native_seq "$1" "$2" idle) || seq=0
    [ "$seq" -le "$3" ] || return 0
    sleep "${FM_AGY_POLL_INTERVAL:-0.5}"
  done
  return 1
}

fm_agy_native_submit() { # <backend> <target> <id> <text>
  local verdict
  verdict=$(FM_COMPOSER_HARNESS=agy fm_backend_send_text_submit \
    "$1" "$2" "$4" 3 0.5 0.5 "fm-$3") || return 1
  [ "$verdict" = empty ]
}

fm_agy_native_activate() {
  local backend=$1 target=$2 state=$3 id=$4 gen=$5 scratch=$6
  local i screen seq nonce marker prompt
  fm_agy_native_supported "$backend" || return 1
  [ "$(cat "$state/$id.busy-gen" 2>/dev/null)" = "$gen" ] || return 1
  for ((i=0; i<${FM_AGY_NATIVE_POLLS:-160}; i++)); do
    if [ "$(FM_COMPOSER_HARNESS=agy fm_backend_composer_state "$backend" "$target" "fm-$id")" = empty ]; then break; fi
    sleep "${FM_AGY_POLL_INTERVAL:-0.5}"
  done
  [ "$i" -lt "${FM_AGY_NATIVE_POLLS:-160}" ] || return 1
  seq=$(fm_agy_native_seq "$state" "$id") || return 1
  fm_agy_native_submit "$backend" "$target" "$id" \
    'This is a launch readiness check, before your task. Reply exactly WARM_READY. Use no tools and do nothing else.' || return 1
  fm_agy_native_wait_stop "$state" "$id" "$seq" || return 1
  for ((i=0; i<=4; i++)); do
    screen=$(fm_agy_native_screen "$backend" "$target" "$id") || return 1
    if printf '%s' "$screen" | python3 "$SCRIPT_DIR/fm-agy-native.py" active 2>/dev/null; then break; fi
    [ "$i" -lt 4 ] || return 1
    fm_backend_send_key "$backend" "$target" BTab "fm-$id" || return 1
    sleep 0.8
  done
  nonce=$(python3 -c 'import secrets; print(secrets.token_hex(24))') || return 1
  marker="$scratch/agy-activation-$gen-$nonce"
  [ ! -e "$marker" ] && [ ! -L "$marker" ] || return 1
  prompt="Launch activation check: run exactly one run_command call: /usr/bin/printf $(fm_agy_native_quote "$nonce") > $(fm_agy_native_quote "$marker"). Use no other tools, files, credentials, network, delegation or settings. Do not retry after refusal. Reply DONE when it returns."
  seq=$(fm_agy_native_seq "$state" "$id") || return 1
  fm_agy_native_submit "$backend" "$target" "$id" "$prompt" || return 1
  fm_agy_native_wait_stop "$state" "$id" "$seq" || return 1
  python3 - "$marker" "$nonce" <<'PY' || return 1
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.is_symlink() or p.read_bytes() != sys.argv[2].encode():
    raise SystemExit(1)
p.unlink()
PY
  screen=$(fm_agy_native_screen "$backend" "$target" "$id") || return 1
  printf '%s' "$screen" | python3 "$SCRIPT_DIR/fm-agy-native.py" active || return 1
  [ "$(cat "$state/$id.busy-gen" 2>/dev/null)" = "$gen" ] || return 1
  jq -cn --arg task "$id" --arg gen "$gen" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{event:"native-activated",task:$task,gen:$gen,ts:$ts,posture:"native-auto",tool:"native-auto"}' \
    >> "$state/agy-permission-log.jsonl"
}

# These management functions run only in the policy owner's context. Its
# policy/pending paths, payload parsing, status_append and close_pending stay
# authoritative for both native and legacy tasks.
fm_agy_native_decision() {
  local action=$1 policy=$2 key=${3:-} state meta backend target screen panel
  local candidate found='' count=0 slug marker proof current selected seq i
  [ "${PENDING_DIR+x}" = x ] && [ -n "$PENDING_DIR" ] || return 1
  state=${policy%/*} meta="$state/$TASK.meta"
  [ -f "$meta" ] && [ "$(fm_meta_get "$meta" harness)" = agy ] \
    && [ "$(fm_meta_get "$meta" busy_gen)" = "$GEN" ] \
    && [ "$(cat "$state/$TASK.busy-gen" 2>/dev/null)" = "$GEN" ] || return 1
  backend=$(fm_meta_get "$meta" backend); backend=${backend:-tmux}
  target=$(fm_meta_get "$meta" window)
  fm_agy_native_supported "$backend" || return 1
  if [ "$action" = resume ]; then
    fm_agy_native_resume "$backend" "$target" "$state" "$key"
    return
  fi
  screen=$(fm_agy_native_screen "$backend" "$target" "$TASK") || return 1
  panel=$(printf '%s' "$screen" | python3 "$SCRIPT_DIR/fm-agy-native.py" prompt 2>/dev/null) || {
    [ "$action" = poll ] || return 1
    printf '%s' "$screen" | python3 "$SCRIPT_DIR/fm-agy-native.py" dialog >/dev/null 2>&1 || return 0
    panel=''
  }
  for candidate in "$PENDING_DIR"/*.candidate; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    jq -e --arg gen "$GEN" '.gen == $gen' "$candidate" >/dev/null || continue
    if [ -n "$panel" ] && printf '%s' "$screen" | python3 "$SCRIPT_DIR/fm-agy-native.py" match "$candidate" >/dev/null 2>&1; then
      count=$((count+1)); found=$candidate
    fi
  done
  if [ "$count" -ne 1 ]; then
    marker="$PENDING_DIR/native-unbound.pending"
    if [ "$action" = poll ] && [ ! -e "$marker" ]; then
      printf 'agy-native-unbound-%s\nunbound native prompt\n\nnative-unbound\n' "$GEN" > "$marker" || return 1
      status_append "needs-decision [at=$(date +%s)] [key=agy-native-unbound-$GEN]: agy native approval cannot be bound to one exact hook input; inspect the worker or use guarded relaunch; no approval was sent"
    fi
    [ "$action" = poll ]
    return
  fi
  slug=${found##*/}; slug=${slug%.candidate}
  marker="$PENDING_DIR/$slug.pending" proof="$PENDING_DIR/$slug.native"
  panel=$(printf '%s' "$screen" | python3 "$SCRIPT_DIR/fm-agy-native.py" match "$found") || return 1
  if [ "$action" = poll ]; then
    if [ ! -e "$marker" ]; then
      # Store the full command separately; the status is only a bounded hint.
      printf 'agy-permission-%s\n%s\n\nnative\n' "$slug" \
        "$(one_line "$(jq -r '.args.CommandLine' "$found")" 300)" > "$marker" || return 1
      printf '%s\n' "$panel" > "$proof" || return 1
      TOOL=run_command TOOL_USE_ID=$slug
      SESSION_ID=$(jq -r .session "$found")
      log_record escalate native 'native Auto requested one-shot approval' "$(jq -r .args.CommandLine "$found")"
      status_append "needs-decision [at=$(date +%s)] [key=agy-permission-$slug]: agy native review awaits one-shot approve or decline; exact call: $found"
    fi
    return 0
  fi
  [ "$key" = "agy-permission-$slug" ] && [ -f "$marker" ] && [ -f "$proof" ] || return 1
  # A repeated or uncertain send must never approve a later prompt.
  [ ! -e "$proof.sent" ] || return 1
  current=$(jq -r .fingerprint <<<"$panel")
  [ "$current" = "$(jq -r .fingerprint "$proof")" ] \
    && [ "$(jq -r .candidate_digest <<<"$panel")" = "$(jq -r .candidate_digest "$proof")" ] || return 1
  selected=$(jq -r .selected <<<"$panel")
  [ "$selected" = 1 ] || return 1
  if [ "$action" = decline ]; then
    for i in 1 2 3; do fm_backend_send_key "$backend" "$target" Down "fm-$TASK" || return 1; done
    selected=4
  elif [ "$action" != approve ]; then return 1; fi
  screen=$(fm_agy_native_screen "$backend" "$target" "$TASK") || return 1
  panel=$(printf '%s' "$screen" | python3 "$SCRIPT_DIR/fm-agy-native.py" match "$found") || return 1
  [ "$(jq -r .fingerprint <<<"$panel")" = "$current" ] \
    && [ "$(jq -r .candidate_digest <<<"$panel")" = "$(jq -r .candidate_digest "$proof")" ] \
    && [ "$(jq -r .selected <<<"$panel")" = "$selected" ] || return 1
  # Persist the decline before any reconciliation turn can retry the call.
  if [ "$action" = decline ]; then cp "$found" "$PENDING_DIR/$slug.native-declined" || return 1; fi
  (set -C; printf '%s\n' "$action" > "$proof.sent") || return 1
  fm_backend_send_key "$backend" "$target" Enter "fm-$TASK" || return 1
  if [ "$action" = decline ]; then
    fm_agy_native_resume "$backend" "$target" "$state" "$key"
    return
  fi
  for ((i=0; i<${FM_AGY_NATIVE_POLLS:-160}; i++)); do
    [ "$(cat "$state/$TASK.busy-gen" 2>/dev/null)" = "$GEN" ] || return 1
    if [ "$(cat "$proof.completed" 2>/dev/null)" = "$GEN" ]; then
      rm -f "$proof.completed"
      return 0
    fi
    sleep "${FM_AGY_POLL_INTERVAL:-0.5}"
  done
  return 1
}

fm_agy_native_resume() { # <backend> <target> <state> <key>
  local backend=$1 target=$2 state=$3 key=$4 slug marker proof screen seq invocation i
  [ "${PENDING_DIR+x}" = x ] && [ -n "$PENDING_DIR" ] || return 1
  slug=${key#agy-permission-}
  case "$slug" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  marker="$PENDING_DIR/$slug.pending" proof="$PENDING_DIR/$slug.native"
  [ -f "$marker" ] && [ "$(cat "$proof.sent" 2>/dev/null)" = decline ] || return 1
  # shellcheck disable=SC2034 # Read by the policy owner's close_pending/log_record.
  TOOL=run_command TOOL_USE_ID=$slug
  # shellcheck disable=SC2034 # Read by the policy owner's close_pending/log_record.
  SESSION_ID=$(jq -er .session "$PENDING_DIR/$slug.candidate") || return 1
  if [ ! -e "$proof.resume" ]; then
    for ((i=0; i<${FM_AGY_NATIVE_POLLS:-160}; i++)); do
      screen=$(fm_agy_native_screen "$backend" "$target" "$TASK") || return 1
      if ! printf '%s' "$screen" | python3 "$SCRIPT_DIR/fm-agy-native.py" prompt >/dev/null 2>&1 \
        && [[ "$screen" == *'User declined the tool call'* ]] \
        && [ "$(FM_COMPOSER_HARNESS=agy fm_backend_composer_state "$backend" "$target" "fm-$TASK")" = empty ]; then break; fi
      sleep "${FM_AGY_POLL_INTERVAL:-0.5}"
    done
    [ "$i" -lt "${FM_AGY_NATIVE_POLLS:-160}" ] || return 1
    seq=$(fm_agy_native_seq "$state" "$TASK") || return 1
    (set -C; printf '%s\n' "$seq" > "$proof.resume") || return 1
    fm_agy_native_submit "$backend" "$target" "$TASK" \
      'The previous tool call was declined. Do not retry it or use an alternative. This is cancellation reconciliation: reply exactly CANCEL_ACK, use no tools, then wait for firstmate.' || return 1
    printf '%s\n' "$GEN" > "$proof.resume-submitted" || return 1
  fi
  [ "$(cat "$proof.resume-submitted" 2>/dev/null)" = "$GEN" ] || return 1
  seq=$(cat "$proof.resume")
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  # A delayed Stop from the cancelled turn cannot prove a new invocation.
  for ((i=0; i<${FM_AGY_NATIVE_POLLS:-160}; i++)); do
    [ "$(cat "$state/$TASK.busy-gen" 2>/dev/null)" = "$GEN" ] || return 1
    invocation=$(cat "$state/$TASK.agy-hooks/$GEN.invocation" 2>/dev/null) || invocation=0
    case "$invocation" in ''|*[!0-9]*) return 1 ;; esac
    [ "$invocation" -le "$seq" ] || break
    sleep "${FM_AGY_POLL_INTERVAL:-0.5}"
  done
  [ "$invocation" -gt "$seq" ] || return 1
  fm_agy_native_wait_stop "$state" "$TASK" "$invocation" || return 1
  [ "$(cat "$state/$TASK.busy-gen" 2>/dev/null)" = "$GEN" ] || return 1
  [ "$(FM_COMPOSER_HARNESS=agy fm_backend_composer_state "$backend" "$target" "fm-$TASK")" = empty ] || return 1
  close_pending "$marker" declined "native call declined; a new accepted Stop verified cancellation and resumed the worker" firstmate
  rm -f "$PENDING_DIR/$slug.candidate" "$proof" "$proof.sent" "$proof.resume" "$proof.resume-submitted"
}
