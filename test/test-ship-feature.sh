#!/usr/bin/env bash
# Tests for the ship-feature CLI + privacy scan. Uses real temp git repos and a stubbed
# pr-review-relay; no network. Run: bash test/test-ship-feature.sh
set -uo pipefail

# The own-gate cases at the end run bin/ci, and bin/ci runs this suite as its last stage. Those
# cases stop bin/ci before that stage, but a broken bin/ci (a dropped stage) would let one reach it,
# and the suite would then start itself again and again with no end. This guard turns that into a
# fast failure: a suite started inside a running suite exits 2 at once.
if [ -n "${SHIP_FEATURE_SUITE_RUNNING:-}" ]; then
  echo "ship-feature tests: started inside a running suite (a bin/ci case reached the tests stage) — refusing" >&2
  exit 2
fi
export SHIP_FEATURE_SUITE_RUNNING=1

HERE="$(cd "$(dirname "$0")" && pwd)"
CLI="$HERE/../bin/ship-feature"
SCAN="$HERE/../scripts/scan-personal-data.sh"
WORK="$(mktemp -d)" || {
  echo "mktemp failed" >&2
  exit 1
}
[ -n "$WORK" ] && [ -d "$WORK" ] || {
  echo "no temp dir" >&2
  exit 1
}
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# --- git isolation -----------------------------------------------------------
# This suite builds real git repos under $WORK and commits in them. It must operate on THOSE and
# nothing else, and its result must not depend on how the developer's git happens to be configured.
# Two ways that goes wrong, both observed:
#
#   1. SIGNING. With `commit.gpgsign = true` and an agent-backed signer (1Password's op-ssh-sign
#      here), every fixture commit is really signed — measured, `%G?` came back `G`. When the agent
#      is locked the signer returns nothing and the commits fail or block, and the suite reports a
#      handful of failures that have nothing to do with the code. The green we get today is
#      conditional on 1Password being unlocked, which is not a property of this repository.
#
#   2. REPO-LOCAL ENVIRONMENT. git exports GIT_DIR (and friends) to its hooks, and those variables
#      OUTRANK the working directory: with GIT_DIR set, `cd "$repo" && git init && git commit`
#      commits to the HOST repo and leaves the fixture empty. Run from a pre-push hook, the sibling
#      pr-review-relay suite did exactly that — junk commits on the branch being pushed, the branch
#      renamed, HEAD moved, and user.name rewritten in the real repository.
#
# The list comes from `git rev-parse --local-env-vars` rather than being typed here: it is git's own
# answer, it cannot go stale, and a hand-written version of this list missed 7 of the 15 entries when
# it was tried. GIT_CONFIG_COUNT is itself on that list, so the clearing must happen BEFORE the
# controlled values are set, not after.
#
# GIT_CONFIG_PARAMETERS matters more than it looks: it is set whenever anything up the process tree
# ran `git -c …`, and it OVERRIDES GIT_CONFIG_COUNT. Measured: with both present, an ambient
# `commit.gpgsign=true` wins and the isolation silently does nothing. Clearing the list first is what
# closes that.
#
# NOT `GIT_CONFIG_GLOBAL=/dev/null`, which is the obvious one-liner: it discards the whole global
# config including safe.directory and init.defaultBranch, so on a CI runner that needs them it turns
# a signing bug into a stranger failure. NOT `git config` inside the fixtures either — that was tried
# in pr-review-relay and was worse than the bug it fixed: where a fixture's `git init` fails quietly,
# the following `git config` writes into whatever repo the suite was launched from, and it set
# user.name=t and disabled commit signing in the real repository.
#
# ONE function, called here and again inside every hostile subprocess below. A copied block would
# keep those tests passing after this one is deleted, which is the exact failure mode being fixed.
# tag.gpgsign has no effect on this suite today (nothing tags); it is here so a future tag test does
# not reintroduce the hang, and it has a config assertion so it cannot rot unnoticed.
# HARD REQUIREMENT, not a skip. On a git without GIT_CONFIG_COUNT (pre-2.31) the unset loop below
# still clears GIT_DIR, but none of the controlled values take effect — so the isolation would be
# HALF applied while the suite stayed green, which is the fail-open shape this whole change exists
# to remove. The first version skipped the proof tests and counted them as passes, which made that
# worse: green suite, no isolation, including when launched from a hook. Refuse instead.
# The probe requires the VALUE, not merely that the lookup succeeded. Checking only the exit status
# meant an ambient config that happens to define sf.probe would satisfy it on a pre-2.31 git, and the
# suite would then run with the isolation half applied — precisely the fail-open this gate exists to
# prevent. The value is deliberately unlikely to collide.
_probe=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=sf.probe GIT_CONFIG_VALUE_0=sf-isolation-probe-ok \
  git config --get sf.probe 2>/dev/null)
if [ "$_probe" != "sf-isolation-probe-ok" ]; then
  echo "ship-feature tests: need git 2.31+ (GIT_CONFIG_COUNT) to isolate the fixtures; found $(git --version)" >&2
  exit 2
fi
# The unset half depends on this listing, and a process substitution that fails leaves the loop a
# silent no-op while the exports proceed — the same half-applied shape. Require it to name GIT_DIR.
if ! git rev-parse --local-env-vars 2>/dev/null | grep -qx GIT_DIR; then
  echo "ship-feature tests: 'git rev-parse --local-env-vars' does not list GIT_DIR; cannot isolate fixtures" >&2
  exit 2
fi
unset _probe

sf_isolate_git() {
  while IFS= read -r _v; do [ -n "$_v" ] && unset "$_v"; done < <(git rev-parse --local-env-vars)
  unset _v
  export GIT_CONFIG_COUNT=7
  export GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
  export GIT_CONFIG_KEY_1=tag.gpgsign GIT_CONFIG_VALUE_1=false
  # Signing and hooks were the measured failures, but they are not the only ambient settings that
  # reach a fixture. core.excludesFile is the sharpest: a global ignore rule for `*.dat` makes the
  # binary-scan fixture's file invisible and that test fails for a reason nobody would guess.
  # attributesFile can rewrite content through filters; fsmonitor attaches a daemon to throwaway
  # repos. color.ui=always would put ANSI into the `%G?` read below and break an exact comparison.
  # A path that does not exist: hooks are then simply never found. An ambient core.hooksPath can
  # otherwise fail or mutate every fixture commit — measured, a planted pre-commit made `git commit`
  # exit 1 until this was set.
  export GIT_CONFIG_KEY_2=core.hooksPath GIT_CONFIG_VALUE_2="${WORK:-/nonexistent}/no-such-hooks"
  export GIT_CONFIG_KEY_3=core.excludesFile GIT_CONFIG_VALUE_3=/dev/null
  export GIT_CONFIG_KEY_4=core.attributesFile GIT_CONFIG_VALUE_4=/dev/null
  export GIT_CONFIG_KEY_5=core.fsmonitor GIT_CONFIG_VALUE_5=false
  export GIT_CONFIG_KEY_6=color.ui GIT_CONFIG_VALUE_6=false
  # DELIBERATELY NOT init.templateDir="". It was in the first version of this function, to stop a
  # global template installing hooks, and it is both redundant and harmful. Redundant because
  # core.hooksPath above already wins over anything a template drops in .git/hooks — measured, a
  # template-installed pre-commit did not run once hooksPath pointed elsewhere. Harmful because an
  # empty template means `git init` creates no .git/info at all, so `>> .git/info/exclude` fails and
  # the fixtures that git-ignore the worktree marker break: it turned two passing preflight tests
  # red, which is how it was found.
}
sf_isolate_git

# Isolate from the user's real config/env so the suite is deterministic outside CI.
export SHIP_FEATURE_CONFIG=/dev/null
# The SHARED panel config (pr-review-relay's file) is read as the last fallback, so the
# suite must not see the developer's real one — its MODEL_* keys would satisfy the
# default-pin assertions and the tests would pass on this machine only.
export PR_RELAY_CONFIG=/dev/null
# The model pins are not SHIP_FEATURE_* keys (the names are shared with pr-review-relay), so they
# would not be caught by the namespace above — but they are knobs people really do export once
# ship-feature/pr-review-relay are in use, and an exported value would quietly satisfy the
# default-pin assertions below. Clear them here so the suite stays hermetic no matter who runs it.
# PR_RELAY_OPENCODE_MODEL joined the list when the config file learned to carry it.
# SHIP_FEATURE_PLAN_TIMEOUT and PR_RELAY_AGENT_TIMEOUT joined this list when the timeout learned to
# come from the shared config. They are knobs people really do export, and an exported one would
# satisfy the "no config at all -> the built-in default" assertion below: green on this machine,
# red in CI, for a reason the assertion never mentions.
unset SHIP_FEATURE_WORKTREE_ROOT SHIP_FEATURE_EXCLUDE_MARKER SHIP_FEATURE_DENYLIST SHIP_FEATURE_REVIEWERS SHIP_FEATURE_PLAN_REVIEWERS CURSOR_REVIEW_MODEL GLM_REVIEW_MODEL KIMI3_REVIEW_MODEL GROK45HIGH_REVIEW_MODEL CLAUDE_REVIEW_MODEL CLAUDE_REVIEW_EFFORT CODEX_REVIEW_MODEL CODEX_REVIEW_EFFORT GROK_REVIEW_MODEL GROK_REVIEW_EFFORT PI_GLM_REVIEW_MODEL PI_GLM_REVIEW_EFFORT PI_GROK_REVIEW_MODEL PI_GROK_REVIEW_EFFORT PR_RELAY_OPENCODE_MODEL SHIP_FEATURE_PLAN_TIMEOUT PR_RELAY_AGENT_TIMEOUT SHIP_FEATURE_GEMINI_MODEL SHIP_FEATURE_GEMINI_TESTED_VERSIONS
# The gemini seat picks its auth method from the environment, and anyone who actually uses gemini
# has one of these exported — a working machine is the normal case, not the exotic one. Leave them
# in place and the seat takes the API-key path on this developer's box and the OAuth path in CI,
# from the same source, with the cases that cover the OAuth copy silently asserting nothing. Each
# test below sets exactly the auth it means to exercise.
unset GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_GENAI_USE_VERTEXAI GOOGLE_GENAI_USE_GCA

# Assert the isolation is actually in force HERE, before a single fixture runs. This check used to
# sit at the very end with the others, which meant that if the sf_isolate_git call were deleted the
# whole suite would run against the host repo and only complain afterwards — with a hook-exported
# GIT_DIR that is the corruption this change exists to stop, reported far too late to help. The
# end-of-suite cases prove the isolation WORKS; this one proves it was APPLIED.
sf_check_isolated() {
  [ "${GIT_CONFIG_COUNT:-0}" = 7 ] && [ "$(git config --get commit.gpgsign 2>/dev/null)" = "false" ]
}
if ! sf_check_isolated; then
  echo "ship-feature tests: the top-level sf_isolate_git call is missing or ineffective — refusing to run" >&2
  exit 2
fi

PASS=0
FAIL=0
check() { # check <desc> <actual_rc> <want_rc>
  if [ "$2" = "$3" ]; then
    echo "  ok   [$2] $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [got $2 want $3] $1"
    FAIL=$((FAIL + 1))
  fi
}

echo "ship-feature tests:"

# --- the relay libraries come from the script's own checkout, through links ---------------------
# install.sh links bin/ship-feature into ~/.local/bin, and the script sources relay/lib-panel.sh and
# relay/lib-pi.sh from its checkout. An absolute link and a relative link to that link must both
# resolve to the checkout; a copy with no relay/ next to it must stop and say so.
mkdir -p "$WORK/linkbin" "$WORK/lonely/bin"
ln -s "$CLI" "$WORK/linkbin/ship-feature"
ln -s ship-feature "$WORK/linkbin/sf-relative"
bash "$WORK/linkbin/ship-feature" help >/dev/null 2>&1
check "a linked ship-feature finds relay/ in its checkout" $? 0
bash "$WORK/linkbin/sf-relative" help >/dev/null 2>&1
check "a relative link to that link finds relay/ too" $? 0
cp "$CLI" "$WORK/lonely/bin/ship-feature"
out=$(bash "$WORK/lonely/bin/ship-feature" help 2>&1)
check "a copy with no relay/ next to it stops and says so" "$?|$(printf '%s' "$out" | grep -c 'no relay/ next to')" "1|1"

# --- build a real remote + clone + feature worktree --------------------------
REMOTE="$WORK/remote.git"
git init -q --bare "$REMOTE"
MAIN="$WORK/main"
git clone -q "$REMOTE" "$MAIN"
# The seed carries the repository's gate: a committed .githooks/pre-push. `git add --chmod=+x` records
# 100755 whatever the host's core.filemode says; chmod +x makes the checked-out file executable too.
sf_seed_hook() { # sf_seed_hook <dir>: writes and stages a do-nothing .githooks/pre-push
  mkdir -p "$1/.githooks" && printf '#!/bin/sh\nexit 0\n' >"$1/.githooks/pre-push" && chmod +x "$1/.githooks/pre-push" &&
    git -C "$1" add --chmod=+x .githooks/pre-push
}
(cd "$MAIN" && sf_seed_hook . && git commit -q -m "seed" && git push -q origin HEAD:main && git remote set-head origin main >/dev/null 2>&1)
git -C "$REMOTE" symbolic-ref HEAD refs/heads/main # so fresh clones resolve origin/HEAD = main
printf '.claude/\n' >>"$MAIN/.git/info/exclude"
(cd "$MAIN" && git worktree add -q -b feat .claude/worktrees/feat origin/main)

# sf_isolate_git points core.hooksPath (environment config, key 2) at a directory that does not exist, so
# no ambient hook runs in a fixture. A preflight that must find the gate overrides that one value for
# that one call: `pf` is preflight with core.hooksPath=.githooks.
# shellcheck disable=SC2120 # "$@" is the helper's interface; today every call passes none
pf() { GIT_CONFIG_VALUE_2=.githooks bash "$CLI" preflight "$@"; }

# preflight: correct worktree setup → pass
(cd "$MAIN/.claude/worktrees/feat" && pf >/dev/null 2>&1)
check "preflight passes in a proper feature worktree" $? 0
# preflight: on the default branch → fail
(cd "$MAIN" && bash "$CLI" preflight >/dev/null 2>&1)
check "preflight fails on the default branch" $? 1
# preflight: on a feature branch but NOT a linked worktree → fail
(cd "$MAIN" && git checkout -q -b feat2 && bash "$CLI" preflight >/dev/null 2>&1)
check "preflight fails outside a linked worktree" $? 1

# preflight negatives:
# (a) worktree marker not git-ignored → fail (fresh clone, no exclude entry added)
MAINB="$WORK/mainb"
git clone -q "$REMOTE" "$MAINB"
(cd "$MAINB" && git worktree add -q -b featb .claude/worktrees/featb origin/main)
(cd "$MAINB/.claude/worktrees/featb" && bash "$CLI" preflight >/dev/null 2>&1)
check "preflight fails when the marker is not git-ignored" $? 1
# (b) worktree outside the configured root → fail
(cd "$MAIN" && git worktree add -q -b featx "$WORK/elsewhere" origin/main)
(cd "$WORK/elsewhere" && bash "$CLI" preflight >/dev/null 2>&1)
check "preflight fails when worktree is outside the root" $? 1
# (c) behind the default branch → fail, unless SHIP_FEATURE_ALLOW_BEHIND
(cd "$MAIN" && git checkout -q main && git commit -q --allow-empty -m "advance main" && git push -q origin main)
(cd "$MAIN/.claude/worktrees/feat" && git fetch -q origin && bash "$CLI" preflight >/dev/null 2>&1)
check "preflight fails when behind the default branch" $? 1
(cd "$MAIN/.claude/worktrees/feat" && SHIP_FEATURE_ALLOW_BEHIND=1 pf >/dev/null 2>&1)
check "preflight passes behind with SHIP_FEATURE_ALLOW_BEHIND" $? 0

# --- preflight: the repository's pre-push hook (.githooks/pre-push) ------------------------------
# Each case gets a fresh remote + clone + feature worktree whose seed commit carries a 100755 hook.
HKN=0
mk_hk() { # sets HKM (the main tree) and HKW (the feature worktree)
  HKN=$((HKN + 1))
  local r="$WORK/hk$HKN"
  git init -q --bare "$r.git"
  git clone -q "$r.git" "$r" 2>/dev/null
  (cd "$r" && sf_seed_hook . && git commit -q -m seed && git push -q origin HEAD:main && git remote set-head origin main >/dev/null 2>&1)
  git -C "$r.git" symbolic-ref HEAD refs/heads/main
  printf '.claude/\n' >>"$r/.git/info/exclude"
  (cd "$r" && git worktree add -q -b hk .claude/worktrees/hk origin/main)
  HKM="$r"
  HKW="$r/.claude/worktrees/hk"
}
# hk_pf <dir> [VAR=value ...]: preflight in <dir> with core.hooksPath=.githooks unless a VAR overrides
# it; stdout to $WORK/pf.out, stderr to $WORK/pf.err.
hk_pf() {
  local d="$1"
  shift
  (cd "$d" && env GIT_CONFIG_VALUE_2=.githooks "$@" bash "$CLI" preflight >"$WORK/pf.out" 2>"$WORK/pf.err")
}
# hk_case <desc> <want_rc> <file: out|err> <extended-regex>: the exit code AND the message, from the
# stream that carries it (ok writes to stdout, die to stderr).
hk_case() {
  local desc="$1" want="$2" rc="$3" stream="$4" re="$5" got
  got="$rc"
  [ "$rc" = "$want" ] && ! grep -Eq -- "$re" "$WORK/pf.$stream" && got="wrong-reason($(tr '\n' ' ' <"$WORK/pf.$stream" | cut -c1-110))"
  check "preflight hook: $desc" "$got" "$want"
}
mk_hk
hk_pf "$HKW"
hk_case "a committed 100755 .githooks/pre-push that git runs passes" 0 $? out 'pre-push hook: \.githooks/pre-push'
mk_hk
mkdir -p "$HKW/sub/dir"
hk_pf "$HKW/sub/dir"
hk_case "the same from a subdirectory passes (a relative --git-path joined to the root)" 0 $? out '\.githooks/pre-push'
mk_hk
git -C "$HKW" rm -q .githooks/pre-push && git -C "$HKW" commit -q -m rm
hk_pf "$HKW"
hk_case "no .githooks/pre-push fails and says what the hook must run" 1 $? err 'no pre-push hook.*tests, a linter and a formatter'
mk_hk
chmod -x "$HKW/.githooks/pre-push"
hk_pf "$HKW"
hk_case "a hook without the executable bit on disk fails" 1 $? err 'not executable'
mk_hk
git -C "$HKW" add --chmod=-x .githooks/pre-push && git -C "$HKW" commit -q -m demote
hk_pf "$HKW"
hk_case "a hook executable on disk but committed 100644 fails and names the fix" 1 $? err '100644, not 100755.*--chmod=\+x'
mk_hk
rm "$HKW/.githooks/pre-push"
mkdir "$HKW/.githooks/pre-push"
hk_pf "$HKW"
hk_case "a directory named pre-push fails" 1 $? err 'not a regular file'
mk_hk
git -C "$HKW" rm -q --cached .githooks/pre-push && git -C "$HKW" commit -q -m untrack
hk_pf "$HKW"
hk_case "an untracked hook fails" 1 $? err 'not committed'
git -C "$HKW" add --chmod=+x .githooks/pre-push
hk_pf "$HKW"
hk_case "a staged, not committed hook fails" 1 $? err 'not committed'
git -C "$HKW" commit -q -m retrack
hk_pf "$HKW"
hk_case "the same hook passes once it is committed" 0 $? out 'pre-push hook'
mk_hk
printf 'exit 0 # edited\n' >>"$HKW/.githooks/pre-push"
hk_pf "$HKW"
hk_case "a hook edited on disk and not committed fails" 1 $? err 'differs from the committed'
mk_hk
printf '#!/bin/sh\necho other\n' >"$WORK/other-hook$HKN"
chmod +x "$WORK/other-hook$HKN"
rm "$HKW/.githooks/pre-push"
ln -s "$WORK/other-hook$HKN" "$HKW/.githooks/pre-push"
hk_pf "$HKW"
hk_case "a hook replaced by an uncommitted symlink to another script fails" 1 $? err 'reached through a symlink'
# The same with a link target that holds the committed bytes: -f, hash-object and -ef all follow it.
mk_hk
cp "$HKW/.githooks/pre-push" "$WORK/same-hook$HKN"
chmod +x "$WORK/same-hook$HKN"
rm "$HKW/.githooks/pre-push"
ln -s "$WORK/same-hook$HKN" "$HKW/.githooks/pre-push"
hk_pf "$HKW"
hk_case "an uncommitted symlink to a file with the committed bytes fails" 1 $? err 'reached through a symlink'
mk_hk
mkdir "$WORK/same-dir$HKN"
cp -p "$HKW/.githooks/pre-push" "$WORK/same-dir$HKN/"
rm -r "$HKW/.githooks"
ln -s "$WORK/same-dir$HKN" "$HKW/.githooks"
hk_pf "$HKW"
hk_case "a .githooks directory replaced by a symlink to a copy with the committed bytes fails" 1 $? err 'reached through a symlink'
mk_hk
git -C "$HKW" update-index --assume-unchanged .githooks/pre-push
printf 'exit 0 # hidden\n' >>"$HKW/.githooks/pre-push"
hk_pf "$HKW"
hk_case "an assume-unchanged hook edited on disk fails (blob ids, not git diff)" 1 $? err 'differs from the committed'
mk_hk
printf 'exit 0 # staged\n' >>"$HKW/.githooks/pre-push"
git -C "$HKW" add .githooks/pre-push
git -C "$HKW" show HEAD:.githooks/pre-push >"$HKW/.githooks/pre-push"
hk_pf "$HKW"
hk_case "a staged edit that differs from HEAD fails although the disk matches HEAD" 1 $? err 'differs from the committed'
# A clean filter that turns the edited file back into the committed bytes: hash-object would apply it.
mk_hk
cp "$HKW/.githooks/pre-push" "$WORK/clean-copy$HKN"
git -C "$HKW" config filter.hide.clean "cat '$WORK/clean-copy$HKN'"
printf '.githooks/pre-push filter=hide\n' >>"$(git -C "$HKW" rev-parse --path-format=absolute --git-path info/attributes)"
printf 'exit 0 # hidden by a clean filter\n' >>"$HKW/.githooks/pre-push"
hk_pf "$HKW"
hk_case "a hook edit hidden by a clean filter fails (the bytes on disk, --no-filters)" 1 $? err 'differs from the committed'
# The committed hook with CRLF line ends on disk and core.autocrlf=true: the conversion would hash it
# to the committed blob, but git runs the CRLF bytes (#!/bin/sh followed by a carriage return).
mk_hk
git -C "$HKW" config core.autocrlf true
awk '{ printf "%s\r\n", $0 }' "$HKW/.githooks/pre-push" >"$WORK/crlf$HKN"
cat "$WORK/crlf$HKN" >"$HKW/.githooks/pre-push"
hk_pf "$HKW"
hk_case "the committed hook with CRLF line ends on disk fails (core.autocrlf=true, --no-filters)" 1 $? err 'differs from the committed'
mk_hk
(cd "$HKW" && mv .githooks/pre-push .githooks/real-hook && git add --chmod=+x .githooks/real-hook && ln -s real-hook .githooks/pre-push && git add .githooks/pre-push && git commit -q -m symlink)
hk_pf "$HKW"
hk_case "a committed symlink at .githooks/pre-push, checked out as a link, fails" 1 $? err 'reached through a symlink'
# The same commit with a regular file on disk in place of the link: HEAD still holds mode 120000.
(cd "$HKW" && rm .githooks/pre-push && cp -p .githooks/real-hook .githooks/pre-push)
hk_pf "$HKW"
hk_case "a regular file on disk over a symlink committed in HEAD fails (mode 120000)" 1 $? err 'not a 100755 file \(mode 120000\)'
# core.hooksPath unset: key 2 becomes a dummy key (GIT_CONFIG_COUNT stays 7), and no real global or
# system config can supply a value.
mkdir -p "$WORK/hk-home"
HK_UNSET="GIT_CONFIG_KEY_2=sf.dummy GIT_CONFIG_VALUE_2=x HOME=$WORK/hk-home XDG_CONFIG_HOME=$WORK/hk-home GIT_CONFIG_NOSYSTEM=1"
mk_hk
(
  unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
  hk_pf "$HKW" $HK_UNSET
)
hk_case "core.hooksPath unset fails and names the fix" 1 $? err 'git config core.hooksPath \.githooks'
mk_hk
ln -s "$HKM/.githooks/pre-push" "$HKM/.git/hooks/pre-push"
(
  unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
  hk_pf "$HKW" $HK_UNSET
)
hk_case "core.hooksPath unset, .git/hooks/pre-push a symlink to the main tree's copy, fails" 1 $? err 'not this worktree'
mk_hk
mkdir -p "$WORK/hk-link$HKN"
ln -s "$HKW/.githooks/pre-push" "$WORK/hk-link$HKN/pre-push"
hk_pf "$HKW" GIT_CONFIG_VALUE_2="$WORK/hk-link$HKN"
hk_case "core.hooksPath at a symlink to this worktree's own hook passes (-ef, not a string compare)" 0 $? out 'pre-push hook'
mk_hk
hk_pf "$HKW" GIT_CONFIG_VALUE_2="$HKM/.githooks"
hk_case "an absolute core.hooksPath into the main tree fails and names the fix" 1 $? err 'not this worktree.*core\.hooksPath \.githooks'
mk_hk
HK_OTHER="$HKM"
mk_hk
hk_pf "$HKW" GIT_CONFIG_VALUE_2="$HK_OTHER/.githooks"
hk_case "core.hooksPath into another repository's hooks fails" 1 $? err 'not this worktree'
mk_hk
hk_pf "$HKW" GIT_CONFIG_VALUE_2=
hk_case "an empty core.hooksPath fails" 1 $? err 'not this worktree'

# --- relay passthrough: exit code + stdout preserved -------------------------
BIN="$WORK/bin"
mkdir -p "$BIN"
make_relay() {
  printf '#!/usr/bin/env bash\necho "RELAY-STDOUT-MARKER"\nexit %s\n' "$1" >"$BIN/pr-review-relay"
  chmod +x "$BIN/pr-review-relay"
}
for code in 0 3 4; do
  make_relay "$code"
  out=$(PATH="$BIN:$PATH" bash "$CLI" relay --author claude 2>/dev/null)
  rc=$?
  check "relay passthrough preserves exit $code" "$rc" "$code"
  printf '%s' "$out" | grep -q "RELAY-STDOUT-MARKER" && {
    echo "  ok   [-] relay preserves stdout (exit $code)"
    PASS=$((PASS + 1))
  } || {
    echo "  FAIL relay dropped stdout (exit $code)"
    FAIL=$((FAIL + 1))
  }
done
# relay: dependency missing → clear failure
(PATH="/usr/bin:/bin" bash "$CLI" relay >/dev/null 2>&1)
check "relay fails clearly when pr-review-relay is absent" $? 1

# --- review passthrough: review-local's args, stdout and exit code -----------
for code in 0 3; do
  printf '#!/usr/bin/env bash\necho "REVIEW-LOCAL ARGS: $*"\nexit %s\n' "$code" >"$BIN/review-local"
  chmod +x "$BIN/review-local"
  out=$(PATH="$BIN:$PATH" bash "$CLI" review --author claude --base origin/main --reviewers codex 2>/dev/null)
  rc=$?
  check "review passthrough: exit $code, stdout and every argument reach review-local" "$rc|$out" "$code|REVIEW-LOCAL ARGS: --author claude --base origin/main --reviewers codex"
done
rm -f "$BIN/review-local"
out=$(PATH="/usr/bin:/bin" bash "$CLI" review 2>&1)
check "review fails clearly when review-local is absent, and names install.sh" "$?|$(printf '%s' "$out" | grep -c 'install.sh')" "1|1"

# --- privacy scan: planted term caught; clean tree passes --------------------
SREPO="$WORK/scanrepo"
git init -q "$SREPO"
(cd "$SREPO" && echo "hello world" >a.txt && git add a.txt && git commit -q -m "clean commit")
printf 'SECRET-SLUG-XYZ\n' >"$WORK/deny.txt"
(cd "$SREPO" && bash "$SCAN" "$WORK/deny.txt" >/dev/null 2>&1)
check "scan passes on a clean repo" $? 0
(cd "$SREPO" && echo "leak: SECRET-SLUG-XYZ" >b.txt && git add b.txt && git commit -q -m "oops" && bash "$SCAN" "$WORK/deny.txt" >/dev/null 2>&1)
check "scan catches a planted term in history" $? 1
# planted term in a COMMIT MESSAGE (not file contents) is also caught
SREPO2="$WORK/scanrepo2"
git init -q "$SREPO2"
(cd "$SREPO2" && git commit -q --allow-empty -m "mentions SECRET-SLUG-XYZ" && bash "$SCAN" "$WORK/deny.txt" >/dev/null 2>&1)
check "scan catches a planted term in a commit message" $? 1
# planted term in a FILENAME is also caught
SREPO3="$WORK/scanrepo3"
git init -q "$SREPO3"
(cd "$SREPO3" && : >"SECRET-SLUG-XYZ-name.txt" && git add . && git commit -q -m "add file" && bash "$SCAN" "$WORK/deny.txt" >/dev/null 2>&1)
check "scan catches a deny-listed term in a filename" $? 1

# --- install.sh under a throwaway HOME (exercises symlinks + AGENTS.md awk) ---
FAKEHOME="$WORK/home"
mkdir -p "$FAKEHOME"
(cd "$HERE/.." && HOME="$FAKEHOME" bash install.sh >/dev/null 2>&1)
check "install.sh succeeds under a clean HOME" $? 0
if [ -f "$FAKEHOME/.config/ship-feature/WORKFLOW.md" ] && [ -f "$FAKEHOME/.local/bin/ship-feature" ] &&
  [ -f "$FAKEHOME/.claude/skills/ship-feature/SKILL.md" ] &&
  grep -qF '# >>> ship-feature >>>' "$FAKEHOME/.codex/AGENTS.md" 2>/dev/null; then
  echo "  ok   [-] install wired WORKFLOW + CLI + skill + Codex block"
  PASS=$((PASS + 1))
else
  echo "  FAIL install did not wire everything"
  FAIL=$((FAIL + 1))
fi
# The plans directory is step 1 of the pipeline, so it must exist before the
# first plan is written — not be created by some later command that happens to
# run first.
check "install.sh creates the plans directory" "$([ -d "$FAKEHOME/.config/ship-feature/plans" ] && echo yes || echo no)" yes
_rl_bad=""
for _c in pr-review-relay review-local pr-review-fetch pr-review-distill pr-review-collapse-comments pr-review-consensus wrap-collapsed-pr-comment.mjs; do
  [ "$(readlink "$FAKEHOME/.local/bin/$_c" 2>/dev/null)" = "$(cd "$HERE/.." && pwd)/relay/$_c" ] || _rl_bad="$_rl_bad $_c"
done
check "install.sh links every relay command to relay/" "${_rl_bad:-none}" none
out="$(cd "$WORK" && HOME="$FAKEHOME" "$FAKEHOME/.local/bin/review-local" --help 2>&1)"
check "the linked review-local runs (finds its libraries through the link)" "$?|$(printf '%s' "$out" | grep -q '^review-local' && echo help)" "0|help"
# `stat -c` is GNU; macOS ships BSD stat and would return an empty string, so the
# assertion below would compare "" against 700 and fail the required macOS job.
# `ls -ld` is in POSIX and prints the same permission string on both.
dir_mode() { ls -ld "$1" 2>/dev/null | cut -c1-10; }
# Owner-only: a plan describes an unreleased change in a private repo, and the
# common 022 umask would leave it readable by every local user.
check "install.sh makes the plans directory owner-only" "$(dir_mode "$FAKEHOME/.config/ship-feature/plans")" "drwx------"
# Set on EVERY run, not only at creation — a directory made before this rule
# existed is precisely the one that is still world readable.
chmod 755 "$FAKEHOME/.config/ship-feature/plans"
(cd "$HERE/.." && HOME="$FAKEHOME" bash install.sh >/dev/null 2>&1)
check "install.sh re-secures an existing loose plans directory" "$(dir_mode "$FAKEHOME/.config/ship-feature/plans")" "drwx------"
# Fail-closed: a FILE where the plans directory belongs must make the install
# fail loudly. Reporting success without it is the dangerous outcome — the next
# plan goes somewhere volatile and nobody is told.
FAKEHOME3="$WORK/home3"
mkdir -p "$FAKEHOME3/.config/ship-feature"
: >"$FAKEHOME3/.config/ship-feature/plans"
(cd "$HERE/.." && HOME="$FAKEHOME3" bash install.sh >/dev/null 2>&1)
check "install.sh fails when the plans path is a file" $? 1
# A `plans` SYMLINK must not have its target tightened: chmod follows the link,
# and an installer silently changing permissions outside its own tree is not
# acceptable however well meant.
FAKEHOME4="$WORK/home4"
mkdir -p "$FAKEHOME4/.config/ship-feature" "$WORK/shared-plans"
chmod 775 "$WORK/shared-plans"
ln -s "$WORK/shared-plans" "$FAKEHOME4/.config/ship-feature/plans"
(cd "$HERE/.." && HOME="$FAKEHOME4" bash install.sh >/dev/null 2>&1)
check "install.sh leaves a symlinked plans target alone" "$(dir_mode "$WORK/shared-plans")" "drwxrwxr-x"
(cd "$HERE/.." && HOME="$FAKEHOME" bash install.sh >/dev/null 2>&1)
# grep -c prints "0" and exits 1 on no match; capture stdout, don't append via `|| echo 0`.
n=$(grep -cF '# >>> ship-feature >>>' "$FAKEHOME/.codex/AGENTS.md" 2>/dev/null)
[ -n "$n" ] || n=0
check "install.sh is idempotent (exactly one Codex block)" "$n" 1
# The skill is a linked DIRECTORY. Codex skips a SKILL.md that is a symlink to a file, so the old
# layout (a real directory holding a SKILL.md link) hid the skill from Codex alone.
_sk="$FAKEHOME/.agents/skills/ship-feature"
check "the skill is a linked directory with a regular SKILL.md (Codex skips a linked file)" \
  "$([ -L "$_sk" ] && [ -f "$_sk/SKILL.md" ] && [ ! -L "$_sk/SKILL.md" ] && echo yes || echo no)" yes
# FAKEHOME has had three installs by now: a reinstall replaces the link, and leaves no backup that
# every harness would load as a second "ship-feature".
check "reinstalls leave exactly one ship-feature in the skills directory" \
  "$(ls -A "$FAKEHOME/.agents/skills" | tr '\n' ' ')" "ship-feature "
# Cursor always gets the skill, as it always gets the Cursor rule.
check "install.sh links the skill for Cursor" \
  "$([ -f "$FAKEHOME/.cursor/skills/ship-feature/SKILL.md" ] && echo yes || echo no)" yes
