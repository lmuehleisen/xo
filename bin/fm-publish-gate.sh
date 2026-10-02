#!/usr/bin/env bash
# fm-publish-gate.sh - the publish gate: destination allowlist, old-commit
# refusal, identity check, and private-denylist plus gitleaks content scan for
# everything this installation and its workers send to a public forge.
#
# Usage:
#   fm-publish-gate.sh pre-push <remote-name> <remote-url> [--config <dir>]
#       Pre-push hook mode. Git passes the remote name and URL as arguments and
#       "<local ref> <local sha> <remote ref> <remote sha>" lines on stdin.
#       Exit 0 lets the push proceed; any other exit refuses it.
#   fm-publish-gate.sh pre-commit [--config <dir>]
#       Pre-commit check for a repository that has a public or unlisted network
#       remote: the staged added lines and paths against the denylist, the
#       generic patterns, and email addresses. The full-history and gitleaks
#       pass stays at pre-push.
#   fm-publish-gate.sh commit-msg <msgfile> [--config <dir>]
#       Commit-msg check for a repository that has a public or unlisted network
#       remote: refuses a message carrying a non-allowlisted email address or a
#       denylist or generic-pattern hit. Never rewrites the message.
#   fm-publish-gate.sh check-text --dest <owner/repo|gist> [--pr-base <branch> --pr-head <branch> | --pr <number> | --pr-branch <branch>] [--unscannable <what>]... [--config <dir>] [<text>...]
#       The scanner the gh publish guard (bin/fm-gh-publish-policy.mjs) calls
#       for PR, issue, release, gist, repo, and API text. Each <text> is a
#       file, optionally prefixed with its kind - title:<file>, body:<file> (a
#       PR or issue description), or reply:<file> (a comment or review reply)
#       - so the shape limits below apply to it. With no <text> only the
#       destination is checked. Each --unscannable names content the command
#       also publishes that no scanner reads (a release asset, an attachment,
#       an API content write); it is refused for a public destination and
#       allowed for a confirmed-private one. Exit 0 allows.
#   fm-publish-gate.sh preflight [--config <dir>] <file>...
#       The literal check bin/fm-publish-judge.sh runs on the exact material it
#       is about to send to a model, whoever called it: every line of each
#       file against the denylist. Refused when the denylist is missing or any
#       line matches, naming the rule and line, never the text. Exit 0 allows.
#   fm-publish-gate.sh classify <url> [--config <dir>]
#       Print the destination class of <url>: public, private, owned (an
#       unlisted repository of an owner below), local, or unlisted (a network
#       destination with no allowlist entry).
#   fm-publish-gate.sh identity [--config <dir>]
#       Print "<name><TAB><email>" from the identity file, nothing when it is
#       absent, and exit 1 when it is malformed. bin/fm-spawn.sh uses this for
#       the identity pin.
#   fm-publish-gate.sh ci-commits --base <ref> --head <ref> [--identity-email <email>]
#       The public CI check: for every commit in <head> not reachable from
#       <base>, refuse any author, committer, or trailer email other than the
#       identity email (or, when none is given, any *@users.noreply.github.com
#       address) and noreply@github.com, then scan added lines, paths, and
#       messages with the generic patterns and, when installed, gitleaks.
#   fm-publish-gate.sh ci-text [--dest <owner/repo> --pr <number> --pr-upstream <owner/repo>] <text>...
#       The public CI check for PR text: generic patterns, emails, and the
#       shape limits, with the same kind prefixes as check-text. CI can also
#       supply FM_CI_PR_DEST, FM_CI_PR_NUMBER, and FM_CI_PR_UPSTREAM; older base
#       gates ignore this environment metadata and retain their normal caps.
#   fm-publish-gate.sh install <hooks-dir> [--config <dir>]
#       Write a pre-push and a commit-msg hook into <hooks-dir> (for example an
#       installation's .git/hooks) that run this gate. Refuses to replace an
#       existing hook it did not write.
#   fm-publish-gate.sh suggest-allowlist [<dir>...]
#       Print candidate allowlist rows for project repositories: each <dir> is
#       a repository or a directory of repositories, by default this home's
#       projects directory plus every "at /<path>" location recorded in
#       data/projects.md. Prints "private <owner>/<repo>" for each GitHub origin
#       a live gh read confirms private, and a comment line for every other
#       origin, which is never listed automatically, including a repository of
#       an owner, which needs no entry. A repository whose owner also owns
#       a GitHub repository in the upstream file is never suggested.
#       Writes nothing but the private-verdicts cache.
#   fm-publish-gate.sh disable-push <repo-dir> [<remote>]
#       Set remote.<remote>.pushurl to DISABLED (default remote: upstream) and
#       print the push URL before and after. Idempotent.
#   fm-publish-gate.sh config-dir
#       Print the publish-guard directory this invocation resolves (see
#       PRIVATE CONFIG), or refuse when no firstmate home owns it.
#   fm-publish-gate.sh policy
#       Print the public-text policy.
#
# PRIVATE CONFIG. Every private value lives in the gitignored publish-guard
# directory of the owning firstmate home. Without --config it is, in order:
# $FM_CONFIG_OVERRIDE/publish-guard; $FM_HOME/config/publish-guard; the
# directory named by the publish-guard-config file in this launch's per-task
# hooks (the core.hooksPath a fleet launch passes through GIT_CONFIG_*, written
# by bin/fm-git-strip-ai-trailers.sh install); or this repository's own
# config/publish-guard only when this repository is not a linked git worktree.
# A worker's worktree therefore never supplies its own config: when none of
# these names a home, every command that reads the config refuses. Nothing
# private is ever tracked, and a refusal names a rule and a location, never the
# matched text or the offending email.
#   identity        two lines, "name=<name>" and "email=<email>": the only
#                   identity allowed on public commits.
#   allowlist       one destination per line, "<class> <destination>", where
#                   class is public or private and destination is an exact
#                   GitHub owner/repo or an absolute local path. No wildcards:
#                   example-org/project, for example, is refused unless it is
#                   listed exactly.
#   denylist        one extended regular expression per line, matched
#                   case-insensitively; a refusal names it as "denylist rule
#                   <line number>".
#   poison-commits  one full commit id per line: old history that must never
#                   reach a public destination.
#   upstream        optional; one exact GitHub owner/repo or absolute local
#                   path per line: public repositories whose advertised
#                   branches and tags a public push treats as already
#                   published (for example the project this one merges from).
#   owners          optional; one GitHub owner per line whose repositories
#                   pass as private without an allowlist entry. Without it,
#                   the login in the identity's users.noreply.github.com
#                   address.
#   gh              optional; one absolute path: the gh binary that answers
#                   the live privacy read. Without it the first of
#                   /opt/homebrew/bin/gh, /usr/local/bin/gh, and /usr/bin/gh is
#                   used; PATH never is.
#   git             optional; one absolute path: the git binary that reads
#                   what a public destination and each upstream advertise.
#                   Without it the first of /opt/homebrew/bin/git,
#                   /usr/local/bin/git, and /usr/bin/git is used; PATH never
#                   is.
#   private-verdicts  written by the gate: "<owner>/<repo> <epoch>" for each
#                   repository a live read confirmed private.
# Blank lines and lines starting with # are ignored in every file.
#
# DESTINATIONS. A remote URL on github.com is matched by owner/repo; any other
# network URL can be listed only by nothing and is therefore always refused. A
# local path or file:// URL is matched by its resolved path. The class decides:
#   local (a local path with no entry)  allowed with no scan; this is what test
#       fixtures and scratch mirrors use.
#   unlisted (a network URL with no entry, or any destination when the
#       allowlist is missing)  refused.
#   private, and owned (an unlisted GitHub repository whose owner is listed
#       in owners)  allowed with no content scan, but only while the
#       repository is private: a live `gh api repos/<owner>/<repo>` read must
#       confirm it, or, when that read cannot answer (offline, rate-limited, no
#       gh), a private-verdicts entry from the last 24 hours must. A read that
#       answers public drops the entry and refuses. The read runs the gh named
#       above against github.com explicitly, with the proxy, GH_HOST, gh-config,
#       and certificate variables removed, so a worker's PATH or environment
#       cannot answer it. A public destination always needs its allowlist
#       entry.
#   public  scanned. Refused unless identity, denylist, poison-commits, and
#       gitleaks are all present, so missing private config never lets a public
#       push through.
#
# WHAT A PUBLIC PUSH MUST PASS, per pushed ref:
#   - not a tag: tag pushes to a public destination are refused outright;
#   - the remote ref name, against the denylist and the generic patterns;
#   - every commit each pushed tip reaches (`git rev-list <local>`, with no
#     exclusion at all): none may be in poison-commits;
#   - the outgoing commits (`git rev-list <local> --not <remote sha>
#     <advertised>`, where <advertised> is every branch and tag the
#     destination and each upstream entry advertise in a live, anonymous
#     `git ls-remote` run by the trusted git above from outside the
#     repository, with an empty environment and no git config; locally cached
#     remote-tracking refs, of any remote name, are never trusted, and a read
#     that fails or exits nonzero excludes nothing): author and committer
#     emails must be the identity email or noreply@github.com, and any
#     Co-authored-by or Signed-off-by trailer email must be one of those too;
#   - every outgoing commit's added lines, every added or changed path
#     (binary and empty files and submodules included), and its message, one
#     commit at a time so content added and then deleted inside one push is
#     still seen, against the denylist and the generic patterns;
#   - gitleaks over the same commits (secrets), with in-content allow comments
#     and ignore files disregarded.
# A deletion is checked for its destination only.
#
# PUBLISH JUDGE. Once a public push or public text passes every check above,
# bin/fm-publish-judge.sh reviews the same material semantically with a model
# and refuses what the patterns miss; its header owns the judges, the policy
# categories it is given, its cache, and the captain's override. It never sees
# this directory's private files, and when no judge answers it refuses.
#
# TEXT SHAPE (public PR text; the policy subcommand states the rule): a title
# is at most 100 characters; a body is at most 20 lines and 1500 characters.
# A verified upstream-integration PR into its fork's main may use 80 lines and
# 6000 characters, recording the full upstream source commit in the body.
# Verification uses live GitHub ancestry and the configured upstream remote
# (CI supplies --pr-upstream); failures retain the ordinary cap. The complete
# body still passes every content check and the publish judge.
# A reply is at most 5 lines and 750 characters; and a body or reply must not
# carry what the operator asked or decided ("captain asked", "per <someone>'s
# direction") or the shapes of incident evidence: a process id with its number
# (pid 4242, pid=4242), a tmux pane id (%12), or a clock time (14:05). Everyday
# words such as pid, pane, timeline, or incident are not refused on their own.
# Titles, bodies, and replies failing a limit are refused by rule, never quoted.
#
# GENERIC PATTERNS (no private data; also what CI runs): a Claude session link,
# a home-directory path with a real-looking user name (/Users/<name>/ or
# /home/<name>/, except placeholder names), and, outside tests/, a UUID-shaped
# device id.
#
# LIMITS. Client-side hooks run inside the pushing environment, so this gate is
# friction and detection, not a hard boundary; the hard boundary would be a
# separate publisher that alone holds public-write credentials. The gh publish
# guard, the worker pre-tool policy, and the CI checks are the other layers.
set -u
unset CDPATH
export LC_ALL=C

SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
ROOT="$(cd "$(dirname "$SELF")/.." && pwd -P)"
TAG="fm-publish-gate"
TAB=$(printf '\t')

PG_CONFIG=""
PG_TMP=""

cleanup() {
  [ -z "$PG_TMP" ] || rm -rf "$PG_TMP"
}
trap cleanup EXIT

say() {
  printf '%s: %s\n' "$TAG" "$*" >&2
}

# refuse <reason> <fix>: every refusal names what is wrong and the one command
# (or the one edit) that fixes it.
refuse() {
  say "REFUSED: $1"
  local fix=${2:-}
  [ -n "$fix" ] || fix="read '$(basename "$SELF") policy' and correct what the lines above name"
  say "fix: $fix"
  exit 1
}

usage() {
  sed -n '2,/^set -u$/p' "$SELF" | sed -e '/^set -u$/d' -e 's/^# \{0,1\}//' >&2
  exit 2
}

tmpdir() {
  if [ -z "$PG_TMP" ]; then
    PG_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-publish-gate.XXXXXX") ||
      refuse "cannot create a temporary directory" "mkdir -p \"\${TMPDIR:-/tmp}\" && ls -ld \"\${TMPDIR:-/tmp}\""
  fi
}

# task_hooks_config: print the publish-guard directory the per-task hooks in
# this launch's GIT_CONFIG_* core.hooksPath recorded at install, if any.
task_hooks_config() {
  local i=0 key value hooks="" line=""
  case "${GIT_CONFIG_COUNT:-}" in '' | *[!0-9]*) return 1 ;; esac
  while [ "$i" -lt "$GIT_CONFIG_COUNT" ] && [ "$i" -lt 100 ]; do
    key=GIT_CONFIG_KEY_$i
    value=GIT_CONFIG_VALUE_$i
    if [ "$(lower "${!key:-}")" = core.hookspath ]; then
      hooks=${!value:-}
    fi
    i=$((i + 1))
  done
  [ -n "$hooks" ] && [ -f "$hooks/publish-guard-config" ] || return 1
  IFS= read -r line <"$hooks/publish-guard-config" || [ -n "$line" ] || return 1
  case "$line" in
  /*) printf '%s' "$line" ;;
  *) return 1 ;;
  esac
}

# linked_worktree <dir>: true when <dir> is a linked git worktree, whose git
# dir is not its repository's common dir. A plain clone, a separate-git-dir
# clone, a submodule, or no repository is not; a .git file git cannot read is
# treated as one.
linked_worktree() {
  local gd common
  [ -f "$1/.git" ] || return 1
  gd=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 0
  common=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  [ "$gd" != "$common" ]
}

# home_config: print the owning home's publish-guard directory (PRIVATE CONFIG
# owns the order), or fail when no home owns this invocation.
home_config() {
  if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
    printf '%s/publish-guard' "$FM_CONFIG_OVERRIDE"
  elif [ -n "${FM_HOME:-}" ]; then
    printf '%s/config/publish-guard' "$FM_HOME"
  elif task_hooks_config; then
    :
  elif ! linked_worktree "$ROOT"; then
    printf '%s/config/publish-guard' "$ROOT"
  else
    return 1
  fi
}

# resolve_config: set PG_CONFIG from --config or the owning home, or refuse.
resolve_config() {
  [ -z "$PG_CONFIG" ] || return 0
  PG_CONFIG=$(home_config) ||
    refuse "no firstmate home owns this publish-guard config: FM_HOME is unset, this launch's hooks name none, and $ROOT is a worktree, whose own config is never read" \
      "relaunch the task through bin/fm-spawn.sh so its hooks name its home, or set FM_HOME to the owning firstmate home for this command"
}

config_dir() {
  printf '%s' "$PG_CONFIG"
}

# Print the meaningful lines of a config file: no blanks, no comments, no CR,
# each prefixed with its 1-based line number and a tab.
config_lines() {
  awk '{ sub(/\r$/, "") } /^[[:space:]]*(#|$)/ { next } { print NR "\t" $0 }' "$1"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# --- identity ----------------------------------------------------------------

ID_NAME=""
ID_EMAIL=""
ID_EMAIL_RAW=""

# 0 = loaded, 1 = absent, 2 = malformed.
load_identity() {
  local file line key value
  file="$(config_dir)/identity"
  [ -f "$file" ] || return 1
  ID_NAME=""
  ID_EMAIL=""
  while IFS="$TAB" read -r _ line; do
    key=${line%%=*}
    value=${line#*=}
    [ "$key" != "$line" ] || return 2
    case "$key" in
    name) ID_NAME=$value ;;
    email)
      ID_EMAIL_RAW=$value
      ID_EMAIL=$(lower "$value")
      ;;
    *) return 2 ;;
    esac
  done < <(config_lines "$file")
  [ -n "$ID_NAME" ] || return 2
  case "$ID_EMAIL" in
  *[[:space:]]* | '') return 2 ;;
  ?*@?*.?*) ;;
  *) return 2 ;;
  esac
  return 0
}

# True when <email> may appear on a public commit or in public text.
email_allowed() {
  local email
  email=$(lower "$1")
  [ "$email" = noreply@github.com ] && return 0
  [ -n "$ID_EMAIL" ] && [ "$email" = "$ID_EMAIL" ] && return 0
  if [ -n "${PG_ANY_USER_NOREPLY:-}" ]; then
    case "$email" in
    *@users.noreply.github.com) return 0 ;;
    esac
  fi
  return 1
}

# Reserved example domains (RFC 2606 and RFC 6761) never identify a person.
email_is_placeholder() {
  local domain
  domain=$(lower "${1#*@}")
  case "$domain" in
  example.com | example.org | example.net | *.example.com | *.example.org | *.example.net) return 0 ;;
  example | *.example | invalid | *.invalid | test | *.test | localhost | *.localhost) return 0 ;;
  esac
  return 1
}

# --- destinations --------------------------------------------------------------

# Print owner/repo (lowercase) for a github.com URL, or nothing.
github_slug() {
  local url
  url=$(lower "$1")
  url=$(printf '%s' "$url" | sed -E \
    -e 's#^(https?|git|ssh)://([^@/]+@)?github\.com(:[0-9]+)?/##' \
    -e 's#^[^@/:]+@github\.com:##')
  [ "$url" != "$(lower "$1")" ] || return 0
  url=${url%/}
  url=${url%.git}
  case "$url" in
  */*/* | '') return 0 ;;
  esac
  printf '%s' "$url" | grep -Eq '^[a-z0-9._-]+/[a-z0-9._-]+$' || return 0
  printf '%s' "$url"
}

is_local_url() {
  case "$1" in
  file://*) return 0 ;;
  /* | ./* | ../* | .) return 0 ;;
  *://*) return 1 ;;
  *:*) return 1 ;;
  esac
  return 0
}

resolve_local() {
  local p=${1#file://}
  if [ -d "$p" ]; then
    (cd "$p" 2>/dev/null && pwd -P) && return 0
  fi
  printf '%s' "${p%/}"
}

ALLOW_STATE=""
ALLOW_CLASS=""

# Look up <key> (owner/repo or resolved path) in the allowlist. Sets
# ALLOW_STATE to missing, malformed, listed, or unlisted, and ALLOW_CLASS to
# the listed class.
allowlist_class() {
  local key=$1 file line class dest n
  file="$(config_dir)/allowlist"
  ALLOW_CLASS=""
  if [ ! -f "$file" ]; then
    ALLOW_STATE=missing
    return 0
  fi
  ALLOW_STATE=unlisted
  while IFS="$TAB" read -r n line; do
    class=${line%%[[:space:]]*}
    dest=${line#"$class"}
    dest=$(printf '%s' "$dest" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    case "$class" in
    public | private) ;;
    *)
      ALLOW_STATE=malformed
      say "allowlist line $n: class must be public or private"
      return 0
      ;;
    esac
    [ -n "$dest" ] || {
      ALLOW_STATE=malformed
      say "allowlist line $n: missing destination"
      return 0
    }
    case "$dest" in
    /*) dest=$(resolve_local "$dest") ;;
    *) dest=$(lower "$dest") ;;
    esac
    if [ "$dest" = "$key" ]; then
      ALLOW_STATE=listed
      ALLOW_CLASS=$class
      return 0
    fi
  done < <(config_lines "$file")
}

DEST_CLASS=""
DEST_KEY=""
DEST_WHY=""

classify_destination() {
  local url=$1 slug
  DEST_WHY=""
  if is_local_url "$url"; then
    DEST_KEY=$(resolve_local "$url")
    allowlist_class "$DEST_KEY"
    case "$ALLOW_STATE" in
    listed) DEST_CLASS=$ALLOW_CLASS ;;
    malformed)
      DEST_CLASS=unlisted
      DEST_WHY="the allowlist is malformed"
      ;;
    *) DEST_CLASS=local ;;
    esac
    return 0
  fi
  slug=$(github_slug "$url")
  if [ -z "$slug" ]; then
    DEST_KEY=$url
    DEST_CLASS=unlisted
    DEST_WHY="only exact GitHub owner/repo destinations can be allowlisted"
    return 0
  fi
  DEST_KEY=$slug
  allowlist_class "$slug"
  # A repository of a configured owner needs no allowlist entry: it is treated
  # as private, and a push or text passes only while the privacy read confirms
  # it. A public destination still needs its explicit entry.
  if [ "$ALLOW_STATE" = missing ] || [ "$ALLOW_STATE" = unlisted ]; then
    if account_owners | grep -qxF "${slug%%/*}"; then
      DEST_CLASS=owned
      return 0
    fi
  fi
  case "$ALLOW_STATE" in
  listed) DEST_CLASS=$ALLOW_CLASS ;;
  missing)
    DEST_CLASS=unlisted
    DEST_WHY="the allowlist $(config_dir)/allowlist is missing"
    ;;
  malformed)
    DEST_CLASS=unlisted
    DEST_WHY="the allowlist is malformed"
    ;;
  *)
    DEST_CLASS=unlisted
    DEST_WHY="$slug is not on the allowlist"
    ;;
  esac
}

# Print, lowercased, the GitHub owners whose confirmed-private repositories
# need no allowlist entry: the lines of the private config file owners, else
# the login in the identity's users.noreply.github.com address.
account_owners() {
  local file
  file="$(config_dir)/owners"
  if [ -f "$file" ]; then
    config_lines "$file" | cut -f2- | sed -E 's/[[:space:]]+//g' | tr '[:upper:]' '[:lower:]' | grep -E '^[a-z0-9-]+$'
    return 0
  fi
  load_identity || return 0
  printf '%s\n' "$ID_EMAIL" | sed -nE 's/^([0-9]+\+)?([a-z0-9-]+)@users\.noreply\.github\.com$/\2/p'
}

# refuse_unlisted: the refusal for a destination the allowlist does not admit,
# with the entry that would admit it.
refuse_unlisted() {
  local file
  file="$(config_dir)/allowlist"
  case "$DEST_WHY" in
  "only exact GitHub"*)
    refuse "destination $DEST_KEY is not allowed: $DEST_WHY" "push to a github.com owner/repo or a local path instead; no other host can be allowlisted"
    ;;
  "the allowlist is malformed")
    refuse "destination $DEST_KEY is not allowed: $DEST_WHY" "grep -nvE '^[[:space:]]*(#|\$)|^(public|private)[[:space:]]+[^[:space:]]+[[:space:]]*\$' '$file'  # prints the malformed lines"
    ;;
  esac
  refuse "destination $DEST_KEY is not allowed: $DEST_WHY" "printf 'public %s\\n' '$DEST_KEY' >> '$file'  # only if publishing to $DEST_KEY is intended; write private instead for a private repository"
}

# Print the gh that answers the live privacy read: the absolute path in the
# private config file gh, else the first of the fixed install locations. PATH
# is never consulted, so a gh placed earlier on a worker's PATH cannot answer.
trusted_gh() {
  local file candidate
  file="$(config_dir)/gh"
  if [ -f "$file" ]; then
    candidate=$(config_lines "$file" | cut -f2- | head -n 1)
    case "$candidate" in
    /*) ;;
    *) return 1 ;;
    esac
    [ -f "$candidate" ] && [ -x "$candidate" ] || return 1
    printf '%s' "$candidate"
    return 0
  fi
  for candidate in /opt/homebrew/bin/gh /usr/local/bin/gh /usr/bin/gh; do
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# A live read that confirms a repository private is recorded in the private
# config file private-verdicts as "<owner/repo> <epoch>". When a later live
# read cannot answer (offline, rate-limited, no trusted gh), a verdict younger
# than 24 hours stands in for it; a read that finds the repository public drops
# its verdict at once.
VERDICT_TTL=86400

verdict_epoch() { # <key>: print the recorded epoch, if any
  local file
  file="$(config_dir)/private-verdicts"
  [ -f "$file" ] || return 0
  config_lines "$file" | cut -f2- | awk -v k="$1" '$1 == k && $2 ~ /^[0-9]+$/ { e = $2 } END { if (e != "") print e }'
}

verdict_record() { # <key> [<epoch>]: record a verdict, or drop it with no epoch
  local file tmp
  file="$(config_dir)/private-verdicts"
  tmp=$(mktemp "$file.XXXXXX" 2>/dev/null) || return 0
  if {
    [ ! -f "$file" ] || awk -v k="$1" '$1 != k' "$file"
    [ -z "${2:-}" ] || printf '%s %s\n' "$1" "$2"
  } >"$tmp" && mv -f "$tmp" "$file"; then
    return 0
  fi
  rm -f "$tmp"
}

# private_status <key>: set PRIVATE_STATE to confirmed (a live read says
# private), cached (the live read could not answer and a verdict from the last
# 24 hours says private), public (a live read says public), or unconfirmed.
# The read runs the trusted gh against github.com explicitly, without the
# proxy, host, certificate, and gh-config variables that could route it to
# something else. PRIVATE_GH is the gh used, empty when none was found.
PRIVATE_STATE=""
PRIVATE_GH=""
private_status() {
  local key=$1 out rc epoch now
  case "$key" in
  /*)
    PRIVATE_STATE=confirmed
    return 0
    ;;
  esac
  PRIVATE_STATE=unconfirmed
  if PRIVATE_GH=$(trusted_gh); then
    out=$(env -u GH_HOST -u GH_REPO -u GH_CONFIG_DIR -u XDG_CONFIG_HOME \
      -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy -u ALL_PROXY -u all_proxy \
      -u SSL_CERT_FILE -u SSL_CERT_DIR \
      "$PRIVATE_GH" api --hostname github.com "repos/$key" --jq .private 2>/dev/null)
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = true ]; then
      verdict_record "$key" "$(date +%s)"
      PRIVATE_STATE=confirmed
      return 0
    fi
    if [ "$rc" -eq 0 ] && [ "$out" = false ]; then
      verdict_record "$key"
      PRIVATE_STATE=public
      return 0
    fi
  else
    PRIVATE_GH=""
  fi
  epoch=$(verdict_epoch "$key")
  now=$(date +%s)
  if [ -n "$epoch" ] && [ "$epoch" -le "$now" ] && [ $((now - epoch)) -lt "$VERDICT_TTL" ]; then
    PRIVATE_STATE=cached
  fi
}

# True when <key> is private by a live read or a recent verdict.
private_confirmed() {
  private_status "$1"
  [ "$PRIVATE_STATE" = confirmed ] || [ "$PRIVATE_STATE" = cached ]
}

# private_gate <key>: allow a private destination - an allowlisted private
# entry, or a repository of a configured owner - only while it is private.
# Exits 0 or refuses.
private_gate() {
  local key=$1 file
  file="$(config_dir)/allowlist"
  private_status "$key"
  case "$PRIVATE_STATE" in
  confirmed) exit 0 ;;
  cached)
    say "the live privacy read for $key did not answer; using its private verdict from the last 24 hours"
    exit 0
    ;;
  public)
    [ "$DEST_CLASS" != private ] ||
      refuse "$key is listed private but is public now" "sed -i.bak 's#^private $key\$#public $key#' '$file'  # only if publishing to $key is intended"
    refuse "$key is public and is not on the allowlist" "printf 'public %s\\n' '$key' >> '$file'  # only if publishing to $key is intended"
    ;;
  esac
  [ -n "$PRIVATE_GH" ] ||
    refuse "could not confirm $key is private: no trusted gh at $(config_dir)/gh or a fixed install path, and no verdict from the last 24 hours" "printf '%s\\n' \"\$(command -v gh)\" > '$(config_dir)/gh'"
  refuse "could not confirm $key is private: the live read failed and no verdict from the last 24 hours is cached" "'$PRIVATE_GH' auth status && '$PRIVATE_GH' api --hostname github.com repos/$key --jq .private"
}

# --- scanning -------------------------------------------------------------------

GENERIC_RULES_NAMES="session-link home-path device-id"

# Generic rule regexes. device-id skips locations under tests/.
generic_rule() {
  case "$1" in
  session-link) printf '%s' 'claude\.ai/code/session_' ;;
  home-path) printf '%s' '(^|[^A-Za-z0-9_.-])/(Users|home)/[A-Za-z0-9._-]+/' ;;
  device-id) printf '%s' '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' ;;
  esac
}

# Home-path hits whose user name is a placeholder are not findings.
HOME_PLACEHOLDERS='someone|x|u|me|you|user|username|name|example|fleet|runner|operator|alice|bob|dev|test|tester|home|state|config|data|projects|shared|\.\.\.|<[^>]*>'

# Corpus: $PG_TMP/corpus.txt holds one text line per line and
# $PG_TMP/where.txt the matching "<location>" line.
corpus_reset() {
  tmpdir
  : >"$PG_TMP/corpus.txt"
  : >"$PG_TMP/where.txt"
}

corpus_add() { # <location> <text>
  printf '%s\n' "$2" | tr -d '\r' >>"$PG_TMP/corpus.txt.part"
  local n
  n=$(wc -l <"$PG_TMP/corpus.txt.part" | tr -d ' ')
  cat "$PG_TMP/corpus.txt.part" >>"$PG_TMP/corpus.txt"
  awk -v loc="$1" -v n="$n" 'BEGIN { for (i = 0; i < n; i++) print loc }' >>"$PG_TMP/where.txt"
  rm -f "$PG_TMP/corpus.txt.part"
}

# Append a file's lines with per-line locations "<label>:<n>".
corpus_add_file() { # <label> <file>
  tr -d '\r' <"$2" | awk '{ print }' >>"$PG_TMP/corpus.txt"
  tr -d '\r' <"$2" | awk -v l="$1" '{ print l ":" NR }' >>"$PG_TMP/where.txt"
}

# Added lines, new paths, and the message of one commit. A merge contributes
# only what is new against every parent (git's combined diff), so merging
# upstream's already-public history does not rescan it.
corpus_add_commit() { # <sha>
  local c=$1 short parents nparents
  short=$(git rev-parse --short=12 "$c")
  parents=$(git rev-list --parents -n 1 "$c" | cut -d' ' -f2-)
  [ "$parents" != "$(git rev-parse "$c")" ] || parents=""
  nparents=$(printf '%s' "$parents" | wc -w | tr -d ' ')
  git show -s --format=%B "$c" >"$PG_TMP/msg.txt" || return 1
  corpus_add_file "commit $short message line" "$PG_TMP/msg.txt"
  if [ "$nparents" -gt 1 ]; then
    git diff-tree -r -z -c --name-only --no-commit-id "$c"
  elif [ "$nparents" -eq 1 ]; then
    git diff-tree -r -z -M --name-only --diff-filter=d "$parents" "$c"
  else
    git diff-tree -r -z --root --name-only --no-commit-id "$c"
  fi >"$PG_TMP/paths.bin" || return 1
  corpus_add_paths "commit $short" "$PG_TMP/paths.bin"
  if [ "$nparents" -gt 1 ]; then
    git -c core.quotePath=false diff-tree -p --cc --no-commit-id --no-color --no-ext-diff --no-textconv "$c"
  elif [ "$nparents" -eq 1 ]; then
    git -c core.quotePath=false diff-tree -p -r -M --no-color --no-ext-diff --no-textconv "$parents" "$c"
  else
    git -c core.quotePath=false diff-tree -p -r -M --root --no-commit-id --no-color --no-ext-diff --no-textconv "$c"
  fi >"$PG_TMP/diff.txt" || return 1
  [ "$nparents" -gt 1 ] || nparents=1
  corpus_add_patch "commit $short" "$PG_TMP/diff.txt" "$nparents"
}

# The staged change a commit is about to record: every added or changed path
# and every added line in the index, against HEAD (or nothing, before the first
# commit).
corpus_add_staged() {
  git diff --cached -z --name-only --diff-filter=d >"$PG_TMP/paths.bin" || return 1
  corpus_add_paths "staged" "$PG_TMP/paths.bin"
  git -c core.quotePath=false diff --cached -M --no-color --no-ext-diff --no-textconv >"$PG_TMP/diff.txt" || return 1
  corpus_add_patch "staged" "$PG_TMP/diff.txt" 1
}

# corpus_add_paths <label> <file>: add each NUL-delimited path in <file>, as
# "<label> path <path>". Names come from git's name list rather than a patch,
# because a binary, an empty file, and a submodule have no +++ line; a newline
# inside a name becomes a space so each name stays one corpus line.
corpus_add_paths() {
  tr '\n\0' ' \n' <"$2" >"$PG_TMP/paths.txt"
  awk -v l="$1" -v corpus="$PG_TMP/corpus.txt" -v where="$PG_TMP/where.txt" \
    '{ print >> corpus; print l " path " $0 >> where }' "$PG_TMP/paths.txt"
}

# corpus_add_patch <label> <patch> <parents>: add each line the patch adds, as
# "<label> <path>:<line>"; <parents> is 1 for a plain patch and the parent
# count for a combined merge patch, whose added lines are new against every
# parent.
corpus_add_patch() {
  awk -v l="$1" -v np="$3" -v corpus="$PG_TMP/corpus.txt" -v where="$PG_TMP/where.txt" '
    BEGIN { plus = ""; for (i = 0; i < np; i++) plus = plus "+" }
    /^diff / { inhdr = 1; next }
    inhdr && /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); sub(/\t$/, "", f); next }
    /^@@/ {
      inhdr = 0
      for (i = 2; i <= NF; i++) if (substr($i, 1, 1) == "+") { split($i, a, ","); ln = substr(a[1], 2) + 0; break }
      next
    }
    inhdr { next }
    {
      prefix = substr($0, 1, np)
      if (prefix == plus) { print substr($0, np + 1) >> corpus; print l " " f ":" ln >> where; ln++; next }
      if (index(prefix, "-") == 0 && index(prefix, "\\") == 0) ln++
    }
  ' "$2"
}

FINDINGS=0

# Report a finding by rule and location. A location that itself contains a
# denylisted term (a branch name or a path) is redacted to its commit or ref
# kind, so a refusal never echoes the matched text.
finding() {
  local loc=$2
  FINDINGS=$((FINDINGS + 1))
  [ "$FINDINGS" -le 40 ] || return 0
  if [ -s "${PG_TMP:-/nonexistent}/rules.txt" ] && printf '%s\n' "$loc" | grep -qiE -f "$PG_TMP/rules.txt" 2>/dev/null; then
    case "$loc" in
    commit\ *) loc="$(printf '%s' "$loc" | cut -d' ' -f1-2) (location redacted: it contains a denylisted term)" ;;
    *) loc="${loc%% *} (name redacted: it contains a denylisted term)" ;;
    esac
  fi
  say "finding: $1 at $loc"
}

# Scan the corpus with the denylist. Findings go to stderr as rule id plus
# location.
scan_corpus_denylist() {
  local file n rule hits h loc
  file="$(config_dir)/denylist"
  config_lines "$file" | cut -f2- >"$PG_TMP/rules.txt"
  while IFS="$TAB" read -r n rule; do
    hits=$(grep -niE -e "$rule" "$PG_TMP/corpus.txt" 2>/dev/null)
    case $? in
    0 | 1) ;;
    *)
      FINDINGS=$((FINDINGS + 1))
      say "denylist rule $n is not a valid extended regular expression"
      continue
      ;;
    esac
    for h in $(printf '%s\n' "$hits" | cut -d: -f1); do
      loc=$(sed -n "${h}p" "$PG_TMP/where.txt")
      finding "denylist rule $n" "$loc"
    done
  done < <(config_lines "$file")
}

# Scan the corpus with the denylist (when <use_denylist> is 1) and the generic
# rules. Findings go to stderr as rule id plus location.
scan_corpus() { # <use_denylist>
  local use_denylist=$1 rule hits h loc name
  [ "$use_denylist" != 1 ] || scan_corpus_denylist
  for name in $GENERIC_RULES_NAMES; do
    rule=$(generic_rule "$name")
    case "$name" in
    device-id) hits=$(grep -niE -e "$rule" "$PG_TMP/corpus.txt") ;;
    home-path)
      hits=$(grep -nE -e "$rule" "$PG_TMP/corpus.txt" | while IFS= read -r h; do
        printf '%s\n' "${h#*:}" | grep -oE '/(Users|home)/[A-Za-z0-9._-]+/' |
          grep -viqE "^/(Users|home)/($HOME_PLACEHOLDERS)/$" && printf '%s\n' "$h"
      done)
      ;;
    *) hits=$(grep -nE -e "$rule" "$PG_TMP/corpus.txt") ;;
    esac
    for h in $(printf '%s\n' "$hits" | cut -d: -f1); do
      loc=$(sed -n "${h}p" "$PG_TMP/where.txt")
      if [ "$name" = device-id ]; then
        case "$loc" in
        *" tests/"* | tests/*) continue ;;
        esac
      fi
      finding "generic rule $name" "$loc"
    done
  done
}

# Email addresses in the corpus that are neither allowed nor placeholders.
scan_corpus_emails() {
  local h email loc
  while IFS= read -r h; do
    email=${h#*:}
    email_allowed "$email" && continue
    email_is_placeholder "$email" && continue
    loc=$(sed -n "${h%%:*}p" "$PG_TMP/where.txt")
    finding "email address not on the identity allowlist" "$loc"
  done < <(grep -noE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$PG_TMP/corpus.txt")
}

# What the operator asked or decided, which public PR bodies and replies must
# not carry.
NARRATIVE_RULE='(^|[^a-z])captain (asked|said|wants|wanted|requested|decided|approved|directed)([^a-z]|$)|per [a-z'"'"' ]*(direction|request|instruction)'
# The shapes of incident evidence they must not carry either: a process id with
# its number, a tmux pane id, and a clock time. Shapes, not everyday words.
EVIDENCE_RULE='(^|[^a-z0-9_])pid[ =:]?[0-9]+|(^|[^a-z0-9%])%[0-9]+([^0-9]|$)|(^|[^0-9:])([01]?[0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?([^0-9:]|$)'

# PR context is evidence to verify, never an override. Only PR create/edit and
# ci-text supply it; issues, replies, and other text retain the ordinary cap.
PR_BASE=""
PR_HEAD=""
PR_NUMBER=""
PR_BRANCH=""
PR_UPSTREAM=""
INTEGRATION_SOURCES=""

# Use the same trusted executable and environment isolation as privacy reads.
integration_gh() {
  env -u GH_HOST -u GH_REPO -u GH_CONFIG_DIR -u XDG_CONFIG_HOME \
    -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy -u ALL_PROXY -u all_proxy \
    -u SSL_CERT_FILE -u SSL_CERT_DIR \
    "$INTEGRATION_GH" "$@" 2>/dev/null
}

integration_api() {
  local paging=()
  [ "${3:-}" != paginate ] || paging=(--paginate)
  integration_gh api --hostname github.com "$1" --jq "$2" ${paging[@]+"${paging[@]}"}
}

# Prove a fork-local PR to main contains a two-parent merge since main, whose
# first parent descends from the fork's published main and second parent adds
# upstream ancestry.
# The destination must be this checkout's origin, and its upstream must be
# configured in the owning home's publish guard (or CI's trusted base workflow).
# GitHub supplies the graph; cached refs and caller-supplied SHAs prove nothing.
# No fetch or repository mutation is needed. Any unavailable fact fails closed.
verify_integration() {
  local dest=$1 origin upstream metadata base head repo merges merge first source status count=0
  INTEGRATION_SOURCES=""
  [ -n "$PR_NUMBER" ] || [ -n "$PR_BRANCH" ] || { [ -n "$PR_BASE" ] && [ -n "$PR_HEAD" ]; } || return 0
  printf '%s' "$dest" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || return 0
  INTEGRATION_GH=$(trusted_gh) || return 0
  origin=$(git remote get-url origin 2>/dev/null) || return 0
  [ "$(github_slug "$origin")" = "$(lower "$dest")" ] || return 0
  upstream=$PR_UPSTREAM
  if [ -z "$upstream" ]; then
    upstream=$(git remote get-url upstream 2>/dev/null) || return 0
    upstream=$(github_slug "$upstream")
    [ -n "$upstream" ] || return 0
    upstream_sources | grep -qxF "$upstream" || return 0
  fi
  printf '%s' "$upstream" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || return 0
  [ "$(lower "$upstream")" != "$(lower "$dest")" ] || return 0
  base=$PR_BASE head=$PR_HEAD
  if [ -n "$PR_BRANCH" ] && [ -z "$PR_NUMBER" ]; then
    printf '%s' "$PR_BRANCH" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_./-]*$' || return 0
    PR_NUMBER=$(integration_gh pr view "$PR_BRANCH" --repo "github.com/$dest" --json number --jq .number) || return 0
  fi
  if [ -n "$PR_NUMBER" ]; then
    printf '%s' "$PR_NUMBER" | grep -Eq '^[0-9]+$' || return 0
    metadata=$(integration_api "repos/$dest/pulls/$PR_NUMBER" '[.base.ref, .head.sha, .head.repo.full_name] | @tsv') || return 0
    IFS="$TAB" read -r base head repo <<<"$metadata"
    [ "$(lower "$repo")" = "$(lower "$dest")" ] || return 0
    [ -z "$PR_BASE" ] || base=$PR_BASE
  fi
  [ "$base" = main ] && [ -n "$head" ] || return 0
  # A plain fork-local branch or full SHA only; owner:branch heads do not qualify.
  printf '%s' "$head" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_./-]*$' || return 0
  case "$head" in *..*) return 0 ;; esac
  merges=$(integration_api "repos/$dest/compare/main...$head?per_page=100" '.commits[] | select((.parents | length) == 2) | [.sha, .parents[0].sha, .parents[1].sha] | @tsv' paginate) || return 0
  # Comparison pages are chronological; consider the latest merges first so
  # upstream's own older merges cannot crowd out the integration merge.
  merges=$(printf '%s\n' "$merges" | awk '{ row[NR] = $0 } END { for (i = NR; i > 0; i--) print row[i] }')
  while IFS="$TAB" read -r merge first source; do
    [ -n "$merge" ] || continue
    count=$((count + 1))
    [ "$count" -le 8 ] || break
    printf '%s\n' "$merge" "$first" "$source" | grep -Eqv '^[0-9a-f]{40}$' && continue
    status=$(integration_api "repos/$dest/compare/main...$first" .status) || continue
    case "$status" in ahead | identical) ;; *) continue ;; esac
    status=$(integration_api "repos/$upstream/compare/$source...main" .status) || continue
    case "$status" in ahead | identical) ;; *) continue ;; esac
    status=$(integration_api "repos/$dest/compare/$source...main" .status) || continue
    case "$status" in behind | diverged) ;; *) continue ;; esac
    INTEGRATION_SOURCES="${INTEGRATION_SOURCES:+$INTEGRATION_SOURCES
}$source"
  done <<<"$merges"
}

# Parse optional PR context before text paths. CI's upstream is fixed by its
# trusted base workflow; check-text derives its upstream from this checkout.
parse_text_context() {
  TEXT_ARGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --pr-base | --pr-head | --pr | --pr-branch | --pr-upstream)
      [ "$#" -gt 1 ] || usage
      case "$1" in
      --pr-base) PR_BASE=$2 ;;
      --pr-head) PR_HEAD=$2 ;;
      --pr) PR_NUMBER=$2 ;;
      --pr-branch) PR_BRANCH=$2 ;;
      --pr-upstream) [ "$CMD" = ci-text ] || usage; PR_UPSTREAM=$2 ;;
      esac
      shift 2
      ;;
    *) TEXT_ARGS+=("$1"); shift ;;
    esac
  done
}

# check_shape <kind> <file> <n>: the length and narrative limits of the public
# text policy for a title, body, or reply.
check_shape() {
  local kind=$1 file=$2 n=$3 chars lines body_lines=20 body_chars=1500 source
  chars=$(tr -d '\n' <"$file" | wc -c | tr -d ' ')
  lines=$(grep -c . "$file" || true)
  case "$kind" in
  title)
    [ "$chars" -le 100 ] || finding "shape: a title longer than 100 characters" "text $n"
    ;;
  body)
    while IFS= read -r source; do
      [ -n "$source" ] || continue
      if grep -qE "(^|[^[:alnum:]])$source([^[:alnum:]]|$)" "$file"; then
        body_lines=80 body_chars=6000
        lines=$(awk 'END { print NR + 0 }' "$file")
        break
      fi
    done <<<"$INTEGRATION_SOURCES"
    [ "$lines" -le "$body_lines" ] || finding "shape: a description longer than $body_lines lines" "text $n"
    [ "$chars" -le "$body_chars" ] || finding "shape: a description longer than $body_chars characters" "text $n"
    ;;
  reply)
    [ "$lines" -le 5 ] || finding "shape: a reply longer than 5 lines" "text $n"
    [ "$chars" -le 750 ] || finding "shape: a reply longer than 750 characters" "text $n"
    ;;
  esac
  case "$kind" in
  body | reply)
    if grep -qiE "$NARRATIVE_RULE" "$file"; then
      finding "shape: narrative about what the operator asked or decided" "text $n"
    fi
    if grep -qiE "$EVIDENCE_RULE" "$file"; then
      finding "shape: incident evidence (a process id, a tmux pane id, or a clock time)" "text $n"
    fi
    ;;
  esac
}

# add_texts <text>...: corpus lines plus shape checks for kind-prefixed files.
add_texts() {
  local t kind f i=0
  for t in "$@"; do
    i=$((i + 1))
    case "$t" in
    title:* | body:* | reply:*)
      kind=${t%%:*}
      f=${t#*:}
      ;;
    *)
      kind=other
      f=$t
      ;;
    esac
    [ -r "$f" ] || refuse "cannot read text file $i" "ls -l '$f'  # the text file must exist and be readable"
    corpus_add_file "text $i line" "$f"
    check_shape "$kind" "$f" "$i"
  done
}

# Identity of each outgoing commit (and trailer emails).
check_identities() { # <file of shas>
  local c ae ce short line email
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    short=$(git rev-parse --short=12 "$c")
    ae=$(git show -s --format=%ae "$c")
    ce=$(git show -s --format=%ce "$c")
    email_allowed "$ae" || finding "author email is not the pinned identity" "commit $short"
    email_allowed "$ce" || finding "committer email is not the pinned identity" "commit $short"
    while IFS= read -r line; do
      email=$(printf '%s' "$line" | sed -nE 's/.*<([^>]*)>.*/\1/p')
      [ -n "$email" ] || continue
      email_allowed "$email" || finding "trailer email is not the pinned identity" "commit $short"
    done < <(git show -s --format=%B "$c" | grep -iE '^[[:space:]]*(co-authored-by|signed-off-by):')
  done <"$1"
}

