#!/usr/bin/env bash
# Behavior tests and seeded validation corpus for the publish gate
# (bin/fm-publish-gate.sh), its per-task hook wiring
# (bin/fm-git-strip-ai-trailers.sh), and the PreToolUse publish policy
# (bin/fm-gh-publish-policy.mjs through bin/fm-arm-pretool-check.sh).
#
# Every leak class the gate targets is seeded here with SYNTHETIC values
# only - a made-up private address, private term, host name, and hardware
# tag - and every push goes to a local bare repository that the
# allowlist marks public. Nothing touches the network: GitHub destinations are
# exercised by calling the hook directly, and `gh` is a local stub.
#
# When a real gitleaks is on PATH the secret cases run against it; otherwise a
# stub that finds nothing stands in, and the gitleaks-only case reports a skip.
set -u

# A fleet pane already carries GIT_CONFIG core.hooksPath. These cases install
# their own hooks, so drop the inherited one before any git command.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-publish-gate.sh"
STRIP="$ROOT/bin/fm-git-strip-ai-trailers.sh"
PRETOOL="$ROOT/bin/fm-arm-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-publish-gate)

# Synthetic stand-ins for the private values the real config holds.
PIN_NAME='Example Owner'
# Fixture emails are assembled at runtime so the committed lines never carry
# an address the staged-change email check would refuse.
PIN_EMAIL="4242+example-owner@""users.noreply.github.com"
LEAK_EMAIL="private.fixture@""synthmail.io"
PRIVATE_TERM='Zorblaxify'
HOST_TERM='hostquux-7'
HARDWARE='hardware tag HWQ-9912'
# Assembled at runtime so this file's own committed lines never match the
# generic patterns it proves.
SESSION_URL="https://claude.ai/code/""session_01SyntheticSessionId"
REAL_HOME_PATH="/Us""ers/fixture-user/file"

CFG="$TMP_ROOT/config/publish-guard"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$CFG" "$FAKEBIN"

REAL_GITLEAKS=0
if command -v gitleaks >/dev/null 2>&1; then
  REAL_GITLEAKS=1
else
  cat >"$FAKEBIN/gitleaks" <<'SH'
#!/usr/bin/env bash
# Stub: accepts the gate's invocation and finds nothing.
exit 0
SH
  chmod +x "$FAKEBIN/gitleaks"
fi
export PATH="$FAKEBIN:$PATH"
# Public pushes and text reach the publish judge after these checks pass; stub
# judges allow everything here, and tests/fm-publish-judge.test.sh covers it.
fm_fake_publish_judges "$FAKEBIN" "$CFG"
export FM_STATE_OVERRIDE="$TMP_ROOT/state"

write_config() {
  printf 'name=%s\nemail=%s\n' "$PIN_NAME" "$PIN_EMAIL" >"$CFG/identity"
  {
    printf '# synthetic denylist\n'
    printf '%s\n' "$PRIVATE_TERM" "$HOST_TERM" 'HWQ-9912' 'synthmail\.io'
  } >"$CFG/denylist"
  : >"$CFG/poison-commits"
  printf 'public %s\n' "$TMP_ROOT/public.git" >"$CFG/allowlist"
  printf 'public acme/widgets\nprivate acme/secret-app\n' >>"$CFG/allowlist"
  reset_trusted_gh
}

# The privacy read's gh is always the local stub path, present or not, so no
# case ever reaches the real gh or the network.
reset_trusted_gh() {
  rm -f "$FAKEBIN/gh"
  printf '%s\n' "$FAKEBIN/gh" >"$CFG/gh"
}

# install_gh_stub [<config-dir>]: a gh that answers only the live privacy read
# for FM_TEST_GH_REPO (acme/secret-app by default) with FM_TEST_GH_PRIVATE
# (true by default), recorded as the trusted gh in the config's gh file; the
# gate never looks gh up on PATH.
install_gh_stub() {
  local cfg=${1:-$CFG}
  cat >"$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
[ "$*" = "api --hostname github.com repos/${FM_TEST_GH_REPO:-acme/secret-app} --jq .private" ] || exit 1
printf '%s\n' "${FM_TEST_GH_PRIVATE:-true}"
SH
  chmod +x "$FAKEBIN/gh"
  printf '%s\n' "$FAKEBIN/gh" >"$cfg/gh"
}

pinned() {
  env GIT_AUTHOR_NAME="$PIN_NAME" GIT_AUTHOR_EMAIL="$PIN_EMAIL" \
    GIT_COMMITTER_NAME="$PIN_NAME" GIT_COMMITTER_EMAIL="$PIN_EMAIL" "$@"
}

unpinned() {
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL "$@"
}

# fresh_repo <name>: a work repo whose origin is the allowlisted public bare
# repository and whose hooks are the gate's installed pre-push and commit-msg.
fresh_repo() {
  local repo="$TMP_ROOT/$1" hooks="$TMP_ROOT/$1.hooks"
  rm -rf "$TMP_ROOT/public.git" "$repo" "$hooks"
  git init -q --bare -b main "$TMP_ROOT/public.git"
  git init -q -b main "$repo"
  mkdir -p "$hooks"
  "$GATE" install "$hooks" --config "$CFG" >/dev/null 2>&1 || fail "gate install failed"
  # These cases prove the push side, so they commit content the staged check
  # would stop at commit time; its own cases keep the pre-commit hook.
  rm -f "$hooks/pre-commit"
  git -C "$repo" config core.hooksPath "$hooks"
  git -C "$repo" remote add origin "$TMP_ROOT/public.git"
  printf 'base\n' >"$repo/README.md"
  git -C "$repo" add README.md
  pinned git -C "$repo" commit -q -m 'initial commit' || fail "initial commit failed"
  printf '%s\n' "$repo"
}

commit_file() { # <repo> <file> <content> <message> [git args...]
  local repo=$1 file=$2 content=$3 msg=$4
  shift 4
  mkdir -p "$(dirname "$repo/$file")"
  printf '%s\n' "$content" >"$repo/$file"
  git -C "$repo" add "$file"
  pinned git -C "$repo" "$@" commit -q -m "$msg"
}

# push_expect <repo> <expected rc 0|1> <label> [refspec]
PUSH_OUT=""
push_expect() {
  local repo=$1 want=$2 label=$3 refspec=${4:-main} rc
  PUSH_OUT=$(git -C "$repo" push -q origin "$refspec" 2>&1)
  rc=$?
  if [ "$want" = 0 ]; then
    [ "$rc" -eq 0 ] || fail "$label: push should pass, got rc=$rc: $PUSH_OUT"
  else
    [ "$rc" -ne 0 ] || fail "$label: push should be refused"
    assert_contains "$PUSH_OUT" "fm-publish-gate: REFUSED" "$label: refusal should come from the gate"
  fi
}

assert_no_secret_echo() { # <output> <label>
  assert_not_contains "$1" "$PRIVATE_TERM" "$2: the refusal must not print the matched text"
  assert_not_contains "$1" "$LEAK_EMAIL" "$2: the refusal must not print the offending email"
  assert_not_contains "$1" "$HOST_TERM" "$2: the refusal must not print the machine name"
}

write_config

# --- S1 identity ----------------------------------------------------------------

test_identity_file_contract() {
  local out rc
  out=$("$GATE" identity --config "$CFG")
  assert_equals "$PIN_NAME"$'\t'"$PIN_EMAIL" "$out" "identity should print name and email"
  out=$("$GATE" identity --config "$TMP_ROOT/no-such-dir")
  assert_equals "" "$out" "an absent identity file should print nothing"
  mkdir -p "$TMP_ROOT/bad-id"
  printf 'email=not-an-address\n' >"$TMP_ROOT/bad-id/identity"
  "$GATE" identity --config "$TMP_ROOT/bad-id" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed identity file should fail"
  pass "identity prints the pinned identity, nothing when absent, and fails when malformed"
}

test_pin_neutralizes_git_c_user_email() {
  local repo ident
  repo="$TMP_ROOT/pin-precedence"
  git init -q -b main "$repo"
  printf 'x\n' >"$repo/a"
  git -C "$repo" add a
  pinned git -C "$repo" -c user.name=Leak -c user.email="$LEAK_EMAIL" commit -q -m 'pinned commit'
  ident=$(git -C "$repo" log -1 --format='%ae %ce')
  assert_equals "$PIN_EMAIL $PIN_EMAIL" "$ident" "with the pin exported, git -c user.email must not change author or committer"
  pass "the identity pin outranks git -c user.email for author and committer"
}

# --- S2 pre-push: every leak class ------------------------------------------------

test_clean_push_passes() {
  local repo
  repo=$(fresh_repo clean)
  commit_file "$repo" src/app.txt 'hello world' 'add app' || fail "commit failed"
  push_expect "$repo" 0 "clean pinned push"
  pass "a clean push by the pinned identity to a public destination passes"
}

test_private_address_via_git_c_is_refused() {
  local repo
  repo=$(fresh_repo leak-c)
  printf 'x\n' >"$repo/a.txt"
  git -C "$repo" add a.txt
  unpinned git -C "$repo" -c user.name=Leak -c user.email="$LEAK_EMAIL" commit -q -m 'add a' || fail "commit failed"
  push_expect "$repo" 1 "git -c user.email"
  assert_contains "$PUSH_OUT" "author email is not the pinned identity" "git -c: author finding"
  assert_contains "$PUSH_OUT" "committer email is not the pinned identity" "git -c: committer finding"
  assert_no_secret_echo "$PUSH_OUT" "git -c"
  pass "a commit made with git -c user.email=<private address> is refused on push"
}

test_private_address_via_author_flag_is_refused() {
  local repo
  repo=$(fresh_repo leak-author)
  printf 'x\n' >"$repo/a.txt"
  git -C "$repo" add a.txt
  pinned git -C "$repo" commit -q --author="Leak <$LEAK_EMAIL>" -m 'add a' || fail "commit failed"
  push_expect "$repo" 1 "--author"
  assert_contains "$PUSH_OUT" "author email is not the pinned identity" "--author finding"
  assert_no_secret_echo "$PUSH_OUT" "--author"
  pass "a commit made with --author=<private address> is refused on push"
}

test_private_address_in_squash_trailer_is_refused() {
  local repo
  repo=$(fresh_repo leak-trailer)
  printf 'x\n' >"$repo/a.txt"
  git -C "$repo" add a.txt
  # The address is written into the message the way a forge squash merge
  # copies a co-author; the commit-msg hook is bypassed deliberately so the
  # push side is what is proven.
  pinned git -C "$repo" -c core.hooksPath=/dev/null commit -q -m 'squash merge' \
    -m "Co-authored-by: Leak <$LEAK_EMAIL>" || fail "commit failed"
  push_expect "$repo" 1 "squash trailer"
  assert_contains "$PUSH_OUT" "trailer email is not the pinned identity" "trailer finding"
  assert_no_secret_echo "$PUSH_OUT" "squash trailer"
  pass "a squash-style Co-authored-by trailer with a private address is refused on push"
}

test_denylist_term_in_content_is_refused() {
  local repo
  repo=$(fresh_repo leak-content)
  printf 'notes about %s here\n' "$PRIVATE_TERM" >"$repo/docs.md"
  git -C "$repo" add docs.md
  pinned git -C "$repo" commit -q -m 'add docs' || fail "commit failed"
  push_expect "$repo" 1 "denylist content"
  assert_contains "$PUSH_OUT" "denylist rule 2 at commit" "denylist finding names the rule and location"
  assert_contains "$PUSH_OUT" "docs.md:1" "denylist finding names file and line"
  assert_no_secret_echo "$PUSH_OUT" "denylist content"
  pass "a private-term mention in pushed content is refused by rule id and location only"
}

test_host_and_hardware_terms_are_refused() {
  local repo
  repo=$(fresh_repo leak-hw)
  printf 'Use %s (%s) for the signed-in browser.\n' "$HOST_TERM" "$HARDWARE" >"$repo/notes.md"
  git -C "$repo" add notes.md
  pinned git -C "$repo" commit -q -m 'add notes' || fail "commit failed"
  push_expect "$repo" 1 "hardware tag"
  assert_contains "$PUSH_OUT" "denylist rule 3" "machine name rule"
  assert_contains "$PUSH_OUT" "denylist rule 4" "hardware rule"
  pass "a host name and hardware tag in pushed content are refused"
}

test_session_url_is_refused() {
  local repo
  repo=$(fresh_repo leak-session)
  printf 'See %s\n' "$SESSION_URL" >"$repo/log.md"
  git -C "$repo" add log.md
  pinned git -C "$repo" commit -q -m 'add log' || fail "commit failed"
  push_expect "$repo" 1 "session url"
  assert_contains "$PUSH_OUT" "generic rule session-link" "session link finding"
  pass "a Claude session link in pushed content is refused by the generic rule"
}

test_added_then_deleted_in_one_push_is_refused() {
  local repo
  repo=$(fresh_repo leak-deleted)
  printf 'token for %s\n' "$PRIVATE_TERM" >"$repo/tmp.txt"
  git -C "$repo" add tmp.txt
  pinned git -C "$repo" commit -q -m 'add tmp' || fail "commit failed"
  git -C "$repo" rm -q tmp.txt
  pinned git -C "$repo" commit -q -m 'remove tmp' || fail "commit failed"
  [ ! -e "$repo/tmp.txt" ] || fail "the tip should not contain the file"
  push_expect "$repo" 1 "added then deleted"
  assert_contains "$PUSH_OUT" "tmp.txt:1" "the finding points at the intermediate commit"
  pass "content added and then deleted inside one push is still refused"
}