# Antigravity and Junie get a link where they are installed, and nothing where they are not: the
# installer must not create config for a tool nobody uses.
FAKEHOME5="$WORK/home5"
mkdir -p "$FAKEHOME5/.gemini/config" "$FAKEHOME5/.gemini/antigravity-cli" "$FAKEHOME5/.junie"
(cd "$HERE/.." && HOME="$FAKEHOME5" bash install.sh >/dev/null 2>&1)
check "install.sh links the skill for Antigravity and Junie when they are installed" \
  "$(for _h in .gemini/config .junie; do [ -f "$FAKEHOME5/$_h/skills/ship-feature/SKILL.md" ] && printf y || printf n; done)" yy
# Antigravity keeps its state in ~/.gemini/antigravity-cli, but does not read skills there
# (measured with `agy -p`); the link that went there loaded nothing.
check "install.sh puts no skill in ~/.gemini/antigravity-cli, which Antigravity does not read" \
  "$([ -e "$FAKEHOME5/.gemini/antigravity-cli/skills" ] && echo linked || echo none)" none
check "install.sh creates no skill home for a harness that is not installed" \
  "$({ [ -e "$FAKEHOME/.junie" ] || [ -e "$FAKEHOME/.gemini" ]; } && echo created || echo none)" none
# Migration from the old layout, WITHOUT a backup: a backup would sit in the skills directory, and
# every harness would load it as a second "ship-feature".
FAKEHOME6="$WORK/home6"
mkdir -p "$FAKEHOME6/.agents/skills/ship-feature"
ln -s "$(cd "$HERE/.." && pwd)/adapters/skill/SKILL.md" "$FAKEHOME6/.agents/skills/ship-feature/SKILL.md"
(cd "$HERE/.." && HOME="$FAKEHOME6" bash install.sh >/dev/null 2>&1)
_sk="$FAKEHOME6/.agents/skills/ship-feature"
check "install.sh moves the old skill layout to a linked directory" \
  "$([ -L "$_sk" ] && [ -f "$_sk/SKILL.md" ] && [ ! -L "$_sk/SKILL.md" ] && echo yes || echo no)" yes
check "the move leaves no second ship-feature in the skills directory" \
  "$(ls -A "$FAKEHOME6/.agents/skills" | tr '\n' ' ')" "ship-feature "

# The two messages that steer a user away from the volatile path — run for real
# against a stubbed reviewer, not grepped out of the source. A source match can
# pass while the line is unreachable, or while the path it prints is wrong; this
# asserts the message a user actually sees AND that the directory in it follows
# SHIP_FEATURE_CONFIG rather than being hard-coded to $HOME.
printf '#!/usr/bin/env bash\ncat >/dev/null 2>&1\necho "stub review"\n' >"$BIN/codex"
chmod +x "$BIN/codex"
# Its own config dir: the shared $CFGDIR is created further down this file, and
# depending on it would tie these assertions to the order of unrelated blocks.
PLANCFG="$WORK/plancfg"
mkdir -p "$PLANCFG"
printf 'SHIP_FEATURE_REVIEWERS=codex\n' >"$PLANCFG/config"
# The plans directory is overridden EXPLICITLY. Deriving it from
# SHIP_FEATURE_CONFIG looked tidier and was wrong: that variable is routinely
# `/dev/null` to mean "no config", which would put plans in `/dev`.
PLANDIR="$WORK/plancfg/plans"
PLANWORK="$WORK/planmsg"
mkdir -p "$PLANWORK"
printf 'a plan\n' >"$PLANWORK/plan.md"
err=$(cd "$PLANWORK" && PATH="$BIN:$PATH" SHIP_FEATURE_CONFIG="$PLANCFG/config" SHIP_FEATURE_PLANS_DIR="$PLANDIR" \
  bash "$CLI" plan-review --reviewers codex 2>&1 >/dev/null)
case "$err" in
  *"keep plans in $PLANDIR"*)
    echo "  ok   [-] reading ./plan.md warns, naming the configured plans directory"
    PASS=$((PASS + 1))
    ;;
  *)
    echo "  FAIL ./plan.md warning missing or names the wrong directory: $err"
    FAIL=$((FAIL + 1))
    ;;
esac
PLANEMPTY="$WORK/planempty"
mkdir -p "$PLANEMPTY"
err=$(cd "$PLANEMPTY" && PATH="$BIN:$PATH" SHIP_FEATURE_CONFIG="$PLANCFG/config" SHIP_FEATURE_PLANS_DIR="$PLANDIR" \
  bash "$CLI" plan-review --reviewers codex </dev/null 2>&1 >/dev/null)
case "$err" in
  *"no plan given"*"$PLANDIR"*)
    echo "  ok   [-] the no-plan error names the configured plans directory"
    PASS=$((PASS + 1))
    ;;
  *)
    echo "  FAIL no-plan error missing or names the wrong directory: $err"
    FAIL=$((FAIL + 1))
    ;;
esac
# Upgrade-safe: an existing install that pulls the new workflow has no plans
# directory until install.sh runs again, and the first plan write would fail.
# The CLI creates it on demand.
rmdir "$PLANDIR" 2>/dev/null
(cd "$PLANEMPTY" && PATH="$BIN:$PATH" SHIP_FEATURE_CONFIG="$PLANCFG/config" SHIP_FEATURE_PLANS_DIR="$PLANDIR" \
  bash "$CLI" plan-review --reviewers codex </dev/null >/dev/null 2>&1)
check "the CLI creates the plans directory on demand" "$([ -d "$PLANDIR" ] && echo yes || echo no)" yes
check "and creates it owner-only" "$(dir_mode "$PLANDIR")" "drwx------"
rm -f "$BIN/codex"
# The old wording gone, not merely the new wording present: an added line and a
# surviving one look identical to a grep for the new text, and very different to
# somebody reading the error.
if grep -q 'create a non-empty ./plan.md' "$CLI"; then
  echo "  FAIL bin/ship-feature still tells users to create ./plan.md"
  FAIL=$((FAIL + 1))
else
  echo "  ok   [-] bin/ship-feature no longer tells users to create ./plan.md"
  PASS=$((PASS + 1))
fi

# --- generic scanner: proves it catches each claimed category ----------------
bash "$HERE/../scripts/scan-generic.sh" "$HERE/fixtures/leaky.sample" >/dev/null 2>&1
check "generic scan flags the leaky fixture (email + home path)" $? 1
echo "just some ordinary text" >"$WORK/clean.txt"
bash "$HERE/../scripts/scan-generic.sh" "$WORK/clean.txt" >/dev/null 2>&1
check "generic scan passes a clean file" $? 0
printf 'contact us at hello@example.com\n' >"$WORK/dummy.txt"
bash "$HERE/../scripts/scan-generic.sh" "$WORK/dummy.txt" >/dev/null 2>&1
check "generic scan ignores reserved example.com email" $? 0
printf 'a URL with userinfo: https://user:pass@ghe.example.com/owner/repo\n' >"$WORK/dummy-sub.txt"
bash "$HERE/../scripts/scan-generic.sh" "$WORK/dummy-sub.txt" >/dev/null 2>&1
check "generic scan ignores a reserved subdomain of example.com" $? 0
# The look-alikes are built at run time ('@' passed through %s), so the repo-wide scan of this
# file does not flag them.
printf 'pass%sghe.example.com.evil.io\n' @ >"$WORK/dummy-near.txt"
bash "$HERE/../scripts/scan-generic.sh" "$WORK/dummy-near.txt" >/dev/null 2>&1
check "generic scan flags a domain that only starts like a subdomain of example.com" $? 1
printf 'real.person%snotexample.com\n' @ >"$WORK/dummy-near2.txt"
bash "$HERE/../scripts/scan-generic.sh" "$WORK/dummy-near2.txt" >/dev/null 2>&1
check "generic scan flags a domain that only ends in example.com" $? 1

# --- cmd_relay injects SHIP_FEATURE_REVIEWERS from config (and honors explicit override) ------
printf '#!/usr/bin/env bash\necho "ARGS: $*"\nexit 0\n' >"$BIN/pr-review-relay"
chmod +x "$BIN/pr-review-relay"
CFGDIR="$WORK/cfg"
mkdir -p "$CFGDIR"
printf 'SHIP_FEATURE_REVIEWERS=codex,cursor\n' >"$CFGDIR/config"
out=$(PATH="$BIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config" bash "$CLI" relay --author claude 2>/dev/null)
printf '%s' "$out" | grep -q -- "--reviewers codex,cursor" && {
  echo "  ok   [-] relay injects configured reviewers when omitted"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL relay did not inject configured reviewers"
  FAIL=$((FAIL + 1))
}
out=$(PATH="$BIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config" bash "$CLI" relay --author claude --reviewers x,y 2>/dev/null)
if printf '%s' "$out" | grep -q -- "--reviewers x,y" && ! printf '%s' "$out" | grep -q "codex,cursor"; then
  echo "  ok   [-] explicit --reviewers overrides config"
  PASS=$((PASS + 1))
else
  echo "  FAIL explicit --reviewers did not override config"
  FAIL=$((FAIL + 1))
fi
# the --reviewers= form is rejected with a clear error (relay doesn't accept it)
(PATH="$BIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config" bash "$CLI" relay --author claude --reviewers=x >/dev/null 2>&1)
check "relay rejects the --reviewers= form" $? 1
# an explicitly empty env value disables config injection (env-defined wins)
out=$(PATH="$BIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config" SHIP_FEATURE_REVIEWERS='' bash "$CLI" relay --author claude 2>/dev/null)
if ! printf '%s' "$out" | grep -q -- "--reviewers"; then
  echo "  ok   [-] empty SHIP_FEATURE_REVIEWERS env disables injection"
  PASS=$((PASS + 1))
else
  echo "  FAIL empty env did not disable injection"
  FAIL=$((FAIL + 1))
fi

# --- install.sh --copy produces a real WORKFLOW.md (not a symlink) ------------
FAKEHOME2="$WORK/home2"
mkdir -p "$FAKEHOME2"
(cd "$HERE/.." && HOME="$FAKEHOME2" bash install.sh --copy >/dev/null 2>&1)
check "install.sh --copy succeeds" $? 0
if [ -f "$FAKEHOME2/.config/ship-feature/WORKFLOW.md" ] && [ ! -L "$FAKEHOME2/.config/ship-feature/WORKFLOW.md" ]; then
  echo "  ok   [-] --copy installs a real WORKFLOW.md (not a symlink)"
  PASS=$((PASS + 1))
else
  echo "  FAIL --copy did not produce a real file"
  FAIL=$((FAIL + 1))
fi

# --- scan catches a deny-listed term in a ref (branch) name ------------------
SREPO5="$WORK/scanrepo5"
git init -q "$SREPO5"
(cd "$SREPO5" && git commit -q --allow-empty -m init && git branch "SECRET-SLUG-XYZ-branch" && bash "$SCAN" "$WORK/deny.txt" >/dev/null 2>&1)
check "scan catches a deny-listed term in a ref name" $? 1

# --- scan-generic scans a SYMLINK's target string (committed data), not the pointee ----------
# Build the target from a var so this test file doesn't itself contain a literal home path (which the
# repo-wide scan would flag).
lu="privuser"
ln -s "/home/$lu/secret" "$WORK/leaky-link" 2>/dev/null
bash "$HERE/../scripts/scan-generic.sh" "$WORK/leaky-link" >/dev/null 2>&1
check "generic scan flags a home path in a symlink target" $? 1

# --- scan-personal-data catches a term inside a BINARY blob (no -I) ---------------------------
SREPO6="$WORK/scanrepo6"
git init -q "$SREPO6"
(cd "$SREPO6" && printf 'SECRET-SLUG-XYZ\000\001\002binary' >bin.dat && git add bin.dat && git commit -q -m "add binary" && bash "$SCAN" "$WORK/deny.txt" >/dev/null 2>&1)
check "scan catches a deny-listed term inside a binary blob" $? 1

# --- load_config strips an inline comment from a value ---------------------------------------
printf 'SHIP_FEATURE_REVIEWERS=codex,cursor  # my quorum\n' >"$CFGDIR/config2"
out=$(PATH="$BIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config2" bash "$CLI" relay --author claude 2>/dev/null)
if printf '%s' "$out" | grep -q -- "--reviewers codex,cursor" && ! printf '%s' "$out" | grep -q "quorum"; then
  echo "  ok   [-] config value inline comment is stripped"
  PASS=$((PASS + 1))
else
  echo "  FAIL inline comment not stripped"
  FAIL=$((FAIL + 1))
fi

# --- preflight fails on a DIVERGED branch (own commit + default advanced) ---------------------
(cd "$MAIN/.claude/worktrees/feat" && git commit -q --allow-empty -m "feature work" && bash "$CLI" preflight >/dev/null 2>&1)
check "preflight fails on a diverged branch" $? 1

# --- plan-review: fan a plan out to a panel of stubbed reviewers -------------
# Stub the reviewer CLIs so no network/real agent is touched. Each echoes a marker
# plus its argv (so the argv/read-only contract can be asserted). cursor's binary is
# `cursor-agent`; the rest match their reviewer name.
PBIN="$WORK/pbin"
mkdir -p "$PBIN"
# The stub also surfaces the OPENCODE_CONFIG_CONTENT env (how glm pins read-only — the
# highest-precedence config layer), the OPENCODE_CONFIG env (must be empty — glm unsets it),
# and CWD (the checkout normally; an isolated dir only when the checkout carries its own opencode
# config). Harmless for reviewers that don't set them.
make_reviewer() {
  # $1 = review tag, $2 = exit code, $3 = binary name on PATH
  cat >"$PBIN/$3" <<STUB
#!/usr/bin/env bash
# glm probes \`opencode --help\` first, to tell v1 (--pure) from v2 (--standalone). OC_HELP picks the
# answer: unset = v1, v2 = @opencode/cli 2.x, nopure = a CLI older than both.
if [ "\$(basename "\$0")" = opencode ] && [ "\${1:-}" = --version ]; then echo 1.2.27; exit 0; fi
if [ "\$(basename "\$0")" = opencode ] && [ "\${1:-}" = --help ]; then
  case "\${OC_HELP:-}" in
    v2) printf 'FLAGS\n  --standalone            Run with a private server instead of the background service\n' ;;
    nopure) printf 'Options:\n      --print-logs    print logs to stderr\n' ;;
    *) printf 'Options:\n      --pure          run without external plugins\n' ;;
  esac
  exit 0
fi
_cd_empty=no
[ -n "\${OPENCODE_CONFIG_DIR:-}" ] && [ -d "\$OPENCODE_CONFIG_DIR" ] && [ -z "\$(ls -A "\$OPENCODE_CONFIG_DIR")" ] && _cd_empty=yes
echo "REVIEW-$1 CFGDIR_EMPTY=[\$_cd_empty] PROJCFG=[\${OPENCODE_DISABLE_PROJECT_CONFIG:-}] argv=[\$*] OPENCODE_CONFIG_CONTENT=[\${OPENCODE_CONFIG_CONTENT:-}] OPENCODE_CONFIG=[\${OPENCODE_CONFIG:-}] OPENCODE_CONFIG_DIR=[\${OPENCODE_CONFIG_DIR:-}] CWD=[\${PWD}]"
_args=("\$@")
for ((_i=0; _i<\${#_args[@]}; _i++)); do
  if [ "\${_args[\$_i]}" = "--prompt-file" ]; then
    _pf="\${_args[\$((_i+1))]}"
    if [ -n "\$_pf" ] && [ -f "\$_pf" ]; then
      echo "PROMPT_BEGIN"
      cat -- "\$_pf"
      echo "PROMPT_END"
    fi
    break
  fi
done
echo "Looks good."
exit ${2:-0}
STUB
  chmod +x "$PBIN/$3"
}
make_reviewer claude 0 claude
make_reviewer codex 0 codex
# glm is invoked through the `opencode` binary (opencode run --agent plan), so the stub
# is named `opencode` but tags its output REVIEW-glm.
make_reviewer glm 0 opencode
make_reviewer cursor 0 cursor-agent
# grok is invoked through the `grok` binary
make_reviewer grok 0 grok
# antigravity/gemini reviewer (the `gemini` CLI). A richer stub than make_reviewer: it also reports
# its CWD and whether the isolated, locked-down `.gemini/settings.json` (write tools excluded + hooks
# off) is present in that CWD — so the read-only isolation contract can be asserted, not just argv.
cat >"$PBIN/gemini" <<'GEMINISTUB'
#!/usr/bin/env bash
# The seat runs `gemini --version` first and refuses to review against a tool registry it
# has not been audited against. STUB_GEMINI_VERSION lets a test drive that gate.
# SCAN the whole argv, not just $1: the probe runs inside the isolation and reaches this stub as
# `-e none --version`, so matching on the first argument alone silently stopped answering.
for a in "$@"; do
  case "$a" in --version|-v)
    # STUB_GEMINI_VERSION_STDERR mimics a CLI that prints its version on stderr: the probe must
    # still see it, or the gate fails closed on a binary that was in fact audited.
    if [ -n "${STUB_GEMINI_VERSION_STDERR:-}" ]; then echo "${STUB_GEMINI_VERSION:-0.26.0}" >&2
    else echo "${STUB_GEMINI_VERSION:-0.26.0}"; fi
    exit 0;; esac
done
# The plan arrives on STDIN; -p carries the prompt. Nothing asserted the body actually got here, so
# a CLI that ignored stdin would have the seat reviewing an empty input with every argv assertion
# still green.
plan_in="$(cat)"
stdinbytes=$(printf '%s' "$plan_in" | wc -c | tr -d '[:space:]')
stdinmagic=no; case "$plan_in" in *MAGICPLANTOKEN*) stdinmagic=yes;; esac
# credwalk=adjacent when the OAuth creds sit in the workspace's own tree, in its immediate parent, or
# in a sibling of the workspace — the specific regression this layout avoids. Be honest about the
# scope: both directories must live under STATUS_DIR so they get cleaned up, so a traversal that
# ignores gemini's workspace confinement altogether reaches them whatever the layout. gemini's
# confinement is the control. This asserts the layout, not a second line of defence.
credwalk=clean
cwparent=$(dirname "$PWD")
if [ -e "$PWD/.gemini/oauth_creds.json" ] || [ -e "$cwparent/.gemini/oauth_creds.json" ] \
   || [ -n "$(ls "$cwparent"/*/.gemini/oauth_creds.json 2>/dev/null)" ]; then credwalk=adjacent; fi
# locked=yes only if the workspace settings allowlist exactly the read-only tools, deny-list ALL of
# today's write tools, disable hooks (hooksConfig-specific), and declare no MCP — structural, not just
# tool-name presence.
locked=no
if [ -f .gemini/settings.json ]; then
  ok=yes
  # tools.core must be an ALLOWLIST of exactly the read-only tools (fail-closed to any new/renamed
  # write tool) — assert the exact array, so a stray write tool added to core fails the test.
  grep -q '"core":\["read_file","read_many_files","glob","search_file_content","list_directory"\]' .gemini/settings.json || ok=no
  grep -q '"allowed"' .gemini/settings.json && ok=no        # a locked file must NOT re-allow anything
  # EVERY write tool named in GEMINI_LOCKED_SETTINGS must sit inside the "exclude" array (defence-in-depth).
  for tool in run_shell_command replace write_file web_fetch google_web_search save_memory write_todos delegate_to_agent; do
    grep -q "\"exclude\":\[[^]]*\"$tool\"" .gemini/settings.json || ok=no
  done
  # Match hooksConfig specifically, so a stray "enabled":false elsewhere can't satisfy it.
  grep -q '"hooksConfig":{"enabled":false}' .gemini/settings.json || ok=no
  grep -q '"mcpServers":{}' .gemini/settings.json || ok=no
  locked=$ok
fi
# homeiso=yes when GEMINI_CLI_HOME is set to a SEPARATE dir from the workspace (CWD), so the copied
# OAuth creds live outside the workspace and the allowlisted read_file can't reach them.
homeiso=no; [ -n "$GEMINI_CLI_HOME" ] && [ "$GEMINI_CLI_HOME" != "$PWD" ] && homeiso=yes
# credsafe=yes when no OAuth credential file sits in the workspace (CWD) tree.
credsafe=yes; { [ -e .gemini/oauth_creds.json ] || [ -e .gemini/google_accounts.json ]; } && credsafe=no
# envstop=yes when a controlled .gemini/.env sits in the workspace, halting gemini's ancestor .env walk
# (so a hostile /tmp/.env can't inject CODE_ASSIST_ENDPOINT / a base-URL override).
envstop=no; [ -f .gemini/.env ] && envstop=yes
# sysiso=yes when the SYSTEM + SYSTEM_DEFAULTS scopes are redirected under GEMINI_CLI_HOME (so
# /etc/gemini-cli or an inherited hostile GEMINI_CLI_SYSTEM_SETTINGS_PATH can't apply).
sysiso=no
case "$GEMINI_CLI_SYSTEM_SETTINGS_PATH" in "$GEMINI_CLI_HOME"/*)
  case "$GEMINI_CLI_SYSTEM_DEFAULTS_PATH" in "$GEMINI_CLI_HOME"/*) sysiso=yes;; esac;; esac
# Isolation facts go on their OWN first line: the prompt (in argv) contains newlines, so anything
# after argv=[$*] would land on an unrelated line and a single-line grep would miss it.
# gca=... whether the run opted into Google Code Assist, i.e. took the OAuth path.
gca=${GOOGLE_GENAI_USE_GCA-UNSET}
# homecreds/credmode: the OAuth creds the seat copies into GEMINI_CLI_HOME. That copy is the one
# part of this isolation that handles a real secret, so report whether it happened and with what
# mode — a plain `cp -p` would carry a world-readable source mode straight into the sandbox.
homecreds=no; credmode=none
if [ -f "$GEMINI_CLI_HOME/.gemini/oauth_creds.json" ]; then
  homecreds=yes
  credmode=$(ls -l "$GEMINI_CLI_HOME/.gemini/oauth_creds.json" | cut -c1-10)
fi
# lockedsame=yes when the USER scope reads the SAME locked settings as the workspace scope. A
# workspace-only lock would leave the user scope free to re-enable a write tool.
lockedsame=no
cmp -s "$GEMINI_CLI_HOME/.gemini/settings.json" .gemini/settings.json && lockedsame=yes
echo "GEMINI-ISO cwd=$PWD locked=$locked homeiso=$homeiso credsafe=$credsafe sysiso=$sysiso xdg=${XDG_CONFIG_HOME-UNSET} envstop=$envstop gca=$gca homecreds=$homecreds credmode=$credmode lockedsame=$lockedsame stdinbytes=$stdinbytes stdinmagic=$stdinmagic cae=${CODE_ASSIST_ENDPOINT-UNSET} gburl=${GEMINI_BASE_URL-UNSET} ggburl=${GOOGLE_GEMINI_BASE_URL-UNSET} credwalk=$credwalk"
echo "REVIEW-gemini argv=[$*]"
echo "Looks good."
exit 0
GEMINISTUB
chmod +x "$PBIN/gemini"

# clean run with an explicit panel → exit 0, both reviews on stdout
out=$(printf 'Step 1: X\nStep 2: Y\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers codex,glm 2>/dev/null)
rc=$?
check "plan-review clean run exits 0" "$rc" 0
printf '%s' "$out" | grep -q "REVIEW-codex" && printf '%s' "$out" | grep -q "REVIEW-glm" &&
  {
    echo "  ok   [-] plan-review prints each reviewer's output"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL plan-review dropped a reviewer's output"
    FAIL=$((FAIL + 1))
  }

# read-only argv contract: EVERY supported reviewer must carry its read-only flag, so the
# "nothing is written" guarantee is real. A dropped flag here is a security regression.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude,codex,cursor,glm 2>/dev/null)
# claude's own line must carry BOTH --permission-mode plan AND --safe-mode (safe-mode
# stops checkout hooks/plugins/MCP from loading). Grep claude's line specifically so
# another reviewer's flags can't satisfy this by accident.
cl=$(printf '%s' "$out" | grep 'REVIEW-claude')
printf '%s' "$cl" | grep -q -- "--permission-mode plan" && printf '%s' "$cl" | grep -q -- "--safe-mode" && {
  echo "  ok   [-] claude runs read-only (--permission-mode plan --safe-mode)"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL claude not fully read-only (plan + safe-mode) in plan-review"
  FAIL=$((FAIL + 1))
}
printf '%s' "$out" | grep 'REVIEW-codex' | grep -q -- "--sandbox read-only" && {
  echo "  ok   [-] codex runs read-only (--sandbox read-only)"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL codex not read-only in plan-review"
  FAIL=$((FAIL + 1))
}
# Grep cursor's own line, like claude's check above. Whole-stdout matching is satisfied by ANY
# reviewer's line carrying the flag, so it would keep passing if cursor silently lost it while a
# future reviewer happened to use the same one. Today's stubs echo argv, not stdin, so the plan
# text itself cannot trigger it — the point is not to depend on that staying true.
cu=$(printf '%s' "$out" | grep 'REVIEW-cursor')
printf '%s' "$cu" | grep -q -- "--mode=ask" && {
  echo "  ok   [-] cursor runs in ask (Q&A) mode"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL cursor not in ask mode"
  FAIL=$((FAIL + 1))
}
# cursor-agent's own default model is "Auto", which routes to the frontier models and may pick a
# CLAUDE one — so the agent that usually wrote the plan would be grading it while the panel reports
# an independent "Cursor" reviewer. The pin is what keeps the panel honest, so it is asserted.
printf '%s' "$cu" | grep -q -- "--model composer-2.5" && {
  echo "  ok   [-] cursor model is pinned (not Auto)"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL cursor model not pinned: $cu"
  FAIL=$((FAIL + 1))
}
# glm's read-only guarantee: OPENCODE_CONFIG_CONTENT (highest-precedence config layer)
# DENIES `edit` AND `bash` (removing both tools — no write, no shell), OPENCODE_CONFIG is
# unset (empty), it runs --pure, and never the all-allow build agent. The `plan` agent alone
# denies edit but leaves bash allowed — not enough — so the CONTENT denial is what makes it
# real. Assert all of it on glm's line.
#
# The cwd is asserted by the PAIR below, not by one line: glm READS THE CHECKOUT, because a
# reviewer that cannot open the code can only review prose — it used to run in an empty dir and
# returned empty reviews twice on 2026-08-14, having spent its turn looking for the repo. It
# falls back to an isolated dir only when the checkout carries its own opencode config, which is
# the one thing the permission denial above cannot pin down.
km=$(printf '%s' "$out" | grep 'REVIEW-glm')
printf '%s' "$km" | grep -q -- "--agent plan" && printf '%s' "$km" | grep -q -- "glm-5.3" && {
  echo "  ok   [-] glm runs opencode plan agent (glm-5.3)"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL glm not on opencode plan agent"
  FAIL=$((FAIL + 1))
}
printf '%s' "$km" | grep -q -- "--pure" && {
  echo "  ok   [-] glm runs --pure (no checkout plugins)"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL glm missing --pure"
  FAIL=$((FAIL + 1))
}
printf '%s' "$km" | grep -q 'OPENCODE_CONFIG_CONTENT=\[.*"edit":"deny".*"bash":"deny".*\]' && {
  echo "  ok   [-] glm read-only via OPENCODE_CONFIG_CONTENT (edit+bash denied)"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL glm not hard read-only (OPENCODE_CONFIG_CONTENT must deny edit AND bash)"
  FAIL=$((FAIL + 1))
}
# The other denials are load-bearing now that the seat reads a tree, and each is one JSON edit
# away from being dropped in silence:
#   external_directory   a rejected external read KILLS the run — this is what produced the
#                        empty reviews the checkout change exists to fix
#   task                 the plan agent fans out to explore subagents and spends the whole
#                        timeout doing it
#   webfetch, websearch  read-the-tree plus any network reach is an exfiltration path; these
#                        repos carry committed keystores, and a search query carries content
#                        outward exactly as well as a URL
#   lsp                  a language server is a process the PROJECT starts and configures —
#                        denying bash while leaving this on still lets the reviewed tree run code
for k in external_directory task webfetch websearch lsp; do
  printf '%s' "$km" | grep -q "\"$k\":\"deny\"" &&
    {
      echo "  ok   [-] glm denies $k"
      PASS=$((PASS + 1))
    } ||
    {
      echo "  FAIL glm does not deny $k"
      FAIL=$((FAIL + 1))
    }
done
printf '%s' "$km" | grep -q 'OPENCODE_CONFIG=\[\]' && {
  echo "  ok   [-] glm unsets inherited OPENCODE_CONFIG"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL glm left OPENCODE_CONFIG set (could weaken perms)"
  FAIL=$((FAIL + 1))
}
# OPENCODE_CONFIG_DIR is the other half of "unsets any inherited OPENCODE_CONFIG*", and it was
# only the comment that said so: the code unset one variable. A config DIR carries agents, MCP
# servers and model settings just as a config file does.
printf '%s' "$km" | grep -q 'OPENCODE_CONFIG_DIR=\[\]' && {
  echo "  ok   [-] glm unsets inherited OPENCODE_CONFIG_DIR"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL glm left OPENCODE_CONFIG_DIR set (agents/MCP could load)"
  FAIL=$((FAIL + 1))
}
kcwd=$(printf '%s' "$km" | sed -n 's/.*CWD=\[\([^]]*\)\].*/\1/p')
case "$kcwd" in "")
  echo "  FAIL glm cwd not captured"
  FAIL=$((FAIL + 1))
  ;;
"$PWD")
  echo "  ok   [-] glm reads the checkout"
  PASS=$((PASS + 1))
  ;;
*)
  echo "  FAIL glm ran outside the checkout ($kcwd) — it can only review prose from there"
  FAIL=$((FAIL + 1))
  ;;
esac
printf '%s' "$km" | grep -q -- "--agent build" && {
  echo "  FAIL glm uses the all-allow build agent"
  FAIL=$((FAIL + 1))
} || {
  echo "  ok   [-] glm never uses the all-allow build agent"
  PASS=$((PASS + 1))
}
# --- glm on OpenCode v2 (@opencode/cli 2.x): no --pure, so `run --standalone` (a private server;
# the shared background service ignores this env) with OPENCODE_CONFIG_DIR at an empty dir (what
# keeps the user's global plugins out). Same policy, same agent, same model, same cwd as v1.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" OC_HELP=v2 bash "$CLI" plan-review --reviewers glm 2>/dev/null)
km2=$(printf '%s' "$out" | grep 'REVIEW-glm')
printf '%s' "$km2" | grep -q -- "argv=\[run --standalone --agent plan -m " && ! printf '%s' "$km2" | grep -q -- "--pure" && {
  echo "  ok   [-] glm on v2 runs --standalone with the plan agent and no --pure"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL glm on v2 argv wrong: $km2"
  FAIL=$((FAIL + 1))
}
printf '%s' "$km2" | grep -q 'CFGDIR_EMPTY=\[yes\] PROJCFG=\[1\]' && {
  echo "  ok   [-] glm on v2 points OPENCODE_CONFIG_DIR at an empty dir and skips project config (no plugins)"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL glm on v2 has no empty config dir: $km2"
  FAIL=$((FAIL + 1))
}
printf '%s' "$km2" | grep -q 'OPENCODE_CONFIG_CONTENT=\[.*"edit":"deny".*"bash":"deny".*\]' &&
  printf '%s' "$km2" | grep -q "CWD=\[$PWD\]" && {
  echo "  ok   [-] glm on v2 keeps the read-only policy and reads the checkout"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL glm on v2 lost the policy or the cwd: $km2"
  FAIL=$((FAIL + 1))
}
# A CLI with neither flag fails the seat with the reason, and the review never starts.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" OC_HELP=nopure bash "$CLI" plan-review --reviewers glm 2>&1)
printf '%s' "$out" | grep -q 'has neither --pure (v1) nor --standalone (v2)' && ! printf '%s' "$out" | grep -q 'REVIEW-glm' && {
  echo "  ok   [-] glm on an opencode with neither flag fails with the reason and runs no review"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL glm on an old opencode: $(printf '%s' "$out" | grep -i -m3 'glm\|opencode')"
  FAIL=$((FAIL + 1))
}
unset km2

# The other half of the cwd contract: a checkout that ships its OWN opencode config must push
# the seat back into an isolated dir, and must SAY so. Permissions are pinned by the deny above
# and cannot be overridden, but a repo config also carries MCP servers, agents and model
# routing, and no permission key covers those — so the tree being reviewed would otherwise get
# to reconfigure the reviewer reading it.
ocfg_repo="$WORK/ocfg"
mkdir -p "$ocfg_repo"
(cd "$ocfg_repo" && git init -q . && printf '{}\n' >opencode.json)
ocfg_out=$(cd "$ocfg_repo" && printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers glm 2>/dev/null)
ocfg_cwd=$(printf '%s' "$ocfg_out" | grep 'REVIEW-glm' | sed -n 's/.*CWD=\[\([^]]*\)\].*/\1/p')
case "$ocfg_cwd" in
  "$ocfg_repo" | "$ocfg_repo"/*)
    echo "  FAIL glm read a checkout carrying its own opencode.json ($ocfg_cwd)"
    FAIL=$((FAIL + 1))
    ;;
  "")
    echo "  FAIL glm cwd not captured in the repo-config case"
    FAIL=$((FAIL + 1))
    ;;
  *)
    echo "  ok   [-] glm falls back to an isolated cwd when the checkout has an opencode config"
    PASS=$((PASS + 1))
    ;;
esac
printf '%s' "$ocfg_out" | grep -q 'opencode.json would configure the reviewer' &&
  {
    echo "  ok   [-] glm announces the degraded review"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL glm degraded silently — a prose-only review must say so"
    FAIL=$((FAIL + 1))
  }
# From a SUBDIRECTORY the config is still found: opencode discovers config by walking up, so a
# check that only looked at $PWD would miss it and hand the reviewer a config we refused. This
# is the case the walk-up exists for, and it is also this workflow's normal shape — plan-review
# usually runs inside .claude/worktrees/<name>.
mkdir -p "$ocfg_repo/sub/deeper"
sub_out=$(cd "$ocfg_repo/sub/deeper" && printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers glm 2>/dev/null)
sub_cwd=$(printf '%s' "$sub_out" | grep 'REVIEW-glm' | sed -n 's/.*CWD=\[\([^]]*\)\].*/\1/p')
case "$sub_cwd" in
  "$ocfg_repo" | "$ocfg_repo"/*)
    echo "  FAIL glm missed an opencode config in a parent directory ($sub_cwd)"
    FAIL=$((FAIL + 1))
    ;;
  "")
    echo "  FAIL glm cwd not captured in the subdirectory case"
    FAIL=$((FAIL + 1))
    ;;
  *)
    echo "  ok   [-] glm finds an opencode config above the cwd"
    PASS=$((PASS + 1))
    ;;
esac
printf '%s' "$sub_out" | grep -q 'would configure the reviewer' &&
  {
    echo "  ok   [-] glm announces the degraded review from a subdirectory too"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL glm degraded silently from a subdirectory"
    FAIL=$((FAIL + 1))
  }

# All THREE config names trigger the fallback. The function checks opencode.json, opencode.jsonc
# and .opencode; only the first was exercised, so a typo in either of the others was free.
for cfgname in opencode.jsonc .opencode; do
  rm -rf "${ocfg_repo:?}/opencode.json" "${ocfg_repo:?}/opencode.jsonc" "${ocfg_repo:?}/.opencode"
  if [ "$cfgname" = .opencode ]; then mkdir -p "$ocfg_repo/.opencode"; else printf '{}\n' >"$ocfg_repo/$cfgname"; fi
  n_cwd=$(cd "$ocfg_repo" && printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers glm 2>/dev/null |
    grep 'REVIEW-glm' | sed -n 's/.*CWD=\[\([^]]*\)\].*/\1/p')
  case "$n_cwd" in
    "$ocfg_repo" | "$ocfg_repo"/* | "")
      echo "  FAIL $cfgname did not trigger the isolated fallback ($n_cwd)"
      FAIL=$((FAIL + 1))
      ;;
    *)
      echo "  ok   [-] $cfgname triggers the isolated fallback"
      PASS=$((PASS + 1))
      ;;
  esac
done
rm -rf "${ocfg_repo:?}/.opencode"
printf '{}\n' >"$ocfg_repo/opencode.json"

# A LINKED WORKTREE at <repo>/.claude/worktrees/<name> is its own git toplevel, so a walk that
# stops at the toplevel never sees the main checkout's config — while opencode, running in the
# worktree, is inside that repo. This is the exact layout ship-feature creates, so it is checked
# explicitly rather than by walking past the root (which would degrade reviews over configs
# opencode never loads).
wt_main="$WORK/wtmain"
mkdir -p "$wt_main"
(cd "$wt_main" && git init -q . && git commit -q --allow-empty -m init && printf '{}\n' >opencode.json &&
  git worktree add -q ".claude/worktrees/w" -b wtprobe >/dev/null 2>&1)
wt_cwd=$(cd "$wt_main/.claude/worktrees/w" && printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers glm 2>/dev/null |
  grep 'REVIEW-glm' | sed -n 's/.*CWD=\[\([^]]*\)\].*/\1/p')