gitleaks_scan() { # <file of shas>
  local rc sub report ignore
  tmpdir
  report="$PG_TMP/gitleaks.json"
  ignore="$PG_TMP/gitleaks-ignore"
  mkdir -p "$ignore"
  if gitleaks git --help >/dev/null 2>&1; then
    sub=git
  else
    sub=detect
  fi
  # One commit per call keeps --no-walk semantics simple and the scan exact.
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if [ "$sub" = git ]; then
      gitleaks git --no-banner --redact --ignore-gitleaks-allow -i "$ignore" \
        --exit-code 3 --report-format json --report-path "$report" \
        --log-opts "--no-walk $c" . >/dev/null 2>&1
    else
      gitleaks detect --no-banner --redact --ignore-gitleaks-allow -i "$ignore" \
        --exit-code 3 --report-format json --report-path "$report" \
        --source . --log-opts "--no-walk $c" >/dev/null 2>&1
    fi
    rc=$?
    case "$rc" in
    0) ;;
    3)
      if command -v jq >/dev/null 2>&1; then
        while IFS= read -r line; do
          finding "gitleaks rule ${line%%"$TAB"*}" "commit $(git rev-parse --short=12 "$c") ${line#*"$TAB"}"
        done < <(jq -r '.[] | "\(.RuleID)\t\(.File):\(.StartLine)"' "$report")
      else
        finding "gitleaks findings" "commit $(git rev-parse --short=12 "$c")"
      fi
      ;;
    *)
      FINDINGS=$((FINDINGS + 1))
      say "gitleaks failed (exit $rc) on commit $(git rev-parse --short=12 "$c")"
      ;;
    esac
  done <"$1"
}