test_secret_added_then_deleted_is_refused_by_gitleaks() {
  local repo key
  if [ "$REAL_GITLEAKS" -eq 0 ]; then
    printf 'skip: gitleaks not installed (secret-scanner case)\n'
    return 0
  fi
  repo=$(fresh_repo leak-secret)
  # Assembled at runtime so no secret-shaped literal is committed here.
  key="ghp_$(printf 'Z%.0s' $(seq 1 16))9a8b7c6d5e4f3a2b1c0d"
  printf 'GITHUB_TOKEN=%s\n' "$key" >"$repo/env.sh"
  git -C "$repo" add env.sh
  pinned git -C "$repo" commit -q -m 'add env' || fail "commit failed"
  git -C "$repo" rm -q env.sh
  pinned git -C "$repo" commit -q -m 'remove env' || fail "commit failed"
  push_expect "$repo" 1 "secret added then deleted"
  assert_contains "$PUSH_OUT" "gitleaks rule" "gitleaks finding"
  assert_not_contains "$PUSH_OUT" "$key" "the refusal must not print the secret"
  pass "a secret added then deleted in one push is refused by gitleaks"
}

test_old_history_commit_is_refused() {
  local repo old
  repo=$(fresh_repo leak-old)
  printf 'old\n' >"$repo/old.txt"
  git -C "$repo" add old.txt
  pinned git -C "$repo" commit -q -m 'old history' || fail "commit failed"
  old=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n' "$old" >"$CFG/poison-commits"
  push_expect "$repo" 1 "old history"
  assert_contains "$PUSH_OUT" "old-history commit" "old-history finding"
  : >"$CFG/poison-commits"
  pass "a push carrying a commit from the old-history list is refused"
}

test_sensitive_branch_name_is_refused() {
  local repo
  repo=$(fresh_repo leak-branch)
  git -C "$repo" branch "fm/$PRIVATE_TERM-plan"
  push_expect "$repo" 1 "sensitive branch" "fm/$PRIVATE_TERM-plan"
  assert_contains "$PUSH_OUT" "denylist rule 2 at ref (name redacted" "branch-name finding"
  assert_no_secret_echo "$PUSH_OUT" "sensitive branch"
  pass "a push to a branch whose name hits the denylist is refused"
}

test_home_path_rule_spares_placeholders() {
  local repo
  repo=$(fresh_repo home-paths)
  printf 'cp /Users/someone/file .\n' >"$repo/ok.md"
  git -C "$repo" add ok.md
  pinned git -C "$repo" commit -q -m 'placeholder path' || fail "commit failed"
  push_expect "$repo" 0 "placeholder home path"
  printf 'cp %s .\n' "$REAL_HOME_PATH" >"$repo/bad.md"
  git -C "$repo" add bad.md
  pinned git -C "$repo" commit -q -m 'real path' || fail "commit failed"
  push_expect "$repo" 1 "real home path"
  assert_contains "$PUSH_OUT" "generic rule home-path" "home path finding"
  pass "a real-looking home path is refused and a placeholder one is not"
}

test_deletion_push_checks_destination_only() {
  local repo
  repo=$(fresh_repo deletion)
  push_expect "$repo" 0 "seed main"
  git -C "$repo" push -q origin main:refs/heads/scratch 2>/dev/null || fail "seed scratch failed"
  push_expect "$repo" 0 "delete scratch" ":refs/heads/scratch"
  pass "a ref deletion to an allowlisted destination passes"
}

# An upstream merge contributes only what is new against every parent: upstream's
# own already-public commits are exempt, and a merge that adds new text of its
# own is still scanned.
test_upstream_merge_scans_only_new_merge_content() {
  local repo up
  repo=$(fresh_repo merge)
  push_expect "$repo" 0 "seed main"
  up="$TMP_ROOT/upstream-src"
  rm -rf "$up"
  git clone -q "$TMP_ROOT/public.git" "$up"
  printf 'upstream docs: %s\n' "$REAL_HOME_PATH" >"$up/upstream.md"
  git -C "$up" add upstream.md
  git -C "$up" -c user.name=Upstream -c user.email=dev@upstream.invalid commit -q -m 'upstream change'
  git -C "$repo" remote add upstream "$up"
  git -C "$repo" fetch -q upstream
  # Upstream's history is exempt only as the configured upstream advertises it.
  printf '%s\n' "$up" >"$CFG/upstream"
  printf 'fork\n' >"$repo/fork.md"
  git -C "$repo" add fork.md
  pinned git -C "$repo" commit -q -m 'fork change'
  pinned git -C "$repo" merge -q --no-edit upstream/main || fail "merge failed"
  push_expect "$repo" 0 "clean upstream merge"
  printf 'more\n' >"$up/more.md"
  git -C "$up" add more.md
  git -C "$up" -c user.name=Upstream -c user.email=dev@upstream.invalid commit -q -m 'upstream more'
  git -C "$repo" fetch -q upstream
  pinned git -C "$repo" merge -q --no-commit upstream/main || true
  printf 'resolved for %s\n' "$PRIVATE_TERM" >"$repo/fork.md"
  git -C "$repo" add fork.md
  pinned git -C "$repo" -c core.hooksPath=/dev/null commit -q --no-edit || fail "evil merge commit failed"
  push_expect "$repo" 1 "evil merge"
  assert_contains "$PUSH_OUT" "fork.md:1" "evil merge finding"
  rm -f "$CFG/upstream"
  pass "an upstream merge passes while new text added inside the merge itself is refused"
}

# Locally cached remote-tracking refs are not proof that the destination holds
# a commit: a remote repointed at a new public repository keeps its old
# tracking refs until a fetch, and any ref can be written under a remote name.
test_cached_remote_refs_never_exempt_history() {
  local repo leak poison
  repo=$(fresh_repo stale-origin)
  rm -rf "$TMP_ROOT/old-archive.git"
  git init -q --bare -b main "$TMP_ROOT/old-archive.git"
  git -C "$repo" remote set-url origin "$TMP_ROOT/old-archive.git"
  printf 'notes for %s\n' "$PRIVATE_TERM" >"$repo/old.md"
  git -C "$repo" add old.md
  pinned git -C "$repo" -c core.hooksPath=/dev/null commit -q -m 'old history' || fail "commit failed"
  push_expect "$repo" 0 "push to the unlisted local archive"
  [ -n "$(git -C "$repo" rev-parse -q --verify refs/remotes/origin/main)" ] || fail "the archive push should leave a tracking ref"
  git -C "$repo" remote set-url origin "$TMP_ROOT/public.git"
  push_expect "$repo" 1 "repointed origin with a stale tracking ref"
  assert_contains "$PUSH_OUT" "old.md:1" "the commit only the stale tracking ref holds is scanned"

  repo=$(fresh_repo cached-upstream)
  git -C "$repo" checkout -q -b topic
  printf 'draft for %s\n' "$PRIVATE_TERM" >"$repo/draft.md"
  git -C "$repo" add draft.md
  pinned git -C "$repo" -c core.hooksPath=/dev/null commit -q -m 'draft' || fail "commit failed"
  leak=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" update-ref refs/remotes/upstream/saved "$leak"
  git -C "$repo" update-ref refs/remotes/origin/old-archive-branch "$leak"
  push_expect "$repo" 1 "content under cached upstream and origin refs" topic
  assert_contains "$PUSH_OUT" "draft.md:1" "a cached ref named upstream or origin exempts nothing"

  repo=$(fresh_repo cached-poison)
  git -C "$repo" checkout -q -b topic
  commit_file "$repo" clean.txt 'clean' 'clean but old' || fail "commit failed"
  poison=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n' "$poison" >"$CFG/poison-commits"
  git -C "$repo" update-ref refs/remotes/origin/old-archive-branch "$poison"
  push_expect "$repo" 1 "poison under a cached origin ref" topic
  assert_contains "$PUSH_OUT" "old-history commit" "poison reached through a cached origin ref"
  git -C "$repo" update-ref -d refs/remotes/origin/old-archive-branch
  git -C "$repo" update-ref refs/remotes/upstream/saved "$poison"
  push_expect "$repo" 1 "poison under a cached upstream ref" topic
  assert_contains "$PUSH_OUT" "old-history commit" "poison reached through a cached upstream ref"
  : >"$CFG/poison-commits"
  pass "cached remote-tracking refs exempt neither poison commits nor content from a public push"
}

# A poison commit is refused even when the destination already advertises it:
# old history is checked against everything the pushed tip reaches.
test_poison_is_checked_before_any_exemption() {
  local repo poison
  repo=$(fresh_repo poison-advertised)
  push_expect "$repo" 0 "seed main"
  poison=$(git -C "$repo" rev-parse HEAD)
  commit_file "$repo" more.txt more 'more' || fail "commit failed"
  printf '%s\n' "$poison" >"$CFG/poison-commits"
  push_expect "$repo" 1 "tip reaching an advertised poison commit"
  assert_contains "$PUSH_OUT" "old-history commit" "advertised poison is still refused"
  : >"$CFG/poison-commits"
  pass "old-history commits are refused before any already-public exemption applies"
}

# The live advertisement read is the one that can exempt outgoing commits, so
# it comes from the trusted git, run with an empty environment, and counts
# only when that git exits 0: neither a git earlier on PATH nor a trusted git
# that fails after printing can forge what the destination holds.
test_advertised_history_comes_from_the_trusted_git() {
  local repo child real_git forger="$TMP_ROOT/adv-forger" failing="$TMP_ROOT/adv-failing-forger" shadow="$TMP_ROOT/adv-shadow" out rc
  real_git=$(command -v git)
  repo=$(fresh_repo adv-history)
  commit_file "$repo" notes.md "notes for $PRIVATE_TERM" 'add notes' || fail "commit failed"
  child=$(git -C "$repo" rev-parse HEAD)
  mkdir -p "$shadow"
  # A git that answers ls-remote with the outgoing commit, as if the
  # destination already held it, and runs the real git for everything else;
  # the failing one exits 128 after printing. The read runs with an empty
  # environment, so each script carries its own values.
  for rc in 0 128; do
    cat >"$TMP_ROOT/adv-forger-$rc" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = ls-remote ]; then
  printf '%s\trefs/heads/main\n' "$child"
  exit $rc
fi
exec "$real_git" "\$@"
SH
    chmod +x "$TMP_ROOT/adv-forger-$rc"
  done
  mv "$TMP_ROOT/adv-forger-0" "$forger"
  mv "$TMP_ROOT/adv-forger-128" "$failing"
  cp "$forger" "$shadow/git"
  adv_push() {
    out=$(cd "$repo" && printf 'refs/heads/main %s refs/heads/main %040d\n' "$child" 0 |
      "$GATE" pre-push origin "$TMP_ROOT/public.git" --config "$CFG" 2>&1)
  }
  adv_push
  rc=$?
  [ "$rc" -eq 1 ] || fail "the leaking commit should be refused on its own (rc=$rc): $out"
  assert_contains "$out" "notes.md:1" "the outgoing commit is scanned"

  # Control: a configured trusted git is believed, so the forger is live.
  printf '%s\n' "$forger" >"$CFG/git"
  adv_push
  rc=$?
  [ "$rc" -eq 0 ] || fail "a configured trusted git's advertisement should exempt the commit (rc=$rc): $out"

  printf '%s\n' "$failing" >"$CFG/git"
  adv_push
  rc=$?
  [ "$rc" -eq 1 ] || fail "ids from a trusted git that exited nonzero must exempt nothing (rc=$rc)"
  assert_contains "$out" "notes.md:1" "the failed read exempted nothing"

  rm -f "$CFG/git"
  PATH="$shadow:$PATH" adv_push
  rc=$?
  [ "$rc" -eq 1 ] || fail "a git earlier on PATH must not answer the advertisement read (rc=$rc)"
  assert_contains "$out" "notes.md:1" "the PATH-shadowed read exempted nothing"
  printf '%s\n' "$TMP_ROOT/no-such-git" >"$CFG/git"
  PATH="$shadow:$PATH" adv_push
  rc=$?
  [ "$rc" -eq 1 ] || fail "a configured git that does not exist must exempt nothing (rc=$rc)"
  assert_contains "$out" "no trusted git" "names the missing trusted git"
  rm -f "$CFG/git"
  [ -z "$(git -C "$TMP_ROOT/public.git" rev-list --all)" ] || fail "the destination must still be empty"
  unset -f adv_push
  pass "only the trusted git's successful live read can exempt history, never a git on PATH or a failed read"
}

# --- extra history and ref cases -------------------------------------------------

test_amend_cherry_pick_and_rebase_keep_the_leak_visible() {
  local repo
  # amend: an amend that switches the author to a private address.
  repo=$(fresh_repo amend)
  commit_file "$repo" a.txt one 'add a' || fail "commit failed"
  pinned git -C "$repo" commit -q --amend --no-edit --author="Leak <$LEAK_EMAIL>" || fail "amend failed"
  push_expect "$repo" 1 "amend with --author"
  assert_contains "$PUSH_OUT" "author email is not the pinned identity" "amend finding"
  # cherry-pick: git keeps the original author of the picked commit.
  repo=$(fresh_repo cherry)
  git -C "$repo" checkout -q -b side
  printf 'side\n' >"$repo/side.txt"
  git -C "$repo" add side.txt
  unpinned git -C "$repo" -c user.name=Leak -c user.email="$LEAK_EMAIL" commit -q -m 'side change'
  git -C "$repo" checkout -q main
  pinned git -C "$repo" cherry-pick side >/dev/null || fail "cherry-pick failed"
  push_expect "$repo" 1 "cherry-pick"
  assert_contains "$PUSH_OUT" "author email is not the pinned identity" "cherry-pick finding"
  assert_not_contains "$PUSH_OUT" "committer email" "the pinned committer of the pick is allowed"
  # rebase: the replayed commit keeps its private author.
  repo=$(fresh_repo rebase)
  git -C "$repo" checkout -q -b topic
  printf 'topic\n' >"$repo/topic.txt"
  git -C "$repo" add topic.txt
  unpinned git -C "$repo" -c user.name=Leak -c user.email="$LEAK_EMAIL" commit -q -m 'topic change'
  git -C "$repo" checkout -q main
  commit_file "$repo" main.txt m 'main change' || fail "commit failed"
  git -C "$repo" checkout -q topic
  pinned git -C "$repo" rebase -q main || fail "rebase failed"
  push_expect "$repo" 1 "rebase" topic:refs/heads/main
  assert_contains "$PUSH_OUT" "author email is not the pinned identity" "rebase finding"
  pass "amend, cherry-pick, and rebase cannot launder a private author past the gate"
}