case "$wt_cwd" in
  "$wt_main"/* | "")
    echo "  FAIL glm missed the MAIN repo's opencode.json from a linked worktree ($wt_cwd)"
    FAIL=$((FAIL + 1))
    ;;
  *)
    echo "  ok   [-] glm finds the main checkout's opencode config from a linked worktree"
    PASS=$((PASS + 1))
    ;;
esac

# The $HOME bound, which the code comment calls load-bearing: `~/.opencode` exists on any
# machine that has run opencode, so a walk that does not stop at $HOME matches it for EVERY
# checkout under $HOME and degrades every review to prose. Point HOME at a temp dir that has
# one, put the checkout beneath it, and the seat must still read the checkout.
home_probe="$WORK/homeprobe"
mkdir -p "$home_probe/.opencode" "$home_probe/repo"
(cd "$home_probe/repo" && git init -q .)
hp_cwd=$(cd "$home_probe/repo" && printf 'plan\n' | PATH="$PBIN:$PATH" HOME="$home_probe" bash "$CLI" plan-review --reviewers glm 2>/dev/null |
  grep 'REVIEW-glm' | sed -n 's/.*CWD=\[\([^]]*\)\].*/\1/p')
case "$hp_cwd" in
  "$home_probe/repo")
    echo "  ok   [-] glm ignores ~/.opencode and still reads the checkout"
    PASS=$((PASS + 1))
    ;;
  "")
    echo "  FAIL glm cwd not captured in the HOME-bound case"
    FAIL=$((FAIL + 1))
    ;;
  *)
    echo "  FAIL a config at \$HOME degraded the review ($hp_cwd) — every checkout under \$HOME would go prose-only"
    FAIL=$((FAIL + 1))
    ;;
esac

# FAIL CLOSED: config present and no isolated dir available → the seat is SKIPPED, never run in
# the checkout whose config we just refused. The old code left ro_cwd empty and fell through to
# $PWD while still announcing an isolated review — a reviewer that lies about what it read.
mkfail="$WORK/mkfail"
mkdir -p "$mkfail"
# The stub lets the FIRST mktemp through: that one creates STATUS_DIR, and failing it aborts
# plan-review before the seat is ever reached — the test would then pass without exercising the
# branch at all. Everything after it fails, which is the seat's own isolated dir.
cat >"$mkfail/mktemp" <<STUB
#!/usr/bin/env bash
if [ ! -e "$mkfail/used" ]; then : > "$mkfail/used"; exec /usr/bin/mktemp "\$@"; fi
exit 1
STUB
chmod +x "$mkfail/mktemp"
fc_out=$(cd "$ocfg_repo" && printf 'plan\n' | PATH="$mkfail:$PBIN:$PATH" bash "$CLI" plan-review --reviewers glm 2>&1)
if printf '%s' "$fc_out" | grep -q 'REVIEW-glm'; then
  echo "  FAIL the seat ran with no isolated cwd — in the checkout it was supposed to avoid"
  FAIL=$((FAIL + 1))
else
  echo "  ok   [-] glm is skipped rather than run in a checkout it must not read"
  PASS=$((PASS + 1))
fi
printf '%s' "$fc_out" | grep -q 'no isolated cwd could be created' &&
  {
    echo "  ok   [-] the skipped seat says why"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the seat was skipped silently"
    FAIL=$((FAIL + 1))
  }

# --- the config file carries the MODEL PINS too -----------------------------------------------
# The panel used to be described in two places: who sits on it in this file, what they actually
# run in the shell profile. A seat and its model could then drift apart, and a run with no shell
# profile (cron, a fresh machine) silently got the bundled default instead of the pinned model.
printf 'GLM_REVIEW_MODEL=openrouter/z-ai/glm-5.2\n' >"$CFGDIR/config3"
mout=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config3" bash "$CLI" plan-review --reviewers glm 2>/dev/null | grep 'REVIEW-glm')
printf '%s' "$mout" | grep -q -- "-m openrouter/z-ai/glm-5.2" &&
  {
    echo "  ok   [-] the config file pins the glm model"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the config file's model pin was ignored (seat fell back to the bundled default)"
    FAIL=$((FAIL + 1))
  }
# Environment still wins over the file, exactly like the SHIP_FEATURE_* keys.
eout=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config3" GLM_REVIEW_MODEL=openrouter/z-ai/glm-9.9 bash "$CLI" plan-review --reviewers glm 2>/dev/null | grep 'REVIEW-glm')
printf '%s' "$eout" | grep -q -- "-m openrouter/z-ai/glm-9.9" &&
  {
    echo "  ok   [-] the environment still overrides the config file's model pin"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the config file overrode an explicit environment model"
    FAIL=$((FAIL + 1))
  }
# pr-review-relay is a CHILD PROCESS, so its variable has to be EXPORTED, not merely assigned —
# a plain shell variable does not cross that boundary and the relay would keep its own default.
# The stub is swapped for one that echoes its ENVIRONMENT, then RESTORED. Leaving it in place
# would hand every later relay test a stub that prints no argv, and they would pass for the wrong
# reason — a test fixture that quietly breaks its neighbours is worse than the gap it filled.
cp "$BIN/pr-review-relay" "$WORK/relay-stub-backup"
printf '#!/usr/bin/env bash\necho "RELAYENV PR_RELAY_OPENCODE_MODEL=${PR_RELAY_OPENCODE_MODEL:-} CURSOR_REVIEW_MODEL=${CURSOR_REVIEW_MODEL:-}"\nexit 0\n' >"$BIN/pr-review-relay"
chmod +x "$BIN/pr-review-relay"
printf 'PR_RELAY_OPENCODE_MODEL=openrouter/z-ai/glm-5.2\nCURSOR_REVIEW_MODEL=composer-2.5-fast\n' >"$CFGDIR/config4"
rout=$(PATH="$BIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config4" bash "$CLI" relay --author claude 2>/dev/null)
printf '%s' "$rout" | grep -q 'PR_RELAY_OPENCODE_MODEL=openrouter/z-ai/glm-5.2' &&
  {
    echo "  ok   [-] the relay's model pin reaches the child process"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL PR_RELAY_OPENCODE_MODEL did not reach pr-review-relay (not exported?)"
    FAIL=$((FAIL + 1))
  }
# CURSOR_REVIEW_MODEL is the one variable BOTH tools read, which is the whole reason it keeps its
# vendor-shaped name — so it must cross the process boundary too, not just reach plan-review.
printf '%s' "$rout" | grep -q 'CURSOR_REVIEW_MODEL=composer-2.5-fast' &&
  {
    echo "  ok   [-] the shared cursor pin reaches the child process"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL CURSOR_REVIEW_MODEL did not reach pr-review-relay (not exported?)"
    FAIL=$((FAIL + 1))
  }
cp "$WORK/relay-stub-backup" "$BIN/pr-review-relay"
chmod +x "$BIN/pr-review-relay"
# The cursor seat, from the file and with the environment still winning. The grok seat's old key
# in this same file is RECORDED AND IGNORED: the seat is `grok` now and is pinned by MODEL_grok in
# the shared file. Stderr is captured, not discarded — the warning is the behaviour under test.
printf 'CURSOR_REVIEW_MODEL=composer-2.5-fast\nGROK45HIGH_REVIEW_MODEL=grok-9.9\n' >"$CFGDIR/config5"
pout=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config5" bash "$CLI" plan-review --reviewers cursor,grok 2>&1)
printf '%s' "$pout" | grep 'REVIEW-cursor' | grep -q -- "--model composer-2.5-fast" &&
  {
    echo "  ok   [-] the config file pins the cursor model"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the config file's cursor pin was ignored"
    FAIL=$((FAIL + 1))
  }
printf '%s' "$pout" | grep 'REVIEW-grok' | grep -q -- "-m grok-4.6 " &&
  printf '%s' "$pout" | grep -q "GROK45HIGH_REVIEW_MODEL is set in ship-feature's config.*IGNORED" &&
  {
    echo "  ok   [-] the config file's old grok45high pin warns and is ignored"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the config file's GROK45HIGH_REVIEW_MODEL was honoured or not reported"
    FAIL=$((FAIL + 1))
  }
pout2=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config5" CURSOR_REVIEW_MODEL=composer-2.5 GROK_REVIEW_MODEL=grok-4.7 bash "$CLI" plan-review --reviewers cursor,grok 2>/dev/null)
# Anchored on the argv closing bracket: bare "composer-2.5" is a PREFIX of the "composer-2.5-fast"
# the config file sets, so an unanchored grep would pass whether the override worked or not —
# precisely the bug this case exists to catch.
printf '%s' "$pout2" | grep 'REVIEW-cursor' | grep -q -- "--model composer-2.5]" &&
  printf '%s' "$pout2" | grep 'REVIEW-grok' | grep -q -- "-m grok-4.7 " &&
  {
    echo "  ok   [-] the environment overrides the cursor and grok pins"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the config file overrode an explicit environment model"
    FAIL=$((FAIL + 1))
  }

# --- the SHARED panel config (pr-review-relay's file) is the last fallback ---------------------
# Both tools drive the same seats on the same accounts, so the model a seat runs belongs to the
# machine, not to whichever tool is invoking it. The relay's file has carried MODEL_glm since
# 2026-08-14; reading it here is what makes one file the answer instead of two that drift.
printf 'MODEL_glm=openrouter/z-ai/glm-9.9\nMODEL_grok=grok-9.9\nMODEL_cursor=composer-9.9\n' >"$CFGDIR/shared1"
sh1=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared1" bash "$CLI" plan-review --reviewers glm,grok,cursor 2>/dev/null)
printf '%s' "$sh1" | grep 'REVIEW-glm' | grep -q -- "-m openrouter/z-ai/glm-9.9" &&
  printf '%s' "$sh1" | grep 'REVIEW-grok' | grep -q -- "-m grok-9.9" &&
  {
    echo "  ok   [-] the shared relay config pins the models"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the shared relay config was not read"
    FAIL=$((FAIL + 1))
  }
# All three mapped seats, not just two: each is its own case arm, so a missing one fails
# silently on exactly one reviewer.
printf '%s' "$sh1" | grep 'REVIEW-cursor' | grep -q -- "--model composer-9.9" &&
  {
    echo "  ok   [-] the shared relay config pins the cursor model too"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL MODEL_cursor was not mapped"
    FAIL=$((FAIL + 1))
  }
# An EMPTY environment value must not block the shared file. Empty means "no pin", not
# "disable" — the SHIP_FEATURE_* keys use the other rule on purpose. With the wrong one,
# CURSOR_REVIEW_MODEL= left ship-feature on its built-in default while pr-review-relay used the
# shared value: same inputs, two different models.
sh6=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared1" CURSOR_REVIEW_MODEL='' bash "$CLI" plan-review --reviewers cursor 2>/dev/null)
printf '%s' "$sh6" | grep 'REVIEW-cursor' | grep -q -- "--model composer-9.9" &&
  {
    echo "  ok   [-] an empty environment pin does not block the shared file"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL an empty env pin blocked the shared config"
    FAIL=$((FAIL + 1))
  }
# A file with NO FINAL NEWLINE keeps its last line. pr-review-relay's parser reads it, so
# dropping it here would make the same file select different models in the two tools.
printf 'MODEL_glm=openrouter/z-ai/glm-9.9' >"$CFGDIR/shared5"
sh7=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared5" bash "$CLI" plan-review --reviewers glm 2>/dev/null)
printf '%s' "$sh7" | grep 'REVIEW-glm' | grep -q -- "-m openrouter/z-ai/glm-9.9" &&
  {
    echo "  ok   [-] a config file with no final newline keeps its last line"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the last line was dropped when the file had no final newline"
    FAIL=$((FAIL + 1))
  }
# Parser parity with pr-review-relay on a BOM'd file: it strips the BOM, so without this the
# first key reads as "\ufeffMODEL_glm" here and "MODEL_glm" there — one file, two models.
printf '\xef\xbb\xbfMODEL_glm=openrouter/z-ai/glm-9.9\n' >"$CFGDIR/shared6"
sh8=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared6" bash "$CLI" plan-review --reviewers glm 2>/dev/null)
printf '%s' "$sh8" | grep 'REVIEW-glm' | grep -q -- "-m openrouter/z-ai/glm-9.9" &&
  {
    echo "  ok   [-] a UTF-8 BOM does not hide the first key"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL a BOM'd shared config was not parsed like the relay parses it"
    FAIL=$((FAIL + 1))
  }
# HOME unset must not abort the command under `set -u`. A caller that passes both paths
# explicitly has every right not to have one.
nh0=$(printf 'plan\n' | env -u HOME PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG=/dev/null PR_RELAY_CONFIG="$CFGDIR/shared1" SHIP_FEATURE_PLANS_DIR="$WORK/plans" \
  bash "$CLI" plan-review --reviewers glm 2>&1)
# An unbound variable exits 1 in a script, like an ordinary refusal, so the exit code cannot tell
# them apart: read the error itself. And send a plan: an empty one is refused before any seat code
# runs, which left this test unable to fail.
! printf '%s' "$nh0" | grep -q 'unbound variable' && printf '%s' "$nh0" | grep -q 'REVIEW-glm' && {
  echo "  ok   [-] an unset HOME does not abort the run"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL unset HOME aborted (unbound variable)"
  FAIL=$((FAIL + 1))
}
# The same with NO PR_RELAY_CONFIG: the shared file's default path is built from HOME, so this is
# the path that needs the guard in relay/lib-panel.sh. An unbound variable exits 1 in a script, the
# same code as an ordinary failure, so read the error itself and require the seat to have run.
nh=$(printf 'plan\n' | env -u HOME -u PR_RELAY_CONFIG PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG=/dev/null SHIP_FEATURE_PLANS_DIR="$WORK/plans" \
  bash "$CLI" plan-review --reviewers glm 2>&1)
nhrc=$?
if [ "$nhrc" = 0 ] && ! printf '%s' "$nh" | grep -q 'unbound variable' && printf '%s' "$nh" | grep -q 'REVIEW-glm'; then
  echo "  ok   [-] an unset HOME with no PR_RELAY_CONFIG still runs the seat"
  PASS=$((PASS + 1))
else
  echo "  FAIL unset HOME with no PR_RELAY_CONFIG (rc=$nhrc): $(printf '%s' "$nh" | tail -n 3)"
  FAIL=$((FAIL + 1))
fi
# An inline `# ...` is part of the value in the shared file. The relay's parser has always read it
# that way, and ship-feature reads the file with that parser now; stripping it here again would give
# one line two meanings, one per tool.
printf 'MODEL_glm=openrouter/z-ai/glm-9.9 # pinned\n' >"$CFGDIR/shared-inline"
shi=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-inline" bash "$CLI" plan-review --reviewers glm 2>/dev/null)
printf '%s' "$shi" | grep 'REVIEW-glm' | grep -qF -- "-m openrouter/z-ai/glm-9.9 # pinned" &&
  {
    echo "  ok   [-] an inline comment in the shared file stays part of the value"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the shared value lost its inline '# ...': $(printf '%s' "$shi" | grep 'REVIEW-glm')"
    FAIL=$((FAIL + 1))
  }
# WHO sits on the panel comes from the shared file too. It was duplicated in both configs —
# identical today, free to drift tomorrow, and a panel that differs between the plan gate and the
# PR gate is something you discover from a verdict.
printf 'REVIEWERS=codex,grok\nPLAN_REVIEWERS=codex,glm\n' >"$CFGDIR/shared7"
sh9=$(PATH="$BIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared7" bash "$CLI" relay --author claude 2>/dev/null)
printf '%s' "$sh9" | grep -q -- "--reviewers codex,grok" &&
  {
    echo "  ok   [-] the shared file names the relay panel"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL REVIEWERS was not read from the shared file"
    FAIL=$((FAIL + 1))
  }
sh10=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared7" bash "$CLI" plan-review 2>/dev/null)
printf '%s' "$sh10" | grep -q 'REVIEW-glm' && printf '%s' "$sh10" | grep -q 'REVIEW-codex' &&
  ! printf '%s' "$sh10" | grep -q 'REVIEW-grok' &&
  {
    echo "  ok   [-] the shared file names the plan-review panel"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL PLAN_REVIEWERS was not read from the shared file"
    FAIL=$((FAIL + 1))
  }
# ship-feature's own config still wins, so one tool can differ on purpose.
printf 'SHIP_FEATURE_PLAN_REVIEWERS=codex\n' >"$CFGDIR/shared8"
sh11=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/shared8" PR_RELAY_CONFIG="$CFGDIR/shared7" bash "$CLI" plan-review 2>/dev/null)
printf '%s' "$sh11" | grep -q 'REVIEW-codex' && ! printf '%s' "$sh11" | grep -q 'REVIEW-glm' &&
  {
    echo "  ok   [-] ship-feature's own panel beats the shared one"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the shared panel overrode ship-feature's own"
    FAIL=$((FAIL + 1))
  }
# An explicitly EMPTY environment value still disables the injected quorum — that is what the
# ${VAR+x} rule is for, and it must survive a value sitting in the shared file.
sh12=$(PATH="$BIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared7" SHIP_FEATURE_REVIEWERS='' bash "$CLI" relay --author claude 2>/dev/null)
printf '%s' "$sh12" | grep -q -- "--reviewers" &&
  {
    echo "  FAIL an empty SHIP_FEATURE_REVIEWERS no longer disables the injected quorum"
    FAIL=$((FAIL + 1))
  } ||
  {
    echo "  ok   [-] an empty environment quorum still disables injection"
    PASS=$((PASS + 1))
  }
# LAST value wins within the shared file, as in pr-review-relay's own parser. Guarding only on
# "is it set" kept the FIRST line here while the relay kept the last — a valid file handing the
# two tools different panels, which is the thing reading one file is supposed to prevent.
printf 'REVIEWERS=codex\nMODEL_glm=openrouter/z-ai/glm-5.2\nREVIEWERS=codex,grok\nMODEL_glm=openrouter/z-ai/glm-9.9\n' >"$CFGDIR/shared9"
sh13=$(PATH="$BIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared9" bash "$CLI" relay --author claude 2>/dev/null)
printf '%s' "$sh13" | grep -q -- "--reviewers codex,grok" &&
  {
    echo "  ok   [-] a repeated key takes the LAST value, like the relay"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL a repeated key kept the first value (the relay would keep the last)"
    FAIL=$((FAIL + 1))
  }
sh14=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared9" bash "$CLI" plan-review --reviewers glm 2>/dev/null)
printf '%s' "$sh14" | grep 'REVIEW-glm' | grep -q -- "-m openrouter/z-ai/glm-9.9" &&
  {
    echo "  ok   [-] a repeated model pin takes the LAST value too"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL a repeated model pin kept the first value"
    FAIL=$((FAIL + 1))
  }
# The empty-environment contract, on the OTHER key. PLAN_REVIEWERS is its own line of code, so a
# typo there would pass every test above.
sh15=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared7" SHIP_FEATURE_PLAN_REVIEWERS='' SHIP_FEATURE_REVIEWERS=codex bash "$CLI" plan-review 2>/dev/null)
printf '%s' "$sh15" | grep -q 'REVIEW-codex' && ! printf '%s' "$sh15" | grep -q 'REVIEW-glm' &&
  {
    echo "  ok   [-] an empty plan panel falls back to the quorum, not to the shared file"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL an empty SHIP_FEATURE_PLAN_REVIEWERS did not survive the shared file"
    FAIL=$((FAIL + 1))
  }
# Closing the 2x2: a SET environment quorum must beat the shared file on the relay side too.
sh16=$(PATH="$BIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared7" SHIP_FEATURE_REVIEWERS=claude,codex bash "$CLI" relay --author claude 2>/dev/null)
printf '%s' "$sh16" | grep -q -- "--reviewers claude,codex" &&
  {
    echo "  ok   [-] an environment quorum beats the shared file"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the shared file overrode an explicit environment quorum"
    FAIL=$((FAIL + 1))
  }
# INVERTED in 2026-09. `grok` is ONE seat in both tools now: MODEL_grok / EFFORT_grok pin the plan
# review exactly as they pin the relay's grok seat. (Until then plan-review ran a separate
# `grok45high` seat at a hardcoded high effort, and this case asserted MODEL_grok did NOT reach it.)
printf 'MODEL_grok=grok-0.0\nEFFORT_grok=low\n' >"$CFGDIR/shared4"
sh5=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared4" bash "$CLI" plan-review --reviewers grok 2>/dev/null)
printf '%s' "$sh5" | grep 'REVIEW-grok' | grep -q -- "-m grok-0.0 --reasoning-effort low " &&
  {
    echo "  ok   [-] MODEL_grok / EFFORT_grok pin the plan-review grok seat"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL MODEL_grok / EFFORT_grok did not reach the grok seat: $sh5"
    FAIL=$((FAIL + 1))
  }

# --- claude and codex take their model/effort pins too (Fizzy #1123) -------------------------
# Until 2026-09 plan-review ran a bare `claude -p` and a bare `codex exec`: MODEL_claude and
# MODEL_codex / EFFORT_codex in the shared file pinned the PR review and not the plan review, and
# codex ran whatever ~/.codex/config.toml happened to say.
printf 'MODEL_claude=claude-pin-1\nEFFORT_claude=high\nMODEL_codex=codex-pin-1\nEFFORT_codex=medium\n' >"$CFGDIR/shared-pins"
pn=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-pins" bash "$CLI" plan-review --reviewers claude,codex 2>&1)
# Anchored on the flags that stay in place AND on "You are reviewing" (the start of the prompt):
# the pins must sit between the read-only flags and the prompt, not after it.
printf '%s' "$pn" | grep 'REVIEW-claude' | grep -q -- "--permission-mode plan --safe-mode --model claude-pin-1 --effort high You are reviewing" &&
  {
    echo "  ok   [-] MODEL_claude / EFFORT_claude reach the claude seat, before the prompt"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the claude pins did not reach its argv in place: $(printf '%s' "$pn" | grep 'REVIEW-claude')"
    FAIL=$((FAIL + 1))
  }
printf '%s' "$pn" | grep 'REVIEW-codex' | grep -qF -- 'exec --sandbox read-only -m codex-pin-1 -c model_reasoning_effort="medium" You are reviewing' &&
  {
    echo "  ok   [-] MODEL_codex / EFFORT_codex reach the codex seat, before the prompt"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the codex pins did not reach its argv in place: $(printf '%s' "$pn" | grep 'REVIEW-codex')"
    FAIL=$((FAIL + 1))
  }
# The resolved pins are printed on each seat's dispatch line.
printf '%s' "$pn" | grep -q '→ claude reviewing… (model=claude-pin-1, effort=high)' &&
  printf '%s' "$pn" | grep -q '→ codex reviewing… (model=codex-pin-1, effort=medium)' &&
  {
    echo "  ok   [-] the dispatch line shows each seat's resolved model and effort"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the dispatch line does not show the resolved pins"
    FAIL=$((FAIL + 1))
  }
# No pins → exactly today's argv: no new argument, not even an empty one.
pn0=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude,codex 2>&1)
printf '%s' "$pn0" | grep 'REVIEW-claude' | grep -q -- "argv=\[-p --permission-mode plan --safe-mode You are reviewing" &&
  printf '%s' "$pn0" | grep 'REVIEW-codex' | grep -q -- "argv=\[exec --sandbox read-only You are reviewing" &&
  printf '%s' "$pn0" | grep -q '→ claude reviewing… (model=cli default, effort=cli default)' &&
  {
    echo "  ok   [-] unpinned claude and codex get no extra argument"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL an unpinned seat gained an argument: $pn0"
    FAIL=$((FAIL + 1))
  }
# Every other seat's dispatch line too — each is its own arm in plan_seat_pins, so a misspelt
# variable there would print "(model=)" on exactly one seat. grok is the one whose default effort
# changed. The line is printed by the parent before the seat starts, so the seat's own outcome
# (the gemini stub's auth path) does not matter here.
pnd=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_FORCE_SANDBOX_PROBE=ok bash "$CLI" plan-review --reviewers grok,cursor,glm,antigravity 2>&1)
printf '%s' "$pnd" | grep -q '→ grok reviewing… (model=grok-4.6, effort=medium)' &&
  printf '%s' "$pnd" | grep -q '→ cursor reviewing… (model=composer-2.5)' &&
  printf '%s' "$pnd" | grep -q '→ glm reviewing… (model=opencode-go/glm-5.3)' &&
  printf '%s' "$pnd" | grep -q '→ antigravity reviewing… (model=gemini-3.1-pro-preview)' &&
  {
    echo "  ok   [-] the dispatch line shows grok, cursor, glm and gemini's resolved pins"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL a dispatch line is missing or wrong: $(printf '%s' "$pnd" | grep '→')"
    FAIL=$((FAIL + 1))
  }
# The environment beats the shared file, per key; an EMPTY environment value does not block it.
pn1=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-pins" CODEX_REVIEW_MODEL=env-codex CLAUDE_REVIEW_EFFORT=low CODEX_REVIEW_EFFORT='' bash "$CLI" plan-review --reviewers claude,codex 2>&1)
printf '%s' "$pn1" | grep 'REVIEW-codex' | grep -qF -- '-m env-codex -c model_reasoning_effort="medium" ' &&
  printf '%s' "$pn1" | grep 'REVIEW-claude' | grep -q -- "--model claude-pin-1 --effort low " &&
  {
    echo "  ok   [-] an environment pin beats the shared file, and an empty one does not block it"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL environment/shared-file precedence is wrong: $pn1"
    FAIL=$((FAIL + 1))
  }
# ship-feature's OWN config is not a home for these six: the value is reported and ignored.
printf 'CODEX_REVIEW_MODEL=own-codex\n' >"$CFGDIR/own-pins"
pn2=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/own-pins" bash "$CLI" plan-review --reviewers codex 2>&1)
! printf '%s' "$pn2" | grep 'REVIEW-codex' | grep -q -- "own-codex" &&
  printf '%s' "$pn2" | grep -q "CODEX_REVIEW_MODEL is set in ship-feature's config and is IGNORED" &&
  {
    echo "  ok   [-] a pin in ship-feature's own config warns and is ignored"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL a pin in ship-feature's own config was honoured or dropped in silence: $pn2"
    FAIL=$((FAIL + 1))
  }
# Config typos must not become flags: a leading '-' in a model, or a non-word effort, stops the
# run before any reviewer starts.
printf 'MODEL_codex=--yolo\n' >"$CFGDIR/shared-bad1"
pb1=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-bad1" bash "$CLI" plan-review --reviewers codex 2>&1)
rc=$?
[ "$rc" != 0 ] && ! printf '%s' "$pb1" | grep -q 'REVIEW-' &&
  {
    echo "  ok   [-] a model pin starting with '-' is refused before dispatch"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL MODEL_codex=--yolo reached a reviewer (rc=$rc)"
    FAIL=$((FAIL + 1))
  }
printf 'EFFORT_codex=x" y\n' >"$CFGDIR/shared-bad2"
pb2=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-bad2" bash "$CLI" plan-review --reviewers codex 2>&1)
rc=$?
[ "$rc" != 0 ] && ! printf '%s' "$pb2" | grep -q 'REVIEW-' &&
  {
    echo "  ok   [-] an effort that is not a bare word is refused before dispatch"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL a quoting effort reached a reviewer (rc=$rc)"
    FAIL=$((FAIL + 1))
  }
# `ship-feature relay` is unchanged: the ten pins are read for plan-review and NOT pushed into the
# relay child, which reads the same file itself. Includes the empty-export case: a plain
# assignment keeps an inherited export attribute, so without `export -n` an exported EMPTY
# CODEX_REVIEW_MODEL= would carry the file's value across.
cp "$BIN/pr-review-relay" "$WORK/relay-stub-backup-pins"
cat >"$BIN/pr-review-relay" <<'STUB'
#!/usr/bin/env bash
for v in CLAUDE_REVIEW_MODEL CLAUDE_REVIEW_EFFORT CODEX_REVIEW_MODEL CODEX_REVIEW_EFFORT GROK_REVIEW_MODEL GROK_REVIEW_EFFORT PI_GLM_REVIEW_MODEL PI_GLM_REVIEW_EFFORT PI_GROK_REVIEW_MODEL PI_GROK_REVIEW_EFFORT; do
  if [ -n "${!v+x}" ]; then echo "$v=[${!v}]"; else echo "$v=unset"; fi
done
STUB
chmod +x "$BIN/pr-review-relay"
printf 'MODEL_claude=c1\nEFFORT_claude=high\nMODEL_codex=file-m\nEFFORT_codex=medium\nMODEL_grok=g1\nEFFORT_grok=low\nMODEL_pi_glm=pg-m\nEFFORT_pi_glm=minimal\nMODEL_pi_grok=pk-m\nEFFORT_pi_grok=xhigh\n' >"$CFGDIR/shared-pins-relay"
rp=$(PATH="$BIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-pins-relay" bash "$CLI" relay --author claude 2>/dev/null)
rp2=$(PATH="$BIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-pins-relay" CODEX_REVIEW_MODEL='' PI_GROK_REVIEW_EFFORT='' bash "$CLI" relay --author claude 2>/dev/null)
cp "$WORK/relay-stub-backup-pins" "$BIN/pr-review-relay"
chmod +x "$BIN/pr-review-relay"
[ "$(printf '%s\n' "$rp" | grep -c '=unset$')" = 10 ] &&
  {
    echo "  ok   [-] the shared pins are not pushed into the relay child"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL a shared pin reached the relay child's environment: $rp"
    FAIL=$((FAIL + 1))
  }
# PI_GROK_REVIEW_EFFORT is the pi seats' copy of the same trap: an arm copied from MODEL_glm (which
# exports, on purpose) would carry the file's xhigh into the relay, on top of the relay's own config.
! printf '%s' "$rp2" | grep -q 'file-m' && ! printf '%s' "$rp2" | grep -q 'xhigh' &&
  printf '%s\n' "$rp2" | grep -qx 'PI_GROK_REVIEW_EFFORT=unset' &&
  {
    echo "  ok   [-] an exported empty pin does not carry the file value into the relay child"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the shared file's value leaked through an exported empty name: $rp2"
    FAIL=$((FAIL + 1))
  }
# ship-feature's OWN config wins over the shared one — a per-tool override has to be possible,
# or consolidating would mean losing the ability to differ on purpose.
printf 'GLM_REVIEW_MODEL=openrouter/z-ai/glm-5.2\n' >"$CFGDIR/shared2"
sh2=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/shared2" PR_RELAY_CONFIG="$CFGDIR/shared1" bash "$CLI" plan-review --reviewers glm 2>/dev/null)
printf '%s' "$sh2" | grep 'REVIEW-glm' | grep -q -- "-m openrouter/z-ai/glm-5.2" &&
  {
    echo "  ok   [-] ship-feature's own config beats the shared one"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the shared config overrode ship-feature's own"
    FAIL=$((FAIL + 1))
  }
# And the environment still beats both.
sh3=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/shared2" PR_RELAY_CONFIG="$CFGDIR/shared1" GLM_REVIEW_MODEL=opencode-go/glm-5.3-flash bash "$CLI" plan-review --reviewers glm 2>/dev/null)
printf '%s' "$sh3" | grep 'REVIEW-glm' | grep -q -- "-m opencode-go/glm-5.3-flash" &&
  {
    echo "  ok   [-] the environment beats both config files"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL a config file overrode an explicit environment model"
    FAIL=$((FAIL + 1))
  }
# MODEL_opencode is NOT mapped: that seat is pr-review-relay's own, and it reads this same file.
# Exporting PR_RELAY_OPENCODE_MODEL from here would beat the relay's own config, which is the
# opposite of consolidating.
printf 'MODEL_opencode=openrouter/should-not-be-used\n' >"$CFGDIR/shared3"
printf '#!/usr/bin/env bash\necho "RELAYENV PR_RELAY_OPENCODE_MODEL=${PR_RELAY_OPENCODE_MODEL:-unset}"\nexit 0\n' >"$BIN/pr-review-relay.shared"
chmod +x "$BIN/pr-review-relay.shared"
cp "$BIN/pr-review-relay" "$WORK/relay-stub-backup2"
cp "$BIN/pr-review-relay.shared" "$BIN/pr-review-relay"
sh4=$(PATH="$BIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared3" bash "$CLI" relay --author claude 2>/dev/null)
cp "$WORK/relay-stub-backup2" "$BIN/pr-review-relay"
chmod +x "$BIN/pr-review-relay"
printf '%s' "$sh4" | grep -q 'PR_RELAY_OPENCODE_MODEL=unset' &&
  {
    echo "  ok   [-] MODEL_opencode is left to pr-review-relay itself"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL ship-feature exported the relay's own seat model over its config"
    FAIL=$((FAIL + 1))
  }

# REGRESSION (Codex round 3): a HOSTILE inherited OPENCODE_CONFIG_CONTENT that re-enables
# edit/bash must be overridden by our deny (we own the highest-precedence layer).
hostile=$(printf 'plan\n' | PATH="$PBIN:$PATH" OPENCODE_CONFIG_CONTENT='{"permission":{"edit":"allow","bash":"allow"}}' bash "$CLI" plan-review --reviewers glm 2>/dev/null | grep 'REVIEW-glm')
printf '%s' "$hostile" | grep -q 'OPENCODE_CONFIG_CONTENT=\[.*"edit":"deny".*"bash":"deny".*\]' && ! printf '%s' "$hostile" | grep -q '"edit":"allow"' && {
  echo "  ok   [-] glm overrides a hostile inherited OPENCODE_CONFIG_CONTENT"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL a hostile OPENCODE_CONFIG_CONTENT survived (read-only bypass)"
  FAIL=$((FAIL + 1))
}