is_zero() {
  case "$1" in
  *[!0]* | '') return 1 ;;
  esac
  return 0
}

# --- publish judge --------------------------------------------------------------

# judge_public <corpus|text> <args>...: the semantic review of a public
# publication that already passed the literal checks. Its refusal prints its
# own findings and fix, so the gate only exits.
judge_public() {
  local mode=$1
  shift
  "$(dirname "$SELF")/fm-publish-judge.sh" "$mode" --dest "$DEST_KEY" --config "$PG_CONFIG" "$@" >/dev/null || exit 1
}

# --- pre-push -------------------------------------------------------------------

# The command that writes the identity file from git's own identity.
identity_fix() {
  printf '%s' "printf 'name=%s\\nemail=%s\\n' \"\$(git config user.name)\" \"\$(git config user.email)\" > '$(config_dir)/identity'  # git's identity must be the noreply address"
}

# require_public_config [<with-gitleaks>]: refuse unless the private config a
# public destination needs is present (and gitleaks, for commit scans).
require_public_config() {
  local dir missing="" fix=""
  dir=$(config_dir)
  load_identity
  case $? in
  1)
    missing="$missing identity"
    fix=$(identity_fix)
    ;;
  2) refuse "$dir/identity is malformed (need name=<name> and email=<email>)" "$(identity_fix)" ;;
  esac
  if [ ! -f "$dir/denylist" ]; then
    missing="$missing denylist"
    [ -n "$fix" ] || fix=": > '$dir/denylist'  # then add one private term (an extended regular expression) per line"
  fi
  if [ "${1:-1}" = 1 ]; then
    if [ ! -f "$dir/poison-commits" ]; then
      missing="$missing poison-commits"
      [ -n "$fix" ] || fix=": > '$dir/poison-commits'  # then add every old commit id that must never be published"
    fi
    if ! command -v gitleaks >/dev/null 2>&1; then
      missing="$missing gitleaks(not-installed)"
      [ -n "$fix" ] || fix="'$ROOT/bin/fm-install-gitleaks.sh' \"\$HOME/.local/bin\"  # then put that directory on PATH"
    fi
  fi
  [ -z "$missing" ] || refuse "public destination $DEST_KEY needs private config that is missing in $dir:$missing" "$fix"
  if [ "${1:-1}" = 1 ] && config_lines "$dir/poison-commits" | cut -f2 | grep -vqE '^[0-9a-f]{40}([0-9a-f]{24})?$'; then
    refuse "$dir/poison-commits has a line that is not a full commit id" "grep -nvE '^[[:space:]]*(#|\$)|^[0-9a-f]{40}([0-9a-f]{24})?\$' '$dir/poison-commits'  # prints the bad lines"
  fi
}