test_author_and_committer_email_config_keys() {
  local repo ident
  repo=$(fresh_repo cfg-keys)
  printf 'x\n' >"$repo/x.txt"
  git -C "$repo" add x.txt
  pinned git -C "$repo" -c author.email="$LEAK_EMAIL" -c committer.email="$LEAK_EMAIL" commit -q -m 'pinned wins'
  ident=$(git -C "$repo" log -1 --format='%ae %ce')
  assert_equals "$PIN_EMAIL $PIN_EMAIL" "$ident" "the pin must outrank author.email and committer.email config keys"
  printf 'y\n' >"$repo/y.txt"
  git -C "$repo" add y.txt
  unpinned git -C "$repo" -c user.name=U -c user.email="$PIN_EMAIL" \
    -c author.email="$LEAK_EMAIL" -c committer.email="$LEAK_EMAIL" commit -q -m 'config keys'
  push_expect "$repo" 1 "author.email/committer.email keys"
  assert_contains "$PUSH_OUT" "author email is not the pinned identity" "author.email finding"
  assert_contains "$PUSH_OUT" "committer email is not the pinned identity" "committer.email finding"
  policy "git -c author.email=$LEAK_EMAIL commit -m x"
  [ $? -eq 2 ] || fail "git -c author.email should be refused by the policy layer"
  policy "git -c committer.email=$LEAK_EMAIL commit -m x"
  [ $? -eq 2 ] || fail "git -c committer.email should be refused by the policy layer"
  pass "author.email and committer.email keys are outranked by the pin, refused on push, and refused as commands"
}

test_new_branch_and_tag_pushes() {
  local repo
  repo=$(fresh_repo new-branch)
  push_expect "$repo" 0 "seed main"
  git -C "$repo" checkout -q -b feature
  printf 'feature for %s\n' "$PRIVATE_TERM" >"$repo/f.txt"
  git -C "$repo" add f.txt
  pinned git -C "$repo" commit -q -m 'feature'
  push_expect "$repo" 1 "new branch" feature
  assert_contains "$PUSH_OUT" "f.txt:1" "a new branch's commits are scanned"
  git -C "$repo" checkout -q main
  git -C "$repo" tag v1.0.0
  push_expect "$repo" 1 "lightweight tag" v1.0.0
  assert_contains "$PUSH_OUT" "tag pushes to public destination" "tag refusal"
  pinned git -C "$repo" tag -a v1.0.1 -m 'release'
  push_expect "$repo" 1 "annotated tag" v1.0.1
  assert_contains "$PUSH_OUT" "tag pushes to public destination" "annotated tag refusal"
  pass "a new branch is scanned in full and tag pushes to a public destination are refused"
}

test_artifact_file_names_are_scanned() {
  local repo name
  for name in "screenshots/$HOST_TERM-browser.png" "logs/$PRIVATE_TERM-run.log" "artifacts/har-$HOST_TERM.har"; do
    repo=$(fresh_repo artifact)
    mkdir -p "$repo/$(dirname "$name")"
    printf 'binary-ish\n' >"$repo/$name"
    git -C "$repo" add "$name"
    pinned git -C "$repo" commit -q -m 'add artifact'
    push_expect "$repo" 1 "artifact $name"
    assert_contains "$PUSH_OUT" "location redacted" "artifact path finding is redacted"
    assert_no_secret_echo "$PUSH_OUT" "artifact name"
  done
  pass "screenshot, log, and artifact file names that carry private terms are refused without echoing them"
}

# A binary or an empty file has no +++ line in git's patch, so its name must
# come from the tree diff itself.
test_binary_and_empty_file_names_are_scanned() {
  local repo name
  for name in "screenshots/$PRIVATE_TERM.png" "notes/$HOST_TERM.txt"; do
    repo=$(fresh_repo binary-name)
    mkdir -p "$repo/$(dirname "$name")"
    case "$name" in
    *.png) printf '\211PNG\r\n\032\n\000\000\000\015IHDR\000\001' >"$repo/$name" ;;
    *) : >"$repo/$name" ;;
    esac
    git -C "$repo" add "$name"
    pinned git -C "$repo" commit -q -m 'add artifact'
    if git -C "$repo" show --format= HEAD | grep '^+++ ' >/dev/null; then
      fail "the fixture must have no +++ line, or it does not prove the name is read elsewhere: $name"
    fi
    push_expect "$repo" 1 "binary or empty $name"
    assert_contains "$PUSH_OUT" "location redacted" "the name of a binary or empty file is scanned"
    assert_no_secret_echo "$PUSH_OUT" "binary name"
  done
  pass "binary and empty files whose names carry private terms are refused"
}

# The permission-policy suite's synthetic decision ids must not read as
# secrets to the pinned scanner, or the fork's own history fails the public
# leak check.
test_permission_fixtures_pass_the_secret_scan() {
  local repo base out
  if [ "$REAL_GITLEAKS" -eq 0 ]; then
    printf 'skip: gitleaks not installed (permission-fixture scan)\n'
    return 0
  fi
  repo="$TMP_ROOT/fixture-scan"
  fm_git_init_commit "$repo" >/dev/null
  base=$(git -C "$repo" rev-parse HEAD)
  mkdir -p "$repo/tests"
  cp "$ROOT/tests/fm-agy-permission-policy.test.sh" "$repo/tests/"
  git -C "$repo" add tests
  pinned git -C "$repo" commit -q -m 'add permission fixtures'
  out=$(cd "$repo" && "$GATE" ci-commits --base "$base" --head HEAD --identity-email "$PIN_EMAIL" 2>&1) \
    || fail "the permission-policy fixtures must pass the pinned secret scan: $out"
  pass "the permission-policy fixtures pass the public leak check's secret scan"
}

# --- S6 destinations ----------------------------------------------------------------

hook_direct() { # <remote-name> <url> -> rc, output in HOOK_OUT
  local repo="$TMP_ROOT/direct"
  [ -d "$repo/.git" ] || fm_git_init_commit "$repo" >/dev/null
  HOOK_OUT=$(cd "$repo" && printf 'refs/heads/main %s refs/heads/main %040d\n' "$(git rev-parse HEAD)" 0 |
    "$GATE" pre-push "$1" "$2" --config "$CFG" 2>&1)
}

test_unlisted_github_destination_is_refused() {
  local rc
  hook_direct upstream https://github.com/example-org/upstream.git
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unlisted upstream destination should be refused"
  assert_contains "$HOOK_OUT" "example-org/upstream is not on the allowlist" "unlisted reason"
  hook_direct origin git@github.com:someone-else/fork.git
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unlisted SSH destination should be refused"
  if hook_direct origin https://gitlab.com/acme/widgets.git; then
    fail "a non-GitHub network destination should be refused"
  fi
  pass "unlisted GitHub destinations (including an upstream's) and non-GitHub hosts are refused"
}

test_missing_allowlist_refuses_network_and_allows_local() {
  local saved="$TMP_ROOT/allowlist.saved" rc repo
  mv "$CFG/allowlist" "$saved"
  hook_direct origin https://github.com/acme/widgets.git
  rc=$?
  [ "$rc" -ne 0 ] || fail "a network push with no allowlist should be refused"
  assert_contains "$HOOK_OUT" "allowlist" "missing-allowlist reason"
  repo=$(fresh_repo unlisted-local)
  printf '%s\n' "$PRIVATE_TERM" >"$repo/x.md"
  git -C "$repo" add x.md
  pinned git -C "$repo" commit -q -m x
  push_expect "$repo" 0 "unlisted local destination"
  mv "$saved" "$CFG/allowlist"
  pass "with no allowlist a network push is refused while an unlisted local path passes unscanned"
}

test_missing_private_config_refuses_public_push() {
  local repo name
  for name in denylist identity poison-commits; do
    repo=$(fresh_repo "missing-$name")
    mv "$CFG/$name" "$CFG/$name.saved"
    push_expect "$repo" 1 "missing $name"
    assert_contains "$PUSH_OUT" "missing" "missing $name reason"
    assert_contains "$PUSH_OUT" "$name" "missing $name names the file"
    mv "$CFG/$name.saved" "$CFG/$name"
  done
  pass "a public push is refused when identity, denylist, or poison-commits is missing"
}

test_missing_gitleaks_refuses_public_push() {
  local repo path_sans
  repo=$(fresh_repo missing-gitleaks)
  path_sans=$(fm_test_base_path_sans "$PATH" gitleaks)
  PUSH_OUT=$(PATH="$path_sans" git -C "$repo" push -q origin main 2>&1) && fail "a public push without gitleaks should be refused"
  assert_contains "$PUSH_OUT" "gitleaks" "missing gitleaks reason"
  pass "a public push is refused when gitleaks is not installed"
}

test_private_destination_needs_live_confirmation() {
  local rc
  install_gh_stub
  hook_direct origin https://github.com/acme/secret-app.git
  rc=$?
  [ "$rc" -eq 0 ] || fail "a confirmed private destination should pass: $HOOK_OUT"
  FM_TEST_GH_PRIVATE=false hook_direct origin https://github.com/acme/secret-app.git
  rc=$?
  [ "$rc" -ne 0 ] || fail "a private entry that is no longer private should be refused"
  assert_contains "$HOOK_OUT" "acme/secret-app is listed private but is public now" "public-now reason"
  assert_contains "$HOOK_OUT" "fix: sed -i.bak 's#^private acme/secret-app\$#public acme/secret-app#'" "public-now fix line"
  rm -f "$FAKEBIN/gh"
  if hook_direct origin https://github.com/acme/secret-app.git; then
    fail "a private entry whose live read fails should be refused"
  fi
  assert_contains "$HOOK_OUT" "could not confirm acme/secret-app is private" "unconfirmed private reason"
  assert_contains "$HOOK_OUT" "fix: printf '%s\\n' \"\$(command -v gh)\" > '$CFG/gh'" "missing trusted gh fix line"
  reset_trusted_gh
  pass "a private allowlist entry passes unscanned only while a live read confirms it is private"
}

# The privacy read must come from the trusted gh, not whatever gh or proxy the
# pushing environment supplies: here the trusted gh reports the repository
# public, as a repository flipped public would read.
test_private_check_ignores_worker_gh_and_proxy() {
  local shadow="$TMP_ROOT/shadow-bin" rc
  install_gh_stub
  mkdir -p "$shadow"
  printf '#!/usr/bin/env bash\nprintf "true\\n"\n' >"$shadow/gh"
  chmod +x "$shadow/gh"
  FM_TEST_GH_PRIVATE=false PATH="$shadow:$PATH" hook_direct origin https://github.com/acme/secret-app.git
  rc=$?
  [ "$rc" -ne 0 ] || fail "a gh earlier on PATH must not answer the privacy read"
  assert_contains "$HOOK_OUT" "acme/secret-app is listed private but is public now" "PATH-shadowed gh reason"
  # A trusted gh that a proxy would talk into answering private.
  cat >"$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
if [ -n "${HTTPS_PROXY:-}${GH_HOST:-}${GH_CONFIG_DIR:-}" ]; then printf 'true\n'; else printf 'false\n'; fi
SH
  if HTTPS_PROXY=http://127.0.0.1:9 GH_HOST=ghe.example GH_CONFIG_DIR="$TMP_ROOT" hook_direct origin https://github.com/acme/secret-app.git; then
    fail "proxy, host, and gh-config variables must not reach the privacy read"
  fi
  printf '%s\n' "$TMP_ROOT/no-such-gh" >"$CFG/gh"
  if hook_direct origin https://github.com/acme/secret-app.git; then
    fail "a configured gh that does not exist must refuse"
  fi
  reset_trusted_gh
  pass "the privacy read ignores a gh on PATH and the environment's proxy, host, and gh config"
}

test_suggest_allowlist_lists_only_confirmed_private_repos() {
  local home out
  home="$TMP_ROOT/suggest-home"
  mkdir -p "$home/projects" "$home/data" "$TMP_ROOT/elsewhere"
  fm_git_init_commit "$home/projects/secret" >/dev/null
  git -C "$home/projects/secret" remote add origin https://github.com/acme/secret-app.git
  fm_git_init_commit "$home/projects/tool" >/dev/null
  git -C "$home/projects/tool" remote add origin https://github.com/example-org/tool.git
  fm_git_init_commit "$TMP_ROOT/elsewhere/site" >/dev/null
  git -C "$TMP_ROOT/elsewhere/site" remote add origin git@github.com:acme/site.git
  printf -- '- site [direct-PR] - Site at %s; public (added)\n' "$TMP_ROOT/elsewhere/site" >"$home/data/projects.md"
  mkdir -p "$home/config/publish-guard"
  install_gh_stub "$home/config/publish-guard"
  printf 'example-org/upstream\n' >"$home/config/publish-guard/upstream"
  out=$(FM_HOME="$home" "$GATE" suggest-allowlist 2>&1) || fail "suggest-allowlist failed: $out"
  assert_contains "$out" "private acme/secret-app" "a confirmed private repo is suggested"
  assert_contains "$out" "# site: acme/site is not confirmed private" "an unconfirmed repo is only a comment"
  assert_contains "$out" "example-org/tool is never suggested" "an upstream owner's repo is never suggested"
  case $'\n'"$out" in *$'\n''public '*) fail "nothing may be suggested as a public row: $out" ;; esac
  # Even confirmed private, a repository of an owner in the upstream file is
  # never suggested; without that file the same repository would be.
  out=$(FM_TEST_GH_REPO=example-org/tool FM_HOME="$home" "$GATE" suggest-allowlist 2>&1) ||
    fail "suggest-allowlist failed: $out"
  assert_not_contains "$out" "private example-org/tool" "a private repo of an upstream owner was suggested"
  assert_contains "$out" "example-org/tool is never suggested" "the upstream owner rule did not apply"
  rm -f "$home/config/publish-guard/upstream"
  out=$(FM_TEST_GH_REPO=example-org/tool FM_HOME="$home" "$GATE" suggest-allowlist 2>&1) ||
    fail "suggest-allowlist failed: $out"
  assert_contains "$out" "private example-org/tool" "without an upstream file the confirmed private repo is suggested"
  printf 'not a repository\n' >"$home/config/publish-guard/upstream"
  out=$(FM_HOME="$home" "$GATE" suggest-allowlist 2>&1) && fail "a malformed upstream file must refuse: $out"
  assert_not_contains "$out" "private acme/secret-app" "a malformed upstream file still printed suggestions"
  rm -f "$FAKEBIN/gh"
  pass "suggest-allowlist lists only live-confirmed private repos, from projects and registry paths"
}