# CURSOR_REVIEW_MODEL is the documented way out if Cursor retires the pinned id, so it is part of
# the contract rather than a convenience: a pin that could not be overridden would be a dead end.
cuo=$(printf 'plan\n' | PATH="$PBIN:$PATH" CURSOR_REVIEW_MODEL=cursor-grok-4.5-high bash "$CLI" plan-review --reviewers cursor 2>/dev/null | grep 'REVIEW-cursor')
printf '%s' "$cuo" | grep -q -- "--model cursor-grok-4.5-high" && {
  echo "  ok   [-] CURSOR_REVIEW_MODEL overrides the pinned default"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL CURSOR_REVIEW_MODEL ignored: $cuo"
  FAIL=$((FAIL + 1))
}

# GLM_REVIEW_MODEL is the documented way to route glm at a pay-as-you-go model (e.g. an
# OpenRouter id) instead of the bundled OpenCode Go tier — same contract as CURSOR_REVIEW_MODEL
# above: a pin that could not be overridden would be a dead end.
kmo=$(printf 'plan\n' | PATH="$PBIN:$PATH" GLM_REVIEW_MODEL=openrouter/z-ai/glm-5.2 bash "$CLI" plan-review --reviewers glm 2>/dev/null | grep 'REVIEW-glm')
printf '%s' "$kmo" | grep -q -- "-m openrouter/z-ai/glm-5.2" && {
  echo "  ok   [-] GLM_REVIEW_MODEL overrides the pinned default"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL GLM_REVIEW_MODEL ignored: $kmo"
  FAIL=$((FAIL + 1))
}

# --- the seat's OLD name is dead, and dies LOUDLY ----------------------------------------------
# This seat was `kimi3` until 2026-09. Renaming it in a config file alone is what motivated the
# rename in code: `MODEL_glm` used to hit no case arm at all, get dropped in silence, and leave the
# seat on its built-in default while the config plainly named another model. Every stale spelling
# must therefore be LOUD. Each assertion below keeps stderr (2>&1) — the surrounding tests use
# 2>/dev/null, and copying that here would make every one of them pass vacuously.

# 1. The old SEAT name is an unknown reviewer: the round fails rather than passing on a thinned panel.
dep1=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers kimi3 2>&1)
dep1_rc=$?
printf '%s' "$dep1" | grep -q "unknown reviewer 'kimi3'" &&
  {
    echo "  ok   [-] the old seat name 'kimi3' is rejected as unknown"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL 'kimi3' did not fail as an unknown reviewer: $dep1"
    FAIL=$((FAIL + 1))
  }
[ "$dep1_rc" -ne 0 ] &&
  {
    echo "  ok   [-] a panel naming the old seat exits non-zero"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL a panel naming 'kimi3' exited 0"
    FAIL=$((FAIL + 1))
  }

# 2. The old key in the ENVIRONMENT: warned about, and NOT honoured. The value below is a real id
# and is deliberately NOT the new default, so honouring it would be visible in the -m argument.
dep2=$(printf 'plan\n' | PATH="$PBIN:$PATH" KIMI3_REVIEW_MODEL=openrouter/z-ai/glm-5.2 bash "$CLI" plan-review --reviewers glm 2>&1)
printf '%s' "$dep2" | grep -q 'KIMI3_REVIEW_MODEL is set in the ENVIRONMENT' &&
  {
    echo "  ok   [-] a stale KIMI3_REVIEW_MODEL in the environment is reported"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL a stale KIMI3_REVIEW_MODEL in the environment was silent"
    FAIL=$((FAIL + 1))
  }
printf '%s' "$dep2" | grep 'REVIEW-glm' | grep -q -- "-m opencode-go/glm-5.3]" &&
  {
    echo "  ok   [-] the old environment key does not pin the model — the seat ran on its default"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the old environment key was honoured, or the seat never dispatched: $(printf '%s' "$dep2" | grep 'REVIEW-glm')"
    FAIL=$((FAIL + 1))
  }

# 3. The old key in ship-feature's OWN config file. A file-only pin never enters the environment,
# so the check above cannot cover it, and load_config has no `*)` arm to catch it either.
printf 'KIMI3_REVIEW_MODEL=openrouter/z-ai/glm-5.2\n' >"$CFGDIR/deprecated1"
dep3=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/deprecated1" bash "$CLI" plan-review --reviewers glm 2>&1)
printf '%s' "$dep3" | grep -q "KIMI3_REVIEW_MODEL is set in ship-feature's config" &&
  {
    echo "  ok   [-] a stale KIMI3_REVIEW_MODEL in the config file is reported"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL a stale KIMI3_REVIEW_MODEL in the config file was silent"
    FAIL=$((FAIL + 1))
  }
printf '%s' "$dep3" | grep 'REVIEW-glm' | grep -q -- "-m opencode-go/glm-5.3]" &&
  {
    echo "  ok   [-] the old config key does not pin the model — the seat ran on its default"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the old config key was honoured, or the seat never dispatched: $(printf '%s' "$dep3" | grep 'REVIEW-glm')"
    FAIL=$((FAIL + 1))
  }

# 4. The old key in the SHARED panel file — the exact failure that motivated this rename.
printf 'MODEL_kimi3=openrouter/z-ai/glm-5.2\n' >"$CFGDIR/deprecated2"
dep4=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG=/dev/null PR_RELAY_CONFIG="$CFGDIR/deprecated2" bash "$CLI" plan-review --reviewers glm 2>&1)
printf '%s' "$dep4" | grep -q 'MODEL_kimi3 is set in the shared panel config' &&
  {
    echo "  ok   [-] a stale MODEL_kimi3 in the shared config is reported"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL a stale MODEL_kimi3 in the shared config was silent"
    FAIL=$((FAIL + 1))
  }
printf '%s' "$dep4" | grep 'REVIEW-glm' | grep -q -- "-m opencode-go/glm-5.3]" &&
  {
    echo "  ok   [-] the old shared key does not pin the model — the seat ran on its default"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the old shared key was honoured, or the seat never dispatched: $(printf '%s' "$dep4" | grep 'REVIEW-glm')"
    FAIL=$((FAIL + 1))
  }

# 5. MIXED: a stale KIMI3_REVIEW_MODEL in the environment must NOT suppress a valid MODEL_glm in
# the shared file. Only GLM_REVIEW_MODEL outranks MODEL_glm; if the old name did, the shared pin
# would be skipped as "already provided by a higher source", the very silent drop
# this rename removes, rebuilt inside the fix for it.
printf 'MODEL_glm=openrouter/z-ai/glm-5.2\n' >"$CFGDIR/deprecated3"
dep5=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG=/dev/null PR_RELAY_CONFIG="$CFGDIR/deprecated3" KIMI3_REVIEW_MODEL=openrouter/z-ai/glm-9.9 bash "$CLI" plan-review --reviewers glm 2>&1)
printf '%s' "$dep5" | grep 'REVIEW-glm' | grep -q -- "-m openrouter/z-ai/glm-5.2" &&
  {
    echo "  ok   [-] a stale env key does not suppress MODEL_glm from the shared file"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL a stale KIMI3_REVIEW_MODEL suppressed the shared MODEL_glm pin: $(printf '%s' "$dep5" | grep 'REVIEW-glm')"
    FAIL=$((FAIL + 1))
  }
printf '%s' "$dep5" | grep -q 'KIMI3_REVIEW_MODEL is set in the ENVIRONMENT' &&
  {
    echo "  ok   [-] and it is still reported"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the stale env key went unreported in the mixed case"
    FAIL=$((FAIL + 1))
  }

# 6. The warnings belong to plan-review ALONE. `relay` and `preflight` also call load_config, and a
# deprecation notice about a plan-review seat has no business printing on a cross-review run —
# especially while pr-review-relay still accepts MODEL_kimi3 in its own PANEL_SEATS.
# Each of these asserts an ABSENCE, so each first proves the command actually RAN. An earlier
# draft of this test ran `cd "$TMP"` — a variable this suite does not define — so the subshell
# died, the output was empty, and "no warning present" passed while the warning was being printed
# on every command. Caught by mutating load_config to warn unconditionally and watching this block
# stay green. An absence test without a liveness check is not a test.
printf '#!/usr/bin/env bash\necho "RELAY-STDOUT-MARKER"\nexit 0\n' >"$BIN/pr-review-relay"
chmod +x "$BIN/pr-review-relay"
# BOTH warning texts have to be exercised, and they share no substring: the shared-key warning
# says MODEL_kimi3 and never says KIMI3_REVIEW_MODEL. Grepping only the latter would leave the
# shared arm untested here — move it into load_shared_panel_config and `relay` would print it on
# every run with this block still green. So each command below is given all three stale spellings
# at once (environment, ship-feature's own file, and the shared panel file) and is checked against
# both texts.
dep6=$(cd "$MAIN/.claude/worktrees/feat" && PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/deprecated1" PR_RELAY_CONFIG="$CFGDIR/deprecated2" KIMI3_REVIEW_MODEL=openrouter/z-ai/glm-5.2 bash "$CLI" preflight 2>&1)
# Liveness marker is preflight's FIRST check, not its verdict: whether preflight passes here
# depends on what earlier tests did to this worktree, and that is not what this assertion is
# about. All it has to prove is that the command ran far enough to have loaded config.
printf '%s' "$dep6" | grep -q 'default branch:' &&
  {
    echo "  ok   [-] the preflight deprecation check actually ran preflight"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL preflight did not run — the absence check below would be vacuous: $dep6"
    FAIL=$((FAIL + 1))
  }
printf '%s' "$dep6" | grep -qE 'KIMI3_REVIEW_MODEL|MODEL_kimi3' &&
  {
    echo "  FAIL preflight printed a plan-review deprecation warning"
    FAIL=$((FAIL + 1))
  } ||
  {
    echo "  ok   [-] preflight prints no plan-review deprecation warning"
    PASS=$((PASS + 1))
  }
dep7=$(PATH="$BIN:$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/deprecated1" PR_RELAY_CONFIG="$CFGDIR/deprecated2" KIMI3_REVIEW_MODEL=openrouter/z-ai/glm-5.2 bash "$CLI" relay --author claude 2>&1)
printf '%s' "$dep7" | grep -q 'RELAY-STDOUT-MARKER' &&
  {
    echo "  ok   [-] the relay deprecation check actually ran relay"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL relay did not run — the absence check below would be vacuous: $dep7"
    FAIL=$((FAIL + 1))
  }
printf '%s' "$dep7" | grep -qE 'KIMI3_REVIEW_MODEL|MODEL_kimi3' &&
  {
    echo "  FAIL relay printed a plan-review deprecation warning"
    FAIL=$((FAIL + 1))
  } ||
  {
    echo "  ok   [-] relay prints no plan-review deprecation warning"
    PASS=$((PASS + 1))
  }
# 7. An EXPORTED BUT EMPTY old key is still a dead name in a profile, and is still reported. This
# inverts the convention every model pin uses (empty means "not configured"), so it gets its own
# assertion — the check is ${VAR+x}, and a regression to ${VAR:-} would go unnoticed otherwise.
depe=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG=/dev/null KIMI3_REVIEW_MODEL='' bash "$CLI" plan-review --reviewers glm 2>&1)
printf '%s' "$depe" | grep -q 'KIMI3_REVIEW_MODEL is set in the ENVIRONMENT' &&
  {
    echo "  ok   [-] an exported-but-empty old key is still reported"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL an exported-but-empty KIMI3_REVIEW_MODEL was silent"
    FAIL=$((FAIL + 1))
  }
printf '%s' "$depe" | grep 'REVIEW-glm' | grep -q -- "-m opencode-go/glm-5.3]" &&
  {
    echo "  ok   [-] and the seat still runs its default"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the empty old key changed the model, or the seat never dispatched"
    FAIL=$((FAIL + 1))
  }

# 8. The realistic MIGRATION STATE: one shared file carrying BOTH keys, old and new, as it looks
# mid-rename. The new one must win and the old one must still be reported — the arms are
# independent, but this is the combination a user actually has on disk.
printf 'MODEL_kimi3=openrouter/z-ai/glm-9.9\nMODEL_glm=openrouter/z-ai/glm-5.2\n' >"$CFGDIR/deprecated4"
depm=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG=/dev/null PR_RELAY_CONFIG="$CFGDIR/deprecated4" bash "$CLI" plan-review --reviewers glm 2>&1)
printf '%s' "$depm" | grep 'REVIEW-glm' | grep -q -- "-m openrouter/z-ai/glm-5.2" &&
  {
    echo "  ok   [-] with both keys in one file, MODEL_glm wins"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL MODEL_kimi3 beat MODEL_glm, or neither applied: $(printf '%s' "$depm" | grep 'REVIEW-glm')"
    FAIL=$((FAIL + 1))
  }
printf '%s' "$depm" | grep -q 'MODEL_kimi3 is set in the shared panel config' &&
  {
    echo "  ok   [-] and the old key is still reported alongside it"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the old key went unreported when the new one was present"
    FAIL=$((FAIL + 1))
  }

# And prove BOTH texts are reachable at all, or the two absence checks above could be passing
# because no warning exists to print. Same run, same three stale keys, through plan-review.
depb=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/deprecated1" PR_RELAY_CONFIG="$CFGDIR/deprecated2" KIMI3_REVIEW_MODEL=openrouter/z-ai/glm-5.2 bash "$CLI" plan-review --reviewers glm 2>&1)
printf '%s' "$depb" | grep -q 'KIMI3_REVIEW_MODEL' && printf '%s' "$depb" | grep -q 'MODEL_kimi3' &&
  {
    echo "  ok   [-] plan-review does print both deprecation texts for the same input"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL a deprecation text is unreachable — the relay/preflight silence checks are vacuous"
    FAIL=$((FAIL + 1))
  }
# Restore the stub the relay tests further up installed, so this block cannot decide the outcome
# of any relay assertion appended below it.
printf '#!/usr/bin/env bash\necho "ARGS: $*"\nexit 0\n' >"$BIN/pr-review-relay"
chmod +x "$BIN/pr-review-relay"

# GROK_REVIEW_MODEL / GROK_REVIEW_EFFORT (the relay's own environment names) pin grok at a
# different version and effort — same contract as CURSOR_REVIEW_MODEL/GLM_REVIEW_MODEL above: a
# pin that could not be overridden would be a dead end when xAI ships the next model.
gmo=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_FORCE_SANDBOX_PROBE=ok GROK_REVIEW_MODEL=grok-4.7 GROK_REVIEW_EFFORT=high bash "$CLI" plan-review --reviewers grok 2>/dev/null | grep 'REVIEW-grok')
printf '%s' "$gmo" | grep -q -- "-m grok-4.7 --reasoning-effort high " && {
  echo "  ok   [-] GROK_REVIEW_MODEL / GROK_REVIEW_EFFORT override the defaults"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL GROK_REVIEW_MODEL / GROK_REVIEW_EFFORT ignored: $gmo"
  FAIL=$((FAIL + 1))
}
# The OLD environment name is reported and ignored — and it must NOT block the shared file. This is
# the case the plan review caught: were the "env already set" flag armed from the old name, a
# stale export would skip MODEL_grok in silence and the seat would run the built-in default.
printf 'MODEL_grok=grok-4.7\n' >"$CFGDIR/shared-grok-old"
gold=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_FORCE_SANDBOX_PROBE=ok PR_RELAY_CONFIG="$CFGDIR/shared-grok-old" GROK45HIGH_REVIEW_MODEL=grok-old bash "$CLI" plan-review --reviewers grok 2>&1)
printf '%s' "$gold" | grep 'REVIEW-grok' | grep -q -- "-m grok-4.7 " &&
  printf '%s' "$gold" | grep -q 'GROK45HIGH_REVIEW_MODEL is set in the ENVIRONMENT.*IGNORED' &&
  {
    echo "  ok   [-] a stale GROK45HIGH_REVIEW_MODEL export warns and does not block MODEL_grok"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL a stale GROK45HIGH_REVIEW_MODEL export blocked MODEL_grok or was not reported: $gold"
    FAIL=$((FAIL + 1))
  }
# MODEL_grok45high in the shared file: reported, ignored.
printf 'MODEL_grok45high=grok-old\n' >"$CFGDIR/shared-grok-old2"
gold2=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_FORCE_SANDBOX_PROBE=ok PR_RELAY_CONFIG="$CFGDIR/shared-grok-old2" bash "$CLI" plan-review --reviewers grok 2>&1)
printf '%s' "$gold2" | grep 'REVIEW-grok' | grep -q -- "-m grok-4.6 " &&
  printf '%s' "$gold2" | grep -q 'MODEL_grok45high is set in the shared panel config.*IGNORED' &&
  ! printf '%s' "$gold2" | grep -q 'internal: no message' &&
  {
    echo "  ok   [-] MODEL_grok45high in the shared file warns and is ignored"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL MODEL_grok45high was honoured or not reported: $gold2"
    FAIL=$((FAIL + 1))
  }

# --- the per-reviewer TIMEOUT, and the ladder it resolves through -----------------------------
# AGENT_TIMEOUT in pr-review-relay's config was the one panel key ship-feature did NOT read: the
# resolver consulted the environment and stopped. So setting it in that file configured the relay
# and left every plan review on the built-in default, and the failure was quiet in the way that
# matters — a timed-out reviewer exits 3 and says so, but the round returns NO FINDINGS, which on
# the page is indistinguishable from a clean plan.
#
# Nothing prints the resolved number, so these tests read it off the `timeout` invocation itself:
# a stub FIRST on PATH that records $1 and then execs the rest. TBIN is its own directory, kept out
# of PBIN on purpose — the hermetic-environment case further down links the REAL timeout into a bin
# dir, and a leftover stub there would break it.
TBIN="$WORK/tbin"
mkdir -p "$TBIN"
cat >"$TBIN/timeout" <<'TSTUB'
#!/usr/bin/env bash
printf '%s\n' "$1" > "$TIMEOUT_SEEN"
shift
exec "$@"
TSTUB
chmod +x "$TBIN/timeout"

# $1 = expected seconds, $2 = description, rest = env assignments
timeout_case() {
  local want="$1" desc="$2"
  shift 2
  local seen="$WORK/timeout_seen.$want.$$"
  : >"$seen"
  (printf 'plan\n' | env "$@" TIMEOUT_SEEN="$seen" PATH="$TBIN:$PBIN:$PATH" \
    bash "$CLI" plan-review --reviewers codex >/dev/null 2>&1)
  local got
  got="$(cat "$seen" 2>/dev/null || true)"
  if [ "$got" = "$want" ]; then
    echo "  ok   [-] $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $desc — timeout ran with '$got', want '$want'"
    FAIL=$((FAIL + 1))
  fi
}

# EVERY fixture below uses a value that appears nowhere else, so each assertion identifies WHICH
# source won. Asserting 500 against a shared file that also says 500 would pass without proving
# anything — the built-in default is 500 too.
printf 'AGENT_TIMEOUT=470\n' >"$CFGDIR/shared-t1"

# 1. The shared file reaches plan-review at all. This is the bug.
timeout_case 470 "AGENT_TIMEOUT in the shared relay config reaches plan-review" \
  PR_RELAY_CONFIG="$CFGDIR/shared-t1" SHIP_FEATURE_CONFIG=/dev/null

# 2. Rung 1 beats the shared file.
timeout_case 410 "SHIP_FEATURE_PLAN_TIMEOUT in the environment beats the shared file" \
  PR_RELAY_CONFIG="$CFGDIR/shared-t1" SHIP_FEATURE_CONFIG=/dev/null SHIP_FEATURE_PLAN_TIMEOUT=410

# 3. Rung 2: ship-feature's own file beats the shared one, and loses to the environment.
printf 'SHIP_FEATURE_PLAN_TIMEOUT=420\n' >"$CFGDIR/own-t1"
timeout_case 420 "SHIP_FEATURE_PLAN_TIMEOUT in ship-feature's config beats the shared file" \
  PR_RELAY_CONFIG="$CFGDIR/shared-t1" SHIP_FEATURE_CONFIG="$CFGDIR/own-t1"
timeout_case 410 "the environment still beats ship-feature's own config" \
  PR_RELAY_CONFIG="$CFGDIR/shared-t1" SHIP_FEATURE_CONFIG="$CFGDIR/own-t1" SHIP_FEATURE_PLAN_TIMEOUT=410

# 4. Rung 3 — the conflict that made this a Blocker in plan review. Drop PR_RELAY_AGENT_TIMEOUT
# from the ladder and a machine exporting it gets that value in pr-review-relay and the shared
# file's value here: same inputs, two timeouts, which is the whole failure being fixed.
timeout_case 460 "PR_RELAY_AGENT_TIMEOUT in the environment beats the shared file" \
  PR_RELAY_CONFIG="$CFGDIR/shared-t1" SHIP_FEATURE_CONFIG=/dev/null PR_RELAY_AGENT_TIMEOUT=460
timeout_case 410 "SHIP_FEATURE_PLAN_TIMEOUT beats PR_RELAY_AGENT_TIMEOUT" \
  PR_RELAY_CONFIG="$CFGDIR/shared-t1" SHIP_FEATURE_CONFIG=/dev/null PR_RELAY_AGENT_TIMEOUT=460 SHIP_FEATURE_PLAN_TIMEOUT=410

# 5. No config anywhere -> the built-in default, which is 500 and not 300. The default is the point
# of the change, so it gets its own assertion rather than riding on another test.
timeout_case 500 "no config at all → the 500s built-in default" \
  PR_RELAY_CONFIG=/dev/null SHIP_FEATURE_CONFIG=/dev/null

# 6. An EMPTY value means "not set", not "disable" — the model-pin contract, not the REVIEWERS one.
# With ${VAR+x} semantics an empty export would block the file it came from while the shared-file
# flag still filled from AGENT_TIMEOUT, silently deleting a rung. Neither of these can be reached
# by the non-empty fixtures above.
timeout_case 470 "an empty SHIP_FEATURE_PLAN_TIMEOUT does not block the shared file" \
  PR_RELAY_CONFIG="$CFGDIR/shared-t1" SHIP_FEATURE_CONFIG=/dev/null SHIP_FEATURE_PLAN_TIMEOUT=
timeout_case 470 "an empty PR_RELAY_AGENT_TIMEOUT does not block the shared file" \
  PR_RELAY_CONFIG="$CFGDIR/shared-t1" SHIP_FEATURE_CONFIG=/dev/null PR_RELAY_AGENT_TIMEOUT=

# 7. LAST value wins inside the shared file. ship-feature reads it with the relay's own parser now,
# so this holds by construction; the test keeps it true if the two ever split again:
# one valid file, two timeouts.
printf 'AGENT_TIMEOUT=430\nAGENT_TIMEOUT=440\n' >"$CFGDIR/shared-t2"
timeout_case 440 "the last AGENT_TIMEOUT in the shared file wins" \
  PR_RELAY_CONFIG="$CFGDIR/shared-t2" SHIP_FEATURE_CONFIG=/dev/null

# 8. A bad value from the SHARED FILE is rejected exactly like a bad environment value — validation
# happens after resolution, so there is no path that skips it. `timeout 0` DISABLES the limit rather
# than tightening it, which is why zero is refused rather than clamped.
printf 'AGENT_TIMEOUT=nonsense\n' >"$CFGDIR/shared-t3"
(printf 'p\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-t3" SHIP_FEATURE_CONFIG=/dev/null \
  bash "$CLI" plan-review --reviewers codex >/dev/null 2>&1)
check "a non-numeric AGENT_TIMEOUT in the shared file is rejected" $? 1
printf 'AGENT_TIMEOUT=0\n' >"$CFGDIR/shared-t4"
(printf 'p\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-t4" SHIP_FEATURE_CONFIG=/dev/null \
  bash "$CLI" plan-review --reviewers codex >/dev/null 2>&1)
check "a zero AGENT_TIMEOUT in the shared file is rejected" $? 1

# 9. The mapping must NOT cross into the pr-review-relay child. The relay reads this same file
# itself, so an exported value from here would beat its own config — the failure MODEL_opencode's
# test guards against, in a second form. Includes the case a plain assignment does NOT fix: a
# caller that already EXPORTED the name, where the export attribute survives the assignment.
printf 'AGENT_TIMEOUT=470\n' >"$CFGDIR/shared-t5"
printf '#!/usr/bin/env bash\necho "RELAYENV SF=${SHIP_FEATURE_PLAN_TIMEOUT:-unset} PR=${PR_RELAY_AGENT_TIMEOUT:-unset}"\nexit 0\n' >"$BIN/pr-review-relay.tmo"
chmod +x "$BIN/pr-review-relay.tmo"
cp "$BIN/pr-review-relay" "$WORK/relay-stub-backup-tmo"
cp "$BIN/pr-review-relay.tmo" "$BIN/pr-review-relay"
tmo1=$(PATH="$BIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-t5" SHIP_FEATURE_CONFIG=/dev/null bash "$CLI" relay --author claude 2>/dev/null)
tmo2=$(PATH="$BIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-t5" SHIP_FEATURE_CONFIG=/dev/null SHIP_FEATURE_PLAN_TIMEOUT='' bash "$CLI" relay --author claude 2>/dev/null)
cp "$WORK/relay-stub-backup-tmo" "$BIN/pr-review-relay"
chmod +x "$BIN/pr-review-relay"
printf '%s' "$tmo1" | grep -q 'SF=unset PR=unset' &&
  {
    echo "  ok   [-] the mapped timeout is not exported into pr-review-relay"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL ship-feature pushed a timeout at the relay: $tmo1"
    FAIL=$((FAIL + 1))
  }
printf '%s' "$tmo2" | grep -q 'SF=unset' &&
  {
    echo "  ok   [-] an already-exported name does not carry the mapped value into the child"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the export attribute survived and leaked 470 into the relay: $tmo2"
    FAIL=$((FAIL + 1))
  }
# BOTH assigning sites, not just the shared-file one. The first draft of this change put `export -n`
# on load_shared_panel_config and missed the identical trap in load_config, and the test above could
# not see it: it only ever exercised the shared-config path. Cross-review caught it as a Blocker and
# it reproduced exactly — `export SHIP_FEATURE_PLAN_TIMEOUT=` plus a value in ship-feature's own
# config put SF=420 in the child's environment. Two assignments, two chances to leak, two tests.
printf 'SHIP_FEATURE_PLAN_TIMEOUT=420\n' >"$CFGDIR/own-t2"
cp "$BIN/pr-review-relay" "$WORK/relay-stub-backup-tmo3"
cp "$BIN/pr-review-relay.tmo" "$BIN/pr-review-relay"
tmo3=$(PATH="$BIN:$PATH" PR_RELAY_CONFIG=/dev/null SHIP_FEATURE_CONFIG="$CFGDIR/own-t2" SHIP_FEATURE_PLAN_TIMEOUT='' bash "$CLI" relay --author claude 2>/dev/null)
cp "$WORK/relay-stub-backup-tmo3" "$BIN/pr-review-relay"
chmod +x "$BIN/pr-review-relay"
printf '%s' "$tmo3" | grep -q 'SF=unset' &&
  {
    echo "  ok   [-] ship-feature's OWN config does not leak the timeout into the child either"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL load_config's assignment kept the export attribute and leaked into the relay: $tmo3"
    FAIL=$((FAIL + 1))
  }

# grok: Grok 4.6 at medium effort by default (the relay's default for the same seat), prompt-file (not stdin), read-only ALLOWLIST, runs in the
# checkout so it can verify the plan against the code (parity with claude/codex/cursor).
out=$(printf 'UNIQUE_PLAN_TOKEN_42\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_FORCE_SANDBOX_PROBE=ok bash "$CLI" plan-review --reviewers grok 2>/dev/null)
rc=$?
check "plan-review grok clean exit" "$rc" 0
printf '%s' "$out" | grep -q -- '-m grok-4.6' && printf '%s' "$out" | grep -q -- '--reasoning-effort medium' &&
  printf '%s' "$out" | grep -q -- '--permission-mode plan' && printf '%s' "$out" | grep -q -- '--sandbox read-only' &&
  printf '%s' "$out" | grep -qF -- '--tools read_file,list_dir,grep' && printf '%s' "$out" | grep -q -- '--verbatim' &&
  printf '%s' "$out" | grep -qF -- '--disallowed-tools search_tool,use_tool' &&
  printf '%s' "$out" | grep -q -- '--prompt-file' &&
  {
    echo "  ok   [-] grok argv pins model/medium/plan/sandbox/tools-allowlist/mcp-off/verbatim/prompt-file"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL grok argv incomplete"
    FAIL=$((FAIL + 1))
  }
# Read-only means: no shell, no editor, no subagents in the built-in allowlist. Asserted on the
# ARGV LINE ONLY — grepping the whole output would false-fail on a plan that merely mentions one
# of these names, since the stub echoes the plan back.
gargv=$(printf '%s' "$out" | grep 'REVIEW-grok' | head -1 | sed -n 's/.*argv=\[\([^]]*\)\].*/\1/p')
printf '%s' "$gargv" | grep -qE -- '(run_terminal_command|search_replace|spawn_subagent|scheduler_)' &&
  {
    echo "  FAIL grok allowlist leaks a write/exec tool"
    FAIL=$((FAIL + 1))
  } ||
  {
    echo "  ok   [-] grok allowlist excludes shell/editor/subagent tools"
    PASS=$((PASS + 1))
  }
# The MCP bridge survives --tools, so it must be removed explicitly. Verified against the real
# CLI: with `--tools read_file` alone the session still exposes search_tool and use_tool.
printf '%s' "$gargv" | grep -qF -- '--disallowed-tools search_tool,use_tool' &&
  {
    echo "  ok   [-] grok removes the MCP bridge explicitly"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL grok leaves the MCP bridge reachable"
    FAIL=$((FAIL + 1))
  }
printf '%s' "$out" | grep -q 'UNIQUE_PLAN_TOKEN_42' && printf '%s' "$out" | grep -qF -- '--- PLAN ---' &&
  {
    echo "  ok   [-] grok prompt-file contains the plan text"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL grok prompt-file missing plan content"
    FAIL=$((FAIL + 1))
  }
# Runs in the caller's checkout (no --cwd override, no iso- temp dir): that is what lets it read
# the tree the plan is about.
gk=$(printf '%s' "$out" | grep 'REVIEW-grok' | head -1)
gcwd=$(printf '%s' "$gk" | sed -n 's/.*CWD=\[\([^]]*\)\].*/\1/p')
printf '%s' "$out" | grep -q -- '--cwd ' &&
  {
    echo "  FAIL grok still pins --cwd (should inherit the checkout)"
    FAIL=$((FAIL + 1))
  } ||
  {
    echo "  ok   [-] grok does not override cwd"
    PASS=$((PASS + 1))
  }
case "$gcwd" in
  *iso-grok*)
    echo "  FAIL grok still runs in an isolated cwd ($gcwd)"
    FAIL=$((FAIL + 1))
    ;;
  "$PWD")
    echo "  ok   [-] grok inherits the caller's cwd (the checkout, in real use)"
    PASS=$((PASS + 1))
    ;;
  *)
    echo "  FAIL grok cwd is neither the caller's nor recognised ($gcwd)"
    FAIL=$((FAIL + 1))
    ;;
esac
# The prompt-file must never land inside the checkout, or it shows up in `git status`.
printf '%s' "$out" | grep -qF -- "--prompt-file $PWD/" &&
  {
    echo "  FAIL grok prompt-file written inside the checkout"
    FAIL=$((FAIL + 1))
  } ||
  {
    echo "  ok   [-] grok prompt-file lives outside the checkout"
    PASS=$((PASS + 1))
  }
# A sandbox that warns and continues must FAIL the round, not pass it. This is the fail-open
# shape: grok exits 0 with a perfectly good review on stdout, while stderr says the OS write
# barrier could not be set up. Before this guard the round was reported clean.
cat >"$PBIN/grok" <<'STUB'
#!/usr/bin/env bash
echo "warning: failed to set up sandbox (bubblewrap not available), continuing unsandboxed" >&2
echo "REVIEW-grok argv=[$*] CWD=[${PWD}]"
echo "## Blocker"
echo "None."
exit 0
STUB
chmod +x "$PBIN/grok"
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_FORCE_SANDBOX_PROBE=ok bash "$CLI" plan-review --reviewers grok 2>&1)
rc=$?
check "plan-review fails when the sandbox warns and continues (fail-closed)" "$rc" 3
printf '%s' "$out" | grep -qi 'sandbox was not enforced' &&
  {
    echo "  ok   [-] grok sandbox fail-open is reported, not swallowed"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL sandbox fail-open not surfaced"
    FAIL=$((FAIL + 1))
  }
printf '%s' "$out" | grep -q '## Blocker' &&
  {
    echo "  FAIL unsandboxed review was printed as a valid review"
    FAIL=$((FAIL + 1))
  } ||
  {
    echo "  ok   [-] the unsandboxed review is discarded, not printed"
    PASS=$((PASS + 1))
  }
# ...but a benign stderr mentioning "namespace" or "sandbox" must NOT discard a good review.
# The match keys off failure phrasing; a bare token would train people to ignore this signal.
cat >"$PBIN/grok" <<'STUB'
#!/usr/bin/env bash
echo "info: sandbox profile read-only applied; namespace ready" >&2
echo "REVIEW-grok argv=[$*] CWD=[${PWD}]"
echo "Looks good."
exit 0
STUB
chmod +x "$PBIN/grok"
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_FORCE_SANDBOX_PROBE=ok bash "$CLI" plan-review --reviewers grok 2>&1)
rc=$?
check "plan-review keeps the review when stderr mentions the sandbox benignly" "$rc" 0
printf '%s' "$out" | grep -q 'REVIEW-grok' &&
  {
    echo "  ok   [-] benign sandbox log does not discard the review"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL benign sandbox log false-failed the round"
    FAIL=$((FAIL + 1))
  }
make_reviewer grok 0 grok # restore

# When the OS sandbox cannot be enforced, grok DEGRADES to the old isolated posture —
# text-only review, no checkout — instead of refusing, and says so above the review. Refusing would
# make the reviewer unusable on any Linux without bubblewrap (CI runners included); running it in the
# checkout unsandboxed is the one thing we must never do.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_FORCE_SANDBOX_PROBE=fail bash "$CLI" plan-review --reviewers grok 2>&1)
rc=$?
check "plan-review still returns a review when the sandbox is unavailable" "$rc" 0
printf '%s' "$out" | grep -qi 'saw the plan text ONLY' &&
  {
    echo "  ok   [-] degraded grok review is labelled text-only"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL degraded review not labelled"
    FAIL=$((FAIL + 1))
  }
dg=$(printf '%s' "$out" | grep 'REVIEW-grok' | head -1)
printf '%s' "$dg" | grep -qF -- "--deny *" && ! printf '%s' "$dg" | grep -qF -- '--tools read_file' &&
  {
    echo "  ok   [-] degraded grok denies every tool"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL degraded grok did not fall back to deny-all"
    FAIL=$((FAIL + 1))
  }
printf '%s' "$dg" | grep -qF -- '-m grok-4.6 --reasoning-effort medium ' &&
  {
    echo "  ok   [-] degraded grok pins the default model and effort too"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL degraded grok did not pin -m grok-4.6 --reasoning-effort medium"
    FAIL=$((FAIL + 1))
  }