# Print the git that reads what a destination advertises: the absolute path in
# the private config file git, else the first of the fixed install locations.
# PATH is never consulted, so a git placed earlier on a worker's PATH cannot
# answer.
trusted_git() {
  local file candidate
  file="$(config_dir)/git"
  if [ -f "$file" ]; then
    candidate=$(config_lines "$file" | cut -f2- | head -n 1)
    case "$candidate" in
    /*) ;;
    *) return 1 ;;
    esac
    [ -f "$candidate" ] && [ -x "$candidate" ] || return 1
    printf '%s' "$candidate"
    return 0
  fi
  for candidate in /opt/homebrew/bin/git /usr/local/bin/git /usr/bin/git; do
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Print the commit and tag ids a repository advertises in refs/heads and
# refs/tags right now, read anonymously by the trusted git: from / with an
# empty environment (so no PATH, exec path, repository, proxy, ssh, or askpass
# override reaches it), no user or system git config, and no prompt. A GitHub
# owner/repo is read over https, so an answer also proves the repository is
# public; an absolute path is read as a local repository. The ids are accepted
# only from a read that exits 0; otherwise, or with no trusted git, it prints
# nothing, so nothing is exempted.
advertised_ids() { # <owner/repo | /abs/path>
  local where=$1 git out
  case "$where" in
  /*) ;;
  *) where="https://github.com/$where.git" ;;
  esac
  if ! git=$(trusted_git); then
    say "no trusted git at $(config_dir)/git or a fixed install path, so no advertised history is exempt from this scan"
    return 0
  fi
  out=$(cd / && env -i PATH=/usr/bin:/bin HOME=/nonexistent LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    "$git" ls-remote --heads --tags -- "$where" 2>/dev/null) || return 0
  printf '%s\n' "$out" | awk -F '\t' '$1 ~ /^[0-9a-f]+$/ && (length($1) == 40 || length($1) == 64) { print $1 }'
}

# The configured upstream repositories: each meaningful line of the private
# config file upstream is an exact GitHub owner/repo or an absolute local path.
upstream_sources() {
  local file n line
  file="$(config_dir)/upstream"
  [ -f "$file" ] || return 0
  while IFS="$TAB" read -r n line; do
    line=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    case "$line" in
    /*) resolve_local "$line" ;;
    *)
      printf '%s' "$line" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' ||
        refuse "$file line $n: need an exact GitHub owner/repo or an absolute path" "sed -n '${n}p' '$file'  # prints the line to correct"
      lower "$line"
      ;;
    esac
    printf '\n'
  done < <(config_lines "$file")
}

cmd_pre_push() {
  local url=$2 lsha rref rsha excl out src
  classify_destination "$url"
  case "$DEST_CLASS" in
  local) exit 0 ;;
  unlisted) refuse_unlisted ;;
  private | owned) private_gate "$DEST_KEY" ;;
  esac

  require_public_config
  corpus_reset
  : >"$PG_TMP/tips.txt"
  : >"$PG_TMP/public.txt"
  while read -r _ lsha rref rsha; do
    [ -n "${lsha:-}" ] || continue
    is_zero "$lsha" && continue
    case "$rref" in
    refs/tags/*)
      refuse "tag pushes to public destination $DEST_KEY are refused" "git push <remote> <branch>  # push the commit on a branch; a release tag comes from gh release create <tag> --repo $DEST_KEY --target <branch> --notes-file <file>"
      ;;
    esac
    corpus_add "ref $rref" "$rref"
    printf '%s\n' "$lsha" >>"$PG_TMP/tips.txt"
    # The destination's current value of this ref, as the push itself read it.
    if [ -n "${rsha:-}" ] && ! is_zero "$rsha"; then
      printf '%s\n' "$rsha" >>"$PG_TMP/public.txt"
    fi
  done

  # A deletion is checked for its destination only.
  [ -s "$PG_TMP/tips.txt" ] || exit 0

  # Old history first, against everything each pushed tip reaches: no
  # already-public exclusion may hide a poison commit.
  git rev-list --stdin <"$PG_TMP/tips.txt" >"$PG_TMP/reach.txt" ||
    refuse "cannot list the commits the pushed refs reach" "git fsck --connectivity-only  # names the missing objects"
  sort -u "$PG_TMP/reach.txt" -o "$PG_TMP/reach.txt"
  config_lines "$(config_dir)/poison-commits" | cut -f2 | sort -u >"$PG_TMP/poison.txt"
  out=$(comm -12 "$PG_TMP/reach.txt" "$PG_TMP/poison.txt")
  POISON_HIT=""
  if [ -n "$out" ]; then
    for excl in $out; do
      finding "old-history commit" "commit $(printf '%s' "$excl" | cut -c1-12)"
      POISON_HIT=$(git rev-parse --short=12 "$excl")
    done
  fi

  # Already-public history is what the destination and the configured
  # upstream advertise right now, read live; locally cached remote-tracking
  # refs, whatever remote they are named for, are never trusted.
  advertised_ids "$DEST_KEY" >>"$PG_TMP/public.txt"
  upstream_sources >"$PG_TMP/upstreams.txt"
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    advertised_ids "$src" >>"$PG_TMP/public.txt"
  done <"$PG_TMP/upstreams.txt"
  sort -u "$PG_TMP/public.txt" | git cat-file --batch-check='%(objectname) %(objecttype)' |
    awk '$2 == "commit" || $2 == "tag" { print "^" $1 }' >"$PG_TMP/exclude.txt"
  cat "$PG_TMP/tips.txt" "$PG_TMP/exclude.txt" | git rev-list --topo-order --stdin >"$PG_TMP/outgoing.ordered" ||
    refuse "cannot list the outgoing commits" "git fsck --connectivity-only  # names the missing objects"
  sort -u "$PG_TMP/outgoing.ordered" -o "$PG_TMP/outgoing.txt"

  check_identities "$PG_TMP/outgoing.txt"
  while IFS= read -r excl; do
    [ -n "$excl" ] || continue
    corpus_add_commit "$excl" || refuse "cannot read commit $excl" "git fsck --connectivity-only  # names the missing objects"
  done <"$PG_TMP/outgoing.txt"
  scan_corpus 1
  gitleaks_scan "$PG_TMP/outgoing.txt"

  if [ "$FINDINGS" -gt 0 ]; then
    [ "$FINDINGS" -le 40 ] || say "... and $((FINDINGS - 40)) more"
    refuse "$FINDINGS finding(s) on a push to public destination $DEST_KEY (see '$(basename "$SELF") policy')" "$(push_fix)"
  fi
  judge_public corpus "$PG_TMP/corpus.txt" "$PG_TMP/where.txt"
  exit 0
}

# The one command that rewrites a refused push: replace the outgoing commits
# with one clean commit made under the pinned identity (after the flagged lines
# are edited out), or, when old history is in the way, rebuild the new commits
# without it.
push_fix() {
  local oldest base
  if [ -n "${POISON_HIT:-}" ]; then
    printf '%s' "git rebase --onto <last published commit> $POISON_HIT <branch>  # carries only the commits after the old history"
    return 0
  fi
  oldest=$(tail -n 1 "$PG_TMP/outgoing.ordered")
  if [ "$(wc -l <"$PG_TMP/tips.txt" | tr -d ' ')" = 1 ] && base=$(git rev-parse -q --verify "$oldest^" 2>/dev/null); then
    base=$(git rev-parse --short=12 "$base")
  else
    base="<last published commit>"
  fi
  printf '%s' "git reset --soft $base && git commit -m '<neutral summary>'  # after editing out every flagged line; one clean commit replaces the flagged ones"
}

# --- commit-msg -----------------------------------------------------------------

# True when any remote URL of the current repository is public or unlisted.
repo_has_public_remote() {
  local r u
  for r in $(git remote 2>/dev/null); do
    for u in $(git config --get-all "remote.$r.url" 2>/dev/null) $(git config --get-all "remote.$r.pushurl" 2>/dev/null); do
      [ "$u" = DISABLED ] && continue
      classify_destination "$u"
      case "$DEST_CLASS" in
      public | unlisted) return 0 ;;
      esac
    done
  done
  return 1
}

cmd_commit_msg() {
  local msgfile=$1 use_denylist=0
  [ -f "$msgfile" ] || refuse "commit message file not found: $msgfile" "git commit  # run the commit again"
  repo_has_public_remote || exit 0
  load_identity
  [ $? -ne 2 ] || refuse "$(config_dir)/identity is malformed" "$(identity_fix)"
  [ -f "$(config_dir)/denylist" ] && use_denylist=1
  corpus_reset
  # Comment lines are dropped by git before the commit is written.
  grep -v '^#' "$msgfile" >"$PG_TMP/msg.txt"
  corpus_add_file "commit message line" "$PG_TMP/msg.txt"
  scan_corpus "$use_denylist"
  scan_corpus_emails
  if [ "$FINDINGS" -gt 0 ]; then
    refuse "commit message has $FINDINGS finding(s) and this repository has a public remote (see '$(basename "$SELF") policy')" "git commit -m '<what changed, without the flagged text>'"
  fi
  exit 0
}

# --- pre-commit -------------------------------------------------------------------

# The cheap check at commit time, for a repository with a public or unlisted
# remote: the staged added lines and paths against the denylist, the generic
# patterns, and email addresses. The full-history and gitleaks pass stays at
# pre-push.
cmd_pre_commit() {
  local use_denylist=0
  repo_has_public_remote || exit 0
  load_identity
  [ $? -ne 2 ] || refuse "$(config_dir)/identity is malformed" "$(identity_fix)"
  [ -f "$(config_dir)/denylist" ] && use_denylist=1
  corpus_reset
  corpus_add_staged || refuse "cannot read the staged change" "git diff --cached --stat  # shows what git cannot read"
  scan_corpus "$use_denylist"
  scan_corpus_emails
  if [ "$FINDINGS" -gt 0 ]; then
    [ "$FINDINGS" -le 40 ] || say "... and $((FINDINGS - 40)) more"
    refuse "the staged change has $FINDINGS finding(s) and this repository has a public remote (see '$(basename "$SELF") policy')" "git add <each flagged file>  # after editing out the flagged lines, then commit again"
  fi
  exit 0
}

# --- text (gh publish guard) ----------------------------------------------------

cmd_check_text() {
  local dest=$1 unscannable=""
  shift
  parse_text_context "$@"
  set -- ${TEXT_ARGS[@]+"${TEXT_ARGS[@]}"}
  while [ "$#" -gt 0 ] && [ "$1" = --unscannable ]; do
    [ "$#" -gt 1 ] || usage
    unscannable="${unscannable:+$unscannable, }$2"
    shift 2
  done
  if [ "$dest" = gist ]; then
    DEST_KEY=gist
    DEST_CLASS=public
  else
    classify_destination "https://github.com/$dest"
  fi
  case "$DEST_CLASS" in
  unlisted) refuse_unlisted ;;
  private | owned) private_gate "$DEST_KEY" ;;
  esac
  require_public_config 0
  [ -z "$unscannable" ] ||
    refuse "$unscannable cannot be scanned, so it is refused for public destination $DEST_KEY" "publish that file only to a confirmed-private repository, or share it outside GitHub"
  TEXT_ARGS=("$@")
  verify_integration "$DEST_KEY"
  corpus_reset
  add_texts ${TEXT_ARGS[@]+"${TEXT_ARGS[@]}"}
  scan_corpus 1
  scan_corpus_emails
  [ "$FINDINGS" -eq 0 ] ||
    refuse "$FINDINGS finding(s) in text for public destination $DEST_KEY (see '$(basename "$SELF") policy')" "rewrite the flagged text (the rule and line are named above) and run the gh command again"
  judge_public text ${TEXT_ARGS[@]+"${TEXT_ARGS[@]}"}
  exit 0
}

# --- judge preflight --------------------------------------------------------------

cmd_preflight() {
  local f i=0 file
  file="$(config_dir)/denylist"
  [ -f "$file" ] ||
    refuse "no denylist at $file, so no material may go to the publish judge" ": > '$file'  # then add one private term (an extended regular expression) per line"
  corpus_reset
  for f in "$@"; do
    i=$((i + 1))
    [ -r "$f" ] || refuse "cannot read material file $i" "ls -l '$f'  # the material file must exist and be readable"
    corpus_add_file "material $i line" "$f"
  done
  scan_corpus_denylist
  [ "$FINDINGS" -eq 0 ] ||
    refuse "$FINDINGS denylist finding(s) in material for the publish judge, so it is never sent to a model" "remove the flagged text (the rule and line are named above), then run the same command again"
  exit 0
}

# --- CI --------------------------------------------------------------------------

cmd_ci_commits() {
  local base="" head="" email=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --base) base=${2:-}; shift 2 || usage ;;
    --head) head=${2:-}; shift 2 || usage ;;
    --identity-email) email=${2:-}; shift 2 || usage ;;
    *) usage ;;
    esac
  done
  [ -n "$base" ] && [ -n "$head" ] || usage
  if [ -n "$email" ]; then
    ID_EMAIL=$(lower "$email")
  else
    PG_ANY_USER_NOREPLY=1
  fi
  corpus_reset
  git rev-list "$head" --not "$base" >"$PG_TMP/outgoing.txt" ||
    refuse "cannot list $base..$head" "git fetch --no-tags origin '$base'  # the base must be present locally"
  say "checking $(wc -l <"$PG_TMP/outgoing.txt" | tr -d ' ') commit(s) not in $base"
  check_identities "$PG_TMP/outgoing.txt"
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    corpus_add_commit "$c" || refuse "cannot read commit $c" "git fsck --connectivity-only  # names the missing objects"
  done <"$PG_TMP/outgoing.txt"
  scan_corpus 0
  if command -v gitleaks >/dev/null 2>&1; then
    gitleaks_scan "$PG_TMP/outgoing.txt"
  else
    refuse "gitleaks is not installed" "'$ROOT/bin/fm-install-gitleaks.sh' \"\$HOME/.local/bin\"  # then put that directory on PATH"
  fi
  [ "$FINDINGS" -eq 0 ] ||
    refuse "$FINDINGS finding(s) in commits not in $base" "git reset --soft <last clean commit> && git commit -m '<neutral summary>'  # locally, after editing out every flagged line, then push the rewrite"
  say "clean"
  exit 0
}

cmd_ci_text() {
  local dest=${FM_CI_PR_DEST:-}
  PR_NUMBER=${FM_CI_PR_NUMBER:-}
  PR_UPSTREAM=${FM_CI_PR_UPSTREAM:-}
  PG_ANY_USER_NOREPLY=1
  if [ "${1:-}" = --dest ]; then
    dest=${2:-}
    shift 2 || usage
  fi
  parse_text_context "$@"
  [ -z "$dest" ] || verify_integration "$dest"
  corpus_reset
  add_texts ${TEXT_ARGS[@]+"${TEXT_ARGS[@]}"}
  scan_corpus 0
  scan_corpus_emails
  [ "$FINDINGS" -eq 0 ] ||
    refuse "$FINDINGS finding(s) in the pull request text" "gh pr edit <number> --title '<neutral title>' --body-file <file>  # with the flagged text rewritten"
  say "clean"
  exit 0
}

# --- install / disable-push / policy --------------------------------------------

GATE_MARK="# fm-publish-gate hook"

cmd_install() {
  local hooks=$1 name dest cfg_arg=""
  [ -d "$hooks" ] || refuse "hooks directory not found: $hooks" "mkdir -p '$hooks'"
  if [ -n "${PG_CONFIG_SET:-}" ]; then
    case "$PG_CONFIG" in
    /*) ;;
    *) PG_CONFIG="$(pwd -P)/$PG_CONFIG" ;;
    esac
    cfg_arg=" --config $(quote "$PG_CONFIG")"
  fi
  for name in pre-push commit-msg pre-commit; do
    dest="$hooks/$name"
    if [ -e "$dest" ] && ! grep -qF "$GATE_MARK" "$dest"; then
      refuse "$dest exists and was not written by this gate" "mv '$dest' '$dest.local'  # then rerun install and call $name.local from the new hook by hand"
    fi
  done
  cat >"$hooks/pre-push.tmp" <<EOF
#!/usr/bin/env bash
$GATE_MARK
exec $(quote "$SELF") pre-push "\$1" "\$2"$cfg_arg
EOF
  cat >"$hooks/commit-msg.tmp" <<EOF
#!/usr/bin/env bash
$GATE_MARK
exec $(quote "$SELF") commit-msg "\$1"$cfg_arg
EOF
  cat >"$hooks/pre-commit.tmp" <<EOF
#!/usr/bin/env bash
$GATE_MARK
exec $(quote "$SELF") pre-commit$cfg_arg
EOF
  chmod 755 "$hooks/pre-push.tmp" "$hooks/commit-msg.tmp" "$hooks/pre-commit.tmp"
  mv "$hooks/pre-push.tmp" "$hooks/pre-push"
  mv "$hooks/commit-msg.tmp" "$hooks/commit-msg"
  mv "$hooks/pre-commit.tmp" "$hooks/pre-commit"
  say "installed pre-push, commit-msg, and pre-commit in $hooks"
}

quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

suggest_repo() { # <repo-dir>
  local p=$1 url slug
  url=$(git -C "$p" config --get remote.origin.url 2>/dev/null) || return 0
  slug=$(github_slug "$url")
  if [ -z "$slug" ]; then
    printf '# %s: origin is not a GitHub repository; not listed\n' "$(basename "$p")"
    return 0
  fi
  if account_owners | grep -qxF "${slug%%/*}"; then
    printf '# %s: %s passes without an entry while it is private (owner %s)\n' "$(basename "$p")" "$slug" "${slug%%/*}"
    return 0
  fi
  if printf '%s\n' "$UPSTREAM_OWNERS" | grep -qxF "${slug%%/*}"; then
    printf '# %s: %s is never suggested (owner %s is an upstream owner)\n' "$(basename "$p")" "$slug" "${slug%%/*}"
    return 0
  fi
  if private_confirmed "$slug"; then
    printf 'private %s\n' "$slug"
  else
    printf '# %s: %s is not confirmed private; list it as public by hand only if intended\n' "$(basename "$p")" "$slug"
  fi
}

cmd_suggest_allowlist() {
  local home=${FM_HOME:-$ROOT} d p registry
  # The owners of the configured upstream GitHub repositories; read here, not
  # in the pipeline below, so a malformed upstream file ends the command.
  tmpdir
  upstream_sources >"$PG_TMP/upstreams.txt"
  UPSTREAM_OWNERS=$(grep -v '^/' "$PG_TMP/upstreams.txt" | cut -d/ -f1 | sort -u)
  if [ "$#" -eq 0 ]; then
    set -- "${FM_PROJECTS_OVERRIDE:-$home/projects}"
    registry="${FM_DATA_OVERRIDE:-$home/data}/projects.md"
    if [ -f "$registry" ]; then
      while IFS= read -r d; do
        set -- "$@" "$d"
      done < <(grep -oE ' at /[^ ]+' "$registry" | sed -E 's/^ at //; s/[.,;:)]+$//')
    fi
  fi
  for d in "$@"; do
    [ -d "$d" ] || continue
    if git -C "$d" rev-parse --show-toplevel >/dev/null 2>&1 && [ -e "$d/.git" ]; then
      suggest_repo "$d"
      continue
    fi
    for p in "$d"/*/; do
      [ -e "$p/.git" ] || continue
      suggest_repo "$p"
    done
  done | sort -u
}