test_disable_push_helper() {
  local repo out
  repo="$TMP_ROOT/disable"
  fm_git_init_commit "$repo" >/dev/null
  git -C "$repo" remote add origin https://github.com/acme/widgets.git
  git -C "$repo" remote add upstream https://github.com/acme/upstream.git
  cp "$CFG/upstream" "$TMP_ROOT/upstream.saved" 2>/dev/null || : >"$TMP_ROOT/upstream.saved"
  printf 'acme/upstream\n' >"$CFG/upstream"
  out=$("$GATE" disable-push "$repo") || fail "disable-push failed"
  assert_contains "$out" "upstream push after: DISABLED" "disable-push output"
  assert_equals DISABLED "$(git -C "$repo" remote get-url --push upstream)" "upstream push url"
  "$GATE" disable-push "$repo" upstream >/dev/null || fail "disable-push should be idempotent"
  "$GATE" disable-push "$repo" nosuch >/dev/null 2>&1 && fail "disable-push on a missing remote should fail"
  pass "disable-push sets an upstream push URL to DISABLED idempotently"
}

test_install_refuses_foreign_hook() {
  local hooks="$TMP_ROOT/foreign-hooks"
  mkdir -p "$hooks"
  printf '#!/bin/sh\nexit 0\n' >"$hooks/pre-push"
  "$GATE" install "$hooks" --config "$CFG" >/dev/null 2>&1 && fail "install over a foreign hook should refuse"
  assert_equals '#!/bin/sh' "$(head -1 "$hooks/pre-push")" "the foreign hook must be left alone"
  pass "install refuses to replace a hook it did not write"
}

# --- S3 commit-msg ------------------------------------------------------------------

test_commit_msg_check() {
  local repo out
  repo="$TMP_ROOT/cm"
  fm_git_init_commit "$repo" >/dev/null
  mkdir -p "$TMP_ROOT/cm.hooks"
  "$GATE" install "$TMP_ROOT/cm.hooks" --config "$CFG" >/dev/null 2>&1
  git -C "$repo" config core.hooksPath "$TMP_ROOT/cm.hooks"
  printf 'a\n' >"$repo/a"
  git -C "$repo" add a
  pinned git -C "$repo" commit -q -m "note for $LEAK_EMAIL" || fail "no public remote: the message check should stay off"
  git -C "$repo" remote add origin https://github.com/acme/widgets.git
  printf 'b\n' >"$repo/b"
  git -C "$repo" add b
  out=$(pinned git -C "$repo" commit -q -m "ask $LEAK_EMAIL" 2>&1) && fail "an email in the message should be refused"
  assert_contains "$out" "email address not on the identity allowlist" "email finding"
  assert_no_secret_echo "$out" "commit-msg email"
  out=$(pinned git -C "$repo" commit -q -m "see $SESSION_URL" 2>&1) && fail "a session link should be refused"
  assert_contains "$out" "session-link" "session link finding"
  out=$(pinned git -C "$repo" commit -q -m "ship $PRIVATE_TERM tooling" 2>&1) && fail "a denylist term should be refused"
  assert_contains "$out" "denylist rule 2" "denylist finding"
  pinned git -C "$repo" commit -q -m "fix: parse user@example.com fixtures" || fail "a placeholder address should pass"
  pass "commit-msg refuses private emails, session links, and denylist terms on a repo with a public remote"
}

test_per_task_hooks_run_the_gate() {
  local repo hooks out
  rm -rf "$TMP_ROOT/public.git"
  git init -q --bare -b main "$TMP_ROOT/public.git"
  repo="$TMP_ROOT/per-task"
  fm_git_init_commit "$repo" >/dev/null
  git -C "$repo" remote add origin "$TMP_ROOT/public.git"
  hooks="$TMP_ROOT/per-task.hooks"
  "$STRIP" install "$hooks" "$repo" "$CFG" || fail "per-task install failed"
  printf '%s\n' "$PRIVATE_TERM" >"$repo/x.md"
  git -C "$repo" add x.md
  out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" \
    pinned git -C "$repo" commit -q -m 'add x' 2>&1) && fail "the per-task pre-commit should refuse the staged private term"
  assert_contains "$out" "the staged change has 1 finding(s)" "per-task staged-change refusal"
  # Past the commit-time hooks, the push side still refuses.
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" \
    pinned git -C "$repo" commit -q --no-verify -m 'add x' || fail "commit failed"
  out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" \
    git -C "$repo" push -q origin HEAD:refs/heads/main 2>&1) && fail "the per-task pre-push should refuse"
  assert_contains "$out" "fm-publish-gate: REFUSED" "per-task refusal"
  out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" \
    pinned git -C "$repo" commit -q --allow-empty -m "for $LEAK_EMAIL" 2>&1) \
    && fail "the per-task commit-msg hook should refuse a private address for a public remote"
  assert_contains "$out" "email address not on the identity allowlist" "per-task commit-msg finding"
  pass "the per-task hooks path runs the publish gate on pre-commit, commit-msg, and pre-push"
}

test_keep_ai_trailers_still_runs_the_gate() {
  local repo hooks body out
  repo="$TMP_ROOT/keep-trailers"
  fm_git_init_commit "$repo" >/dev/null
  hooks="$TMP_ROOT/keep-trailers.hooks"
  FM_KEEP_AI_TRAILERS=1 "$STRIP" install "$hooks" "$repo" "$CFG" || fail "keep-trailers install failed"
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" \
    pinned git -C "$repo" commit -q --allow-empty --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: keep' \
    || fail "commit without a public remote failed"
  body=$(git -C "$repo" log -1 --format=%B)
  assert_contains "$body" "Co-authored-by: Cursor" "keep-trailers install still stripped the trailer"
  git -C "$repo" remote add origin https://github.com/acme/widgets.git
  out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" \
    pinned git -C "$repo" commit -q --allow-empty -m "for $LEAK_EMAIL" 2>&1) \
    && fail "keep-trailers hooks should still refuse a private address for a public remote"
  assert_contains "$out" "email address not on the identity allowlist" "keep-trailers commit-msg finding"
  pass "keep-ai-trailers skips only the strip; the per-task hooks still run the publish gate"
}

# A repository of the identity's own GitHub login needs no allowlist entry: it
# passes while the live read confirms it private, a verdict from the last 24
# hours stands in when that read cannot answer, and a public one still needs
# its entry.
test_owned_repos_pass_while_private() {
  local repo out
  install_gh_stub
  FM_TEST_GH_REPO=example-owner/tools hook_direct origin https://github.com/example-owner/tools.git \
    || fail "a confirmed-private repository of the identity's login should pass with no entry: $HOOK_OUT"
  if FM_TEST_GH_REPO=example-owner/tools FM_TEST_GH_PRIVATE=false hook_direct origin https://github.com/example-owner/tools.git; then
    fail "an owner's repository that is public needs an allowlist entry"
  fi
  assert_contains "$HOOK_OUT" "example-owner/tools is public and is not on the allowlist" "owned public reason"
  assert_contains "$HOOK_OUT" "fix: printf 'public %s\\n' 'example-owner/tools' >> '$CFG/allowlist'" "owned public fix"
  if FM_TEST_GH_REPO=someone-else/tools hook_direct origin https://github.com/someone-else/tools.git; then
    fail "another owner's repository still needs an entry"
  fi
  assert_contains "$HOOK_OUT" "someone-else/tools is not on the allowlist" "other owner reason"
  FM_TEST_GH_REPO=example-owner/tools hook_direct origin https://github.com/example-owner/tools.git \
    || fail "the owner's repository should pass again once private: $HOOK_OUT"
  rm -f "$FAKEBIN/gh"
  hook_direct origin https://github.com/example-owner/tools.git \
    || fail "a verdict from the last 24 hours should carry a push the live read cannot answer: $HOOK_OUT"
  assert_contains "$HOOK_OUT" "using its private verdict from the last 24 hours" "cached verdict note"
  printf 'example-owner/tools %s\n' "$(($(date +%s) - 90000))" >"$CFG/private-verdicts"
  if hook_direct origin https://github.com/example-owner/tools.git; then
    fail "a verdict older than 24 hours must not carry a push"
  fi
  assert_contains "$HOOK_OUT" "no verdict from the last 24 hours" "stale verdict reason"
  printf 'acme-org\n' >"$CFG/owners"
  install_gh_stub
  FM_TEST_GH_REPO=acme-org/app hook_direct origin https://github.com/acme-org/app.git \
    || fail "an owners entry should admit its confirmed-private repository: $HOOK_OUT"
  if FM_TEST_GH_REPO=example-owner/tools hook_direct origin https://github.com/example-owner/tools.git; then
    fail "with an owners file the identity's login is no longer an owner"
  fi
  rm -f "$CFG/owners" "$CFG/private-verdicts"
  printf 'Built for %s.\n' "$PRIVATE_TERM" >"$TMP_ROOT/owned-body.md"
  FM_TEST_GH_REPO=example-owner/tools policy 'gh pr create --repo example-owner/tools --title t --body-file owned-body.md' \
    || fail "the gh guard should admit text for an owner's private repository: $POLICY_OUT"
  # Commit-time checks treat an owner's repository as private: no scan, no read.
  repo="$TMP_ROOT/owned-commit"
  rm -rf "$repo" "$repo.hooks"
  fm_git_init_commit "$repo" >/dev/null
  mkdir -p "$repo.hooks"
  "$GATE" install "$repo.hooks" --config "$CFG" >/dev/null 2>&1 || fail "gate install failed"
  git -C "$repo" config core.hooksPath "$repo.hooks"
  git -C "$repo" remote add origin https://github.com/example-owner/tools.git
  printf 'for %s\n' "$PRIVATE_TERM" >"$repo/a.md"
  git -C "$repo" add a.md
  out=$(pinned git -C "$repo" commit -q -m "note for $LEAK_EMAIL" 2>&1) \
    || fail "an owner's repository must not get the public commit-time checks: $out"
  rm -f "$FAKEBIN/gh"
  rm -f "$CFG/private-verdicts"
  pass "an owner's repositories pass while private, with a 24-hour verdict when the live read cannot answer"
}

# Every refusal names the one command or edit that fixes it.
test_refusals_name_their_fix() {
  local repo out path_sans
  hook_direct upstream https://github.com/example-org/upstream.git
  assert_contains "$HOOK_OUT" "fix: printf 'public %s\\n' 'example-org/upstream' >> '$CFG/allowlist'  # only if publishing" "unlisted fix"
  hook_direct origin https://gitlab.com/acme/widgets.git
  assert_contains "$HOOK_OUT" "fix: push to a github.com owner/repo or a local path instead" "other host fix"
  repo=$(fresh_repo fix-content)
  push_expect "$repo" 0 "seed main"
  commit_file "$repo" notes.md "about $PRIVATE_TERM" 'add notes' || fail "commit failed"
  push_expect "$repo" 1 "content fix"
  assert_contains "$PUSH_OUT" "fix: git reset --soft $(git -C "$repo" rev-parse --short=12 HEAD~1) && git commit -m '<neutral summary>'" "content fix names the base"
  git -C "$repo" tag v9
  push_expect "$repo" 1 "tag fix" v9
  assert_contains "$PUSH_OUT" "fix: git push <remote> <branch>" "tag fix"
  mv "$CFG/identity" "$CFG/identity.saved"
  push_expect "$repo" 1 "identity fix"
  assert_contains "$PUSH_OUT" "fix: printf 'name=%s\\nemail=%s\\n' \"\$(git config user.name)\" \"\$(git config user.email)\" > '$CFG/identity'" "identity fix"
  mv "$CFG/identity.saved" "$CFG/identity"
  path_sans=$(fm_test_base_path_sans "$PATH" gitleaks)
  PUSH_OUT=$(PATH="$path_sans" git -C "$repo" push -q origin main 2>&1) && fail "a public push without gitleaks should be refused"
  assert_contains "$PUSH_OUT" "fix: '$ROOT/bin/fm-install-gitleaks.sh'" "gitleaks fix"
  git -C "$repo" remote add public https://github.com/acme/widgets.git
  out=$(pinned git -C "$repo" commit -q --allow-empty -m "for $LEAK_EMAIL" 2>&1) && fail "the message check should refuse"
  assert_contains "$out" "fix: git commit -m '<what changed, without the flagged text>'" "commit-msg fix"
  policy "gh pr create --repo acme/widgets --title t --body 'about $PRIVATE_TERM'"
  assert_contains "$POLICY_OUT" "fix: rewrite the flagged text" "check-text fix"
  policy 'gh pr create --title t --body ok'
  assert_contains "$POLICY_OUT" "Fix: add --repo <owner>/<repo> to the gh command." "gh guard fix"
  pass "each refusal prints the one command or edit that fixes it"
}