dcwd=$(printf '%s' "$dg" | sed -n 's/.*CWD=\[\([^]]*\)\].*/\1/p')
case "$dcwd" in
  *iso-grok*)
    echo "  ok   [-] degraded grok runs outside the checkout"
    PASS=$((PASS + 1))
    ;;
  *)
    echo "  FAIL degraded grok ran in $dcwd"
    FAIL=$((FAIL + 1))
    ;;
esac

# The pins must reach the degraded path too — not just the normal one, since a pin that silently
# reverts to the default the moment the sandbox is unavailable would be a surprise no one asked for.
# From the SHARED file here, the way this machine actually sets them.
printf 'MODEL_grok=grok-4.7\nEFFORT_grok=low\n' >"$CFGDIR/shared-grok-dg"
dgo=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_FORCE_SANDBOX_PROBE=fail PR_RELAY_CONFIG="$CFGDIR/shared-grok-dg" bash "$CLI" plan-review --reviewers grok 2>&1 | grep 'REVIEW-grok')
printf '%s' "$dgo" | grep -qF -- '-m grok-4.7 --reasoning-effort low ' &&
  {
    echo "  ok   [-] MODEL_grok / EFFORT_grok reach the degraded path too"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the grok pins were ignored on the degraded path: $dgo"
    FAIL=$((FAIL + 1))
  }

# bare grok is a plan-review seat since 2026-09 (it was relay-only while plan-review ran a separate
# `grok45high` seat). Exit 0 alone proves nothing here — codex would keep the round alive either
# way — so assert grok actually RAN and was not skipped.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers grok,codex 2>&1)
rc=$?
check "plan-review runs bare grok alongside codex" "$rc" 0
printf '%s' "$out" | grep -q 'REVIEW-grok' && ! printf '%s' "$out" | grep -qi "grok.*relay-only" &&
  {
    echo "  ok   [-] plan-review runs bare grok instead of skipping it"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL bare grok was skipped as relay-only"
    FAIL=$((FAIL + 1))
  }
# `grok45high` is the old name: it runs grok, ONCE, with ONE warning — even named twice, and even
# alongside `grok`. The warning has its own guard; collapsing before the de-dupe alone would warn
# twice for `grok45high,grok45high`.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_FORCE_SANDBOX_PROBE=ok bash "$CLI" plan-review --reviewers grok45high,grok,grok45high 2>&1)
rc=$?
check "plan-review accepts the grok45high alias" "$rc" 0
[ "$(printf '%s' "$out" | grep -c 'REVIEW-grok')" = 1 ] &&
  [ "$(printf '%s' "$out" | grep -c "'grok45high' is the old name")" = 1 ] &&
  {
    echo "  ok   [-] grok45high collapses to one grok run with one warning"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL grok45high alias ran grok more than once or warned more than once: $out"
    FAIL=$((FAIL + 1))
  }
# missing grok binary fails closed when grok named — curated PATH so a system
# `grok` cannot mask the miss (same pattern as the missing-gemini test).
rm -f "$PBIN/grok"
MPATH="$PBIN"
for b in bash cat printf timeout gtimeout mktemp tr sed head tail wc rm mkdir chmod; do
  src=$(command -v "$b" 2>/dev/null) || continue
  [ -x "$src" ] || continue
  ln -sf "$src" "$PBIN/$b" 2>/dev/null || true
done
(printf 'plan\n' | PATH="$MPATH" bash "$CLI" plan-review --reviewers grok >/dev/null 2>&1)
check "plan-review missing grok binary → fail (3)" $? 3
make_reviewer grok 0 grok # restore

# --- an answer that is not a review fails the round (the relay's gate, relay/lib-panel.sh) -------
# Any text at all used to count as a seat's verdict. Two shapes from real runs: no verdict at all,
# and a verdict followed by "still reading". Each must exit 3, be labelled, and never appear under
# the "(plan review)" banner, where the reader would take it for a review.
gate_case() { # <label> <body> <expected label text>
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\nexit 0\n' "$2" >"$PBIN/claude"
  chmod +x "$PBIN/claude"
  out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude 2>&1)
  check "$1" "$?|$(printf '%s' "$out" | grep -c "$3")|$(printf '%s' "$out" | grep -cF "│ $2")|$(printf '%s' "$out" | grep -c 'Claude (plan review)')" "3|1|1|0"
}
gate_case "plan-review: an answer with no verdict fails the round (3)" \
  "Reading the plan before reviewing." "names no severity"
gate_case "plan-review: a verdict followed by more reading fails the round (3)" \
  "Blocker: none in the first half. Let me read the rest before concluding." "still reading"
# The accept side, not only "Looks good.": a review that names a severity passes, and reading
# mentioned EARLIER in the answer is fine while the answer ends on a finding.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\nexit 0\n' $'I read the plan twice before I wrote this.\nShould-fix: the rollback step has no owner.' >"$PBIN/claude"
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude 2>&1)
check "plan-review: a review that names a severity passes the gate (0), under the banner" \
  "$?|$(printf '%s' "$out" | grep -c 'Claude (plan review)')|$(printf '%s' "$out" | grep -c 'rollback step has no owner')" "0|1|1"
make_reviewer claude 0 claude # restore
printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude >/dev/null 2>&1
check "plan-review: the restored claude stub, which says it looks good, passes the gate (0)" $? 0

# --- pi seats: pi_glm and pi_grok, one `pi` binary with a model each ---------------------------
# The panel runs both seats in parallel, so the stub keeps its records PER SEAT, keyed from its
# --model value: split on / and -, exactly one part must be `glm` or `grok`. Any other value prints
# STUB-PI-AMBIGUOUS-MODEL and exits 9, so a test that picks a bad pin value fails loudly instead of
# writing the other seat's record. Every model value below has exactly one of those parts.
#
# The json stream is built with node and JSON.stringify, so the text it carries is escaped. The
# seat itself needs node to read the stream, so these cases need a real node too, and do not skip
# without one: a runner with no node fails here, which is the loud outcome.
PIREC="$WORK/pi-rec"
mkdir -p "$PIREC"
write_pi_stub() {
  {
    printf '#!/usr/bin/env bash\nREC=%q\n' "$PIREC"
    cat <<'PISTUB'
model="" prev=""
for a in "$@"; do
  [ "$prev" = "--model" ] && model="$a"
  prev="$a"
done
seat="" n=0
set -f
for part in $(printf '%s' "$model" | tr '/-' '  '); do
  case "$part" in glm) seat=pi_glm n=$((n + 1)) ;; grok) seat=pi_grok n=$((n + 1)) ;; esac
done
set +f
if [ "$n" != 1 ]; then
  echo "STUB-PI-AMBIGUOUS-MODEL model=[$model]"
  exit 9
fi
echo run >>"$REC/$seat.ran"
printf '%s\n' "$@" >"$REC/$seat.argv"
printf '%s\n' "$PWD" >"$REC/$seat.cwd"
command -v node >"$REC/$seat.node"
cat >"$REC/$seat.stdin"
mode="${STUB_PI_MODE:-ok}"
if [ "$mode" = hang ]; then
  # A child that inherits stdout holds the pipe open: only a kill of the whole process group
  # lets the reader see the end of its input.
  sleep 60 &
  sleep 60
  exit 0
fi
node -e '
const [mode, model] = process.argv.slice(1);
const out = (o) => process.stdout.write(JSON.stringify(o) + "\n");
const end = (stopReason, text, extra) =>
  out({ type: "message_end", message: Object.assign({ role: "assistant", stopReason,
    content: text === null ? [] : [{ type: "text", text }], usage: { output: 7 } }, extra || {}) });