cmd_disable_push() {
  local repo=$1 remote=${2:-upstream} before
  git -C "$repo" config --get "remote.$remote.url" >/dev/null || refuse "$repo has no remote named $remote" "git -C '$repo' remote -v  # lists the remote names"
  before=$(git -C "$repo" remote get-url --push "$remote") || refuse "cannot read the push URL of $remote" "git -C '$repo' remote -v  # lists the remote URLs"
  printf '%s push before: %s\n' "$remote" "$before"
  git -C "$repo" remote set-url --push "$remote" DISABLED || refuse "cannot set the push URL of $remote" "git -C '$repo' remote set-url --push '$remote' DISABLED"
  printf '%s push after: %s\n' "$remote" "$(git -C "$repo" remote get-url --push "$remote")"
}

cmd_policy() {
  cat <<'EOF'
Public text policy (commit messages, PR titles and bodies, review replies, issue
and release text, gists) for any public destination.
Purpose: never write sensitive information into a public repository; the rules
below are designed to protect against that. Never publish anything that would
tell a stranger about the operator's private life or work: businesses,
clients, people, accounts, machines, locations, or how the work was directed.
Anything published to a public repository stays public permanently, including
in forks and caches.
Sensitive evidence never goes into the PR. The code can.
- Describe the code change and sanitized test evidence only.
- No quotes of the operator's instructions and no "per <someone>'s direction".
- No private project, company, customer, prospect, or task names.
- No local paths, machine names, hardware details, device ids, account or
  service names, or remote-access tools.
- No session or transcript links.
- No incident evidence about private sessions, people, timings, or operations.
- Use neutral fixtures (example.com, acme) that do not mirror a real business
  flow.
- PR titles and descriptions are short and neutral: what changed and how it
  was tested, nothing else. Review replies are short: "fixed in <sha>" or a
  brief reason.
- Changes touching browser automation land through the direct gated path (a
  local merge and a gated push of main only), with no PR discussion.
- Security and operations changes may ship as normal PRs, but their title,
  description, commits, review replies, and changed content still carry no
  private incident evidence.
Incident evidence stays in private reports; a public PR carries only a
sanitized reproduction.
The gh publish guard and CI refuse a title over 100 characters, a description
over 20 lines or 1500 characters (80 lines and 6000 characters for a verified
upstream-integration PR to its fork's main, recording the full upstream source
commit), a reply over 5 lines or 750 characters, and,
in a description or reply, what the operator asked or decided or the shape of
incident evidence: a process id with its number (pid 4242), a tmux pane id
(%12), or a clock time (14:05). Everyday words such as pid, pane, timeline, or
incident are fine on their own.
Integration descriptions stay a technical record: no machine names, runner
details, logs, or full hunk audit. Only the body length cap changes; the whole
description still passes content checks and semantic review. Unverifiable
integration ancestry retains the ordinary cap.
EOF
  printf '\nSemantic review policy:\n'
  "$(dirname "$SELF")/fm-publish-judge.sh" policy
}

