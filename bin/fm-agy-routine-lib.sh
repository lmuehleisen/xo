#!/usr/bin/env bash
# fm-agy-routine-lib.sh - the exact own-task agy operations that
# fm-agy-permission-policy.sh answers with "allow", so they run without an agy
# review prompt. Sourced by that policy only after its refusal, credential,
# workspace and generation checks; anything unrecognized keeps its existing
# native review or Firstmate hold.
#
# Every path is resolved physically and must name this task's own record:
#   - one echo/printf status line appended (>>) to its own state/<id>.status;
#   - find <inbox> -maxdepth 1 -name '*.msg' 2>/dev/null | sort -V, and
#     list_dir, ls, read_file/view_file or cat of its own state/<id>.inbox,
#     its handled/ and their NNN.msg records, plus mkdir/mv of those records
#     into its own handled/;
#   - list_dir, ls, read_file/view_file or cat of its own status file and its
#     own task data folder (writes keep the policy's ordinary write rules);
#   - <code-root>/bin/fm-publish-gate.sh policy, with no redirection;
#   - sandboxed git rev-parse, status, log, diff, show or branch
#     --show-current whose cwd or -C target is the task worktree, with only
#     the listed read-only options and revision or in-worktree path operands.
# Commands are literal: no variables, globs, substitutions, heredocs, braces,
# background jobs or wrappers, and other executables must resolve to
# /bin, /usr/bin, /usr/local/bin or Homebrew.
# A compound joined by &&, ; or the one find | sort pipe is allowed only when
# every segment is.

agy_routine_read_path() {  # <path> <cwd> <file|dir>
  local abs root
  abs=$(physical_target "$1" "$2" 0) || return 1
  abs=$(resolve_symlink_chain "$abs") || return 1
  case "$3" in
    dir) [ -d "$abs" ] || return 1 ;;
    file) [ -f "$abs" ] || return 1 ;;
  esac
  if [ -n "$STATUS" ] && [ "$abs" = "$(norm_abs "$STATUS")" ] && [ "$3" = file ]; then return 0; fi
  if [ -n "$DATA_DIR" ]; then
    root=$(norm_abs "$DATA_DIR")
    if [ "$abs" = "$root" ] || strictly_inside "$abs" "$root"; then return 0; fi
  fi
  [ -n "$INBOX" ] || return 1
  root=$(norm_abs "$INBOX")
  case "$3:$abs" in
    "dir:$root"|"dir:$root/handled") return 0 ;;
    "file:$root/"*)
      case "${abs%/*}" in
        "$root"|"$root/handled") [[ ${abs##*/} =~ ^[0-9]+\.msg$ ]]; return $? ;;
      esac ;;
  esac
  return 1
}

agy_routine_git() {  # <physical or absolute cwd>; subsequent arguments are literal git operands
  local cwd=$1 sub arg pathspec=0
  shift
  # Outside-sandbox Git could execute configured diff, filter or monitor
  # programs outside the worktree even for otherwise read-only subcommands.
  [ "$AGY_BYPASS_SANDBOX" = false ] || return 1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C) [ "$#" -ge 2 ] && [ -n "$2" ] || return 1
        cwd=$(physical_target "$2" "$cwd" 1) || return 1
        shift ;;
      -P|--no-pager|--no-optional-locks|--literal-pathspecs|--no-replace-objects) ;;
      *) break ;;
    esac
    shift
  done
  [ "$#" -gt 0 ] && [ -d "$cwd" ] &&
    [ "$(norm_abs "$cwd")" = "$(norm_abs "$WORKTREE")" ] || return 1
  sub=$1; shift
  case "$sub" in
    branch) [ "$#" = 1 ] && [ "$1" = --show-current ]; return $? ;;
    rev-parse|status|log|diff|show) ;;
    *) return 1 ;;
  esac
  while [ "$#" -gt 0 ]; do
    arg=$1; shift
    if [ "$pathspec" = 1 ]; then
      arg=$(physical_target "$arg" "$cwd" 0) && arg=$(resolve_symlink_chain "$arg") || return 1
      strictly_inside "$arg" "$WORKTREE" || return 1
      continue
    fi
    case "$sub:$arg" in
      rev-parse:--show-toplevel|rev-parse:--git-dir|rev-parse:--git-common-dir|\
      rev-parse:--is-inside-work-tree|rev-parse:--show-prefix|rev-parse:--show-cdup|\
      rev-parse:--verify|rev-parse:--short|rev-parse:--abbrev-ref) continue ;;
      status:--short|status:-s|status:-sb|status:-bs|status:--branch|status:-b|\
      status:--porcelain|status:--porcelain=v[12]|status:--untracked-files=no|status:-uno) continue ;;
      status:--|log:--|diff:--|show:--) pathspec=1; continue ;;
    esac
    case "$sub" in
      log|diff|show)
        case "$arg" in
          --oneline|--stat|--shortstat|--numstat|--name-only|--name-status|--abbrev-commit|\
          --cached|--staged|--no-ext-diff|--no-textconv|--check|--no-patch|-p|--patch|\
          --format=*|--pretty=*) continue ;;
          -n) [ "$#" -gt 0 ] && [[ $1 =~ ^[0-9]+$ ]] || return 1; shift; continue ;;
        esac
        [[ $arg =~ ^(-|--max-count=)[0-9]+$ ]] && continue ;;
    esac
    # Revision operands only, not reflog dates, :path, shell options or
    # expressions that Git could reinterpret as an absolute file operand.
    case "/$arg/" in */../*|*//*) return 1 ;; esac
    [ "$sub" != status ] && [[ $arg =~ ^[[:alnum:]][[:alnum:]_./~^-]*$ ]] || return 1
  done
}

agy_routine_segment() {  # <cwd> <redir> <target> <command> [args...]
  local CWD=$1 redir=$2 target=$3 cmd path arg
  shift 3
  [ "$#" -gt 0 ] || return 1
  cmd=${1##*/}
  case "$1" in
    echo|printf) ;;
    *)
      path=$(physical_target "$1" "$CWD" 0) || return 1
      if [ "$#" = 2 ] && [ "$path" = "${FIRSTMATE_ROOT:-${SCRIPT_DIR%/bin}}/bin/fm-publish-gate.sh" ] \
        && [ "$2" = policy ] && [ -x "$path" ] && [ ! -L "$path" ]; then
        [ -z "$redir" ]; return $?
      fi
      # Reject project-local lookalikes even when only a basename is typed.
      path=$(type -P "$1" 2>/dev/null) || return 1
      path=$(physical_target "$path" "$CWD" 0) && path=$(resolve_symlink_chain "$path") || return 1
      case "$path" in
        /bin/"$cmd"|/usr/bin/"$cmd"|/usr/local/bin/"$cmd"|/opt/homebrew/Cellar/*/"$cmd"|\
        /usr/local/Cellar/*/"$cmd"|/opt/homebrew/bin/"$cmd") ;;
        *) return 1 ;;
      esac ;;
  esac
  if [ "$redir" = '>>' ]; then
    [ -n "$STATUS" ] && [ "$(physical_target "$target" "$CWD" 0)" = "$(norm_abs "$STATUS")" ] \
      && [ ! -L "$STATUS" ] || return 1
    case "$cmd:$#" in
      echo:2) [[ $2 != [-]* && $2 != *\\* && -n $2 ]] ;;
      printf:3) [ "$2" = '%s\n' ] && [ -n "$3" ] ;;
      *) return 1 ;;
    esac
    return $?
  fi
  # The tokenizer drops fd numbers, so this also covers find's 2>/dev/null;
  # discarding either stream is the only other redirection allowed.
  [ -z "$redir" ] || { [ "$cmd:$redir:$target" = 'find:>:/dev/null' ] || return 1; }
  shift
  case "$cmd" in
    git) agy_routine_git "$CWD" "$@" ;;
    cat)
      [ "${1-}" != -- ] || shift
      [ "$#" -gt 0 ] || return 1
      for arg in "$@"; do [[ $arg != -* ]] && agy_routine_read_path "$arg" "$CWD" file || return 1; done ;;
    ls)
      while [[ ${1-} =~ ^-[1aAdFhl]+$ ]]; do shift; done
      [ "${1-}" != -- ] || shift
      [ "$#" -gt 0 ] || return 1
      for arg in "$@"; do
        [[ $arg != -* ]] && { agy_routine_read_path "$arg" "$CWD" dir ||
          agy_routine_read_path "$arg" "$CWD" file; } || return 1
      done ;;
    find)
      [ -n "$INBOX" ] && [ "$#" = 5 ] && [ "$2:$3:$4:$5" = '-maxdepth:1:-name:*.msg' ] \
        && [ "$(physical_target "$1" "$CWD" 1)" = "$(norm_abs "$INBOX")" ] ;;
    sort) [ "$#" = 1 ] && [ "$1" = -V ] ;;
    mkdir)
      [ "${1-}" != -p ] || shift
      [ "$#" = 1 ] && inbox_ack_path "$1" 0 0 handled ;;
    mv)
      # shellcheck disable=SC2034 # E, EV and EG are inbox_ack_move's dynamically scoped inputs.
      local -a E=(mv "$@") EV=() EG=()
      for arg in "${E[@]}"; do EV+=(0); EG+=(0); done
      inbox_ack_move ;;
    *) return 1 ;;
  esac
}