const ok = () => {
  out({ type: "session", version: 3 });
  end("toolUse", "THINKING-TEXT");
  out({ type: "tool_execution_end", toolName: "read" });
  end("stop", "REVIEW-pi-" + model + "\nThe plan is sound. Looks good.");
};
switch (mode) {
  case "garbage": process.stdout.write("not json\n{\"broken\n"); ok(); process.stdout.write("trailing text\n"); break;
  case "length": case "length1": end("length", null); break;
  case "error": end("error", null, { errorMessage: "quota exceeded\nfor test" }); break;
  case "blank": end("stop", "  \n\t "); break;
  case "none": out({ type: "session", version: 3 }); out({ type: "message_end", message: { role: "user", content: [] } }); break;
  default: ok();
}' "$mode" "$model"
case "$mode" in length1) exit 1 ;; exit124) exit 124 ;; esac
exit 0
PISTUB
  } >"$PBIN/pi"
  chmod +x "$PBIN/pi"
  # The seat needs a node that meets pi's floor (relay/lib-pi.sh PI_NODE_MIN), and the runner's own
  # node may be older: one that reports 22.19.0 and runs the real one.
  pi_node_wrapper "$PBIN" 22.19.0
}
REAL_NODE="$(command -v node)"
pi_node_wrapper() { # <dir> <version>: answers the resolver's -p probe with <version> and itself,
  # runs the real node for anything else. The rm: a redirect would write through a symlink to node.
  mkdir -p "$1"
  rm -f "$1/node"
  printf '#!/bin/sh\n[ "$1" = -p ] && { echo "v%s $0"; exit 0; }\nexec "%s" "$@"\n' "$2" "$REAL_NODE" >"$1/node"
  chmod +x "$1/node"
}
write_pi_stub
pi_clear() { rm -f "${PIREC:?}"/*; }
# The word after <flag> in a seat's recorded argv (one word per line).
pi_arg() { awk -v f="$2" 'p { print; exit } $0 == f { p = 1 }' "$PIREC/$1.argv" 2>/dev/null; }
pi_ran() { [ -s "$PIREC/$1.ran" ] && echo yes || echo no; }

# T.1-T.5: a clean panel of both seats, with nothing pinned.
pi_clear
printf 'Step 1: X\nMAGICPIPLANTOKEN\nStep 2: Y\n' >"$WORK/pi-plan.md"
pout=$(PATH="$PBIN:$PATH" bash "$CLI" plan-review "$WORK/pi-plan.md" --reviewers pi_glm,pi_grok 2>&1)
check "pi: a pi_glm,pi_grok panel exits 0" "$?" 0
check "pi: both banners and both reviews are printed" \
  "$(printf '%s' "$pout" | grep -c -e 'Pi_glm (plan review)' -e 'Pi_grok (plan review)' -e 'REVIEW-pi-zai/glm-5.3' -e 'REVIEW-pi-xai/grok-4.7')" 4
# The reader prints only the FINAL assistant message: the text of a turn that ended in a tool call
# is the model thinking aloud, not the review.
check "pi: text from a tool-call turn is not printed" "$(printf '%s' "$pout" | grep -c 'THINKING-TEXT')" 0
for s in pi_glm pi_grok; do
  # Read-only by allowlist: the VALUE of --tools, not a substring, so no bash/edit/write rides along.
  check "pi: $s runs -p --mode json --tools read,grep,find,ls" \
    "$(grep -Fxc -- -p "$PIREC/$s.argv")|$(pi_arg $s --mode)|$(pi_arg $s --tools)" "1|json|read,grep,find,ls"
  _miss=""
  for f in --no-extensions --no-mcp --no-skills --no-prompt-templates --no-themes --no-context-files --no-approve --no-session --offline; do
    grep -Fxq -- "$f" "$PIREC/$s.argv" || _miss="$_miss $f"
  done
  check "pi: $s carries every --no-* flag and --offline${_miss:+ (missing:$_miss)}" "${_miss:-none}" none
  # Whole-word match: --no-approve contains the same characters.
  check "pi: $s never passes --approve" "$(grep -Fxc -- --approve "$PIREC/$s.argv")" 0
  check "pi: $s runs in the checkout" "$(cat "$PIREC/$s.cwd" 2>/dev/null)" "$PWD"
  # The plan is framed on both sides, so its text cannot run on into instructions.
  check "pi: $s gets the prompt and the framed plan on stdin" "$(awk '
    /^You are reviewing/ && !a { a = NR } $0 == "--- PLAN ---" && !b { b = NR } $0 == "~~~~plan" && !c { c = NR }
    /MAGICPIPLANTOKEN/ && !d { d = NR } $0 == "--- END PLAN ---" { e = NR }
    END { print (a && a < b && b < c && c < d && d < e) ? "framed" : "not framed" }' "$PIREC/$s.stdin")" framed
done
check "pi: the defaults are the relay's (glm-5.3 / grok-4.7, both at low)" \
  "$(pi_arg pi_glm --model) $(pi_arg pi_glm --thinking) $(pi_arg pi_grok --model) $(pi_arg pi_grok --thinking)" \
  "zai/glm-5.3 low xai/grok-4.7 low"
check "pi: the dispatch line shows both seats' pins" \
  "$(printf '%s' "$pout" | grep -c -e '→ pi_glm reviewing… (model=zai/glm-5.3, effort=low)' -e '→ pi_grok reviewing… (model=xai/grok-4.7, effort=low)')" 2

# T.6: the reader, one row per stream shape. pi's own non-zero status wins over the reader's.
pi_row() { # pi_row <mode> → "<rc>" and the combined output in $prow
  pi_clear
  prow=$(printf 'plan\n' | PATH="$PBIN:$PATH" STUB_PI_MODE="$1" bash "$CLI" plan-review --reviewers pi_glm 2>&1)
}
pi_row garbage
check "pi reader: non-JSON lines around the stream are skipped" "$?|$(printf '%s' "$prow" | grep -c 'REVIEW-pi-zai/glm-5.3')" "0|1"
pi_row length
check "pi reader: a cut-off with pi exit 0 is no review, and says stopReason=length" "$?|$(printf '%s' "$prow" | grep -c 'stopReason=length')" "3|1"
pi_row length1
check "pi reader: a cut-off with pi exit 1 reports pi's code and the reader's reason" \
  "$?|$(printf '%s' "$prow" | grep -c -e 'exited with code 1' -e 'stopReason=length')" "3|2"
pi_row error
check "pi reader: a provider error carries its message, on one line" "$?|$(printf '%s' "$prow" | grep -c 'stopReason=error.*quota exceeded for test')" "3|1"
pi_row blank
check "pi reader: a whitespace-only final text is no review" "$?|$(printf '%s' "$prow" | grep -c 'stopReason=stop')" "3|1"
pi_row none
check "pi reader: a stream with no final assistant message is no review" "$?|$(printf '%s' "$prow" | grep -c 'ended without a final assistant message')" "3|1"
pi_row exit124
check "pi reader: pi's 124 wins over a printed review, and reads as a timeout" "$?|$(printf '%s' "$prow" | grep -c 'pi_glm: timed out after')" "3|1"
# A tool child that holds the pipe must not hold the round past the timeout. Needs a timeout binary:
# without one no plan seat has a limit, and this seat follows that rule.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  pi_clear
  _t0=$(date +%s)
  prow=$(printf 'plan\n' | PATH="$PBIN:$PATH" STUB_PI_MODE=hang SHIP_FEATURE_PLAN_TIMEOUT=3 bash "$CLI" plan-review --reviewers pi_glm 2>&1)
  _rc=$?
  _el=$(($(date +%s) - _t0))
  check "pi: a pipe held by a tool child ends at the timeout (rc|diag|under 15 s)" \
    "$_rc|$(printf '%s' "$prow" | grep -c 'timed out after 3s')|$([ "$_el" -lt 15 ] && echo fast || echo "slow ${_el}s")" "3|1|fast"
else
  echo "  ok   [-] pi hang test skipped (no timeout or gtimeout)"
  PASS=$((PASS + 1))
fi

# T.7: no node → the seat refuses before pi starts. $PBIN alone is the curated PATH of the
# missing-grok test above: the tools the CLI needs, the stubs, and no node.
# MISE_DATA_DIR: the seat also looks for mise's Nodes, and this machine's must not count.
pi_clear
rm -f "$PBIN/node"
mkdir -p "$WORK/no-mise"
prow=$(printf 'plan\n' | PATH="$PBIN" MISE_DATA_DIR="$WORK/no-mise" bash "$CLI" plan-review --reviewers pi_glm 2>&1)
check "pi: no node → exit 3, says so, and pi never starts" \
  "$?|$(printf '%s' "$prow" | grep -c "pi_glm: node not found")|$(pi_ran pi_glm)" "3|1|no"
pi_node_wrapper "$PBIN" 22.19.0 # restore
# T.7a: a repo pinned to an old Node puts it first on PATH, and pi runs through `env node`: pi 1.2.0
# on Node 20 died at startup with a SyntaxError. The seat runs pi on a node that meets the floor.
pi_node_wrapper "$WORK/pinned-node" 20.20.2
pi_node_wrapper "$WORK/pi-mise/installs/node/24.11.0/bin" 24.11.0
pi_clear
prow=$(printf 'plan\n' | PATH="$WORK/pinned-node:$PBIN:$PATH" MISE_DATA_DIR="$WORK/pi-mise" bash "$CLI" plan-review --reviewers pi_glm 2>&1)
check "pi: a pinned Node 20 first on PATH → pi runs on the mise Node that meets the floor" \
  "$?|$(cat "$PIREC/pi_glm.node" 2>/dev/null)" "0|$WORK/pi-mise/installs/node/24.11.0/bin/node"
pi_clear
prow=$(printf 'plan\n' | PATH="$WORK/pinned-node:$PBIN:$PATH" MISE_DATA_DIR="$WORK/no-mise" bash "$CLI" plan-review --reviewers pi_glm 2>&1)
check "pi: no node meets the floor → exit 3, the versions named, pi never starts" \
  "$?|$(printf '%s' "$prow" | grep -c "pi_glm: needs Node >= 22.19.0 (pi's engines field), outside the repository under review; found: 20.20.2")|$(pi_ran pi_glm)" "3|1|no"
# T.7b: no pi → the quorum rule fails the round, as for every seat.
rm -f "$PBIN/pi"
prow=$(printf 'plan\n' | PATH="$PBIN" bash "$CLI" plan-review --reviewers pi_grok 2>&1)
check "pi: no pi binary → exit 3 (pi not installed)" "$?|$(printf '%s' "$prow" | grep -c 'pi not installed (required by the panel)')" "3|1"
write_pi_stub # restore

# T.8: the pins. The shared file pins one value per seat; the other value keeps its default.
printf 'MODEL_pi_glm=pin-glm-m1\nEFFORT_pi_grok=high\n' >"$CFGDIR/shared-pi"
pi_clear
prow=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-pi" bash "$CLI" plan-review --reviewers pi_glm,pi_grok 2>&1)
check "pi: MODEL_pi_glm / EFFORT_pi_grok in the shared file reach each seat's argv" \
  "$(pi_arg pi_glm --model) $(pi_arg pi_glm --thinking) $(pi_arg pi_grok --model) $(pi_arg pi_grok --thinking)" \
  "pin-glm-m1 low xai/grok-4.7 high"
check "pi: the dispatch line shows the pinned values" \
  "$(printf '%s' "$prow" | grep -c -e '→ pi_glm reviewing… (model=pin-glm-m1, effort=low)' -e '→ pi_grok reviewing… (model=xai/grok-4.7, effort=high)')" 2
pi_clear
printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-pi" PI_GLM_REVIEW_MODEL=pin-glm-env bash "$CLI" plan-review --reviewers pi_glm >/dev/null 2>&1
check "pi: PI_GLM_REVIEW_MODEL in the environment beats MODEL_pi_glm" "$(pi_arg pi_glm --model)" pin-glm-env
# The flags are per pin. The file pins all four; each run sets ONE in the environment, so a flag
# wired to the wrong pin shows as a default or a file value where the other value belongs.
printf 'MODEL_pi_glm=pin-glm-f\nEFFORT_pi_glm=minimal\nMODEL_pi_grok=pin-grok-f\nEFFORT_pi_grok=high\n' >"$CFGDIR/shared-pi4"
for _pin in PI_GLM_REVIEW_MODEL=pin-glm-e PI_GLM_REVIEW_EFFORT=medium PI_GROK_REVIEW_MODEL=pin-grok-e PI_GROK_REVIEW_EFFORT=xhigh; do
  case "$_pin" in
    PI_GLM_REVIEW_MODEL=*) _want="pin-glm-e minimal pin-grok-f high" ;;
    PI_GLM_REVIEW_EFFORT=*) _want="pin-glm-f medium pin-grok-f high" ;;
    PI_GROK_REVIEW_MODEL=*) _want="pin-glm-f minimal pin-grok-e high" ;;
    PI_GROK_REVIEW_EFFORT=*) _want="pin-glm-f minimal pin-grok-f xhigh" ;;
    *) _want="no expectation for $_pin" ;;
  esac
  pi_clear
  prow=$(
    export "${_pin?}"
    printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-pi4" bash "$CLI" plan-review --reviewers pi_glm,pi_grok 2>&1
  )
  check "pi: ${_pin%%=*} in the environment beats the file; the other three pins come from the file" \
    "$?|$(pi_arg pi_glm --model) $(pi_arg pi_glm --thinking) $(pi_arg pi_grok --model) $(pi_arg pi_grok --thinking)" "0|$_want"
done
# Exported EMPTY is not set: each arming line tests ${VAR:-}, not ${VAR+x}, so the file still wins.
pi_clear
prow=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-pi4" PI_GLM_REVIEW_MODEL='' PI_GLM_REVIEW_EFFORT='' PI_GROK_REVIEW_MODEL='' PI_GROK_REVIEW_EFFORT='' bash "$CLI" plan-review --reviewers pi_glm,pi_grok 2>&1)
check "pi: the four pins exported EMPTY do not block the shared file" \
  "$?|$(pi_arg pi_glm --model) $(pi_arg pi_glm --thinking) $(pi_arg pi_grok --model) $(pi_arg pi_grok --thinking)" "0|pin-glm-f minimal pin-grok-f high"
printf 'PI_GROK_REVIEW_EFFORT=max\n' >"$CFGDIR/own-pi"
pi_clear
prow=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/own-pi" bash "$CLI" plan-review --reviewers pi_grok 2>&1)
check "pi: PI_GROK_REVIEW_EFFORT in ship-feature's own config is reported and ignored" \
  "$(printf '%s' "$prow" | grep -c "PI_GROK_REVIEW_EFFORT is set in ship-feature's config and is IGNORED there")|$(pi_arg pi_grok --thinking)" "1|low"

# T.9: the effort check is an exact list. pi does not refuse a level it does not know, so a value
# that passed as a PATTERN here would run at some other effort and report a clean review.
for v in 'low medium' 'medium high' '*' 'l?w' '?high' '[lm]ow' 'LOW'; do
  pi_clear
  prow=$(printf 'plan\n' | PATH="$PBIN:$PATH" PI_GLM_REVIEW_EFFORT="$v" bash "$CLI" plan-review --reviewers pi_glm 2>&1)
  check "pi: effort '$v' is refused before any seat starts" \
    "$?|$(printf '%s' "$prow" | grep -c 'Valid: off minimal low medium high xhigh max')|$(pi_ran pi_glm)" "1|1|no"
done
_levels=$(sed -n 's/^PI_EFFORT_LEVELS="\(.*\)"$/\1/p' "$HERE/../relay/lib-pi.sh")
_bad=""
for v in $_levels; do
  pi_clear
  printf 'plan\n' | PATH="$PBIN:$PATH" PI_GROK_REVIEW_EFFORT="$v" bash "$CLI" plan-review --reviewers pi_grok >/dev/null 2>&1 || _bad="$_bad $v(rc)"
  [ "$(pi_arg pi_grok --thinking)" = "$v" ] || _bad="$_bad $v(argv)"
done
check "pi: every level in PI_EFFORT_LEVELS (relay/lib-pi.sh) is accepted and reaches --thinking${_bad:+ (failed:$_bad)}" "${_levels:-empty}|${_bad:-none}" "off minimal low medium high xhigh max|none"
# The case arms and the list in the message must name the same words.
_arms=$(awk '/_pv="\$\{!_pi_e\}"/ { f = 1 } f && /\) ;;$/ { sub(/\) ;;$/, ""); gsub(/ \| /, " "); sub(/^ +/, ""); print; exit }' "$CLI")
check "pi: the effort case arms match PI_EFFORT_LEVELS (relay/lib-pi.sh)" "$_arms" "$_levels"
# T.10: a model that would be parsed as a flag.
prow=$(printf 'plan\n' | PATH="$PBIN:$PATH" PI_GROK_REVIEW_MODEL=-x bash "$CLI" plan-review --reviewers pi_grok 2>&1)
check "pi: a model starting with '-' is refused" "$?|$(printf '%s' "$prow" | grep -c "invalid PI_GROK_REVIEW_MODEL: '-x'")" "1|1"
# T.11: the de-dupe.
pi_clear
printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers pi_glm,pi_glm >/dev/null 2>&1
check "pi: pi_glm,pi_glm runs the seat once" "$?|$(wc -l <"$PIREC/pi_glm.ran" | tr -d '[:space:]')" "0|1"

# T.12b: only a pi seat ON THE PANEL has its pins checked, so a pin that a later pi makes valid
# cannot stop a review with no pi seat. The spaced panel proves the pre-pass trims like dispatch.
# (The unpinned case, which must resolve to `low` before the check, is the defaults check above.)
printf 'EFFORT_pi_grok=bogus\n' >"$CFGDIR/shared-pi-bogus"
(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-pi-bogus" bash "$CLI" plan-review --reviewers codex >/dev/null 2>&1)
check "pi: a bad pi pin does not stop a panel with no pi seat" $? 0
(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-pi-bogus" bash "$CLI" plan-review --reviewers pi_grok >/dev/null 2>&1)
check "pi: a bad pi pin stops a panel with that seat" $? 1
(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-pi-bogus" bash "$CLI" plan-review --reviewers 'codex, pi_grok' >/dev/null 2>&1)
check "pi: a bad pi pin stops a spaced panel with that seat" $? 1

# antigravity/gemini runs the `gemini` CLI in DEFAULT non-interactive mode (already excludes
# shell/edit/write_file/web_fetch) with `-e none` to disable extensions. It must NOT pass
# `--approval-mode plan` (throws unless experimental.plan is on) nor `yolo` (auto-approves writes).
# Set XDG_CONFIG_HOME so the assertion below can prove the run UNSETS it.
out=$(printf 'plan\n' | XDG_CONFIG_HOME=/tmp/xdg-should-be-unset PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
ag=$(printf '%s' "$out" | grep 'REVIEW-gemini')
printf '%s' "$ag" | grep -q -- "-e none" && {
  echo "  ok   [-] antigravity runs gemini with extensions off (-e none)"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL antigravity/gemini did not pass -e none"
  FAIL=$((FAIL + 1))
}
printf '%s' "$ag" | grep -q -- "-m gemini-3.1-pro-preview" && {
  echo "  ok   [-] antigravity pins a working model by default"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL antigravity/gemini did not pin the default model"
  FAIL=$((FAIL + 1))
}
printf '%s' "$ag" | grep -q -- "--approval-mode plan" && {
  echo "  FAIL gemini uses --approval-mode plan (throws without experimental.plan)"
  FAIL=$((FAIL + 1))
} || {
  echo "  ok   [-] antigravity avoids the experimental --approval-mode plan"
  PASS=$((PASS + 1))
}
printf '%s' "$ag" | grep -q -- "yolo" && {
  echo "  FAIL gemini uses the auto-approving yolo mode"
  FAIL=$((FAIL + 1))
} || {
  echo "  ok   [-] antigravity never uses yolo"
  PASS=$((PASS + 1))
}
# FAIL-CLOSED isolation: gemini must run from an isolated dir whose locked .gemini/settings.json
# hard-excludes the write tools and disables hooks, so a reviewed checkout's own config can't
# re-enable writes. The stub reports locked=yes only when that settings file is present in its CWD.
iso=$(printf '%s\n' "$out" | grep 'GEMINI-ISO')
printf '%s' "$iso" | grep -q -- "locked=yes" && {
  echo "  ok   [-] antigravity runs fail-closed (read-only tools.core allowlist, all write tools excluded, hooks off, no MCP)"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL antigravity/gemini not isolated with locked read-only settings"
  FAIL=$((FAIL + 1))
}
# GEMINI_CLI_HOME must be a SEPARATE dir from the workspace so the copied OAuth creds live outside it.
printf '%s' "$iso" | grep -q -- "homeiso=yes" && {
  echo "  ok   [-] antigravity isolates GEMINI_CLI_HOME separate from the workspace"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL antigravity/gemini did not separate GEMINI_CLI_HOME from the workspace"
  FAIL=$((FAIL + 1))
}
# No OAuth credential file may sit in the workspace tree (else the allowlisted read_file could disclose it).
printf '%s' "$iso" | grep -q -- "credsafe=yes" && {
  echo "  ok   [-] antigravity keeps OAuth creds out of the workspace"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL antigravity/gemini left OAuth creds reachable in the workspace"
  FAIL=$((FAIL + 1))
}
# XDG_CONFIG_HOME must be UNSET for the run (defence-in-depth against an XDG-honoring gemini).
printf '%s' "$iso" | grep -q -- "xdg=UNSET" && {
  echo "  ok   [-] antigravity unsets XDG_CONFIG_HOME for the run"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL antigravity/gemini did not unset XDG_CONFIG_HOME"
  FAIL=$((FAIL + 1))
}
# A controlled workspace .gemini/.env must halt gemini's ancestor .env walk (no hostile /tmp/.env).
printf '%s' "$iso" | grep -q -- "envstop=yes" && {
  echo "  ok   [-] antigravity plants a controlled .env (blocks ancestor .env injection)"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL antigravity/gemini did not block ancestor .env lookup"
  FAIL=$((FAIL + 1))
}
# The SYSTEM scope (highest precedence) + system-defaults must also be redirected under GEMINI_CLI_HOME,
# so /etc/gemini-cli or an inherited hostile GEMINI_CLI_SYSTEM_SETTINGS_PATH can't re-enable anything.
# NOTE the assumption this rests on: gemini merges its four settings scopes with SYSTEM at the
# highest precedence, which is why SYSTEM points at the locked file while SYSTEM_DEFAULTS is an
# empty {}. If a future release changed that merge order, every scope here would still be a file we
# control — but which one wins would change, and this assertion would not notice. Re-read the merge
# order when widening SHIP_FEATURE_GEMINI_TESTED_VERSIONS.
printf '%s' "$iso" | grep -q -- "sysiso=yes" && {
  echo "  ok   [-] antigravity isolates the SYSTEM settings scope too"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL antigravity/gemini did not isolate the system settings scope"
  FAIL=$((FAIL + 1))
}
# And it must NOT run in the caller's CWD (where a checkout's .gemini/ would live).
# grep -F: $PWD may contain regex metacharacters (e.g. a dotted TMPDIR), so match it as a literal.
printf '%s' "$iso" | grep -Fq -- "cwd=$PWD " && {
  echo "  FAIL antigravity/gemini ran in the caller CWD (checkout .gemini/ could load)"
  FAIL=$((FAIL + 1))
} || {
  echo "  ok   [-] antigravity/gemini ran outside the caller CWD"
  PASS=$((PASS + 1))
}

# agy and gemini are ALIASES of antigravity: the panel collapses them to a SINGLE gemini invocation.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers antigravity,agy,gemini 2>/dev/null)
rc=$?
check "plan-review dedupes antigravity/agy/gemini aliases (exit 0)" "$rc" 0
n=$(printf '%s\n' "$out" | grep -c 'REVIEW-gemini')
[ "$n" = 1 ] && {
  echo "  ok   [-] antigravity/agy/gemini collapse to one Gemini run"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL Gemini ran $n times for the three aliases (want 1)"
  FAIL=$((FAIL + 1))
}

# SHIP_FEATURE_GEMINI_MODEL overrides the pinned default and reaches the argv.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_GEMINI_MODEL=my-model bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
printf '%s' "$out" | grep 'REVIEW-gemini' | grep -q -- "-m my-model" && {
  echo "  ok   [-] SHIP_FEATURE_GEMINI_MODEL overrides the model"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL SHIP_FEATURE_GEMINI_MODEL did not reach gemini argv"
  FAIL=$((FAIL + 1))
}

# A model value starting with '-' must be rejected (can't be smuggled in as a gemini flag).
(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_GEMINI_MODEL=--dangerous bash "$CLI" plan-review --reviewers antigravity >/dev/null 2>&1)
check "plan-review rejects a model name starting with '-' (1)" $? 1

# --- the gemini seat's fail-closed VERSION GATE ------------------------------------------------
# `tools.core` is an allowlist but NOT a universal one: gemini registers some tools outside that
# filter (delegate_to_agent in v0.26.0), and for those only tools.exclude stands in the way. A
# release that registered another write-capable tool the same way would pass BOTH controls while the
# seat kept claiming it cannot write. There is no CLI call that dumps the active registry, so the
# seat refuses to run against a version nobody has audited. These cases are the tripwire's own test:
# without them the gate could be deleted and every other gemini assertion here would stay green.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" STUB_GEMINI_VERSION=9.99.0 bash "$CLI" plan-review --reviewers antigravity 2>&1)
rc=$?
check "plan-review fails the seat on an unaudited gemini version (3)" "$rc" 3
# The seat must fail BEFORE the review runs — a gate that reports a failure but still ran the tool
# is not a gate.
printf '%s' "$out" | grep -q 'REVIEW-gemini' && {
  echo "  FAIL gemini reviewed anyway on an unaudited version"
  FAIL=$((FAIL + 1))
} || {
  echo "  ok   [-] an unaudited gemini version never reaches the review"
  PASS=$((PASS + 1))
}
printf '%s' "$out" | grep -qi 'audited' && {
  echo "  ok   [-] the unaudited-version failure says why"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL the unaudited-version failure gave no reason"
  FAIL=$((FAIL + 1))
}
# Auditing a release and listing it opens the gate — for THAT release.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" STUB_GEMINI_VERSION=9.99.7 SHIP_FEATURE_GEMINI_TESTED_VERSIONS='0.26.0 9.99.7' bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
rc=$?
check "plan-review accepts a gemini version listed as audited (0)" "$rc" 0
printf '%s' "$out" | grep -q 'REVIEW-gemini' && {
  echo "  ok   [-] an audited gemini version runs the review"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL an audited gemini version still did not review"
  FAIL=$((FAIL + 1))
}
# The match is EXACT, not major.minor. A patch release can add a tool outside `tools.core` as easily
# as a minor one, and "9.99.8 is close enough to the 9.99.7 we read" is the assumption this gate
# exists to refuse. This case is the difference between a version gate and a version suggestion.
(printf 'plan\n' | PATH="$PBIN:$PATH" STUB_GEMINI_VERSION=9.99.8 SHIP_FEATURE_GEMINI_TESTED_VERSIONS='0.26.0 9.99.7' bash "$CLI" plan-review --reviewers antigravity >/dev/null 2>&1)
check "an unaudited PATCH release does not ride in on its neighbour (3)" $? 3
# A major.minor prefix is not a wildcard either.
(printf 'plan\n' | PATH="$PBIN:$PATH" STUB_GEMINI_VERSION=9.99.0 SHIP_FEATURE_GEMINI_TESTED_VERSIONS='9.99' bash "$CLI" plan-review --reviewers antigravity >/dev/null 2>&1)
check "a major.minor entry does not admit its patch releases (3)" $? 3
# The list is read from the config file too, not only the environment.
printf 'SHIP_FEATURE_GEMINI_TESTED_VERSIONS=9.99.0\n' >"$CFGDIR/gemver"
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" STUB_GEMINI_VERSION=9.99.0 SHIP_FEATURE_CONFIG="$CFGDIR/gemver" bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
rc=$?
check "the config file can widen the audited gemini versions (0)" "$rc" 0

# MODEL_gemini in the SHARED relay config pins this seat too — one file for the whole panel. The key
# is MODEL_gemini and not MODEL_antigravity on purpose: the relay maps MODEL_antigravity onto its own
# `agy` seat, a different binary that accepts different model ids.
printf 'MODEL_gemini=gemini-9.9-test\n' >"$CFGDIR/sharedgem"
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/sharedgem" bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
printf '%s' "$out" | grep 'REVIEW-gemini' | grep -q -- "-m gemini-9.9-test" && {
  echo "  ok   [-] MODEL_gemini in the shared config pins the gemini seat"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL MODEL_gemini was not mapped"
  FAIL=$((FAIL + 1))
}
# The environment still wins over the shared file, like every other pin.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/sharedgem" SHIP_FEATURE_GEMINI_MODEL=env-wins bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
printf '%s' "$out" | grep 'REVIEW-gemini' | grep -q -- "-m env-wins" && {
  echo "  ok   [-] the environment outranks MODEL_gemini"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL MODEL_gemini overrode the environment"
  FAIL=$((FAIL + 1))
}

# A CLI is free to print a banner around its version number. The gate fails CLOSED, so a fragile
# parse does not leak — it bricks the seat on a version that WAS audited, and the failure blames the
# gate rather than the parse. Assert the number is picked out of the noise.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" STUB_GEMINI_VERSION='gemini-cli version 0.26.0 (build deadbeef)' bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
rc=$?
check "the version gate reads a version printed with a banner (0)" "$rc" 0

# --- the OAuth credential path ------------------------------------------------------------------
# GEMINI_CLI_HOME also moves where gemini looks for its OAuth creds, so the seat copies the real ones
# in. That copy is the only place this isolation handles a live secret, and until now the suite only
# asserted the creds were ABSENT from the workspace — never that the copy itself behaves.
GEMHOME="$WORK/gemhome"
mkdir -p "$GEMHOME/.gemini"
GEMHOME_EMPTY="$WORK/gemhome-empty"
mkdir -p "$GEMHOME_EMPTY"
printf '{"fake":"oauth"}' >"$GEMHOME/.gemini/oauth_creds.json"
printf '{"fake":"accounts"}' >"$GEMHOME/.gemini/google_accounts.json"
chmod 644 "$GEMHOME/.gemini/oauth_creds.json" # deliberately loose: the copy must tighten it

# No environment auth selected -> the OAuth fallback runs.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" HOME="$GEMHOME" bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
iso=$(printf '%s\n' "$out" | grep 'GEMINI-ISO')
printf '%s' "$iso" | grep -q -- "homecreds=yes" && {
  echo "  ok   [-] the OAuth creds are copied into the isolated home"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL the OAuth creds were not copied into GEMINI_CLI_HOME"
  FAIL=$((FAIL + 1))
}
# 0600, not the source's 0644: the copy lands in a temp dir and must not widen the secret.
printf '%s' "$iso" | grep -q -- "credmode=-rw-------" && {
  echo "  ok   [-] the copied creds are 0600 regardless of the source mode"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL the copied OAuth creds did not end up 0600"
  FAIL=$((FAIL + 1))
}
printf '%s' "$iso" | grep -q -- "gca=true" && {
  echo "  ok   [-] the OAuth fallback opts into GOOGLE_GENAI_USE_GCA"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL the OAuth fallback did not set GOOGLE_GENAI_USE_GCA"
  FAIL=$((FAIL + 1))
}
# Copied, never reachable from the workspace: the allowlisted read_file is scoped to the workspace,
# so this is what stops a hostile plan from asking the reviewer to read the token back out.
printf '%s' "$iso" | grep -q -- "credsafe=yes" && {
  echo "  ok   [-] the copied creds stay outside the workspace"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL the copied OAuth creds were reachable from the workspace"
  FAIL=$((FAIL + 1))
}
# The USER scope must read the SAME locked file as the workspace scope, or it could re-enable a tool.
printf '%s' "$iso" | grep -q -- "lockedsame=yes" && {
  echo "  ok   [-] the user scope reads the same locked settings as the workspace"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL the user-scope settings differ from the workspace ones"
  FAIL=$((FAIL + 1))
}
# COPY, not symlink: gemini's own token refresh writes this file, and a symlink would send that write
# through to the user's real ~/.gemini.
[ -s "$GEMHOME/.gemini/oauth_creds.json" ] && {
  echo "  ok   [-] the user's real creds are left intact"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL the user's real OAuth creds were disturbed"
  FAIL=$((FAIL + 1))
}

# GEMINI_API_KEY selected -> no OAuth fallback. GCA outranks an API key inside gemini, so copying
# stale creds here would break an otherwise valid key run.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" HOME="$GEMHOME" GEMINI_API_KEY=k bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
iso=$(printf '%s\n' "$out" | grep 'GEMINI-ISO')
printf '%s' "$iso" | grep -q -- "homecreds=no" && printf '%s' "$iso" | grep -q -- "gca=UNSET" &&
  {
    echo "  ok   [-] GEMINI_API_KEY suppresses the OAuth fallback"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL GEMINI_API_KEY did not suppress the OAuth fallback"
    FAIL=$((FAIL + 1))
  }

# Vertex WITH credentials is selected auth, so the OAuth fallback stays out of the way.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" HOME="$GEMHOME" GOOGLE_GENAI_USE_VERTEXAI=true GOOGLE_APPLICATION_CREDENTIALS="$GEMHOME/sa.json" bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
iso=$(printf '%s\n' "$out" | grep 'GEMINI-ISO')
printf '%s' "$iso" | grep -q -- "homecreds=no" && printf '%s' "$iso" | grep -q -- "gca=UNSET" &&
  {
    echo "  ok   [-] Vertex with credentials suppresses the OAuth fallback"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL Vertex with credentials did not suppress the OAuth fallback"
    FAIL=$((FAIL + 1))
  }
# The FLAG ALONE is not auth. It is a common leftover in a shell profile, and counting it suppressed
# the fallback and left the run with no credentials at all — the same failure as GOOGLE_API_KEY,
# through a different door.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" HOME="$GEMHOME" GOOGLE_GENAI_USE_VERTEXAI=true CLOUDSDK_CONFIG="$GEMHOME_EMPTY" bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
iso=$(printf '%s\n' "$out" | grep 'GEMINI-ISO')
printf '%s' "$iso" | grep -q -- "homecreds=yes" && printf '%s' "$iso" | grep -q -- "gca=true" &&
  {
    echo "  ok   [-] a bare Vertex flag with no credentials still falls back to OAuth"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL a credential-less Vertex flag suppressed the OAuth fallback"
    FAIL=$((FAIL + 1))
  }

# GOOGLE_API_KEY ALONE selects no auth method in gemini-cli v0.26.0. Treating it as one used to
# suppress the fallback and leave the run with no credentials at all — an opaque auth failure for
# anyone who had that variable exported for some other Google tool.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" HOME="$GEMHOME" GOOGLE_API_KEY=k bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
iso=$(printf '%s\n' "$out" | grep 'GEMINI-ISO')
printf '%s' "$iso" | grep -q -- "homecreds=yes" && printf '%s' "$iso" | grep -q -- "gca=true" &&
  {
    echo "  ok   [-] GOOGLE_API_KEY alone does not count as selected auth"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL GOOGLE_API_KEY alone suppressed the OAuth fallback"
    FAIL=$((FAIL + 1))
  }

# No creds to copy at all -> the seat still runs (auth simply rides whatever the environment has).
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" HOME="$GEMHOME_EMPTY" bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
rc=$?
check "the seat runs when there are no OAuth creds to copy (0)" "$rc" 0
printf '%s\n' "$out" | grep 'GEMINI-ISO' | grep -q -- "gca=UNSET" && {
  echo "  ok   [-] no creds copied means no GCA opt-in"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL GCA was opted into with no creds copied"
  FAIL=$((FAIL + 1))
}

# --- the plan actually reaches the reviewer -----------------------------------------------------
# -p carries the PROMPT and the plan goes on stdin. Every other assertion here reads argv, so a CLI
# that ignored stdin would leave the seat reviewing nothing at all with the suite still green. The
# reviewer's whole purpose is the one thing nothing checked.
out=$(printf 'MAGICPLANTOKEN in the plan body\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
iso=$(printf '%s\n' "$out" | grep 'GEMINI-ISO')
printf '%s' "$iso" | grep -q -- "stdinmagic=yes" && {
  echo "  ok   [-] the plan body reaches gemini on stdin"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL the plan body never reached gemini"
  FAIL=$((FAIL + 1))
}
printf '%s' "$iso" | grep -q -- "stdinbytes=0" && {
  echo "  FAIL gemini was handed an empty plan"
  FAIL=$((FAIL + 1))
} || {
  echo "  ok   [-] gemini is not handed an empty plan"
  PASS=$((PASS + 1))
}

# --- an INHERITED GOOGLE_GENAI_USE_GCA must not reach the child ---------------------------------
# gemini gives GCA priority over both an API key and Vertex, and the seat deliberately does not copy
# credentials when env auth is selected. So an exported GCA wins the auth race and then has nothing
# to authenticate with: a valid API key, refused, for a reason nothing in the output names.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" HOME="$GEMHOME" GOOGLE_GENAI_USE_GCA=true GEMINI_API_KEY=k bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
printf '%s\n' "$out" | grep 'GEMINI-ISO' | grep -q -- "gca=UNSET" && {
  echo "  ok   [-] an inherited GCA is dropped when an API key is selected"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL an inherited GOOGLE_GENAI_USE_GCA reached the child over an API key"
  FAIL=$((FAIL + 1))
}
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" HOME="$GEMHOME" GOOGLE_GENAI_USE_GCA=true GOOGLE_GENAI_USE_VERTEXAI=true GOOGLE_APPLICATION_CREDENTIALS="$GEMHOME/sa.json" bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
printf '%s\n' "$out" | grep 'GEMINI-ISO' | grep -q -- "gca=UNSET" && {
  echo "  ok   [-] an inherited GCA is dropped when Vertex is selected"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL an inherited GOOGLE_GENAI_USE_GCA reached the child over Vertex"
  FAIL=$((FAIL + 1))
}
# Dropping the inherited one must not break the deliberate opt-in: env applies -u before NAME=value.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" HOME="$GEMHOME" GOOGLE_GENAI_USE_GCA=true bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
printf '%s\n' "$out" | grep 'GEMINI-ISO' | grep -q -- "gca=true" && {
  echo "  ok   [-] the seat's own GCA opt-in still survives the unset"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL unsetting the inherited GCA also killed the opt-in"
  FAIL=$((FAIL + 1))
}
# No creds to copy and an inherited GCA: the opt-in must NOT happen just because the variable existed.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" HOME="$GEMHOME_EMPTY" GOOGLE_GENAI_USE_GCA=true bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
printf '%s\n' "$out" | grep 'GEMINI-ISO' | grep -q -- "gca=UNSET" && {
  echo "  ok   [-] an inherited GCA does not opt in by itself"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL an inherited GCA survived with no creds copied"
  FAIL=$((FAIL + 1))
}

# --- a base-URL override on the ENVIRONMENT, not just in a .env file ----------------------------
# The planted empty .gemini/.env stops the ancestor .env walk, which closes the file half of this.
# An exported CODE_ASSIST_ENDPOINT redirects auth and bearer tokens just as well and was untouched.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" CODE_ASSIST_ENDPOINT=https://attacker.example bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
printf '%s\n' "$out" | grep 'GEMINI-ISO' | grep -q -- "cae=UNSET" && {
  echo "  ok   [-] an inherited CODE_ASSIST_ENDPOINT is stripped for the run"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL an inherited base-URL override reached gemini"
  FAIL=$((FAIL + 1))
}
# The sibling overrides are named in the same `-u` list and must be covered by the same reasoning:
# one asserted variable and two unasserted ones is a list nobody notices going stale.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" GEMINI_BASE_URL=https://attacker.example GOOGLE_GEMINI_BASE_URL=https://attacker.example bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
iso=$(printf '%s\n' "$out" | grep 'GEMINI-ISO')
printf '%s' "$iso" | grep -q -- "gburl=UNSET" && printf '%s' "$iso" | grep -q -- "ggburl=UNSET" &&
  {
    echo "  ok   [-] the other inherited base-URL overrides are stripped too"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL an inherited GEMINI_BASE_URL/GOOGLE_GEMINI_BASE_URL reached gemini"
    FAIL=$((FAIL + 1))
  }

# --- the creds are not one `../` hop from the workspace -----------------------------------------
# gemini confines read_file to the workspace, and that is the control this relies on. It is also
# someone else's invariant: assert the layout does not hand the creds over the moment it slips.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" HOME="$GEMHOME" bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
printf '%s\n' "$out" | grep 'GEMINI-ISO' | grep -q -- "credwalk=clean" && {
  echo "  ok   [-] the copied creds are not adjacent to the reviewer's workspace"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL the OAuth creds sit in the workspace tree, its parent, or a sibling"
  FAIL=$((FAIL + 1))
}

# --- the version probe must read stderr too -----------------------------------------------------
# The gate fails CLOSED, so a probe that misses the number does not leak — it refuses an audited
# binary and blames the gate.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" STUB_GEMINI_VERSION_STDERR=1 bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
rc=$?
check "the version gate reads a version printed on stderr (0)" "$rc" 0

# antigravity in the panel but the gemini CLI missing → hard quorum failure (3), never a silent pass.
# Build a SELF-CONTAINED PATH: the reviewer stubs plus symlinks to only the coreutils plan-review
# needs — but deliberately NO gemini. Using a curated PATH (not the system one) means the test can't
# be fooled by a real gemini sitting in /usr/bin on some machine (Cursor's nit).
mkdir -p "$WORK/pbin-nogemini"
for b in claude codex qwen cursor-agent; do cp "$PBIN/$b" "$WORK/pbin-nogemini/$b" 2>/dev/null; done
# `command -v gemini` fails at dispatch BEFORE the antigravity branch runs, so exit 3 comes purely from
# the missing binary. mkdir/cp are symlinked anyway so the curated PATH is a realistic minimal toolset.
for t in bash env mkdir cp mktemp rm cat sed tail tr pgrep timeout grep; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$WORK/pbin-nogemini/$t"
done
# SHIP_FEATURE_CONFIG=/dev/null is passed explicitly: env -i clears the exported one, and without it
# the subshell would load the user's real ~/.config/ship-feature/config and become non-deterministic.
(printf 'plan\n' | env -i PATH="$WORK/pbin-nogemini" HOME="$HOME" SHIP_FEATURE_CONFIG=/dev/null bash "$CLI" plan-review --reviewers codex,antigravity >/dev/null 2>&1)
check "plan-review fails the quorum when the gemini CLI is missing (3)" $? 3

# default panel comes from SHIP_FEATURE_REVIEWERS when --reviewers is omitted
out=$(printf 'a plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_REVIEWERS=claude,cursor bash "$CLI" plan-review 2>/dev/null)
rc=$?
check "plan-review uses SHIP_FEATURE_REVIEWERS by default" "$rc" 0
printf '%s' "$out" | grep -q "REVIEW-claude" && printf '%s' "$out" | grep -q "REVIEW-cursor" &&
  {
    echo "  ok   [-] plan-review ran the configured default panel"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL plan-review did not run the configured panel"
    FAIL=$((FAIL + 1))
  }

# SHIP_FEATURE_PLAN_REVIEWERS overrides the shared quorum for plan-review (a smaller panel
# than the PR cross-review). When both are set, the plan-specific one wins.
out=$(printf 'a plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_REVIEWERS=claude,codex,cursor,glm SHIP_FEATURE_PLAN_REVIEWERS=claude,codex bash "$CLI" plan-review 2>/dev/null)
rc=$?
check "plan-review prefers SHIP_FEATURE_PLAN_REVIEWERS" "$rc" 0
if printf '%s' "$out" | grep -q "REVIEW-claude" && printf '%s' "$out" | grep -q "REVIEW-codex" && ! printf '%s' "$out" | grep -q "REVIEW-cursor"; then
  echo "  ok   [-] the plan-specific panel wins over the quorum"
  PASS=$((PASS + 1))
else
  echo "  FAIL plan-review did not prefer SHIP_FEATURE_PLAN_REVIEWERS"
  FAIL=$((FAIL + 1))
fi

# a reviewer that returns an EMPTY review → not clean (exit 3)
printf '#!/usr/bin/env bash\nexit 0\n' >"$PBIN/codex"
chmod +x "$PBIN/codex"
(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers codex,glm >/dev/null 2>&1)
check "plan-review empty review → not clean (3)" $? 3
make_reviewer codex 0 codex # restore

# a NON-ZERO reviewer exit → not clean (exit 3)
make_reviewer codex 1 codex
(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers codex >/dev/null 2>&1)
check "plan-review non-zero reviewer → not clean (3)" $? 3
make_reviewer codex 0 codex # restore

# a supported reviewer from the panel whose CLI is missing → fail (3): the panel is the
# quorum, so it never quietly passes on a thinned set.
(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers codex,doesnotexist >/dev/null 2>&1)
check "plan-review missing panel reviewer → fail (3)" $? 3

# bare opencode is RELAY-ONLY: skipped with a warning, the rest of the panel still runs (0). Bare
# grok is NOT (since 2026-09) — assert it RAN, because codex alone would keep the exit at 0.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers opencode,grok,codex 2>&1)
rc=$?
check "plan-review skips relay-only agents, runs the rest" "$rc" 0
printf '%s' "$out" | grep -qi "opencode is relay-only" && {
  echo "  ok   [-] plan-review warns that opencode is relay-only"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL plan-review did not warn about relay-only agents"
  FAIL=$((FAIL + 1))
}
printf '%s' "$out" | grep -q 'REVIEW-grok' && {
  echo "  ok   [-] plan-review runs grok in the same panel"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL grok was skipped alongside opencode"
  FAIL=$((FAIL + 1))
}

# a panel of ONLY relay-only agents → nobody supported ran → clear error (1)
(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers opencode >/dev/null 2>&1)
check "plan-review with only relay-only agents → error (1)" $? 1

# no panel at all (unset + none passed) → usage error (1)
(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_REVIEWERS='' bash "$CLI" plan-review >/dev/null 2>&1)
check "plan-review with no panel → usage error (1)" $? 1

# an empty plan → error (1)
(printf '' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers codex >/dev/null 2>&1)
check "plan-review on an empty plan → error (1)" $? 1

# a plan passed as a FILE argument is reviewed
printf 'Plan from a file\n' >"$WORK/aplan.md"
out=$(PATH="$PBIN:$PATH" bash "$CLI" plan-review "$WORK/aplan.md" --reviewers codex 2>/dev/null)
rc=$?
check "plan-review reads a plan from a file argument" "$rc" 0
printf '%s' "$out" | grep -q "REVIEW-codex" && {
  echo "  ok   [-] plan-review reviewed the file's contents"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL plan-review did not review the file"
  FAIL=$((FAIL + 1))
}

# a file given after `--` is still reviewed (not dropped)
out=$(PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers codex -- "$WORK/aplan.md" 2>/dev/null)
rc=$?
check "plan-review honors a file after --" "$rc" 0
printf '%s' "$out" | grep -q "REVIEW-codex" && {
  echo "  ok   [-] plan-review reviewed the file passed after --"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL plan-review dropped the file after --"
  FAIL=$((FAIL + 1))
}

# an EMPTY stdin pipe must fall back to ./plan.md, not shadow it with "empty plan"
PDIR="$WORK/plandir"
mkdir -p "$PDIR"
printf 'plan.md content\n' >"$PDIR/plan.md"
out=$(cd "$PDIR" && printf '' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers codex 2>/dev/null)
rc=$?
check "plan-review falls back to ./plan.md on empty stdin" "$rc" 0
printf '%s' "$out" | grep -q "REVIEW-codex" && {
  echo "  ok   [-] plan-review reviewed ./plan.md"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL plan-review did not fall back to ./plan.md"
  FAIL=$((FAIL + 1))
}

# a missing file argument fails clearly
(PATH="$PBIN:$PATH" bash "$CLI" plan-review "$WORK/nope.md" --reviewers codex >/dev/null 2>&1)
check "plan-review fails on a missing file" $? 1

# explicit `-` reads stdin (even conceptually on a TTY) and does NOT fall back to plan.md
out=$(cd "$PDIR" && printf 'STDIN PLAN VIA DASH\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review - --reviewers codex 2>/dev/null)
rc=$?
check "plan-review reads stdin on explicit -" "$rc" 0
printf '%s' "$out" | grep -q "REVIEW-codex" && {
  echo "  ok   [-] plan-review reviewed the '-' stdin plan"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL plan-review did not read '-' stdin"
  FAIL=$((FAIL + 1))
}

# an explicit but EMPTY plan file fails with a file-specific message (exit 1)
: >"$WORK/blank.md"
(PATH="$PBIN:$PATH" bash "$CLI" plan-review "$WORK/blank.md" --reviewers codex >/dev/null 2>&1)
check "plan-review rejects an empty explicit file (1)" $? 1

# the --reviewers= form is rejected (two-token only), matching relay
(printf 'p\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers=codex >/dev/null 2>&1)
check "plan-review rejects the --reviewers= form" $? 1

# a trailing --reviewers with no value → clean usage error, NOT a set -u crash
(printf 'p\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers >/dev/null 2>&1)
check "plan-review: bare --reviewers → usage error (1)" $? 1
# an explicitly EMPTY --reviewers "" is a usage error, not a silent fall-through to the env panel
(printf 'p\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_REVIEWERS=codex bash "$CLI" plan-review --reviewers '' >/dev/null 2>&1)
check "plan-review: --reviewers '' → usage error, no env fallback (1)" $? 1
# --reviewers immediately followed by a flag is also a usage error (not a reviewer named --parallel)
(printf 'p\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers --parallel >/dev/null 2>&1)
check "plan-review: --reviewers <flag> → usage error (1)" $? 1

# a numerically-zero timeout is rejected (GNU `timeout 0` would DISABLE the timeout)
(printf 'p\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_PLAN_TIMEOUT=00 bash "$CLI" plan-review --reviewers codex >/dev/null 2>&1)
check "plan-review rejects a zero timeout (00)" $? 1

# the reviewer list is NOT glob-expanded: a wildcard in a dir with matching files stays
# literal (→ unknown reviewer → fail 3), it does not become those filenames.
GDIR="$WORK/globdir"
mkdir -p "$GDIR"
: >"$GDIR/aaa"
: >"$GDIR/abb"
(cd "$GDIR" && printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers 'a*' >/dev/null 2>&1)
check "plan-review does not glob-expand the reviewer list" $? 3

# `help` prints the header comment block, and it must name every command. It used to print a
# hardcoded line range, so documenting a new flag in the header silently truncated help mid-
# sentence and dropped the last command — invisible unless someone reads the output. There was no
# test at all; this is it.
help_out=$(bash "$CLI" help 2>&1)
check "help exits 0" $? 0
for _c in preflight relay plan-review help; do
  printf '%s' "$help_out" | grep -q "ship-feature $_c"
  check "help documents the '$_c' command" $? 0
done

# The default really is CONCURRENT, not merely "produces the same output as parallel would".
# Counting reviews cannot tell the two apart — a sequential run prints the same three. Three
# reviewers that each sleep 1s take ~1s together and ~3s one after another, so the wall clock is
# the only honest witness. Generous bounds: this must not go flaky on a loaded machine.
# NB: the `glm` reviewer runs the `opencode` binary — stub the tool names, not the seat names.
OVERLAP_LOG="$WORK/overlap.log"
for _slow in claude codex opencode; do
  cat >"$PBIN/$_slow" <<SLOWSTUB
#!/usr/bin/env bash
# glm's v1/v2 flag probe is not a review: answer it at once, outside the log.
[ "\${1:-}" = --help ] && { printf -- '--pure\n'; exit 0; }
echo "start" >> "$OVERLAP_LOG"
sleep 1
echo "end" >> "$OVERLAP_LOG"
echo "REVIEW-$_slow"
echo "Looks good."
SLOWSTUB
  chmod +x "$PBIN/$_slow"
done

# Each stub brackets its sleep with a start and an end marker in one shared log, so the log
# SHAPE — not the clock — says which mode ran. Concurrent: all three start before any ends
# (start start start end end end). Serialized: each one ends before the next starts
# (start end start end …). A wall-clock bound was the first attempt and it was wrong: on a
# loaded machine a genuinely parallel run can exceed any threshold you pick, so the test would
# fail for being slow rather than for being sequential. This shape holds however slow the box
# is; it only needs the dispatch loop to start three processes within one stub's sleep.
overlap_run() { # $1 = extra args; echoes the run's stdout, leaves the log in $OVERLAP_LOG
  : >"$OVERLAP_LOG"
  printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude,codex,glm $1 2>/dev/null
}

out=$(overlap_run "")
n=$(printf '%s' "$out" | grep -c "REVIEW-")
check "plan-review (default) still ran all three slow reviewers" "$n" 3
shape=$(tr '\n' ' ' <"$OVERLAP_LOG")
check "plan-review (default) overlaps the reviewers" "$shape" "start start start end end end "

out=$(overlap_run "--sequential")
n=$(printf '%s' "$out" | grep -c "REVIEW-")
check "plan-review --sequential ran all three slow reviewers" "$n" 3
shape=$(tr '\n' ' ' <"$OVERLAP_LOG")
check "plan-review --sequential never overlaps them" "$shape" "start end start end start end "

# "The last flag wins" is a documented promise, so it gets a test in both orders — using the
# same overlap shape, which is what the promise is actually about.
out=$(overlap_run "--sequential --parallel")
shape=$(tr '\n' ' ' <"$OVERLAP_LOG")
check "plan-review --sequential --parallel ends up parallel" "$shape" "start start start end end end "

out=$(overlap_run "--parallel --sequential")
shape=$(tr '\n' ' ' <"$OVERLAP_LOG")
check "plan-review --parallel --sequential ends up sequential" "$shape" "start end start end start end "

make_reviewer claude 0 claude
make_reviewer codex 0 codex
make_reviewer glm 0 opencode # restore

# Parallel is the DEFAULT, so the flagless run must behave like the --parallel one: reviews are
# buffered and emitted in panel order after the barrier, and the banner does not say "sequential".
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude,codex,glm 2>&1)
rc=$?
check "plan-review runs the panel in parallel with no flag (0)" "$rc" 0
n=$(printf '%s' "$out" | grep -c "REVIEW-")
check "plan-review (default) ran all three reviewers" "$n" 3
n=$(printf '%s' "$out" | grep -c -- "— sequential")
check "plan-review (default) does not announce sequential" "$n" 0

# --sequential is the opt-out: still clean, still every reviewer, and it says so on the banner.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude,codex,glm --sequential 2>&1)
rc=$?
check "plan-review --sequential clean run exits 0" "$rc" 0
n=$(printf '%s' "$out" | grep -c "REVIEW-")
check "plan-review --sequential ran all three reviewers" "$n" 3
n=$(printf '%s' "$out" | grep -c -- "— sequential")
check "plan-review --sequential announces the mode" "$n" 1

# --parallel: clean run exits 0 and prints every reviewer (order-independent)
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude,codex,glm --parallel 2>/dev/null)
rc=$?
check "plan-review --parallel clean run exits 0" "$rc" 0
n=$(printf '%s' "$out" | grep -c "REVIEW-")
check "plan-review --parallel ran all three reviewers" "$n" 3

# --parallel is still fail-closed: one empty reviewer fails the whole round (3)
printf '#!/usr/bin/env bash\nexit 0\n' >"$PBIN/codex"
chmod +x "$PBIN/codex"
(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude,codex,glm --parallel >/dev/null 2>&1)
check "plan-review --parallel stays fail-closed (3)" $? 3
make_reviewer codex 0 codex # restore

# The EXIT trap must actually delete STATUS_DIR. It expands "$STATUS_DIR" when it fires, which is
# after cmd_plan_review has returned — so if that variable is ever made function-local again, the
# name is unbound by then, `set -u` aborts the trap body, and every run leaves its directory (with
# each reviewer's buffered review in it) behind forever. That regression is invisible except for a
# stderr line, which is why it survived ~310 leaks a day until someone counted /tmp.
# Give the CLI its own TMPDIR so this measures only what plan-review created, and keep the panel to
# codex: glm forces TMPDIR=/tmp for its own isolated cwd, which would muddy the count.
leakdir="$WORK/leak"
mkdir -p "$leakdir"
leakerr="$WORK/leak.err"
(printf 'plan\n' | PATH="$PBIN:$PATH" TMPDIR="$leakdir" bash "$CLI" plan-review --reviewers codex >/dev/null 2>"$leakerr")
leakrc=$?
# Assert the run actually SUCCEEDED first. Without this the other two assertions pass vacuously:
# a `die` before mktemp -d would leave nothing behind and print no unbound-variable line, so a
# broken CLI would look like a clean one and the cleanup path would never be exercised at all.
check "plan-review leak probe ran successfully" "$leakrc" 0
# Numeric compare: `wc -l` can emit padded output, so a string test against "0" would false-fail.
leftovers=$(find "$leakdir" -mindepth 1 | wc -l)
[ "$leftovers" -eq 0 ] &&
  {
    echo "  ok   [-] plan-review removes its temp dir on exit"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL plan-review leaked $leftovers entries under its TMPDIR: $(find "$leakdir" -mindepth 1 -maxdepth 1)"
    FAIL=$((FAIL + 1))
  }
# Secondary, and only that: a fix which merely silenced the message would still pass this one.
grep -q 'unbound variable' "$leakerr" &&
  {
    echo "  FAIL plan-review printed an unbound-variable error: $(grep 'unbound variable' "$leakerr")"
    FAIL=$((FAIL + 1))
  } ||
  {
    echo "  ok   [-] plan-review exits without an unbound-variable error"
    PASS=$((PASS + 1))
  }

# Interrupt teardown: ^C during --parallel must kill the reviewer's deep descendants
# (subshell -> $() -> timeout -> agent), not leak them. A slow stub holds a `sleep`
# grandchild; we record every descendant PID, SIGINT the CLI, then assert they're gone.
# pgrep is required for kill_tree; skip cleanly where it's absent rather than false-fail.
if command -v pgrep >/dev/null 2>&1; then
  _descendants() {
    local p="$1" c
    for c in $(pgrep -P "$p" 2>/dev/null); do
      echo "$c"
      _descendants "$c"
    done
  }
  printf 'a plan\n' >"$WORK/intplan.md"
  printf '#!/usr/bin/env bash\nsleep 30\n' >"$PBIN/codex"
  chmod +x "$PBIN/codex" # a "slow agent"
  PATH="$PBIN:$PATH" bash "$CLI" plan-review "$WORK/intplan.md" --reviewers codex --parallel >/dev/null 2>&1 &
  cli=$!
  # Wait (up to ~4s) for the sleep grandchild to materialize under the CLI.
  sleeppids=""
  for _i in $(seq 1 20); do
    for k in $(_descendants "$cli"); do case "$(ps -o comm= -p "$k" 2>/dev/null)" in *sleep) sleeppids="$sleeppids $k" ;; esac done
    [ -n "$sleeppids" ] && break
    sleep 0.2
  done
  kill -INT "$cli" 2>/dev/null
  wait "$cli" 2>/dev/null
  sleep 0.5
  if [ -z "$sleeppids" ]; then
    echo "  FAIL interrupt test: reviewer subtree never materialized (inconclusive)"
    FAIL=$((FAIL + 1))
  else
    alive=0
    for p in $sleeppids; do kill -0 "$p" 2>/dev/null && alive=1; done
    if [ "$alive" = 0 ]; then
      echo "  ok   [-] ^C during --parallel kills the reviewer's descendants"
      PASS=$((PASS + 1))
    else
      echo "  FAIL interrupt left a reviewer descendant alive"
      FAIL=$((FAIL + 1))
      for p in $sleeppids; do kill -9 "$p" 2>/dev/null; done
    fi
  fi
  make_reviewer codex 0 codex # restore
else
  echo "  ok   [-] interrupt teardown test skipped (no pgrep)"
  PASS=$((PASS + 1))
fi

# --- git isolation: proven against a hostile environment ---------------------
# Each case PLANTS the hostility, proves the plant actually took, then applies sf_isolate_git and
# asserts it won. The control step is the entire point. The first version of this block skipped it:
# it ran `git -c commit.gpgsign=true config --get` as its "control", which affects that ONE git
# invocation and leaves nothing behind for the commit that follows — so every case passed on a clean
# machine whether or not the isolation existed. All three cross-reviewers caught it independently.
#
# GIT_CONFIG_PARAMETERS is git's own channel: git sets it for child processes whenever something ran
# `git -c …`, which is exactly how an ambient override reaches a suite launched from a hook. Setting
# it directly here reproduces that state; the format is a space-separated list of single-quoted
# 'key=value' pairs.
#
# Everything runs in a subshell so a planted variable cannot leak back into the suite.

# 0. Still in force after every fixture has run: nothing in the suite re-polluted the environment.
sf_check_isolated &&
  {
    echo "  ok   [-] the git isolation is still in force after the whole suite"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the git isolation was lost partway through the run"
    FAIL=$((FAIL + 1))
  }

# 0b. init.templateDir="" was in the first draft of sf_isolate_git and broke `>> .git/info/exclude`,
#     which is how the worktree marker gets ignored. It was removed with only a comment as memory —
#     this is the assertion that fires if someone "helps" the function again.
(
  T="$WORK/tpl"
  rm -rf "$T"
  mkdir -p "$T"
  cd "$T" || exit 1
  sf_isolate_git
  git init -q . 2>/dev/null || exit 4 # tell "init itself broke" from "no info dir"
  echo x >>.git/info/exclude 2>/dev/null || exit 3
) >/dev/null 2>&1
t0b=$?
case "$t0b" in
  0)
    echo "  ok   [-] git init still produces .git/info (no empty templateDir)"
    PASS=$((PASS + 1))
    ;;
  3)
    echo "  FAIL .git/info missing — init.templateDir was probably reintroduced"
    FAIL=$((FAIL + 1))
    ;;
  *)
    echo "  FAIL .git/info check could not run (git init failed, rc=$t0b)"
    FAIL=$((FAIL + 1))
    ;;
esac

# 1. Signing off at the COMMIT level, against a genuinely planted ambient gpgsign.
#    Asserted as exactly %G? = N, not "not G": a signature that fails verification reports E/B/R,
#    which would slip past a denylist while still meaning isolation failed.
(
  H="$WORK/h1"
  mkdir -p "$H"
  cd "$H" || exit 1
  git init -q . 2>/dev/null
  export GIT_CONFIG_PARAMETERS="'commit.gpgsign=true'"
  [ "$(git config --get commit.gpgsign 2>/dev/null)" = "true" ] || {
    echo PLANT_DEAD
    exit 3
  }
  sf_isolate_git
  git commit -q --allow-empty -m one 2>/dev/null || {
    echo COMMIT_DEAD
    exit 4
  }
  git log -1 --format='%G?' 2>/dev/null | tail -1
) >"$WORK/h1.out" 2>/dev/null
h1=$?
h1v="$(tail -1 "$WORK/h1.out" 2>/dev/null)"
[ "$h1" = 0 ] && [ "$h1v" = "N" ] &&
  {
    echo "  ok   [-] a planted ambient commit.gpgsign is defeated (%G? = N)"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL git isolation: planted signing survived (rc=$h1 out='$h1v')"
    FAIL=$((FAIL + 1))
  }

# 2. GIT_CONFIG_PARAMETERS specifically: it OVERRIDES GIT_CONFIG_COUNT, so if the unset loop is
#    deleted while the exports stay, the controlled values are silently ignored. The control
#    proves the override is live before isolation runs.
(
  cd "$WORK" || exit 1
  export GIT_CONFIG_PARAMETERS="'commit.gpgsign=true'"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
  [ "$(git config --get commit.gpgsign 2>/dev/null)" = "true" ] || {
    echo PLANT_DEAD
    exit 3
  }
  sf_isolate_git
  [ -z "${GIT_CONFIG_PARAMETERS:-}" ] || {
    echo STILL_SET
    exit 4
  }
  git config --get commit.gpgsign 2>/dev/null | tail -1
) >"$WORK/h2.out" 2>/dev/null
h2=$?
h2v="$(tail -1 "$WORK/h2.out" 2>/dev/null)"
[ "$h2" = 0 ] && [ "$h2v" = "false" ] &&
  {
    echo "  ok   [-] GIT_CONFIG_PARAMETERS beats GIT_CONFIG_COUNT, and is cleared first"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL git isolation: GIT_CONFIG_PARAMETERS override not neutralised (rc=$h2 out='$h2v')"
    FAIL=$((FAIL + 1))
  }

# 3. A planted core.hooksPath must not reach fixture commits. Without this, deleting
#    GIT_CONFIG_KEY_2 would go unnoticed — the same rot the tag.gpgsign check exists to prevent.
(
  H="$WORK/h3"
  HK="$WORK/h3hooks"
  mkdir -p "$H" "$HK"
  cd "$H" || exit 1
  # The hook prints a unique marker, so the control proves the commit failed BECAUSE OF THE HOOK
  # rather than for any other reason — otherwise "the commit failed" is satisfied by a broken
  # fixture and the post-isolation success does all the work.
  printf '#!/bin/sh\necho SF_HOOK_MARKER >&2\nexit 1\n' >"$HK/pre-commit"
  chmod +x "$HK/pre-commit"
  git init -q . 2>/dev/null
  export GIT_CONFIG_PARAMETERS="'core.hooksPath=$HK'"
  cerr=$(git commit --allow-empty -m blocked 2>&1)
  crc=$?
  [ "$crc" != 0 ] || {
    echo PLANT_DEAD_COMMIT_SUCCEEDED
    exit 3
  }
  case "$cerr" in *SF_HOOK_MARKER*) ;; *)
    echo "PLANT_DEAD_NOT_THE_HOOK"
    exit 3
    ;;
  esac
  sf_isolate_git
  git commit -q --allow-empty -m allowed 2>/dev/null || {
    echo STILL_BLOCKED
    exit 4
  }
  echo OK
) >"$WORK/h3.out" 2>/dev/null
h3=$?
[ "$h3" = 0 ] &&
  {
    echo "  ok   [-] a planted core.hooksPath cannot block a fixture commit"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL git isolation: hostile hooksPath (rc=$h3 out='$(tail -1 "$WORK/h3.out" 2>/dev/null)')"
    FAIL=$((FAIL + 1))
  }

# 3b. The original bug is a developer with commit.gpgsign=true in ~/.gitconfig — no hook, no
#     GIT_CONFIG_PARAMETERS. Test 1 plants the strictly stronger override, so this plants the plain
#     global one via GIT_CONFIG_GLOBAL, which is how git reads a user config without touching theirs.
(
  H="$WORK/h3b"
  G="$WORK/h3b.gitconfig"
  mkdir -p "$H"
  cd "$H" || exit 1
  # A fresh shell first: the suite already exported GIT_CONFIG_COUNT, and env config OUTRANKS the
  # global file, so the plant would be defeated before isolation ever ran and the case would report
  # PLANT_DEAD. Clearing git's own env list is what "a developer's plain shell" actually looks like.
  while IFS= read -r _v; do [ -n "$_v" ] && unset "$_v"; done < <(git rev-parse --local-env-vars)
  printf '[commit]\n\tgpgsign = true\n' >"$G"
  export GIT_CONFIG_GLOBAL="$G"
  git init -q . 2>/dev/null
  [ "$(git config --get commit.gpgsign 2>/dev/null)" = "true" ] || {
    echo PLANT_DEAD
    exit 3
  }
  sf_isolate_git
  git commit -q --allow-empty -m global 2>/dev/null || {
    echo COMMIT_DEAD
    exit 4
  }
  git log -1 --format='%G?' 2>/dev/null | tail -1
) >"$WORK/h3b.out" 2>/dev/null
h3b=$?
h3bv="$(tail -1 "$WORK/h3b.out" 2>/dev/null)"
[ "$h3b" = 0 ] && [ "$h3bv" = "N" ] &&
  {
    echo "  ok   [-] a plain global commit.gpgsign is defeated too (%G? = N)"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL git isolation: global-config signing survived (rc=$h3b out='$h3bv')"
    FAIL=$((FAIL + 1))
  }

# 3c. core.excludesFile is the sharpest of the remaining ambient settings and had no plant: a global
#     ignore rule for a pattern a fixture uses makes that file invisible to `git add`, and the test
#     that needed it fails for a reason nobody would guess. (`*.dat` is not hypothetical — the
#     binary-scan fixture commits a .dat file.) The other three neutralised keys —
#     core.attributesFile, core.fsmonitor, color.ui — are asserted through this same function being
#     in force, not individually; excludesFile is the one with a demonstrated failure.
(
  H="$WORK/h3c"
  IG="$WORK/h3c.ignore"
  mkdir -p "$H"
  cd "$H" || exit 1
  while IFS= read -r _v; do [ -n "$_v" ] && unset "$_v"; done < <(git rev-parse --local-env-vars)
  printf '*.dat\n' >"$IG"
  export GIT_CONFIG_GLOBAL="$IG.cfg"
  printf '[core]\n\texcludesFile = %s\n' "$IG" >"$IG.cfg"
  git init -q . 2>/dev/null
  : >payload.dat
  git add payload.dat 2>/dev/null
  git diff --cached --name-only 2>/dev/null | grep -q payload.dat && {
    echo PLANT_DEAD
    exit 3
  }
  sf_isolate_git
  git add payload.dat 2>/dev/null
  git diff --cached --name-only 2>/dev/null | grep -q payload.dat || {
    echo STILL_IGNORED
    exit 4
  }
  echo OK
) >"$WORK/h3c.out" 2>/dev/null
h3c=$?
[ "$h3c" = 0 ] &&
  {
    echo "  ok   [-] a planted core.excludesFile cannot hide a fixture's file"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL git isolation: excludesFile (rc=$h3c out='$(tail -1 "$WORK/h3c.out" 2>/dev/null)')"
    FAIL=$((FAIL + 1))
  }

# 3d. The three remaining neutralised keys have no commit-level symptom in this suite, so they get
#     config assertions — the same weight as tag.gpgsign. Without these you could no-op KEY_4..6,
#     keep seven keys so the startup guard still passes, and stay green. color.ui is the one that
#     would bite first: color.ui=always puts ANSI into the `%G?` read above.
(
  cd "$WORK" || exit 1
  sf_isolate_git
  printf '%s|%s|%s' "$(git config --get core.attributesFile 2>/dev/null)" \
    "$(git config --get core.fsmonitor 2>/dev/null)" \
    "$(git config --get color.ui 2>/dev/null)"
) >"$WORK/h3d.out" 2>/dev/null
h3dv="$(tail -1 "$WORK/h3d.out" 2>/dev/null)"
[ "$h3dv" = "/dev/null|false|false" ] &&
  {
    echo "  ok   [-] attributesFile, fsmonitor and color.ui are neutralised too"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL git isolation: attributesFile/fsmonitor/color.ui (got '"'"'$h3dv'"'"')"
    FAIL=$((FAIL + 1))
  }

# 4. tag.gpgsign has no commit-level effect in this suite, which is exactly why it would rot
#    unnoticed. A config assertion is the right weight for it.
(
  cd "$WORK" || exit 1
  sf_isolate_git
  git config --get tag.gpgsign 2>/dev/null | tail -1
) >"$WORK/h4.out" 2>/dev/null
[ "$(tail -1 "$WORK/h4.out" 2>/dev/null)" = "false" ] &&
  {
    echo "  ok   [-] tag.gpgsign is forced off too"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL tag.gpgsign not forced off"
    FAIL=$((FAIL + 1))
  }

# 5. A planted GIT_DIR must not capture a fixture's commits — the failure that corrupted a real
#    repository. The control proves the decoy really would have taken it.
(
  DECOY="$WORK/decoy"
  FIX="$WORK/fix5"
  rm -rf "$DECOY" "$FIX"
  mkdir -p "$DECOY" "$FIX"
  git init -q "$DECOY" 2>/dev/null
  git init -q "$FIX" 2>/dev/null
  before=$(git -C "$DECOY" rev-list --all --count 2>/dev/null || echo 0)
  (cd "$FIX" && GIT_DIR="$DECOY/.git" GIT_WORK_TREE="$DECOY" git commit -q --allow-empty -m captured 2>/dev/null)
  mid=$(git -C "$DECOY" rev-list --all --count 2>/dev/null || echo 0)
  [ "$mid" -gt "$before" ] || {
    echo PLANT_DEAD
    exit 3
  }
  (cd "$FIX" && export GIT_DIR="$DECOY/.git" GIT_WORK_TREE="$DECOY" &&
    sf_isolate_git && git commit -q --allow-empty -m isolated 2>/dev/null)
  after=$(git -C "$DECOY" rev-list --all --count 2>/dev/null || echo 0)
  fixn=$(git -C "$FIX" rev-list --all --count 2>/dev/null || echo 0)
  [ "$after" = "$mid" ] && [ "$fixn" -ge 1 ] && echo OK || echo "LEAKED:$mid->$after fixture=$fixn"
) >"$WORK/h5.out" 2>/dev/null
h5=$?
[ "$h5" = 0 ] && [ "$(tail -1 "$WORK/h5.out" 2>/dev/null)" = "OK" ] &&
  {
    echo "  ok   [-] a planted GIT_DIR cannot capture a fixture's commit"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL git isolation: GIT_DIR capture (rc=$h5 out='$(tail -1 "$WORK/h5.out" 2>/dev/null)')"
    FAIL=$((FAIL + 1))
  }

# --- the adapters must state the same rules as WORKFLOW.md ---------------------------------------
# WORKFLOW.md is NOT the propagation. Each adapter restates the rules in its own words for its own
# audience, and ~/.codex/AGENTS.md gets a COPY of its block rather than a symlink — so an adapter can
# be left behind and every agent but one keeps following the old workflow, silently and indefinitely.
# That is exactly what had happened before this change: all three still said "iterate while any
# Blocker/Should-fix remains" long after the rule moved on.
#
# Asserted CLAUSE BY CLAUSE rather than by matching a sentence out of WORKFLOW.md: the adapters are
# deliberately worded differently, so a whole-sentence match would either fail on wording or pass on a
# partial statement. One grep per clause per file, so a missing one names itself.
echo "adapter consistency:"
# WORKFLOW.md is in this list, checked against the SAME clauses. The stated failure mode is adapters
# drifting from the canonical document, but the inverse — WORKFLOW.md reverting while the adapters
# hold — leaves agents on mixed rules just as effectively, and a suite watching one direction says
# nothing about the other. (It was first appended AFTER the clause calls, where it did nothing at
# all: reverting WORKFLOW.md produced zero failures. Order matters; the list must exist first.)
# Since 2026-10-15 the Codex block and the Cursor rule are POINTERS to the skill, not copies, so the
# rules live in two files: the skill, which is what an agent loads, and WORKFLOW.md. The pointers are
# checked below as pointers ("the Codex block and the Cursor rule stay pointers").
SF_ADAPTERS="adapters/skill/SKILL.md WORKFLOW.md"
# Whitespace is NORMALISED before matching. Without it this test is really a test of line wrapping:
# the first run of it failed on "the plan file is / the source" and "Still two / gates, never three",
# both correct sentences that happened to break across a line. That would have taught the next person
# to reflow prose to please a grep, which is backwards — the adapters are prose for humans and their
# wrapping must stay free.
# KEEP EVERY `{0,n}` AT 255 OR BELOW. BSD grep — which is what macOS runs — refuses a larger
# interval outright with "maximum repetition exceeds 255", and `grep -q` then exits non-zero exactly
# as it would for a genuine miss. So the clause reports the phrase missing from every adapter, on
# macOS only, while GNU grep on Linux passes it. That is the worst shape a test failure can take:
# it names the wrong cause, and it is invisible on the machine most of this gets written on. To span
# a longer distance, concatenate intervals — `.{0,200}.{0,200}` — rather than raising one.
sf_clause() { # sf_clause <label> <extended-regex> [files]
  local label="$1" re="$2" files="${3:-$SF_ADAPTERS}" f miss=""
  for f in $files; do
    tr '\n' ' ' <"$HERE/../$f" | tr -s ' ' | grep -Eqi -- "$re" || miss="$miss $f"
  done
  [ -z "$miss" ] &&
    {
      echo "  ok   [-] every listed doc states: $label"
      PASS=$((PASS + 1))
    } ||
    {
      echo "  FAIL adapter consistency: '$label' missing from$miss"
      FAIL=$((FAIL + 1))
    }
}
# The careful lane's step-by-step rules live in WORKFLOW.md only since the two lanes: the adapters
# summarise the lanes and point at it. Restating every rule in four files is what made the rules
# expensive to change, so the details are checked where they live.
sf_wf_clause() { sf_clause "$1" "$2" WORKFLOW.md; }
# THE CAP IS ENFORCED, not merely documented. This suite is written and run on Linux, where GNU grep
# accepts any interval, so a clause with `.{0,300}` looks perfectly healthy here and fails only on
# the macOS job — reporting the phrase as missing from every adapter, which sends the next reader
# after a documentation drift that never happened. It went unnoticed for eleven days that way. The
# check below reads THIS file, so the guard cannot drift from the clauses it guards.
# EVERY interval form. BSD grep rejects any bound over 255 whatever shape it is written in — the
# exact count, the open form, either bound of a range, and the leading-comma form GNU reads as a
# zero lower bound — and a guard that only knew the one form this commit happened to fix would let
# the next clause reproduce the identical macOS-only "missing from every adapter" report that this
# check exists to prevent. So the extractor takes anything brace-wrapped that is digits and commas,
# splits on the comma, and tests every numeric field it finds; empty fields fall out at the filter.
#
# Comment lines are skipped: the paragraph above names the bad interval as its example, and a guard
# that fails on its own description of the rule teaches people to delete the description. (An
# interval inside a TRAILING comment on a code line would still trip it, as would a brace-wrapped
# number that is not a regex at all. Left alone: telling where a comment starts in shell needs a
# parser, and a rare false alarm that names the real rule is a better failure than a parser that
# gets quoting wrong.)
sf_intervals_over_cap() { # <file> -> prints every bound above the cap, empty when the file is fine
  grep -vE '^[[:space:]]*#' "$1" |
    grep -oE '\{[0-9,]+\}' | tr -d '{}' | tr ',' '\n' |
    grep -E '^[0-9]+$' | awk '$1 > 255' | sort -u | tr '\n' ' '
}
sf_over_cap=$(sf_intervals_over_cap "$HERE/test-ship-feature.sh")
[ -z "$sf_over_cap" ] &&
  {
    echo "  ok   [-] every regex interval stays within BSD grep's 255 cap"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL regex interval(s) over BSD grep's 255 cap (fails on macOS only): $sf_over_cap"
    FAIL=$((FAIL + 1))
  }

# THE GUARD'S OWN NEGATIVE PATH. The check above only says this file is currently clean, which it
# would also say if the guard matched nothing at all — and this suite has already shipped exactly
# that: a first version whose `tr` deleted the zeros inside the number, read 300 as 3, and passed
# everything. A guard nobody has watched reject anything is decoration.
#
# The interval forms are BUILT from parts rather than written literally, because a literal one on a
# non-comment line of this file would be flagged by the very check these cases exercise.
sf_lb='{'
sf_rb='}'
sf_capdir="$WORK/capguard"
mkdir -p "$sf_capdir"
sf_cap_case() { # <spec> <flag|clean> <description>
  local spec="$1" want="$2" why="$3" got
  printf "sf_clause \"x\" 'a.%s%s%s b'\n" "$sf_lb" "$spec" "$sf_rb" >"$sf_capdir/case"
  got=$(sf_intervals_over_cap "$sf_capdir/case")
  if { [ "$want" = flag ] && [ -n "$got" ]; } || { [ "$want" = clean ] && [ -z "$got" ]; }; then
    echo "  ok   [-] the interval guard $why"
    PASS=$((PASS + 1))
  else
    echo "  FAIL the interval guard failed to $why (reported '$got')"
    FAIL=$((FAIL + 1))
  fi
}
sf_cap_case "0,300" flag "rejects the {0,n} form this change fixed"
sf_cap_case "300" flag "rejects the exact-count {n} form"
sf_cap_case "300," flag "rejects the open {n,} form"
sf_cap_case "1,300" flag "rejects a high upper bound in {m,n}"
sf_cap_case ",300" flag "rejects the {,n} form"
sf_cap_case "256" flag "rejects a bound one over the cap"
sf_cap_case "255" clean "accepts a bound exactly at the cap"
sf_cap_case "0,200" clean "accepts an ordinary interval"
# The comment skip is load-bearing, not cosmetic: without it the paragraph that documents this rule
# fails the suite, and the next person makes it green by deleting the paragraph.
printf '# an example naming .%s0,300%s as the thing to avoid\n' "$sf_lb" "$sf_rb" >"$sf_capdir/comment"
sf_cap_comment=$(sf_intervals_over_cap "$sf_capdir/comment")
[ -z "$sf_cap_comment" ] &&
  {
    echo "  ok   [-] the interval guard ignores a full-line comment"
    PASS=$((PASS + 1))
  } ||
  {
    echo "  FAIL the interval guard flagged an interval inside a comment"
    FAIL=$((FAIL + 1))
  }

# The patterns are MULTI-WORD ANCHORS, not single tokens. The first version of this test grepped for
# `qualifying`, `narrow`, `benched`, `dispositions` — words that survive having the rule around them
# deleted or REVERSED, so the test would stay green while the adapter said the opposite. Two reviewers
# caught it independently. Each pattern below has to match a phrase that only the correct rule makes.
sf_wf_clause "always pass the plan with --context-file" 'always pass the plan.{0,40}context-file|context-file.{0,80}always pass the plan'
sf_wf_clause "the plan file is the source of the PR body" 'plan file is the source'
sf_wf_clause "iterate ONLY for a Blocker or qualifying" 'iterate only for a .{0,20}blocker.{0,60}qualifying'
sf_wf_clause "the closing round is the full quorum" 'closing.{0,140}full quorum|full quorum again.{0,160}(candidate|merge)'
sf_wf_clause "never publish the derived context file" '(never|not) .{0,20}(gh pr edit|re-publish).{0,120}derived|derived file to the pr body'
sf_wf_clause "exit 4 = escalate, never --reset" 'exit .?4.?.{0,120}(escalat|stop)'
# The pattern matches "no --reviewers" / "do not pass --reviewers" and NOT the old advice, which
# read "name the reviewers you have — the quorum". `sf_clause` requires EVERY file in SF_ADAPTERS to
# match — the skill AND `WORKFLOW.md`, which is the source it compresses — so one file reverting
# fails the suite; verified by reverting the phrasing in each adapter in turn and watching this
# clause fail on each. A grep run once at PR time does not survive the next edit; this does.
# (Two reviewers read the old wording here as "adapters only" and filed WORKFLOW.md as unguarded.
# It is guarded; the wording was not.)
#
# No `dont` alternative: it can never match "don't", and a dead branch in a guard reads as coverage
# that is not there.
# Anchored on a stable PHRASE, not on a negation word: `(no|not|never)` also matches "note" and
# "another", so that pattern could pass on text that never states the rule at all.
# `SF_PANEL_DOCS` = the adapters and WORKFLOW.md that SF_ADAPTERS already covers, PLUS README.md
# and config.example, which this rule also lives in. They are NOT in SF_ADAPTERS because every other
# clause in this block is asserted against all of it and neither file states those rules — README is
# reference prose and config.example is a template. The panel clauses below are the ones that do
# apply to all five, and a revert in either file is exactly as damaging as one in an adapter.
SF_PANEL_DOCS="$SF_ADAPTERS README.md config.example"
sf_panel_clause() { # sf_panel_clause <label> <extended-regex>
  local label="$1" re="$2" f miss=""
  for f in $SF_PANEL_DOCS; do
    tr '\n' ' ' <"$HERE/../$f" | tr -s ' ' | grep -Eqi -- "$re" || miss="$miss $f"
  done
  [ -z "$miss" ] &&
    {
      echo "  ok   [-] every panel doc states: $label"
      PASS=$((PASS + 1))
    } ||
    {
      echo "  FAIL panel doc consistency: '$label' missing from$miss"
      FAIL=$((FAIL + 1))
    }
}
# `\bno\b`, not bare `no`: without the boundary "know --reviewers" or "into --reviewers" satisfies
# the pin without the rule being stated at all.
# EVERY alternative is a NEGATION. An `injects your configured quorum` alternative was tried and
# removed: `config.example` said "injects it as --reviewers" BEFORE this change, so a revert that
# dropped "run WITHOUT that flag" would still have matched. A pin that the old text satisfies is not
# a pin.
sf_panel_clause "omit --reviewers: the config is the panel" '\bno\b .?--reviewers.?|do not pass .?--reviewers|omit .?--reviewers|without .?--reviewers|WITHOUT that flag'
# The POSITIVE clause alone is not enough, which round 1 of the cross-review caught: the file that
# prompted it kept "(explicit list = the agents you have, e.g. claude,codex,cursor)" three lines
# under the new rule, and matched anyway. A doc that says both things teaches the old one, because
# the old one is the concrete instruction. So: the old advice must be ABSENT, not merely outvoted.
# Best-effort by construction: this is a blacklist of the phrasings that have actually appeared, so
# a NEW way of saying the same thing would slip past it. The positive clauses above carry the load;
# this one stops the exact regressions we have already seen twice.
sf_panel_absent() { # sf_panel_absent <label> <extended-regex>
  local label="$1" re="$2" f hit=""
  for f in $SF_PANEL_DOCS; do
    tr '\n' ' ' <"$HERE/../$f" | tr -s ' ' | grep -Eqi -- "$re" && hit="$hit $f"
  done
  [ -z "$hit" ] &&
    {
      echo "  ok   [-] no panel doc states: $label"
      PASS=$((PASS + 1))
    } ||
    {
      echo "  FAIL panel doc consistency: '$label' still present in$hit"
      FAIL=$((FAIL + 1))
    }
}
# Every phrasing of the old advice that has actually appeared, not just the ones containing
# `--reviewers`: the flag name is exactly what a grep finds, and twice now the surviving sentence
# was one that never mentions it — "(explicit list = the agents you have…)" under the new rule in
# two adapters, then "always pass an explicit reviewer list" in WORKFLOW's Quorum paragraph, which
# the suite passed over while the file three lines up said the opposite.
# The counterpart is pinned too, and for the reason this whole block exists: an edit that KEEPS
# "no --reviewers" while dropping the benched-seat caveat passes the positive clause and brings back
# the exact silent thinning the rule is there to prevent. Omitting the flag fixes a stale list; only
# reading the output catches a seat that dropped out.
sf_panel_clause "read each round's startup lines" 'startup lines.{0,200}(actually ran|benched|relay-only|exits .?0)'
sf_panel_absent "type the panel yourself" 'explicit list = the agents|name the reviewers you have|--reviewers <your|pass an .{0,10}explicit reviewer list|always pass an explicit'
sf_wf_clause "a clean round 1 IS the closing round" 'round 1 was already clean|clean initial round is the closing round'
sf_wf_clause "exit 0 = DISPATCHED, and benched still exits 0" '(dispatched reviewer ran|supposed to dispatch).{0,200}.{0,200}benched'
sf_wf_clause "non-qualifying findings are left unfixed" 'non-qualifying findings are recorded and left unfixed'
sf_wf_clause "post dispositions BEFORE re-running" 'post (the )?dispositions before re-running'
sf_wf_clause "keep the relay marker out of that comment" '(do .{0,4}not.{0,4} put|keep|must not contain).{0,80}marker text.{0,180}delet'
sf_wf_clause "disputes are routed to Gate 2 with both positions" 'disput.{0,80}gate 2.{0,60}both positions|disput.{0,80}both positions'
sf_wf_clause "and that is not a third gate" 'two.{0,12}gates, (never|not) three'
sf_wf_clause "the plan is immutable once approved" 'immutable once approved'
sf_wf_clause "the initial quorum excludes the author" 'except the author'
sf_wf_clause "the author classifies findings in writing" 'author classifies( each finding)? in writing'

# --- plan-review (step 2) gets the SAME discipline, in its own terms ----------------------------
# A real session ran 13 rounds of plan-review before the panel agreed (~1h15m burned on convergence,
# not the plan) because step 2 only ever said "iterate (approx 2 rounds)" — a suggestion, not a rule.
# "plan-qualifying" is asserted as a term DISTINCT from step 5's "qualifying Should-fix" (PR-qualifying:
# correctness/safety/deployability/verification) — the two must not collapse into one grep-satisfying
# phrase, or an adapter could state step 5's rule alone and wrongly pass for step 2's.
sf_wf_clause "plan-review round excludes exit 3" 'exit .?3.?.{0,200}does.{0,6}not.{0,6}count as a round'
sf_wf_clause "two consecutive exit-3s stop retrying and drop that reviewer" 'two consecutive attempts.{0,120}stop retrying.{0,160}drop that reviewer'
sf_wf_clause "a reduced panel is escalated to the human, not silent" '(tell the human|human.{0,20}call).{0,160}reduced panel|reduced panel.{0,160}(tell the human|human.{0,20}call)'
sf_wf_clause "plan-qualifying is compared against PR-qualifying/qualifying Should-fix" 'plan-qualifying.{0,150}.{0,150}(qualifying should-fix|pr-qualifying)|(qualifying should-fix|pr-qualifying).{0,150}.{0,150}plan-qualifying'
sf_wf_clause "plan-qualifying must not be conflated with PR-qualifying" '(not the same as|must not be conflated|distinct term|do not conflate)'
sf_wf_clause "plan-qualifying covers a missing edge case" 'materially incomplete.{0,160}missing edge case|missing edge case.{0,160}materially incomplete'
sf_wf_clause "plan-qualifying covers an unhandled failure mode" 'materially incomplete.{0,160}failure mode|failure mode.{0,160}materially incomplete'
sf_wf_clause "plan-qualifying covers missing verification" 'materially incomplete.{0,160}verification|verification.{0,160}materially incomplete'
sf_wf_clause "dropping the last reviewer is not a completed round" 'zero reviewers.{0,120}(not a completed round|isn.t a completed round)'
# Iterate to consensus without asking (Fizzy #1351). The same four literals are in WORKFLOW.md, the three
# adapters and the plan-review exit-0 echo, so one clause per literal checks every place.
sf_wf_clause "only a qualifying finding changes the plan; a Nit is recorded" 'change the plan only for a blocker or a plan-qualifying should-fix.{0,200}nit.{0,60}recorded.{0,40}not applied'
# The two lanes (2026-10-15): every adapter and WORKFLOW.md state the lane rules an agent needs first.
sf_clause "the light lane is the default" 'light lane.{0,40}default'
sf_clause "the light lane lands with ship-feature land" 'ship-feature land'
sf_clause "the light lane reviews once" 'review once'
sf_clause "a change is done when it is live" 'done means live|done when it is live'
sf_clause "the careful lane is only for real risk" 'careful lane.{0,60}only'
sf_clause "the careful lane reviews the plan in one round" 'one (plan-review )?round'
sf_clause "the careful lane caps the cross-review at two rounds" 'two rounds at most|at most two'
# The old cap must be ABSENT, not merely outvoted: a file that says both teaches the old rule.
# README.md and CHANGELOG.md keep the 2-round cap as history, so they are not scanned.
sf_absent() { # sf_absent <label> <extended-regex> [files]
  local label="$1" re="$2" files="${3:-$SF_ADAPTERS}" f hit=""
  for f in $files; do
    tr '\n' ' ' <"$HERE/../$f" | tr -s ' ' | grep -Eqi -- "$re" && hit="$hit $f"
  done
  [ -z "$hit" ] &&
    {
      echo "  ok   [-] no adapter states: $label"
      PASS=$((PASS + 1))
    } ||
    {
      echo "  FAIL adapter consistency: '$label' still present in$hit"
      FAIL=$((FAIL + 1))
    }
}
sf_absent "the old 'Cap: 2 rounds'" 'cap: 2 rounds'
sf_absent "the old '2-round cap'" '2-round cap'
sf_absent "the old 'do not run a round 3'" 'do not run a round 3'
sf_absent "the old 'revise **once**'" 'revise \*\*once\*\*' WORKFLOW.md
# The two lanes (2026-10-15) removed the iterate-at-once loop, round 7 and the narrow rounds.
sf_absent "the old 'run the next round at once'" 'run the next round at once'
sf_absent "the old 'do not run a round 7'" 'do not run a round 7'
sf_absent "the old narrow rounds" 'narrow rounds|rounds 2…n'

# And the TOOL, not only the documents. `bin/ship-feature` prints the loop rule to the operator on
# every relay run, which out-ranks any document nobody re-reads — so a revert of that one string must
# turn the suite red too. It was not covered until a reviewer pointed out that it silently stays green.
#
# Matched against the `echo` LINE ONLY, not the whole file: the explanatory comment above that `case`
# arm also contains the words, so a whole-file grep stays green when the operator-facing string is
# reverted — the test would then be asserting my own comment, which is the greenwash this whole
# section exists to remove. A reviewer caught it; grep the message, not the prose about it.
sf_tool_clause() { # sf_tool_clause <label> <extended-regex>
  local label="$1" re="$2"
  grep -E '^[[:space:]]*0\)[[:space:]]*echo' "$CLI" | grep -Eqi -- "$re" &&
    {
      echo "  ok   [-] bin/ship-feature's exit-0 message states: $label"
      PASS=$((PASS + 1))
    } ||
    {
      echo "  FAIL adapter consistency: '$label' missing from bin/ship-feature's exit-0 message"
      FAIL=$((FAIL + 1))
    }
}
sf_tool_clause "every DISPATCHED reviewer ran" 'every dispatched reviewer ran'
sf_tool_clause "check the startup lines for a benched seat" 'startup lines for a benched seat'
sf_tool_clause "resolve UNDISPUTED qualifying Should-fix" 'undisputed qualifying should-fix'

# Same idea, for `cmd_plan_review`'s exit-0 message: it used to unconditionally say "revise the plan",
# which itself pushed unbounded revision loops. Matched against that ECHO LINE ONLY (not the whole
# file, for the same greenwash reason as sf_tool_clause above), so a revert of the operator-facing
# string turns the suite red even though the surrounding comments still describe the rule correctly.
sf_plan_tool_clause() { # sf_plan_tool_clause <label> <extended-regex>
  local label="$1" re="$2"
  grep -E 'Plan review done' "$CLI" | grep -Eqi -- "$re" &&
    {
      echo "  ok   [-] bin/ship-feature's plan-review exit-0 message states: $label"
      PASS=$((PASS + 1))
    } ||
    {
      echo "  FAIL adapter consistency: '$label' missing from bin/ship-feature's plan-review exit-0 message"
      FAIL=$((FAIL + 1))
    }
}
# The skill must name the durable plans directory, and must not suggest a bare `plan.md`. The skill
# is what an agent actually loads — WORKFLOW.md is canonical, but nobody reads it first — so a rule
# that lives only there reaches nobody, and the plan goes back to the scratchpad that a reboot wipes.
adapter=adapters/skill/SKILL.md
# shellcheck disable=SC2088 # a literal tilde: the adapter text holds the path as written
if grep -qF '~/.config/ship-feature/plans/' "$HERE/../$adapter"; then
  echo "  ok   [-] $adapter names the durable plans directory"
  PASS=$((PASS + 1))
else
  echo "  FAIL $adapter does not name ~/.config/ship-feature/plans/"
  FAIL=$((FAIL + 1))
fi
# Say so, because no CLI path can run before it: the agent writes the plan
# first, and an install updated by `git pull` alone never re-runs install.sh.
if grep -qF 'mkdir -p' "$HERE/../$adapter"; then
  echo "  ok   [-] $adapter tells the agent to create the directory"
  PASS=$((PASS + 1))
else
  echo "  FAIL $adapter does not say to create the plans directory"
  FAIL=$((FAIL + 1))
fi
if grep -qE '<plan\.md>|`plan\.md`|\./plan\.md' "$HERE/../$adapter"; then
  echo "  FAIL $adapter still suggests a bare plan.md"
  FAIL=$((FAIL + 1))
else
  echo "  ok   [-] $adapter no longer suggests a bare plan.md"
  PASS=$((PASS + 1))
fi
# The Codex block and the Cursor rule stay pointers. Both are always loaded, and while they were
# copies of the lanes every rule change had to be made in four files. A pointer must name the skill
# file, so an agent whose harness did not load the skill can still open it; and it must not grow the
# lane steps back, because a copy that is always loaded wins over a skill that is loaded on request.
for adapter in adapters/codex/AGENTS.snippet.md adapters/cursor/ship-feature.md; do
  # shellcheck disable=SC2088 # a literal tilde: the adapter text holds the path as written
  if grep -qF '~/.agents/skills/ship-feature/SKILL.md' "$HERE/../$adapter"; then
    echo "  ok   [-] $adapter points at the skill file"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $adapter does not name ~/.agents/skills/ship-feature/SKILL.md"
    FAIL=$((FAIL + 1))
  fi
  if grep -qE 'ship-feature (review|land|plan-review|relay|preflight)' "$HERE/../$adapter"; then
    echo "  FAIL $adapter restates lane steps: it must stay a pointer to the skill"
    FAIL=$((FAIL + 1))
  else
    echo "  ok   [-] $adapter is a pointer, not a copy of the lane steps"
    PASS=$((PASS + 1))
  fi
  # shellcheck disable=SC2088 # a literal tilde: the adapter text holds the path as written
  if grep -qF '~/.config/ship-feature/WORKFLOW.md' "$HERE/../$adapter"; then
    echo "  ok   [-] $adapter names WORKFLOW.md"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $adapter does not name ~/.config/ship-feature/WORKFLOW.md"
    FAIL=$((FAIL + 1))
  fi
  # The one rule a pointer keeps: missed, an agent that skipped the skill lands a payment, consent
  # or auth change itself.
  if tr '\n' ' ' <"$HERE/../$adapter" | tr -s ' ' | grep -Eqi 'careful lane.{0,60}human.{0,60}merges.{0,10}never merge those yourself'; then
    echo "  ok   [-] $adapter keeps the careful lane's human merge"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $adapter lost the careful lane's human merge"
    FAIL=$((FAIL + 1))
  fi
done
# A Cursor rule that is not always applied is applied on request, like a skill: the pointer would
# then do nothing that the skill does not already do.
check "the Cursor rule is always applied" \
  "$(grep -cx 'alwaysApply: true' "$HERE/../adapters/cursor/ship-feature.md")" 1

sf_plan_tool_clause "clean round goes straight to Gate 1" 'straight to gate 1'
sf_plan_tool_clause "cap is 1 round" 'cap: 1 round'
sf_plan_tool_clause "keeps the review vocabulary (plan-qualifying)" 'plan-qualifying'
# Every 'Plan review done' line: none may still state the old cap.
sf_plan_tool_absent() { # sf_plan_tool_absent <label> <extended-regex>
  local label="$1" re="$2"
  grep -E 'Plan review done' "$CLI" | grep -Eqi -- "$re" &&
    {
      echo "  FAIL bin/ship-feature's plan-review exit-0 message still states: $label"
      FAIL=$((FAIL + 1))
    } ||
    {
      echo "  ok   [-] bin/ship-feature's plan-review exit-0 message does not state: $label"
      PASS=$((PASS + 1))
    }
}
sf_plan_tool_absent "the old 'both times'" 'both times'
sf_plan_tool_absent "the old 'do not run a round 3'" 'do not run a round 3'
sf_plan_tool_absent "the old 2-round cap" 'cap.{0,10}(2|two) rounds'
sf_plan_tool_absent "the old 6-round cap" 'cap.{0,10}(6|six) rounds'

# The exit-3 (NOT clean) message gets the same treatment: it used to say "Fix and re-run" with no
# mention of the two-consecutive-failure drop rule, which itself invites retrying the same reviewer
# forever.
sf_plan_tool_clause_notclean() { # same pattern as sf_plan_tool_clause, but for the "NOT clean" line
  local label="$1" re="$2"
  grep -E 'Plan review NOT clean' "$CLI" | grep -Eqi -- "$re" &&
    {
      echo "  ok   [-] bin/ship-feature's plan-review exit-3 message states: $label"
      PASS=$((PASS + 1))
    } ||
    {
      echo "  FAIL adapter consistency: '$label' missing from bin/ship-feature's plan-review exit-3 message"
      FAIL=$((FAIL + 1))
    }
}
sf_plan_tool_clause_notclean "drop the reviewer on a second consecutive attempt" 'second consecutive attempt.{0,60}drop'
sf_plan_tool_clause_notclean "tell the human about the reduced panel" 'reduced panel'

# The pre-push hook rule (Fizzy #1370): WORKFLOW.md and the three adapters, then the files that carry
# the CLI text.
sf_wf_clause "preflight refuses a repo without the hook" 'preflight`[^`]{0,30}refuses'
sf_wf_clause "the hook lives at .githooks/pre-push" '\.githooks/pre-push'
sf_wf_clause "the hook runs the tests, a linter and a formatter check" 'tests, a linter and a formatter'
sf_wf_clause "the agent names the hook's checks in the implementation notes" 'implementation notes'
sf_doc() { # sf_doc <label> <file> <extended-regex>
  tr '\n' ' ' <"$HERE/../$2" | tr -s ' ' | grep -Eqi -- "$3" &&
    {
      echo "  ok   [-] $2 states: $1"
      PASS=$((PASS + 1))
    } ||
    {
      echo "  FAIL $2 does not state: $1"
      FAIL=$((FAIL + 1))
    }
}
sf_doc "the preflight bullet names the hook" README.md 'ship-feature preflight` — .{0,200}`\.githooks/pre-push`'
bash "$CLI" help | grep -q '\.githooks/pre-push'
check "ship-feature help names the pre-push hook in preflight" $? 0

# --- this repo's own gate: .githooks/pre-push and bin/ci ----------------------
# The hook runs bin/ci on every push, and bin/ci runs this suite as its last stage. So no case here
# reaches the suite stage of the real checkout: the hook cases run a stub bin/ci, and the bin/ci
# cases either fail before the suite stage or run a copy of bin/ci whose ROOT is a temp repo with a
# stub suite. Every fixture lives under $WORK, never in the checkout, so the hook's "the gate
# created untracked files" check cannot fire on a leftover. If a broken bin/ci lets a case reach
# the suite stage anyway, the guard at the top of this file stops the nested suite at once.
OWN="$HERE/.."

bash "$HERE/test-ship-feature.sh" >"$WORK/nested.out" 2>&1
_nested_rc=$?
check "own gate: a suite started inside a running suite exits 2 at once and says why" "$_nested_rc|$(grep -c 'started inside a running suite' "$WORK/nested.out" | tr -d ' ')" "2|1"

_own_modes="$(git -C "$OWN" ls-files -s -- .githooks/pre-push bin/ci | awk '{ printf "%s %s;", $1, $4 }')"
check "own gate: .githooks/pre-push and bin/ci are in the index with mode 100755" "$_own_modes" "100755 .githooks/pre-push;100755 bin/ci;"

# The hook, by behavior: a temp repo with a copy of the committed hook, a stub bin/ci that leaves a
# marker, runs the shell lines in $HK/act (empty unless a case needs the gate to change something)
# and exits with the code in $HK/rc, and a bare remote. Two commits, so HEAD~1 exists. The
# files are executable on disk AND recorded 100755: git skips a hook file that is not executable on
# disk, whatever the index says. core.hooksPath is the isolation's slot 2, set to .githooks for
# the push only, as pf() does for preflight.
HK="$WORK/own-hook"
mkdir -p "$HK/repo/.githooks" "$HK/repo/bin"
git init -q --bare "$HK/remote.git"
git init -q -b main "$HK/repo"
cp "$OWN/.githooks/pre-push" "$HK/repo/.githooks/pre-push"
printf '#!/bin/sh\n: >"%s/ran"\n. "%s/act"\nexit "$(cat "%s/rc")"\n' "$HK" "$HK" "$HK" >"$HK/repo/bin/ci"
: >"$HK/act"
printf 'ignored.txt\n' >"$HK/repo/.gitignore"
chmod +x "$HK/repo/.githooks/pre-push" "$HK/repo/bin/ci"
(
  cd "$HK/repo" && git add --chmod=+x .githooks/pre-push bin/ci && git add .gitignore && git commit -q -m one &&
    echo x >f && git add f && git commit -q -m two && git remote add origin "$HK/remote.git"
)
hk_push() { # hk_push <refspec>: sets _hk_rc; output in $HK/out
  rm -f "$HK/ran"
  (cd "$HK/repo" && GIT_CONFIG_VALUE_2=.githooks git push origin "$1" >"$HK/out" 2>&1)
  _hk_rc=$?
  [ "$_hk_rc" = 0 ] || _hk_rc=nonzero
}
hk_ran() { if [ -e "$HK/ran" ]; then echo ran; else echo not-run; fi; }
hk_remote() { git -C "$HK/remote.git" rev-parse -q --verify "refs/heads/${1:-main}" || echo none; }
hk_said() { if grep -qF -- "$1" "$HK/out"; then echo said; else echo silent; fi; }

echo 0 >"$HK/rc"
hk_push HEAD:main
_hk_h1="$(git -C "$HK/repo" rev-parse HEAD)"
check "own hook H1: bin/ci exits 0 -> the push goes through, bin/ci ran, the remote has HEAD" "$_hk_rc|$(hk_ran)|$(hk_remote)" "0|ran|$_hk_h1"
# A new commit first, so the push carries code: pushing the same HEAD again sends nothing, and the
# hook then exits 0 without running the gate.
(cd "$HK/repo" && echo y >>f && git commit -q -am three)
echo 1 >"$HK/rc"
hk_push HEAD:main
check "own hook H2: bin/ci exits 1 -> the push is refused, bin/ci ran, the remote stays at the H1 commit" "$_hk_rc|$(hk_ran)|$(hk_remote)" "nonzero|ran|$_hk_h1"
echo 0 >"$HK/rc"
echo z >>"$HK/repo/f"
hk_push HEAD:main
check "own hook H3: a dirty tracked file -> refused before bin/ci, with the hook's own reason" "$_hk_rc|$(hk_ran)|$(hk_remote)|$(hk_said 'working tree has uncommitted changes')" "nonzero|not-run|$_hk_h1|said"
git -C "$HK/repo" checkout -q -- f
: >"$HK/repo/stray"
hk_push HEAD:main
check "own hook H4: an untracked file no rule ignores -> refused before bin/ci, with the hook's own reason" "$_hk_rc|$(hk_ran)|$(hk_remote)|$(hk_said 'untracked files present')" "nonzero|not-run|$_hk_h1|said"
rm -f "$HK/repo/stray"
: >"$HK/repo/ignored.txt"
hk_push HEAD:main
check "own hook H5: an untracked file .gitignore covers does not block -> the push goes through, bin/ci ran" "$_hk_rc|$(hk_ran)|$(hk_remote)" "0|ran|$(git -C "$HK/repo" rev-parse HEAD)"
rm -f "$HK/repo/ignored.txt"
hk_push HEAD~1:refs/heads/other
check "own hook H6: a push of a commit that is not HEAD -> refused before bin/ci, with the hook's own reason" "$_hk_rc|$(hk_ran)|$(hk_remote other)|$(hk_said 'these refs are not your checked-out HEAD')" "nonzero|not-run|none|said"
# The remote has HEAD since H5, so git runs the hook with no stdin lines. A failing gate shows that
# the hook did not run it.
echo 1 >"$HK/rc"
hk_push HEAD:main
check "own hook H7: a push with nothing to send -> exits 0, bin/ci does not run" "$_hk_rc|$(hk_ran)|$(hk_remote)" "0|not-run|$(git -C "$HK/repo" rev-parse HEAD)"
git -C "$HK/remote.git" update-ref refs/heads/gone "$_hk_h1"
echo z >>"$HK/repo/f"
hk_push :refs/heads/gone
check "own hook H8: a push that only deletes a ref, from a dirty tree with a failing gate -> goes through, bin/ci does not run" "$_hk_rc|$(hk_ran)|$(hk_remote gone)" "0|not-run|none"
git -C "$HK/repo" checkout -q -- f
# The gate passes but changes the checkout: each change is refused after bin/ci. A new commit first,
# so the push carries code; every case is refused, so the remote stays at HEAD~1.
(cd "$HK/repo" && echo v >>f && git commit -q -am four)
_hk_h7="$(git -C "$HK/repo" rev-parse HEAD~1)"
echo 0 >"$HK/rc"
echo 'echo w >>f' >"$HK/act"
hk_push HEAD:main
check "own hook H9: bin/ci passes but edits a tracked file -> refused after bin/ci, with the hook's own reason" "$_hk_rc|$(hk_ran)|$(hk_remote)|$(hk_said 'the gate MODIFIED tracked files')" "nonzero|ran|$_hk_h7|said"
git -C "$HK/repo" checkout -q -- f
echo ': >made-by-ci' >"$HK/act"
hk_push HEAD:main
check "own hook H10: bin/ci passes but creates an untracked file -> refused after bin/ci, with the hook's own reason" "$_hk_rc|$(hk_ran)|$(hk_remote)|$(hk_said 'the gate CREATED untracked files')" "nonzero|ran|$_hk_h7|said"
rm -f "$HK/repo/made-by-ci"
echo 'git checkout -q --detach HEAD~1' >"$HK/act"
hk_push HEAD:main
check "own hook H11: bin/ci passes but moves HEAD -> refused after bin/ci, with the hook's own reason" "$_hk_rc|$(hk_ran)|$(hk_remote)|$(hk_said 'the gate MOVED HEAD')" "nonzero|ran|$_hk_h7|said"
git -C "$HK/repo" checkout -q main
: >"$HK/act"
# git diff does not look at a file marked assume-unchanged or skip-worktree, so an edit to one would
# pass every tree check: the hook refuses the mark itself, and names the file.
git -C "$HK/repo" update-index --assume-unchanged f
echo w >>"$HK/repo/f"
hk_push HEAD:main
check "own hook H12: an edited file marked assume-unchanged -> refused before bin/ci, names the file" "$_hk_rc|$(hk_ran)|$(hk_remote)|$(hk_said 'there are tracked files marked assume-unchanged or skip-worktree')|$(grep -cx '  f' "$HK/out")" "nonzero|not-run|$_hk_h7|said|1"
git -C "$HK/repo" update-index --no-assume-unchanged f
git -C "$HK/repo" checkout -q -- f
git -C "$HK/repo" update-index --skip-worktree f
echo w >>"$HK/repo/f"
hk_push HEAD:main
check "own hook H13: an edited file marked skip-worktree -> refused before bin/ci, names the file" "$_hk_rc|$(hk_ran)|$(hk_remote)|$(hk_said 'there are tracked files marked assume-unchanged or skip-worktree')|$(grep -cx '  f' "$HK/out")" "nonzero|not-run|$_hk_h7|said|1"
git -C "$HK/repo" update-index --no-skip-worktree f
git -C "$HK/repo" checkout -q -- f
echo 'git update-index --assume-unchanged f && echo w >>f' >"$HK/act"
hk_push HEAD:main
check "own hook H14: bin/ci passes but marks a file assume-unchanged and edits it -> refused after bin/ci, with the hook's own reason" "$_hk_rc|$(hk_ran)|$(hk_remote)|$(hk_said 'the gate left tracked files marked assume-unchanged or skip-worktree')" "nonzero|ran|$_hk_h7|said"
git -C "$HK/repo" update-index --no-assume-unchanged f
git -C "$HK/repo" checkout -q -- f
: >"$HK/act"
# An annotated tag pushes the tag object's id; the hook peels it to the commit, so a release tag at
# HEAD goes through and a tag at any other commit is refused.
git -C "$HK/repo" tag -a v1 -m v1
hk_push refs/tags/v1
check "own hook H15: an annotated tag at HEAD -> goes through, bin/ci ran" "$_hk_rc|$(hk_ran)|$(git -C "$HK/remote.git" rev-parse -q --verify 'refs/tags/v1^{commit}' || echo none)" "0|ran|$(git -C "$HK/repo" rev-parse HEAD)"
git -C "$HK/repo" tag -a v0 -m v0 HEAD~1
hk_push refs/tags/v0
check "own hook H16: an annotated tag at another commit -> refused before bin/ci, with the hook's own reason" "$_hk_rc|$(hk_ran)|$(git -C "$HK/remote.git" rev-parse -q --verify refs/tags/v0 || echo none)|$(hk_said 'these refs are not your checked-out HEAD')" "nonzero|not-run|none|said"
# A listing that fails must refuse, not read as "no marks". A corrupt index makes git ls-files fail.
cp "$HK/repo/.git/index" "$HK/index.bak"
printf 'not an index' >"$HK/repo/.git/index"
hk_push HEAD:main
check "own hook H17: git ls-files fails -> refused before bin/ci, with the hook's own reason" "$_hk_rc|$(hk_ran)|$(hk_remote)|$(hk_said 'git ls-files failed')" "nonzero|not-run|$_hk_h7|said"
cp "$HK/index.bak" "$HK/repo/.git/index"

# bin/ci, with stub tools first on PATH. Each stub logs EVERY call, --version included, answers
# --version as the real tool does with the version the case sets, and otherwise exits with the code
# the case sets (default 1).
CIS="$WORK/own-ci-stubs"
mkdir -p "$CIS"
cat >"$CIS/shellcheck" <<'EOF'
#!/bin/sh
echo "shellcheck $*" >>"$CISTUB_LOG"
if [ "$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: %s\nlicense: GNU General Public License, version 3\nwebsite: https://www.shellcheck.net\n' "$CISTUB_SC_VERSION"
  exit 0
fi
exit "${CISTUB_SC_RC:-1}"
EOF
cat >"$CIS/shfmt" <<'EOF'
#!/bin/sh
echo "shfmt $*" >>"$CISTUB_LOG"
if [ "$1" = "--version" ]; then
  printf 'v%s\n' "$CISTUB_FMT_VERSION"
  exit 0
fi
exit "${CISTUB_FMT_RC:-1}"
EOF
chmod +x "$CIS/shellcheck" "$CIS/shfmt"
_sc_pin="$(sed -n 's/^shellcheck[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$OWN/mise.toml")"
_fmt_pin="$(sed -n 's/^shfmt[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$OWN/mise.toml")"
export CISTUB_LOG="$WORK/own-ci.log" CISTUB_LOG2="$WORK/own-ci.log2"
ci_run() { # ci_run <bin/ci>: env CISTUB_* from the caller; sets _ci_rc; output in $WORK/own-ci.out
  : >"$CISTUB_LOG"
  : >"$CISTUB_LOG2"
  PATH="$CIS:$PATH" bash "$1" >"$WORK/own-ci.out" 2>&1
  _ci_rc=$?
  [ "$_ci_rc" = 0 ] || _ci_rc=nonzero
}
ci_said() { if grep -qF -- "$1" "$WORK/own-ci.out"; then echo said; else echo silent; fi; }
# ci_calls <tool>: every call of one tool. ci_work <tool>: its calls other than --version.
ci_calls() { grep -c "^$1 " "$CISTUB_LOG" | tr -d ' '; }
ci_work() { grep "^$1 " "$CISTUB_LOG" | grep -vc ' --version$' | tr -d ' '; }
# ci_files <tool>: "ok" when its non-version call lists every shell file and no other file.
ci_files() {
  local line f miss=""
  line=" $(grep "^$1 " "$CISTUB_LOG" | grep -v ' --version$' | head -n 1) "
  for f in .githooks/pre-push bin/ci bin/ship-feature install.sh scripts/scan-generic.sh scripts/scan-personal-data.sh test/test-ship-feature.sh \
    relay/bin/ci relay/lib-argv.sh relay/lib-grok.sh relay/lib-opencode.sh relay/lib-panel.sh relay/lib-pi.sh \
    relay/pr-review-collapse-comments relay/pr-review-consensus relay/pr-review-distill relay/pr-review-fetch \
    relay/pr-review-relay relay/review-local relay/test/lib-hermetic.sh relay/test/test-distill.sh \
    relay/test/test-fail-closed.sh relay/test/test-panel-config.sh; do
    case "$line" in *" ./$f "*) ;; *) miss="$miss missing:$f" ;; esac
  done
  for f in README.md CHANGELOG.md LICENSE mise.toml test/fixtures/leaky.sample relay/wrap-collapsed-pr-comment.mjs relay/assets/; do
    case "$line" in *"$f"*) miss="$miss extra:$f" ;; esac
  done
  echo "${miss:-ok}"
}

CISTUB_SC_VERSION="$_sc_pin" CISTUB_FMT_VERSION=0.0.1 ci_run "$OWN/bin/ci"
check "own bin/ci C2: shfmt at another version -> fails at the tools stage, names both versions, runs no tool work and no suite" "$_ci_rc|$(ci_said "shfmt is v0.0.1, mise.toml pins v$_fmt_pin")|$(ci_work shellcheck)|$(ci_work shfmt)|$(ci_said '==> tests')" "nonzero|said|0|0|silent"
CISTUB_SC_VERSION=0.0.1 CISTUB_FMT_VERSION="$_fmt_pin" ci_run "$OWN/bin/ci"
check "own bin/ci C3: shellcheck at another version -> fails at the tools stage, names both versions, runs no tool work and no suite" "$_ci_rc|$(ci_said "shellcheck is 0.0.1, mise.toml pins $_sc_pin")|$(ci_work shellcheck)|$(ci_work shfmt)|$(ci_said '==> tests')" "nonzero|said|0|0|silent"
CISTUB_SC_VERSION="$_sc_pin" CISTUB_FMT_VERSION="$_fmt_pin" CISTUB_SC_RC=1 ci_run "$OWN/bin/ci"
check "own bin/ci C4: a lint finding -> fails at the lint stage, one shellcheck -S warning call over every shell file, no format call" "$_ci_rc|$(ci_said 'bin/ci [lint]')|$(ci_work shellcheck)|$(grep -c '^shellcheck -S warning \./' "$CISTUB_LOG" | tr -d ' ')|$(ci_work shfmt)|$(ci_files shellcheck)" "nonzero|said|1|1|0|ok"
CISTUB_SC_VERSION="$_sc_pin" CISTUB_FMT_VERSION="$_fmt_pin" CISTUB_SC_RC=0 CISTUB_FMT_RC=1 ci_run "$OWN/bin/ci"
check "own bin/ci C5: a format difference -> fails at the format stage, one shfmt -i 2 -ci -d call over every shell file" "$_ci_rc|$(ci_said 'bin/ci [format]')|$(ci_work shfmt)|$(grep -c '^shfmt -i 2 -ci -d \./' "$CISTUB_LOG" | tr -d ' ')|$(ci_files shfmt)" "nonzero|said|1|1|ok"

# A temp repo laid out like this one, with a copy of the real bin/ci (its ROOT is the temp repo).
# bin/ci finds shell files through git ls-files, so every file a case needs it to see is committed.
ci_repo() { # ci_repo <name> <mise.toml content>: prints the repo path
  local r="$WORK/own-ci-$1"
  mkdir -p "$r/bin" "$r/scripts" "$r/test"
  git init -q "$r"
  cp "$OWN/bin/ci" "$r/bin/ci"
  printf '%s\n' "$2" >"$r/mise.toml"
  echo "$r"
}
ci_commit() { # ci_commit <repo> [extra paths]: commits bin/ci, mise.toml and the named paths
  local r="$1"
  shift
  (cd "$r" && git add --chmod=+x bin/ci && git add mise.toml "$@" && git commit -q -m fixture)
}

_r="$(ci_repo nopin "$(printf '[tools]\nshellcheck = "%s"\n' "$_sc_pin")")"
ci_commit "$_r"
CISTUB_SC_VERSION="$_sc_pin" CISTUB_FMT_VERSION="$_fmt_pin" ci_run "$_r/bin/ci"
check "own bin/ci C6: mise.toml with no shfmt pin -> fails and names it, before any tool is called" "$_ci_rc|$(ci_said 'mise.toml must pin shfmt exactly once')|$(ci_calls shellcheck)|$(ci_calls shfmt)" "nonzero|said|0|0"
_r="$(ci_repo duppin "$(printf '[tools]\nshellcheck = "%s"\nshfmt = "%s"\nshfmt = ""\n' "$_sc_pin" "$_fmt_pin")")"
ci_commit "$_r"
CISTUB_SC_VERSION="$_sc_pin" CISTUB_FMT_VERSION="$_fmt_pin" ci_run "$_r/bin/ci"
check "own bin/ci C6b: mise.toml with a second, empty shfmt pin -> fails and names it, before any tool is called" "$_ci_rc|$(ci_said 'mise.toml must pin shfmt exactly once')|$(ci_calls shellcheck)|$(ci_calls shfmt)" "nonzero|said|0|0"

_r="$(ci_repo syntax "$(cat "$OWN/mise.toml")")"
printf '#!/usr/bin/env bash\nif then\n' >"$_r/scripts/bad.sh"
ci_commit "$_r" scripts/bad.sh
CISTUB_SC_VERSION="$_sc_pin" CISTUB_FMT_VERSION="$_fmt_pin" CISTUB_SC_RC=0 CISTUB_FMT_RC=0 ci_run "$_r/bin/ci"
check "own bin/ci C7: a syntax error -> fails at the syntax stage and names the file; lint and format do not run" "$_ci_rc|$(ci_said 'bin/ci [syntax]: bash -n failed on ./scripts/bad.sh')|$(ci_work shellcheck)|$(ci_work shfmt)" "nonzero|said|0|0"

_r="$(ci_repo stages "$(cat "$OWN/mise.toml")")"
mkdir -p "$_r/relay/bin"
printf '#!/usr/bin/env bash\necho scan >>"$CISTUB_LOG2"\nexit "${CISTUB_SCAN_RC:-0}"\n' >"$_r/scripts/scan-generic.sh"
printf '#!/usr/bin/env bash\necho suite >>"$CISTUB_LOG2"\nexit "${CISTUB_SUITE_RC:-0}"\n' >"$_r/test/test-ship-feature.sh"
printf '#!/usr/bin/env bash\necho relay >>"$CISTUB_LOG2"\nexit "${CISTUB_RELAY_RC:-0}"\n' >"$_r/relay/bin/ci"
ci_commit "$_r" scripts/scan-generic.sh test/test-ship-feature.sh relay/bin/ci
CISTUB_SC_VERSION="$_sc_pin" CISTUB_FMT_VERSION="$_fmt_pin" CISTUB_SC_RC=0 CISTUB_FMT_RC=0 ci_run "$_r/bin/ci"
check "own bin/ci C8a: every stage passes -> exit 0, the leak scan runs, then the suite, then the relay's checks" "$_ci_rc|$(tr '\n' ' ' <"$CISTUB_LOG2")" "0|scan suite relay "
check "own bin/ci C8a: relay/ is syntax-checked, linted and formatted like the rest" "$(ci_said 'syntax (4 files)')|$(ci_said 'lint (4 files)')|$(ci_said 'format (4 files)')" "said|said|said"
CISTUB_SC_VERSION="$_sc_pin" CISTUB_FMT_VERSION="$_fmt_pin" CISTUB_SC_RC=0 CISTUB_FMT_RC=0 CISTUB_SCAN_RC=1 ci_run "$_r/bin/ci"
check "own bin/ci C8b: a leak-scan failure -> fails at that stage, the suite does not run" "$_ci_rc|$(ci_said 'bin/ci [leak scan]')|$(tr '\n' ' ' <"$CISTUB_LOG2")" "nonzero|said|scan "
CISTUB_SC_VERSION="$_sc_pin" CISTUB_FMT_VERSION="$_fmt_pin" CISTUB_SC_RC=0 CISTUB_FMT_RC=0 CISTUB_SUITE_RC=1 ci_run "$_r/bin/ci"
check "own bin/ci C8c: a suite failure -> fails at the tests stage, the relay's checks do not run" "$_ci_rc|$(ci_said 'bin/ci [tests]')|$(tr '\n' ' ' <"$CISTUB_LOG2")" "nonzero|said|scan suite "
CISTUB_SC_VERSION="$_sc_pin" CISTUB_FMT_VERSION="$_fmt_pin" CISTUB_SC_RC=0 CISTUB_FMT_RC=0 CISTUB_RELAY_RC=1 ci_run "$_r/bin/ci"
check "own bin/ci C8d: a relay failure -> fails at the relay stage" "$_ci_rc|$(ci_said 'bin/ci [relay]')|$(tr '\n' ' ' <"$CISTUB_LOG2")" "nonzero|said|scan suite relay "

# --- autonomous mode is gone: its commands stop with a message, never run ------------------------
# An agent with stale instructions must learn why, not get "unknown command" or a relay error.
for _rm in "plan-consensus plan.md --autonomous" "merge-gate 1 --autonomous --merge" "relay --autonomous --pr 1"; do
  # shellcheck disable=SC2086 # the words are the command line under test
  _out="$(PATH="$WORK/empty-path:/usr/bin:/bin" bash "$CLI" $_rm 2>&1)"
  _rc=$?
  check "'$_rm' stops (exit 1) and says autonomous mode was removed" "$_rc|$(printf '%s' "$_out" | grep -c 'removed with autonomous mode')" "1|1"
done

# --- land: the light lane's merge, no PR -------------------------------------
# A fresh remote per case: land pushes, so the cases must not share a default branch.
# ld_repo <name> [nohook]: a bare remote with one seed commit (carrying the committed .githooks/pre-push
# unless "nohook") and a clone with a feature worktree "f" holding one commit. Prints the clone path.
ld_repo() {
  local r="$WORK/land-$1"
  git init -q --bare "$r.git" && git -C "$r.git" symbolic-ref HEAD refs/heads/main &&
    git clone -q "$r.git" "$r" 2>/dev/null &&
    (cd "$r" && { [ "${2:-}" = nohook ] || sf_seed_hook .; } && echo seed >seed.txt && git add seed.txt &&
      git commit -q -m seed && git push -q origin HEAD:main &&
      git remote set-head origin main >/dev/null 2>&1 && printf '.claude/\n' >>.git/info/exclude &&
      git worktree add -q -b f .claude/worktrees/f origin/main &&
      cd .claude/worktrees/f && echo feat >feat.txt && git add feat.txt && git commit -q -m "add feat") &&
    printf '%s\n' "$r"
}
# ld_tip <clone>: the remote's main, read from the bare repo itself (not a possibly stale tracking ref).
ld_tip() { git --git-dir="$1.git" rev-parse refs/heads/main; }
# land with core.hooksPath=.githooks, as a real clone has it (the isolation points it nowhere).
ld() { GIT_CONFIG_VALUE_2=.githooks bash "$CLI" land "$@"; }
# ld_main_commit <clone> <hook body> <file>: a commit on the remote's main that sets the committed hook
# and adds <file>, made from a scratch branch in the clone.
ld_main_commit() {
  (cd "$1" && git checkout -q -B other origin/main && printf '#!/bin/sh\n%s\n' "$2" >.githooks/pre-push &&
    git add --chmod=+x .githooks/pre-push && echo m >"$3" && git add "$3" && git commit -q -m main &&
    git push -q origin HEAD:main)
}

_r="$(ld_repo ok)"
_before="$(ld_tip "$_r")"
(cd "$_r/.claude/worktrees/f" && ld -m "Not fixed: a nit" >"$WORK/land.out" 2>&1)
_rc=$?
_tip="$(ld_tip "$_r")"
_p1="$(git --git-dir="$_r.git" rev-parse "$_tip^1")"
_p2="$(git --git-dir="$_r.git" rev-parse "$_tip^2" 2>/dev/null)"
_f="$(git -C "$_r/.claude/worktrees/f" rev-parse f)"
_msg="$(git --git-dir="$_r.git" log -1 --format=%B "$_tip")"
_on="$(git -C "$_r/.claude/worktrees/f" rev-parse --abbrev-ref HEAD)"
check "land: a merge commit on main, first parent the old main, second the branch" "$_rc|$([ "$_p1" = "$_before" ] && echo old)|$([ "$_p2" = "$_f" ] && echo branch)" "0|old|branch"
check "land: the merge message names the branch and carries each -m" "$(printf '%s' "$_msg" | grep -c "^Merge branch 'f'$")|$(printf '%s' "$_msg" | grep -c '^Not fixed: a nit$')" "1|1"
check "land: returns to the feature branch and prints the cleanup command" "$_on|$(grep -c 'git worktree remove' "$WORK/land.out")" "f|1"

_r="$(ld_repo default)"
(cd "$_r" && git checkout -q -B main origin/main && ld >/dev/null 2>&1)
check "land: refuses on the default branch" $? 1

_r="$(ld_repo maintree)"
_before="$(ld_tip "$_r")"
(cd "$_r" && git checkout -q -b g origin/main && echo g >g.txt && git add g.txt && git commit -q -m g && ld >/dev/null 2>&1)
_rc=$?
check "land: refuses a feature branch in the main working tree, which stays on it" "$_rc|$([ "$(ld_tip "$_r")" = "$_before" ] && echo same)|$(git -C "$_r" rev-parse --abbrev-ref HEAD)" "1|same|g"

_r="$(ld_repo nohook nohook)"
_before="$(ld_tip "$_r")"
(cd "$_r/.claude/worktrees/f" && ld >/dev/null 2>&1)
_rc=$?
check "land: refuses a tree with no committed pre-push hook, remote unchanged, back on the branch" "$_rc|$([ "$(ld_tip "$_r")" = "$_before" ] && echo same)|$(git -C "$_r/.claude/worktrees/f" rev-parse --abbrev-ref HEAD)" "1|same|f"

_r="$(ld_repo dirty)"
_before="$(ld_tip "$_r")"
echo change >>"$_r/.claude/worktrees/f/feat.txt"
(cd "$_r/.claude/worktrees/f" && ld >/dev/null 2>&1)
check "land: refuses uncommitted changes, remote unchanged" "$?|$([ "$(ld_tip "$_r")" = "$_before" ] && echo same)" "1|same"

_r="$(ld_repo empty)"
(cd "$_r/.claude/worktrees/f" && git reset -q --hard origin/main && ld >/dev/null 2>&1)
check "land: refuses a branch with nothing to land" $? 1

_r="$(ld_repo args)"
(cd "$_r/.claude/worktrees/f" && ld --squash >/dev/null 2>&1)
check "land: refuses an unknown argument" $? 1

# A conflict: main changed the same file the branch changed.
_r="$(ld_repo conflict)"
(cd "$_r" && git checkout -q -b other origin/main && echo theirs >feat.txt && git add feat.txt && git commit -q -m other && git push -q origin HEAD:main)
_before="$(ld_tip "$_r")"
(cd "$_r/.claude/worktrees/f" && ld >/dev/null 2>&1)
_rc=$?
_wt="$_r/.claude/worktrees/f"
check "land: a conflict -> refused, remote unchanged, back on the branch, no merge in progress" "$_rc|$([ "$(ld_tip "$_r")" = "$_before" ] && echo same)|$(git -C "$_wt" rev-parse --abbrev-ref HEAD)|$([ -e "$(git -C "$_wt" rev-parse --git-path MERGE_HEAD)" ] && echo merging)" "1|same|f|"

# The committed hook decides. A failing hook on main reaches the merged tree, so the push is refused.
_r="$(ld_repo hookfail)"
ld_main_commit "$_r" 'exit 1' other.txt
_before="$(ld_tip "$_r")"
(cd "$_r/.claude/worktrees/f" && ld >/dev/null 2>&1)
_rc=$?
check "land: a failing pre-push hook -> refused, remote unchanged, back on the branch" "$_rc|$([ "$(ld_tip "$_r")" = "$_before" ] && echo same)|$(git -C "$_r/.claude/worktrees/f" rev-parse --abbrev-ref HEAD)" "1|same|f"

# And the hook sees the MERGED tree: main gained main.txt (and a hook that requires it) after the branch
# was cut, so the hook passes only if land checked the merge out before pushing.
_r="$(ld_repo hooktree)"
ld_main_commit "$_r" '[ -f main.txt ] && [ -f feat.txt ]' main.txt
_before="$(ld_tip "$_r")"
(cd "$_r/.claude/worktrees/f" && ld >/dev/null 2>&1)
check "land: the pre-push hook runs on the merged tree (main's new file and the branch's file both present)" "$?|$([ "$(ld_tip "$_r")" != "$_before" ] && echo moved)" "0|moved"

echo "-------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
# FAIL is checked FIRST: when a case fails, PASS is naturally short of the total, and reporting that
# as "a test was silently dropped" sends the reader after the wrong problem.
[ "$FAIL" = 0 ] || exit 1
# Hard-coded, deliberately NOT overridable from the environment. An ambient SF_EXPECTED_PASS would
# let the very thing this suite now guarantees — that its result does not depend on the environment
# it is run in — be switched off from outside, and would hide a removed test.
EXPECTED=518
if [ "$PASS" != "$EXPECTED" ]; then
  echo "  ! expected PASS=$EXPECTED, got $PASS — a test was added or silently dropped" >&2
  exit 1
fi