# --- dispatch --------------------------------------------------------------------

CMD=${1:-}
[ -n "$CMD" ] || usage
shift
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
  --config)
    [ "$#" -gt 1 ] || usage
    PG_CONFIG=$2
    PG_CONFIG_SET=1
    shift 2
    ;;
  --config=*)
    PG_CONFIG=${1#--config=}
    PG_CONFIG_SET=1
    shift
    ;;
  *)
    ARGS+=("$1")
    shift
    ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

case "$CMD" in
pre-push | commit-msg | pre-commit | check-text | preflight | classify | identity | suggest-allowlist | config-dir)
  resolve_config
  ;;
esac

case "$CMD" in
pre-push)
  [ "$#" -eq 2 ] || usage
  cmd_pre_push "$1" "$2"
  ;;
commit-msg)
  [ "$#" -eq 1 ] || usage
  cmd_commit_msg "$1"
  ;;
pre-commit)
  [ "$#" -eq 0 ] || usage
  cmd_pre_commit
  ;;
check-text)
  [ "$#" -ge 2 ] && [ "$1" = --dest ] || usage
  dest=$2
  shift 2
  cmd_check_text "$dest" "$@"
  ;;
preflight)
  [ "$#" -ge 1 ] || usage
  cmd_preflight "$@"
  ;;
classify)
  [ "$#" -eq 1 ] || usage
  classify_destination "$1"
  printf '%s\n' "$DEST_CLASS"
  ;;
identity)
  [ "$#" -eq 0 ] || usage
  load_identity
  case $? in
  0) printf '%s\t%s\n' "$ID_NAME" "$ID_EMAIL_RAW" ;;
  1) exit 0 ;;
  *) refuse "$(config_dir)/identity is malformed (need name=<name> and email=<email>)" "$(identity_fix)" ;;
  esac
  ;;
ci-commits) cmd_ci_commits "$@" ;;
ci-text)
  [ "$#" -ge 1 ] || usage
  cmd_ci_text "$@"
  ;;
install)
  [ "$#" -eq 1 ] || usage
  cmd_install "$1"
  ;;
suggest-allowlist)
  cmd_suggest_allowlist "$@"
  ;;
disable-push)
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
  cmd_disable_push "$@"
  ;;
config-dir)
  [ "$#" -eq 0 ] || usage
  printf '%s\n' "$PG_CONFIG"
  ;;
policy) cmd_policy ;;
-h | --help | help) usage ;;
*) usage ;;
esac