# The staged change is checked at commit time for a repository with a public
# or unlisted remote; the full-history and gitleaks pass stays at pre-push.
test_pre_commit_checks_the_staged_change() {
  local repo hooks out leak marker
  repo="$TMP_ROOT/staged"
  hooks="$TMP_ROOT/staged.hooks"
  rm -rf "$repo" "$hooks"
  fm_git_init_commit "$repo" >/dev/null
  mkdir -p "$hooks"
  "$GATE" install "$hooks" --config "$CFG" >/dev/null 2>&1 || fail "gate install failed"
  git -C "$repo" config core.hooksPath "$hooks"
  printf 'notes for %s\n' "$PRIVATE_TERM" >"$repo/old.md"
  git -C "$repo" add old.md
  pinned git -C "$repo" commit -q -m 'add old' || fail "with no public remote the staged check stays off"
  git -C "$repo" remote add origin https://github.com/acme/widgets.git
  for leak in "notes for $PRIVATE_TERM" "ask $LEAK_EMAIL" "cp $REAL_HOME_PATH ." "see $SESSION_URL"; do
    printf '%s\n' "$leak" >"$repo/new.md"
    git -C "$repo" add new.md
    out=$(pinned git -C "$repo" commit -q -m 'add new' 2>&1) && fail "a staged leak must be refused: $leak"
    assert_contains "$out" "the staged change has" "staged finding for $leak"
    assert_contains "$out" "fix: git add <each flagged file>" "staged fix line"
    assert_no_secret_echo "$out" "staged refusal"
    git -C "$repo" reset -q -- new.md
  done
  mkdir -p "$repo/shots"
  printf '\211PNG\r\n\032\n\000\000' >"$repo/shots/$HOST_TERM.png"
  git -C "$repo" add shots
  pinned git -C "$repo" commit -q -m 'add shot' 2>/dev/null && fail "a staged binary file name must be scanned"
  git -C "$repo" reset -q -- shots
  rm -rf "$repo/shots"
  # old.md still holds the term, but only the staged change is read.
  printf 'Contact user@example.com for access.\n' >"$repo/new.md"
  git -C "$repo" add new.md
  out=$(pinned git -C "$repo" commit -q -m 'add contact' 2>&1) || fail "a clean staged change must pass: $out"

  repo="$TMP_ROOT/staged-task"
  hooks="$TMP_ROOT/staged-task.hooks"
  rm -rf "$repo" "$hooks" "$TMP_ROOT/staged-marker"
  fm_git_init_commit "$repo" >/dev/null
  git -C "$repo" remote add origin https://github.com/acme/widgets.git
  marker="$TMP_ROOT/staged-marker"
  printf '#!/bin/sh\ntouch %s\n' "$marker" >"$repo/.git/hooks/pre-commit"
  chmod +x "$repo/.git/hooks/pre-commit"
  "$STRIP" install "$hooks" "$repo" "$CFG" || fail "per-task install failed"
  printf 'clean\n' >"$repo/c.md"
  git -C "$repo" add c.md
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" \
    pinned git -C "$repo" commit -q -m 'add c' || fail "a clean commit through the per-task hooks failed"
  [ -e "$marker" ] || fail "the per-task pre-commit must still chain the repository's own pre-commit hook"
  pass "the staged change is checked at commit time, and the repository's own pre-commit hook still runs"
}

# A secondmate home inherits the primary's publish-guard files, so it pushes to
# the same private repositories from its first launch; the machine-local gh
# path and the verdict cache stay per home, and none of it is pasted into an
# agent's re-read instruction.
test_secondmate_home_inherits_publish_guard() {
  local primary_cfg="$TMP_ROOT/primary/config" sm_home="$TMP_ROOT/secondmate-home" report="$TMP_ROOT/inherit-report" item changed payload bytes hash
  rm -rf "$TMP_ROOT/primary" "$sm_home" "$report"
  mkdir -p "$primary_cfg/publish-guard" "$sm_home"
  for item in identity allowlist denylist poison-commits; do cp "$CFG/$item" "$primary_cfg/publish-guard/$item"; done
  printf 'example-org/upstream\n' >"$primary_cfg/publish-guard/upstream"
  printf 'example-owner\n' >"$primary_cfg/publish-guard/owners"
  printf '/opt/homebrew/bin/gh\n' >"$primary_cfg/publish-guard/gh"
  printf 'example-owner/tools 1\n' >"$primary_cfg/publish-guard/private-verdicts"
  : >"$report"
  (
    unset FM_INHERITABLE_CONFIG
    # shellcheck source=bin/fm-config-inherit-lib.sh
    . "$ROOT/bin/fm-config-inherit-lib.sh"
    FM_CONFIG_INHERIT_REPORT="$report" propagate_inheritable_config "$primary_cfg" "$sm_home/config"
  ) || fail "propagation into the secondmate home failed"
  for item in identity allowlist denylist poison-commits upstream owners; do
    cmp -s "$primary_cfg/publish-guard/$item" "$sm_home/config/publish-guard/$item" \
      || fail "the secondmate home did not inherit publish-guard/$item"
  done
  assert_absent "$sm_home/config/publish-guard/gh" "the machine-local gh path must stay per home"
  assert_absent "$sm_home/config/publish-guard/private-verdicts" "the verdict cache must stay per home"
  changed=$(
    unset FM_INHERITABLE_CONFIG
    . "$ROOT/bin/fm-config-inherit-lib.sh"
    fm_config_reread_changed_items "$report"
  )
  assert_not_contains "$changed" "publish-guard" "publish-guard files must never be inlined into a re-read instruction"
  assert_equals owned "$("$GATE" classify https://github.com/example-owner/tools.git --config "$sm_home/config/publish-guard")" \
    "the secondmate's gate reads the inherited owners"
  # The remote route accepts the nested item and refuses a redirected parent.
  payload="$primary_cfg/publish-guard/identity"
  bytes=$(LC_ALL=C wc -c <"$payload" | tr -d ' ')
  hash=$(shasum -a 256 "$payload" 2>/dev/null | awk '{print $1}')
  [ -n "$hash" ] || hash=$(sha256sum "$payload" | awk '{print $1}')
  rm -rf "$TMP_ROOT/remote-home" "$TMP_ROOT/elsewhere-guard"
  mkdir -p "$TMP_ROOT/remote-home/config" "$TMP_ROOT/remote-home/data" "$TMP_ROOT/remote-home/state"
  FM_HOME="$TMP_ROOT/remote-home" "$ROOT/bin/fm-remote-inherit.sh" \
    put config/publish-guard/identity "$bytes" "$hash" 1 <"$payload" >/dev/null \
    || fail "the remote receiver refused an inherited publish-guard file"
  cmp -s "$payload" "$TMP_ROOT/remote-home/config/publish-guard/identity" || fail "the remote receiver did not publish the identity"
  rm -rf "$TMP_ROOT/remote-home/config/publish-guard"
  mkdir -p "$TMP_ROOT/elsewhere-guard"
  ln -s "$TMP_ROOT/elsewhere-guard" "$TMP_ROOT/remote-home/config/publish-guard"
  FM_HOME="$TMP_ROOT/remote-home" "$ROOT/bin/fm-remote-inherit.sh" \
    put config/publish-guard/identity "$bytes" "$hash" 2 <"$payload" >/dev/null 2>&1 \
    && fail "the remote receiver must refuse a publish-guard directory that is a symlink"
  assert_absent "$TMP_ROOT/elsewhere-guard/identity" "nothing may be written through a redirected parent"
  pass "a secondmate home inherits the publish-guard files, never the gh path, the verdict cache, or a re-read paste"
}

# --- S5 gh publish guard and git refusals ------------------------------------------

policy() { # <command> -> rc; output in POLICY_OUT
  POLICY_OUT=$(cd "$TMP_ROOT" && FM_CONFIG_OVERRIDE="$TMP_ROOT/config" "$PRETOOL" --publish-only --claude --command "$1" 2>&1 >/dev/null)
}

test_gh_guard() {
  printf 'Adds a retry to the fetcher.\n' >"$TMP_ROOT/body-clean.md"
  printf 'Built for %s.\n' "$PRIVATE_TERM" >"$TMP_ROOT/body-leak.md"
  policy 'gh pr create --title t --body-file body-clean.md'
  [ $? -eq 2 ] || fail "gh pr create without --repo should be refused"
  assert_contains "$POLICY_OUT" "gh-no-repo" "missing repo code"
  policy 'gh pr create --repo acme/widgets --title "Add retry" --body-file body-clean.md' \
    || fail "a clean PR to an allowlisted public repo should pass: $POLICY_OUT"
  policy 'gh pr create --repo acme/widgets --title "Add retry" --body-file body-leak.md'
  [ $? -eq 2 ] || fail "a private-term mention in the PR body should be refused"
  assert_contains "$POLICY_OUT" "denylist rule 2" "body finding"
  assert_no_secret_echo "$POLICY_OUT" "gh body"
  policy 'gh pr create --repo example-org/upstream --title t --body-file body-clean.md'
  [ $? -eq 2 ] || fail "a PR to an unlisted upstream should be refused"
  policy "gh pr comment https://github.com/acme/widgets/pull/3 --body 'see $SESSION_URL'"
  [ $? -eq 2 ] || fail "a session link in a PR comment should be refused"
  policy "gh issue create --repo acme/widgets --title 'Ask $LEAK_EMAIL' --body ok"
  [ $? -eq 2 ] || fail "a private email in an issue title should be refused"
  # shellcheck disable=SC2016 # the unexpanded $BODY is the unreadable body under test
  policy 'gh pr create --repo acme/widgets --title t --body "$BODY"'
  [ $? -eq 2 ] || fail "an unreadable body should be refused"
  assert_contains "$POLICY_OUT" "gh-unreadable-text" "unreadable code"
  policy "gh pr create --repo acme/widgets --title t --body-file - <<'EOF'
Built for $PRIVATE_TERM.
EOF"
  [ $? -eq 2 ] || fail "a heredoc body should be scanned"
  policy "gh api -X POST repos/acme/widgets/issues/3/comments -f body='about $PRIVATE_TERM'"
  [ $? -eq 2 ] || fail "a gh api comment write should be scanned"
  policy 'gh repo create example-org/other --public'
  [ $? -eq 2 ] || fail "creating an unlisted repo should be refused"
  local read
  for read in 'gh pr view 3 --repo example-org/upstream' 'gh pr list' 'gh pr checks 3' 'gh pr diff 3' \
    'gh pr status' 'gh issue view 5' 'gh issue list --repo acme/widgets' 'gh release list' 'gh repo view' \
    'gh api repos/acme/widgets/pulls/3/comments' 'gh api repos/acme/widgets/pulls -X GET -f state=open' \
    'gh api --method GET repos/acme/widgets/issues -F per_page=100' 'gh api graphql -f query=query{viewer{login}}' \
    'gh run view 12 --log' 'gh auth status'; do
    policy "$read" || fail "a gh read must never be blocked: $read ($POLICY_OUT)"
  done
  install_gh_stub
  policy 'gh pr create --repo acme/secret-app --title t --body-file body-leak.md' \
    || fail "a PR to a confirmed-private project repo must pass: $POLICY_OUT"
  FM_TEST_GH_PRIVATE=false policy 'gh pr create --repo acme/secret-app --title t --body-file body-clean.md'
  [ $? -eq 2 ] || fail "a PR to a private entry that is no longer private should be refused"
  reset_trusted_gh
  policy "bash -c 'gh pr create --title t --body x'"
  [ $? -eq 2 ] || fail "a gh publish inside bash -c should be refused"
  pass "the gh publish guard enforces explicit allowlisted destinations and scans every text form"
}

