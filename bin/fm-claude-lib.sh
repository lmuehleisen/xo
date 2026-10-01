#!/usr/bin/env bash
# Claude desktop-app process identity.
# Sourced by bin/fm-session-lock-lib.sh and bin/fm-harness.sh. This file is
# sourced by scripts and has no side effects on source.
#
# Why one owner: the Claude desktop app (its Code tab, locally or over its SSH
# remote) runs each agent session as a version-named executable inside its own
# install tree, below a shared per-install server:
#
#   tool shell
#   <- ~/.claude/remote/ccd-cli/<version> --output-format stream-json ...  (session)
#   <- ~/.claude/remote/srv/<hash>/server --serve ...                      (shared server)
#
# Neither path has a `claude` component (only `.claude`) and the basename is a
# version, so the generic name and path-component rules cannot see the session.
# Widening those rules to `.claude` would claim any process run from the config
# directory, such as a hook script or a node MCP server under ~/.claude, so the
# match here is anchored on the whole remote/ccd-cli/<version> shape instead.
#
# The shared server is deliberately NOT a harness process. One server hosts every
# desktop session of that install, so counting it would extend a session's
# contiguous Claude ancestry into a process its sibling sessions share, and a
# lock anchored there would be owned by every one of them.

# True when executable path $1 is a Claude desktop-app session executable:
# a version-shaped basename directly inside .claude/remote/ccd-cli/.
fm_claude_desktop_path_is_claude() {  # <path>
  local path=$1 version
  case "$path" in
    */.claude/remote/ccd-cli/*) ;;
    *) return 1 ;;
  esac
  version=${path##*/.claude/remote/ccd-cli/}
  case "$version" in
    [0-9]*) ;;
    *) return 1 ;;
  esac
  case "$version" in
    */*|*[!0-9A-Za-z.+-]*) return 1 ;;
  esac
  return 0
}