agy_routine_command() {
  local cwd i word redir='' target='' pipe=0
  local -a words=()
  # Tokenize once for the whole call; no substitutions, expansions,
  # background jobs, wrappers or unchecked segments borrow an allow.
  case "$CMD" in *$'\n'*|*$'\r'*|*'{'*|*'}'*) return 1 ;; esac
  case "$AGY_CWD" in /*) ;; *) return 1 ;; esac
  cwd=$(physical_target "$AGY_CWD" '' 1) || return 1
  tokenize "$CMD"
  [ "$P_SUBST" = 0 ] && [ "$P_HEREDOC_EXPANDING" = 0 ] || return 1
  for ((i = 0; i < ${#T_TXT[@]}; i++)); do
    word=${T_TXT[i]}
    [ "${T_VAR[i]}${T_GLOB[i]}${T_SUBS[i]}" = 000 ] || return 1
    case "${T_KIND[i]}:$word" in
      w:*) words+=("$word") ;;
      'r:>>'|'r:>')
        [ -z "$redir" ] && [ "${T_KIND[i+1]-}" = w ] \
          && [ "${T_VAR[i+1]}${T_GLOB[i+1]}${T_SUBS[i+1]}" = 000 ] || return 1
        redir=$word; i=$((i+1)); target=${T_TXT[i]} ;;
      'o:&&'|'o:;'|'o:|')
        [ "$pipe" = 0 ] && [ "${#words[@]}" -gt 0 ] || return 1
        agy_routine_segment "$cwd" "$redir" "$target" "${words[@]}" || return 1
        if [ "$word" = '|' ]; then
          [ "${words[0]##*/}" = find ] || return 1
          pipe=1
        fi
        words=() redir='' target='' ;;
      *) return 1 ;;
    esac
  done
  [ "${#words[@]}" -gt 0 ] || return 1
  [ "$pipe" = 0 ] || [ "${words[0]##*/}" = sort ] || return 1
  [ "$pipe" = 1 ] || [ "${words[0]##*/}" != sort ] || return 1
  agy_routine_segment "$cwd" "$redir" "$target" "${words[@]}"
}