# A worker's worktree runs its own copy of bin/ from a linked git worktree
# with no config of its own; the launch's per-task hooks name the home.
test_worker_worktree_uses_the_home_config() {
  local wt="$TMP_ROOT/worker-wt" repo="$TMP_ROOT/worker-repo" hooks="$TMP_ROOT/worker.hooks" out
  local create='gh pr create --repo acme/widgets --title "Add retry" --body-file worker-body.md'
  local sep="$TMP_ROOT/separate-checkout"
  rm -rf "$wt" "$repo" "$hooks" "$sep" "$sep.git"
  fm_git_init_commit "$repo" >/dev/null
  git -C "$repo" worktree add -q --detach "$wt" || fail "linked worktree setup failed"
  cp -R "$ROOT/bin" "$wt/bin"
  "$STRIP" install "$hooks" "$repo" "$CFG" || fail "per-task install failed"
  assert_equals "$CFG" "$(cat "$hooks/publish-guard-config")" "the per-task hooks record the home's publish-guard directory"
  printf 'Adds a retry to the fetcher.\n' >"$TMP_ROOT/worker-body.md"
  wt_policy() { # <hooks-dir or empty> <mode flags>... -- <command>; output in POLICY_OUT
    local h=$1
    shift
    if [ -n "$h" ]; then
      POLICY_OUT=$(cd "$TMP_ROOT" && env -u FM_HOME -u FM_CONFIG_OVERRIDE GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$h" "$wt/bin/fm-arm-pretool-check.sh" "$@" 2>&1 >/dev/null)
    else
      POLICY_OUT=$(cd "$TMP_ROOT" && env -u FM_HOME -u FM_CONFIG_OVERRIDE "$wt/bin/fm-arm-pretool-check.sh" "$@" 2>&1 >/dev/null)
    fi
  }
  wt_policy "$hooks" --publish-only --claude --command "$create" ||
    fail "a clean PR to an allowlisted public repo should pass from a worker worktree: $POLICY_OUT"
  wt_policy "$hooks" --claude --command "$create" ||
    fail "the worktree's full PreToolUse check should pass the same PR: $POLICY_OUT"
  out=$(cd "$TMP_ROOT" && env -u FM_HOME -u FM_CONFIG_OVERRIDE FM_HOME="$TMP_ROOT" "$wt/bin/fm-publish-gate.sh" config-dir) ||
    fail "FM_HOME should name the config"
  assert_equals "$TMP_ROOT/config/publish-guard" "$out" "FM_HOME wins over the worktree"
  # A worktree's own config is never read, however permissive.
  mkdir -p "$wt/config/publish-guard"
  cp "$CFG/identity" "$CFG/denylist" "$CFG/poison-commits" "$CFG/gh" "$wt/config/publish-guard/"
  printf 'public example-org/tool\n' >"$wt/config/publish-guard/allowlist"
  wt_policy "$hooks" --publish-only --claude --command 'gh pr create --repo example-org/tool --title t --body-file worker-body.md'
  [ $? -eq 2 ] || fail "a destination only the worktree's config allows should be refused"
  assert_contains "$POLICY_OUT" "$CFG/allowlist" "the refusal names the home's allowlist"
  assert_not_contains "$POLICY_OUT" "$wt/config" "the refusal never points at the worktree's config"
  wt_policy "" --publish-only --claude --command "$create"
  [ $? -eq 2 ] || fail "with no home resolvable the guard should refuse"
  # A separate-git-dir clone also has a .git file, but it is the owning checkout.
  git init -q --separate-git-dir "$sep.git" "$sep" || fail "separate-git-dir setup failed"
  cp -R "$ROOT/bin" "$sep/bin"
  out=$(env -u FM_HOME -u FM_CONFIG_OVERRIDE "$sep/bin/fm-publish-gate.sh" config-dir) ||
    fail "a separate-git-dir checkout should resolve its own config: $out"
  assert_equals "$(cd "$sep" && pwd -P)/config/publish-guard" "$out" "a separate-git-dir checkout is its own home"
  assert_contains "$POLICY_OUT" "no firstmate home owns this publish-guard config" "no-home refusal"
  assert_contains "$POLICY_OUT" "fix: relaunch the task through bin/fm-spawn.sh" "no-home refusal names its fix"
  out=$(env -u FM_HOME -u FM_CONFIG_OVERRIDE "$wt/bin/fm-publish-gate.sh" check-text --dest acme/widgets "body:$TMP_ROOT/worker-body.md" 2>&1) &&
    fail "check-text with no home should refuse"
  assert_contains "$out" "no firstmate home owns this publish-guard config" "check-text no-home refusal"
  out=$(env -u FM_HOME -u FM_CONFIG_OVERRIDE "$wt/bin/fm-publish-judge.sh" text --dest acme/widgets "body:$TMP_ROOT/worker-body.md" 2>&1) &&
    fail "the judge with no home should refuse"
  assert_contains "$out" "no firstmate home owns this publish-guard config" "judge no-home refusal"
  pass "a worker worktree's gh guard reads the owning home's config, ignores its own, and refuses without a home"
}

deny_expect() { # <code> <command> [label]
  policy "$2"
  [ $? -eq 2 ] || fail "${3:-$2}: should be refused ($POLICY_OUT)"
  assert_contains "$POLICY_OUT" "$1" "${3:-$2}: refusal code"
  assert_no_secret_echo "$POLICY_OUT" "${3:-$2}"
}

allow_expect() { # <command> [label]
  policy "$1" || fail "${2:-$1}: should pass ($POLICY_OUT)"
}

# gh accepts --repo before the command group and attached short values; an
# option spelling the guard does not know is refused rather than skipped.
test_gh_guard_option_spellings() {
  deny_expect gh-refused "gh --repo acme/widgets pr create --title clean --body $PRIVATE_TERM" "leading --repo"
  deny_expect gh-refused "gh -R acme/widgets pr create --title clean --body $PRIVATE_TERM" "leading -R"
  deny_expect gh-refused "gh --repo=example-org/other pr create --title clean --body ok" "leading --repo to an unlisted repo"
  deny_expect gh-refused "gh pr create --repo acme/widgets --title clean -b$PRIVATE_TERM" "attached -b value"
  deny_expect gh-refused "gh pr create --repo acme/widgets --title clean -b=$PRIVATE_TERM" "attached -b= value"
  deny_expect gh-refused "gh pr create -Racme/widgets --title clean --body $PRIVATE_TERM" "attached -R value"
  deny_expect gh-refused "gh pr review 3 --repo acme/widgets -r -b $PRIVATE_TERM" "a review flag that takes no value"
  deny_expect gh-unparsed "gh pr create -dw --repo acme/widgets --title clean --body ok" "combined short options"
  deny_expect gh-unparsed "gh pr create --repo acme/widgets --title clean --body ok --bodyy x" "unknown option"
  deny_expect gh-unparsed "gh --verbose pr create --repo acme/widgets --title clean --body ok" "unknown leading option"
  allow_expect "gh --repo acme/widgets pr create --title clean --body ok"
  allow_expect "gh pr create --help"
  allow_expect "gh -R acme/widgets pr view 3"
  pass "leading --repo, attached short values, and unknown option spellings cannot skip the guard"
}

# A text file is scanned where gh will read it only when nothing else in the
# command can change the directory or rewrite the file first.
test_gh_guard_file_reads_run_alone() {
  mkdir -p "$TMP_ROOT/child"
  printf 'clean\n' >"$TMP_ROOT/same.txt"
  printf 'for %s\n' "$PRIVATE_TERM" >"$TMP_ROOT/child/same.txt"
  allow_expect "gh pr create --repo acme/widgets --title clean --body-file same.txt"
  deny_expect gh-refused "gh pr create --repo acme/widgets --title clean --body-file child/same.txt" "the leaking file itself"
  deny_expect gh-file-compound "cd child && gh pr create --repo acme/widgets --title clean --body-file same.txt" "cd first"
  deny_expect gh-file-compound "printf x > same.txt; gh pr create --repo acme/widgets --title clean --body-file same.txt" "rewrite first"
  deny_expect gh-file-compound "env -C child gh pr create --repo acme/widgets --title clean --body-file same.txt" "env -C"
  deny_expect gh-file-compound "bash -c 'cd child; gh pr create --repo acme/widgets --title clean --body-file same.txt'" "cd inside bash -c"
  deny_expect gh-file-compound "cd child && bash -c 'gh pr create --repo acme/widgets --title clean --body-file same.txt'" "cd around bash -c"
  deny_expect gh-file-compound "gh pr create --repo acme/widgets --title clean --body-file same.txt --label \"\$(cd child)\"" "a substitution in the gh command"
  deny_expect gh-file-compound "cd child && gh api -X POST repos/acme/widgets/issues -f title=t -F body=@same.txt" "an API file field"
  allow_expect "cd child && gh pr create --repo acme/widgets --title clean --body 'inline text'"
  pass "a gh text file must be read by a command run alone, so the scanned file is the one gh publishes"
}

# Text gh would produce after the check - filled from commits, typed in an
# editor or a browser, or taken from a template - cannot be scanned.
test_gh_guard_refuses_generated_text() {
  local cmd
  for cmd in "gh pr create --repo acme/widgets --fill" "gh pr create --repo acme/widgets --fill-first" \
    "gh pr create --repo acme/widgets --title t --body ok --editor" "gh pr create --repo acme/widgets --web" \
    "gh pr create --repo acme/widgets --title t --template t.md" "gh pr create --repo acme/widgets --title t" \
    "gh issue create --repo acme/widgets --title t" "gh issue create --repo acme/widgets -T bug" \
    "gh pr comment 3 --repo acme/widgets --editor" "gh issue comment 3 --repo acme/widgets" \
    "gh release create v1 --repo acme/widgets --generate-notes" "gh gist edit abc123"; do
    deny_expect gh-implicit-text "$cmd"
  done
  allow_expect "gh issue create --repo acme/widgets --title clean --body ''"
  allow_expect "gh pr comment 3 --repo acme/widgets --delete-last --yes"
  pass "fill, editor, web, template, and missing-body forms are refused; an explicit empty body is not"
}

# Publishing routes beyond PR and issue text: absolute API URLs, GraphQL
# mutations, commits and refs made through the API, merge messages, closing
# comments, and uploaded files.
test_gh_guard_covers_other_writes() {
  deny_expect gh-refused "gh api -X POST https://api.github.com/repos/acme/widgets/issues -f title=clean -f body=$PRIVATE_TERM" "absolute API URL"
  deny_expect gh-refused "gh api -XPOST repos/acme/widgets/issues -fbody=$PRIVATE_TERM" "attached API values"
  deny_expect gh-unsupported-write "gh api graphql -f query='mutation { addComment(input: {subjectId: \"X\", body: \"clean\"}) { clientMutationId } }'" "GraphQL mutation"
  deny_expect gh-unsupported-write "gh api graphql -f query='query { viewer { login } } mutation { addComment(input: {subjectId: \"X\", body: \"x\"}) { clientMutationId } }'" "a mutation after a query"
  deny_expect gh-unsupported-write "gh api -X POST user/repos -f name=x" "a write outside repos and gists"
  deny_expect gh-other-host "gh api -X POST https://ghe.example/api/v3/repos/acme/widgets/issues -f title=t" "another API host"
  deny_expect gh-refused "gh api --method PUT repos/acme/widgets/contents/README.md -f message=hi -f content=aGk=" "API contents write"
  deny_expect gh-refused "gh api -X POST repos/acme/widgets/git/refs -f ref=refs/heads/x -f sha=abc" "API ref write"
  deny_expect gh-refused "gh api -X POST repos/acme/widgets/releases -f tag_name=v1 -f body=$PRIVATE_TERM" "API release text"
  deny_expect gh-refused "gh api -X POST gists -f 'files[a.txt][content]=$PRIVATE_TERM'" "API gist"
  deny_expect gh-refused "gh pr merge 1 --repo acme/widgets --squash --body $PRIVATE_TERM" "merge body"
  deny_expect gh-refused "gh pr merge 1 --repo acme/widgets --squash -A $LEAK_EMAIL" "merge author email"
  deny_expect gh-refused "gh pr close 3 --repo acme/widgets --comment 'for $PRIVATE_TERM'" "closing comment"
  printf 'asset\n' >"$TMP_ROOT/asset.bin"
  deny_expect gh-refused "gh release upload v1 asset.bin --repo acme/widgets" "release asset"
  deny_expect gh-refused "gh pr comment 3 --repo acme/widgets --body ok --attach asset.bin" "attachment"
  printf 'query { viewer { login } }\n' >"$TMP_ROOT/read.graphql"
  printf '# looks like a read\nquery { viewer { login } }\nmutation { addComment(input: {subjectId: "X", body: "x"}) { clientMutationId } }\n' >"$TMP_ROOT/write.graphql"
  allow_expect "gh api graphql -F query=@read.graphql" "a GraphQL query read from a file"
  deny_expect gh-unsupported-write "gh api graphql -F query=@write.graphql" "a GraphQL mutation read from a file"
  deny_expect gh-file-compound "cd child && gh api graphql -F query=@read.graphql" "a GraphQL file read in a compound command"
  allow_expect "gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: \"T\"}) { thread { isResolved } } }'"
  allow_expect "gh api -X POST repos/acme/widgets/releases -f tag_name=v1 -f body=clean"
  allow_expect "gh api -X GET https://api.github.com/repos/acme/widgets/pulls"
  allow_expect "gh pr merge 1 --squash"
  install_gh_stub
  allow_expect "gh release upload v1 asset.bin --repo acme/secret-app" "a release asset for a confirmed-private repo"
  allow_expect "gh api --method PUT repos/acme/secret-app/contents/README.md -f message=hi -f content=aGk=" "an API content write to a confirmed-private repo"
  reset_trusted_gh
  pass "absolute API URLs, GraphQL mutations, API commits and refs, merge and close text, and uploads are checked"
}

# gh reads --help as a boolean: --help=false, any false spelling, or a later
# false leaves the command running, so only help in effect skips the checks.
test_gh_guard_help_is_a_boolean() {
  local spelling
  for spelling in '--help=false' '--help=0' '--help=f' '--help=F' '--help=FALSE' '--help=False' '--help --help=false'; do
    deny_expect gh-refused "gh pr create --repo acme/widgets --title clean --body $PRIVATE_TERM $spelling" "denied text with $spelling"
    deny_expect gh-refused "gh pr create --repo example-org/other --title clean --body ok $spelling" "an unlisted destination with $spelling"
  done
  deny_expect gh-refused "gh pr --help create --repo acme/widgets --title clean --body $PRIVATE_TERM --help=false" "help before the verb, false after it"
  deny_expect gh-refused "gh issue comment 3 --repo acme/widgets --body $PRIVATE_TERM --help=false" "an issue comment"
  deny_expect gh-unparsed "gh pr create --repo acme/widgets --title clean --body ok --help=maybe" "a help value gh rejects"
  deny_expect gh-unparsed "gh pr create --repo acme/widgets --title clean --body ok --help=\$H" "a help value the guard cannot read"
  allow_expect "gh pr create --repo acme/widgets --title clean --body $PRIVATE_TERM --help" "help prints and publishes nothing"
  allow_expect "gh pr create --help=true"
  allow_expect "gh pr create --help=false --help" "the last spelling wins"
  allow_expect "gh pr --help create"
  pass "only a --help gh reads as true skips the guard; false spellings and later false values are checked"
}

# gh looks a PR or issue named by a URL up in the URL's own repository,
# whatever --repo says, so the guard checks that repository and refuses a
# disagreement, another host, or a selector it cannot read.
test_gh_guard_url_selector_sets_the_repo() {
  install_gh_stub
  deny_expect gh-target-conflict "gh pr comment https://github.com/acme/widgets/pull/1 --repo acme/secret-app --body $PRIVATE_TERM" "a public PR URL against a private --repo"
  deny_expect gh-target-conflict "gh issue comment https://github.com/acme/widgets/issues/1 --repo acme/secret-app --body $PRIVATE_TERM" "an issue URL"
  deny_expect gh-target-conflict "gh issue comment https://github.com/acme/widgets/pull/1 -R acme/secret-app --body $PRIVATE_TERM" "an issue command given a PR link"
  deny_expect gh-target-conflict "gh issue edit 5 https://github.com/acme/widgets/issues/1 --repo acme/secret-app --body $PRIVATE_TERM" "a number beside a URL"
  deny_expect gh-target-conflict "gh pr merge https://github.com/acme/widgets/pull/1 --repo acme/secret-app --squash --body $PRIVATE_TERM" "a merge"
  deny_expect gh-target-conflict "gh pr edit https://github.com/acme/secret-%61pp/pull/1 --repo acme/widgets --body ok" "an escaped URL path"
  deny_expect gh-target-conflict "gh pr comment https://github.com/acme/secret-app/../widgets/pull/1 --body ok" "dot segments gh does not fold"
  deny_expect gh-target-conflict "gh issue edit https://github.com/acme/widgets/issues/1 https://github.com/acme/secret-app/issues/2 --body ok" "URLs naming two repositories"
  deny_expect gh-target-conflict "gh pr comment \"\$PR\" --repo acme/widgets --body ok" "a selector the guard cannot read"
  deny_expect gh-other-host "gh pr comment https://ghe.example/acme/widgets/pull/1 --repo acme/widgets --body ok" "a PR URL on another host"
  deny_expect gh-other-host "gh issue close https://ghe.example/acme/secret-app/issues/1 --repo acme/secret-app --comment ok" "an issue URL on another host"
  deny_expect gh-refused "gh pr comment https://github.com/acme/widgets/pull/1 --body $PRIVATE_TERM" "a URL alone names the scanned destination"
  deny_expect gh-refused "gh pr comment HTTPS://WWW.GITHUB.COM/Acme/Widgets/pull/1 --repo acme/widgets --body $PRIVATE_TERM" "an agreeing URL in another spelling"
  allow_expect "gh pr comment https://github.com/acme/widgets/pull/1 --repo acme/widgets --body ok"
  allow_expect "gh pr comment 1 --repo acme/secret-app --body $PRIVATE_TERM" "a number stays with a confirmed-private --repo"
  allow_expect "gh issue comment https://github.com/acme/secret-app/issues/1 --body $PRIVATE_TERM" "a confirmed-private URL"
  reset_trusted_gh
  pass "a URL selector's repository is the one checked, and a URL disagreeing with --repo is refused"
}

# A visibility change publishes the whole repository - history, refs,
# releases, issues - so no text check can vouch for it, whatever the
# destination's class before the change.
test_gh_guard_refuses_visibility_changes() {
  local cmd
  install_gh_stub
  printf '{"priv\\u0061te": false}\n' >"$TMP_ROOT/visibility.json"
  printf 'not json\n' >"$TMP_ROOT/not-json.txt"
  for cmd in \
    "gh repo edit acme/secret-app --visibility public --accept-visibility-change-consequences" \
    "gh repo edit acme/secret-app --visibility=public --accept-visibility-change-consequences" \
    "gh repo edit acme/widgets --visibility private --accept-visibility-change-consequences" \
    "gh api -X PATCH repos/acme/secret-app -F private=false" \
    "gh api -X PATCH repos/acme/secret-app -f private=false" \
    "gh api --method PATCH /repos/acme/secret-app --raw-field visibility=public" \
    "gh api -XPATCH https://api.github.com/repos/acme/secret-app -fvisibility=public" \
    "gh api -X PATCH repos/acme/secret-app -F Private=false" \
    "gh api repos/acme/secret-app -F 'private[]=false'" \
    "gh api -X PATCH repos/acme/secret-app --input visibility.json" \
    "gh api -X POST repos/acme/secret-app/generate -f owner=acme -f name=copy" \
    "gh api -X POST repos/acme/secret-app/pages -f 'source[branch]=main'"; do
    deny_expect gh-visibility "$cmd"
    assert_contains "$POLICY_OUT" "Fix: leave the visibility change to the captain's reviewed manual procedure" "visibility fix line for: $cmd"
  done
  deny_expect gh-visibility "gh api -X PATCH repos/acme/secret-app --input - <<'EOF'
{\"visibility\": \"public\"}
EOF" "a heredoc body"
  deny_expect gh-unparsed "gh api -X PATCH repos/acme/secret-app --input not-json.txt" "a body that is not JSON"
  allow_expect "gh api -X PATCH repos/acme/secret-app -f description=clean" "a private repository's other settings"
  allow_expect "gh repo edit acme/secret-app --description clean"
  reset_trusted_gh
  pass "every visibility change, template generate, and Pages write is refused, whatever the destination's class"
}

# gh sends a write URL's query string as it is, so its values are refused
# rather than published unscanned; reads keep their queries.
test_gh_guard_refuses_api_write_queries() {
  deny_expect gh-api-query "gh api -X POST 'repos/acme/widgets/issues?title=$PRIVATE_TERM&body=$PRIVATE_TERM'" "a POST with a query"
  deny_expect gh-api-query "gh api 'repos/acme/widgets/issues?title=clean' -f body=clean" "an implicit POST with a query"
  deny_expect gh-api-query "gh api 'graphql?query=x' -f query='query { viewer { login } }'" "a GraphQL call with a query"
  allow_expect "gh api 'repos/acme/widgets/issues?state=open&per_page=5'" "a read keeps its query"
  pass "a gh api write carrying a query string is refused"
}

# The publish judge's override is the captain's alone: an agent may not run it,
# drive its prompt through a pseudo-terminal, script it, or write its file.
test_judge_override_is_captain_only() {
  local hash cmd
  hash=$(printf 'a%.0s' $(seq 1 64))
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    policy "$cmd"
    [ $? -eq 2 ] || fail "an agent running the judge override must be refused: $cmd"
    assert_contains "$POLICY_OUT" "judge-override" "judge override code for: $cmd"
    assert_contains "$POLICY_OUT" "Fix: report the refused content hash to firstmate" "judge override fix for: $cmd"
  done <<EOF
bin/fm-publish-judge.sh override $hash
"$ROOT/bin/fm-publish-judge.sh" override $hash
script -q /dev/null bin/fm-publish-judge.sh override $hash
printf 'allow\n' | script -q /dev/null bin/fm-publish-judge.sh override $hash
unbuffer bin/fm-publish-judge.sh override $hash
python3 -c 'import pty; pty.spawn(["bin/fm-publish-judge.sh", "override", "$hash"])'
tmux send-keys -t other 'bin/fm-publish-judge.sh override $hash' Enter
bash -c 'bin/fm-publish-judge.sh override $hash'
printf '%s x\n' $hash >> config/publish-guard/judge-overrides
echo $hash | tee -a config/publish-guard/judge-overrides
sed -i.bak 's/^/x/' config/publish-guard/judge-overrides
EOF
  policy "expect <<'EOT'
spawn bin/fm-publish-judge.sh override $hash
expect \"approve\"
send \"allow\\r\"
EOT"
  [ $? -eq 2 ] || fail "an expect script fed on stdin must be refused"
  policy "bash <<'EOT'
bin/fm-publish-judge.sh override $hash
EOT"
  [ $? -eq 2 ] || fail "a heredoc shell program running the override must be refused"
  for cmd in "bin/fm-publish-judge.sh prompt --dest acme/widgets --kind text m.txt" \
    "grep -n override bin/fm-publish-judge.sh" "sed -n 1,40p bin/fm-publish-judge.sh" \
    "cat config/publish-guard/judge-overrides"; do
    policy "$cmd" || fail "a read of the judge must pass: $cmd ($POLICY_OUT)"
  done
  pass "the judge override is refused however an agent would run it, and its file cannot be written"
}

test_pr_text_shape_rules() {
  local long_body reply
  printf 'Adds a retry to the fetcher.\n\nTested with the fetcher suite.\n' >"$TMP_ROOT/short.md"
  policy 'gh pr create --repo acme/widgets --title "Add fetcher retry" --body-file short.md' \
    || fail "a short neutral PR should pass: $POLICY_OUT"
  long_body="$TMP_ROOT/long.md"
  for _ in $(seq 1 30); do printf 'More detail about the change.\n'; done >"$long_body"
  policy 'gh pr create --repo acme/widgets --title t --body-file long.md'
  [ $? -eq 2 ] || fail "a description over the line limit should be refused"
  assert_contains "$POLICY_OUT" "shape: a description longer than 20 lines" "long body finding"
  policy "gh pr create --repo acme/widgets --title '$(printf 'x%.0s' $(seq 1 120))' --body ok"
  [ $? -eq 2 ] || fail "a title over 100 characters should be refused"
  printf 'Fixes the retry.\nThe hang showed pid 4242 in pane %%12 at 14:32.\n' >"$TMP_ROOT/story.md"
  policy 'gh pr create --repo acme/widgets --title t --body-file story.md'
  [ $? -eq 2 ] || fail "incident evidence in a description should be refused"
  assert_contains "$POLICY_OUT" "shape: incident evidence" "evidence finding"
  policy 'gh pr comment https://github.com/acme/widgets/pull/3 --body "Fixed in abc1234."' \
    || fail "a one-line reply should pass: $POLICY_OUT"
  reply='Fixed in abc1234.
Also reworked the loop so the retry stops after three attempts.'
  policy "gh pr comment https://github.com/acme/widgets/pull/3 --body '$reply'" \
    || fail "a short multi-line reply should pass: $POLICY_OUT"
  policy 'gh api -X POST repos/acme/widgets/pulls/3/comments -f in_reply_to=7 -f body="Not changing this: per the owner'"'"'s direction."'
  [ $? -eq 2 ] || fail "a direction-quoting reply through gh api should be refused"
  assert_contains "$POLICY_OUT" "shape: narrative about what the operator asked or decided" "direction finding"
  printf 'Title\n' >"$TMP_ROOT/t.txt"
  printf 'Fixes retries.\nTested with the suite.\n' >"$TMP_ROOT/b.txt"
  "$GATE" ci-text "title:$TMP_ROOT/t.txt" "body:$TMP_ROOT/b.txt" >/dev/null 2>&1 || fail "CI should pass short PR text"
  "$GATE" ci-text "body:$TMP_ROOT/story.md" >/dev/null 2>&1 && fail "CI should refuse incident evidence in PR text"
  pass "PR titles, descriptions, and replies must be short and neutral, in the guard and in CI"
}

# Live GitHub reads are the public graph interface; synthetic responses model
# a fork merge, a feature branch, and unavailable ancestry without networking.
test_integration_pr_body_limits() {
  local repo="$TMP_ROOT/integration-text" source out body="$TMP_ROOT/integration.md"
  source=$(printf 'a%.0s' $(seq 1 40))
  git init -q -b integration "$repo"
  git -C "$repo" remote add origin https://github.com/acme/widgets.git
  git -C "$repo" remote add upstream https://github.com/acme/upstream.git
  cp "$CFG/upstream" "$TMP_ROOT/upstream.saved" 2>/dev/null || : >"$TMP_ROOT/upstream.saved"
  printf 'acme/upstream\n' >"$CFG/upstream"
  cat >"$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2 $3 $4 $5 $6 $7 $8 $9" = 'pr view integration --repo github.com/acme/widgets --json number --jq .number' ]; then
  printf '3\n'
  exit 0
fi
[ "$1 $2 $3" = 'api --hostname github.com' ] || exit 1
source=$(printf 'a%.0s' $(seq 1 40))
first=$(printf 'b%.0s' $(seq 1 40))
merge=$(printf 'c%.0s' $(seq 1 40))
case "$4" in
repos/acme/widgets/pulls/3) printf 'main\tintegration\tacme/widgets\n' ;;
repos/acme/widgets/pulls/4) printf 'main\tintegration\tacme/another-fork\n' ;;
repos/acme/widgets/compare/main...integration\?per_page=100) printf '%s\t%s\t%s\n' "$merge" "$first" "$source" ;;
repos/acme/widgets/compare/main...feature\?per_page=100) exit 0 ;;
repos/acme/upstream/compare/"$source"...main) printf 'ahead\n' ;;
repos/acme/widgets/compare/"$source"...main) printf 'diverged\n' ;;
*) exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN/gh"
  printf '%s\n' "$FAKEBIN/gh" >"$CFG/gh"
  # About 5000 characters, with the full recorded parent SHA and a tail marker
  # proving the semantic judge receives the entire expanded description.
  printf 'Upstream source %s\n' "$source" >"$body"
  printf '%*s\n' 4944 '' | tr ' ' x >>"$body"
  printf 'Tail review marker.\n' >>"$body"
  out=$(cd "$repo" && FM_TEST_JUDGE_PROMPTS="$TMP_ROOT/integration-prompts" FM_CONFIG_OVERRIDE="$TMP_ROOT/config" "$PRETOOL" --publish-only --claude --command "gh pr create --repo acme/widgets --base main --head integration --title Integration --body-file '$body'" 2>&1) || fail "integration create should pass: $out"
  assert_contains "$(cat "$TMP_ROOT/integration-prompts")" 'Tail review marker.' 'whole description reaches the judge'
  out=$(cd "$repo" && FM_CONFIG_OVERRIDE="$TMP_ROOT/config" "$PRETOOL" --publish-only --claude --command "gh pr edit https://github.com/acme/widgets/pull/3 --body-file '$body'" 2>&1) || fail "integration edit should pass: $out"
  out=$(cd "$repo" && FM_CONFIG_OVERRIDE="$TMP_ROOT/config" "$PRETOOL" --publish-only --claude --command "gh pr edit integration --repo acme/widgets --body-file '$body'" 2>&1) || fail "branch-selected integration edit should pass: $out"
  out=$(cd "$repo" && FM_CONFIG_OVERRIDE="$TMP_ROOT/config" "$PRETOOL" --publish-only --claude --command "gh pr edit --repo acme/widgets --body-file '$body'" 2>&1) || fail "current-branch integration edit should pass: $out"
  out=$(cd "$repo" && "$GATE" ci-text --config "$CFG" --dest acme/widgets --pr 3 --pr-upstream acme/upstream "body:$body" 2>&1) || fail "CI integration should pass: $out"
  out=$(cd "$repo" && FM_CI_PR_DEST=acme/widgets FM_CI_PR_NUMBER=3 FM_CI_PR_UPSTREAM=acme/upstream "$GATE" ci-text --config "$CFG" "body:$body" 2>&1) || fail "CI environment context should pass: $out"
  out=$(cd "$repo" && "$GATE" check-text --config "$CFG" --dest acme/widgets --pr-base main --pr-head feature "body:$body" 2>&1) && fail "non-integration body should refuse"
  assert_contains "$out" 'longer than 1500 characters' 'ordinary feature cap'
  cp "$FAKEBIN/gh" "$FAKEBIN/gh.good"
  sed 's@repos/acme/upstream/compare/@repos/acme/unavailable/compare/@' "$FAKEBIN/gh.good" >"$FAKEBIN/gh"
  out=$(cd "$repo" && "$GATE" check-text --config "$CFG" --dest acme/widgets --pr-base main --pr-head integration "body:$body" 2>&1) && fail "unavailable ancestry should refuse"
  assert_contains "$out" 'longer than 1500 characters' 'unavailable ancestry cap'
  cp "$FAKEBIN/gh.good" "$FAKEBIN/gh"
  out=$(cd "$repo" && FM_CONFIG_OVERRIDE="$TMP_ROOT/config" "$PRETOOL" --publish-only --claude --command "gh pr edit https://github.com/acme/widgets/pull/3 --base \"\$TARGET_BASE\" --body-file '$body'" 2>&1) && fail "unreadable base must not qualify"
  out=$(cd "$repo" && "$GATE" check-text --config "$CFG" --dest acme/widgets --pr-base main --pr-head missing "body:$body" 2>&1) && fail "unverifiable head should refuse"
  assert_contains "$out" 'longer than 1500 characters' 'unverifiable cap'
  out=$(cd "$repo" && "$GATE" check-text --config "$CFG" --dest acme/widgets --pr-base develop --pr-head integration "body:$body" 2>&1) && fail "non-main base should refuse"
  out=$(cd "$repo" && "$GATE" ci-text --config "$CFG" --dest acme/widgets --pr 4 --pr-upstream acme/upstream "body:$body" 2>&1) && fail "cross-fork head should refuse"
  printf '%*s\n' 5000 '' | tr ' ' x >"$TMP_ROOT/unrecorded.md"
  out=$(cd "$repo" && "$GATE" check-text --config "$CFG" --dest acme/widgets --pr-base main --pr-head integration "body:$TMP_ROOT/unrecorded.md" 2>&1) && fail "unrecorded source should refuse"
  printf 'Upstream source %s\n' "$source" >"$body"
  printf '%*s\n' 5945 '' | tr ' ' x >>"$body"
  out=$(cd "$repo" && "$GATE" check-text --config "$CFG" --dest acme/widgets --pr-base main --pr-head integration "body:$body" 2>&1) && fail "6001 characters should refuse"
  assert_contains "$out" 'longer than 6000 characters' 'integration character cap'
  printf 'Upstream source %s\n' "$source" >"$body"
  for _ in $(seq 1 80); do printf '\n'; done >>"$body"
  out=$(cd "$repo" && "$GATE" check-text --config "$CFG" --dest acme/widgets --pr-base main --pr-head integration "body:$body" 2>&1) && fail "81 physical lines should refuse"
  assert_contains "$out" 'longer than 80 lines' 'integration line cap'
  # Both inclusive boundaries pass: 6000 non-newline characters in 80 lines.
  printf 'Upstream source %s\n' "$source" >"$body"
  printf '%*s\n' 5866 '' | tr ' ' x >>"$body"
  for _ in $(seq 1 78); do printf 'x\n'; done >>"$body"
  out=$(cd "$repo" && "$GATE" check-text --config "$CFG" --dest acme/widgets --pr-base main --pr-head integration "body:$body" 2>&1) || fail "inclusive integration limits should pass: $out"
  # Longer descriptions still receive denylist, narrative, and reply checks.
  printf 'Upstream source %s\n%s\n' "$source" "$PRIVATE_TERM" >"$body"
  out=$(cd "$repo" && "$GATE" check-text --config "$CFG" --dest acme/widgets --pr-base main --pr-head integration "body:$body" 2>&1) && fail "integration denylist should refuse"
  assert_contains "$out" 'denylist rule' 'integration content scan'
  out=$(cd "$repo" && "$GATE" check-text --config "$CFG" --dest acme/widgets --pr-base main --pr-head integration "reply:$TMP_ROOT/unrecorded.md" 2>&1) && fail "integration context must not expand reply cap"
  assert_contains "$out" 'longer than 750 characters' 'reply cap retained'
  cp "$TMP_ROOT/upstream.saved" "$CFG/upstream"
  reset_trusted_gh
  pass "only verified fork-local integrations get the larger body cap in the guard and CI"
}

