#!/usr/bin/env bash
# fm-private-tmux-lib.sh - retire a private tmux directory (docs/tmux-backend.md
# "Worker isolation from the fleet server").
#
# One owner of stopping the tmux servers socketed inside a private directory and
# removing it, shared by teardown, spawn rollback, and the test runner.
# A socket file inside the directory proves nothing about which server answers
# it: a hardlink or rename of a live foreign socket, or a file name containing a
# newline, can hand `tmux -S` another server. So a server is stopped only when
# its own #{socket_path} is inside the directory too, and a socket answering for
# a server outside it keeps the directory, since it may be that server's only
# socket.
# A socket that answers nothing but a stopped server's "no server running" is
# left over; any other failure to inspect or stop one also keeps the directory,
# since removing it would strand a live server with no reachable socket.
# Callers decide whether the directory is the one they own; this helper refuses
# anything that is not a real directory private to this user.

# fm_private_tmux_retire <dir>: stop every tmux server whose socket is inside
# <dir>, each by its exact socket, then remove <dir>.
# Returns 1 and touches nothing when <dir> is not a non-symlink directory owned
# by this user and closed to group and others, and returns 1 keeping <dir> when
# a socket in it answers for an outside server, could not be inspected, or its
# server could not be stopped.
fm_private_tmux_retire() {
  local dir=${1:-} real sock owned kept=0
  if [ -z "$dir" ] || [ -L "$dir" ] || [ ! -d "$dir" ] || [ ! -O "$dir" ] ||
    [ -n "$(find "$dir" -prune \( -perm -g=w -o -perm -o=w \) -print 2>/dev/null)" ] ||
    ! real=$(cd "$dir" && pwd -P); then
    return 1
  fi
  while IFS= read -r -d '' sock; do
    case "$sock" in "$dir"/*) ;; *) continue ;; esac
    if ! owned=$(env -u TMUX -u TMUX_PANE tmux -S "$sock" display-message -p '#{socket_path}' 2>&1); then
      case "$owned" in "no server running on "*) ;; *) kept=1 ;; esac
      continue
    fi
    case "$owned" in "$dir"/* | "$real"/*) ;; *) kept=1; continue ;; esac
    env -u TMUX -u TMUX_PANE tmux -S "$sock" kill-server >/dev/null 2>&1 || kept=1
  done < <(find "$dir" -type s -print0 2>/dev/null)
  [ "$kept" = 0 ] || return 1
  rm -rf "$dir"
}