# Replies may run to 5 lines and 750 characters, and the narrative rule
# matches the shapes of incident evidence, not the everyday words a tmux
# orchestrator's own changes use.
test_reply_limits_and_evidence_shapes() {
  local reply six long
  printf 'Teardown now checks the pane pid before it stops the worker.\nThe incident timeline in the docs is unchanged.\nTested with the tmux pane suite.\n' >"$TMP_ROOT/words.md"
  policy 'gh pr create --repo acme/widgets --title "Check the pane pid at teardown" --body-file words.md' \
    || fail "everyday words (pid, pane, tmux pane, timeline, incident) must pass: $POLICY_OUT"
  reply=$(printf 'line %s of the reply\n' 1 2 3 4 5)
  policy "gh pr comment 3 --repo acme/widgets --body '$reply'" || fail "a 5-line reply should pass: $POLICY_OUT"
  six=$(printf 'line %s of the reply\n' 1 2 3 4 5 6)
  policy "gh pr comment 3 --repo acme/widgets --body '$six'"
  [ $? -eq 2 ] || fail "a 6-line reply should be refused"
  assert_contains "$POLICY_OUT" "shape: a reply longer than 5 lines" "reply line finding"
  long=$(printf 'x%.0s' $(seq 1 751))
  policy "gh pr comment 3 --repo acme/widgets --body '$long'"
  [ $? -eq 2 ] || fail "a 751-character reply should be refused"
  assert_contains "$POLICY_OUT" "shape: a reply longer than 750 characters" "reply length finding"
  local evidence
  for evidence in 'killed pid 4242 first' 'PID=77 kept running' 'pane %12 hung' 'failed at 14:32 again' 'logged 2026-09-29T09:05:11Z'; do
    policy "gh pr comment 3 --repo acme/widgets --body '$evidence'"
    [ $? -eq 2 ] || fail "incident evidence must be refused: $evidence"
    assert_contains "$POLICY_OUT" "shape: incident evidence" "evidence finding for $evidence"
  done
  policy "gh pr comment 3 --repo acme/widgets --body 'the captain asked for it'"
  [ $? -eq 2 ] || fail "an operator-direction phrase must still be refused"
  assert_contains "$("$GATE" policy)" "Sensitive evidence never goes into the PR. The code can." "policy principle"
  pass "replies may run to 5 lines and 750 characters, and only evidence shapes and operator direction are refused"
}
test_git_refusals() {
  policy "git -c user.email=$LEAK_EMAIL commit -m x"
  [ $? -eq 2 ] || fail "git -c user.email should be refused"
  policy 'git commit --author="X <x@example.com>" -m x'
  [ $? -eq 2 ] || fail "git commit --author should be refused"
  policy 'GIT_AUTHOR_EMAIL=x@example.com git commit -m x'
  [ $? -eq 2 ] || fail "a GIT_AUTHOR_EMAIL assignment should be refused"
  policy 'git push --no-verify origin main'
  [ $? -eq 2 ] || fail "git push --no-verify should be refused"
  policy 'git commit -nm x'
  [ $? -eq 2 ] || fail "git commit -n should be refused"
  policy 'git -c core.hooksPath=/dev/null push origin main'
  [ $? -eq 2 ] || fail "a core.hooksPath override should be refused"
  policy 'git config user.email x@example.com'
  [ $? -eq 2 ] || fail "git config user.email <value> should be refused"
  policy 'git config user.email' || fail "reading git config user.email must pass"
  policy 'git log --author=someone -n 3' || fail "git log --author and -n must pass"
  policy 'git commit -m "fix author parsing"' || fail "an ordinary commit must pass"
  pass "git identity overrides and hook bypasses are refused while reads and ordinary commits pass"
}

# --- S4 CI checks ---------------------------------------------------------------------

test_ci_commits_and_text() {
  local repo base out
  repo="$TMP_ROOT/ci"
  fm_git_init_commit "$repo" >/dev/null
  base=$(git -C "$repo" rev-parse HEAD)
  mkdir -p "$repo/tests" "$repo/docs"
  printf 'id=%s\n' 1b4e28ba-2fa1-11d2-883f-0016d3cca427 >"$repo/tests/fixture.test.sh"
  git -C "$repo" add tests/fixture.test.sh
  pinned git -C "$repo" commit -q -m 'add fixture'
  out=$(cd "$repo" && "$GATE" ci-commits --base "$base" --head HEAD --identity-email "$PIN_EMAIL" 2>&1) \
    || fail "a pinned commit with a test-fixture uuid should pass CI: $out"
  printf 'device %s\n' 1b4e28ba-2fa1-11d2-883f-0016d3cca427 >"$repo/docs/device.md"
  git -C "$repo" add docs/device.md
  pinned git -C "$repo" commit -q -m 'add device'
  out=$(cd "$repo" && "$GATE" ci-commits --base "$base" --head HEAD --identity-email "$PIN_EMAIL" 2>&1) \
    && fail "a device-id-shaped uuid outside tests should fail CI"
  assert_contains "$out" "generic rule device-id" "device id finding"
  git -C "$repo" reset -q --hard HEAD~1
  printf 'y\n' >"$repo/y"
  git -C "$repo" add y
  unpinned git -C "$repo" -c user.name=L -c user.email="$LEAK_EMAIL" commit -q -m y
  out=$(cd "$repo" && "$GATE" ci-commits --base "$base" --head HEAD 2>&1) \
    && fail "a private-address commit should fail CI even without the identity variable"
  assert_contains "$out" "author email is not the pinned identity" "CI identity finding"
  printf 'Fixes retries.\n\n%s\n' "$SESSION_URL" >"$TMP_ROOT/pr-body.txt"
  out=$("$GATE" ci-text "$TMP_ROOT/pr-body.txt" 2>&1) && fail "a session link in PR text should fail CI"
  assert_contains "$out" "session-link" "CI text finding"
  printf 'Fixes retries.\n' >"$TMP_ROOT/pr-body.txt"
  "$GATE" ci-text "$TMP_ROOT/pr-body.txt" >/dev/null 2>&1 || fail "clean PR text should pass CI"
  pass "CI checks refuse non-noreply identities, device ids outside tests, and session links in PR text"
}

test_policy_text() {
  local out
  out=$("$GATE" policy)
  assert_contains "$out" "No session or transcript links." "policy text"
  assert_contains "$out" "Purpose: never write sensitive information into a public repository" "policy purpose"
  assert_contains "$out" "stays public permanently" "policy permanence"
  pass "policy prints the public-text policy"
}

test_identity_file_contract
test_pin_neutralizes_git_c_user_email
test_clean_push_passes
test_private_address_via_git_c_is_refused
test_private_address_via_author_flag_is_refused
test_private_address_in_squash_trailer_is_refused
test_denylist_term_in_content_is_refused
test_host_and_hardware_terms_are_refused
test_session_url_is_refused
test_added_then_deleted_in_one_push_is_refused
test_secret_added_then_deleted_is_refused_by_gitleaks
test_old_history_commit_is_refused
test_sensitive_branch_name_is_refused
test_home_path_rule_spares_placeholders
test_deletion_push_checks_destination_only
test_upstream_merge_scans_only_new_merge_content
test_cached_remote_refs_never_exempt_history
test_poison_is_checked_before_any_exemption
test_advertised_history_comes_from_the_trusted_git
test_amend_cherry_pick_and_rebase_keep_the_leak_visible
test_author_and_committer_email_config_keys
test_new_branch_and_tag_pushes
test_artifact_file_names_are_scanned
test_binary_and_empty_file_names_are_scanned
test_unlisted_github_destination_is_refused
test_missing_allowlist_refuses_network_and_allows_local
test_missing_private_config_refuses_public_push
test_missing_gitleaks_refuses_public_push
test_private_destination_needs_live_confirmation
test_private_check_ignores_worker_gh_and_proxy
test_owned_repos_pass_while_private
test_refusals_name_their_fix
test_suggest_allowlist_lists_only_confirmed_private_repos
test_disable_push_helper
test_install_refuses_foreign_hook
test_commit_msg_check
test_per_task_hooks_run_the_gate
test_keep_ai_trailers_still_runs_the_gate
test_pre_commit_checks_the_staged_change
test_secondmate_home_inherits_publish_guard
test_gh_guard
test_worker_worktree_uses_the_home_config
test_gh_guard_option_spellings
test_gh_guard_file_reads_run_alone
test_gh_guard_refuses_generated_text
test_gh_guard_covers_other_writes
test_gh_guard_help_is_a_boolean
test_gh_guard_url_selector_sets_the_repo
test_gh_guard_refuses_visibility_changes
test_gh_guard_refuses_api_write_queries
test_judge_override_is_captain_only
test_pr_text_shape_rules
test_integration_pr_body_limits
test_reply_limits_and_evidence_shapes
test_git_refusals
test_ci_commits_and_text
test_permission_fixtures_pass_the_secret_scan
test_policy_text

echo "# all fm-publish-gate tests passed"
