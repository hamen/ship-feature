#!/usr/bin/env bash
# Tests for the ship-feature CLI + privacy scan. Uses real temp git repos and a stubbed
# pr-review-relay; no network. Run: bash test/test-ship-feature.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLI="$HERE/../bin/ship-feature"
SCAN="$HERE/../scripts/scan-personal-data.sh"
WORK="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 1; }
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "no temp dir" >&2; exit 1; }
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
  export GIT_CONFIG_KEY_0=commit.gpgsign   GIT_CONFIG_VALUE_0=false
  export GIT_CONFIG_KEY_1=tag.gpgsign      GIT_CONFIG_VALUE_1=false
  # Signing and hooks were the measured failures, but they are not the only ambient settings that
  # reach a fixture. core.excludesFile is the sharpest: a global ignore rule for `*.dat` makes the
  # binary-scan fixture's file invisible and that test fails for a reason nobody would guess.
  # attributesFile can rewrite content through filters; fsmonitor attaches a daemon to throwaway
  # repos. color.ui=always would put ANSI into the `%G?` read below and break an exact comparison.
  # A path that does not exist: hooks are then simply never found. An ambient core.hooksPath can
  # otherwise fail or mutate every fixture commit — measured, a planted pre-commit made `git commit`
  # exit 1 until this was set.
  export GIT_CONFIG_KEY_2=core.hooksPath      GIT_CONFIG_VALUE_2="${WORK:-/nonexistent}/no-such-hooks"
  export GIT_CONFIG_KEY_3=core.excludesFile   GIT_CONFIG_VALUE_3=/dev/null
  export GIT_CONFIG_KEY_4=core.attributesFile GIT_CONFIG_VALUE_4=/dev/null
  export GIT_CONFIG_KEY_5=core.fsmonitor      GIT_CONFIG_VALUE_5=false
  export GIT_CONFIG_KEY_6=color.ui            GIT_CONFIG_VALUE_6=false
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
unset SHIP_FEATURE_WORKTREE_ROOT SHIP_FEATURE_EXCLUDE_MARKER SHIP_FEATURE_DENYLIST SHIP_FEATURE_REVIEWERS SHIP_FEATURE_PLAN_REVIEWERS CURSOR_REVIEW_MODEL KIMI3_REVIEW_MODEL GROK45HIGH_REVIEW_MODEL PR_RELAY_OPENCODE_MODEL SHIP_FEATURE_PLAN_TIMEOUT PR_RELAY_AGENT_TIMEOUT SHIP_FEATURE_GEMINI_MODEL SHIP_FEATURE_GEMINI_TESTED_VERSIONS
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

PASS=0; FAIL=0
check() { # check <desc> <actual_rc> <want_rc>
  if [ "$2" = "$3" ]; then echo "  ok   [$2] $1"; PASS=$((PASS+1)); else echo "  FAIL [got $2 want $3] $1"; FAIL=$((FAIL+1)); fi
}

echo "ship-feature tests:"

# --- build a real remote + clone + feature worktree --------------------------
REMOTE="$WORK/remote.git"; git init -q --bare "$REMOTE"
MAIN="$WORK/main"; git clone -q "$REMOTE" "$MAIN"
( cd "$MAIN" && git commit -q --allow-empty -m "seed" && git push -q origin HEAD:main && git remote set-head origin main >/dev/null 2>&1 )
git -C "$REMOTE" symbolic-ref HEAD refs/heads/main   # so fresh clones resolve origin/HEAD = main
printf '.claude/\n' >> "$MAIN/.git/info/exclude"
( cd "$MAIN" && git worktree add -q -b feat .claude/worktrees/feat origin/main )

# preflight: correct worktree setup → pass
( cd "$MAIN/.claude/worktrees/feat" && bash "$CLI" preflight >/dev/null 2>&1 ); check "preflight passes in a proper feature worktree" $? 0
# preflight: on the default branch → fail
( cd "$MAIN" && bash "$CLI" preflight >/dev/null 2>&1 ); check "preflight fails on the default branch" $? 1
# preflight: on a feature branch but NOT a linked worktree → fail
( cd "$MAIN" && git checkout -q -b feat2 && bash "$CLI" preflight >/dev/null 2>&1 ); check "preflight fails outside a linked worktree" $? 1

# preflight negatives:
# (a) worktree marker not git-ignored → fail (fresh clone, no exclude entry added)
MAINB="$WORK/mainb"; git clone -q "$REMOTE" "$MAINB"
( cd "$MAINB" && git worktree add -q -b featb .claude/worktrees/featb origin/main )
( cd "$MAINB/.claude/worktrees/featb" && bash "$CLI" preflight >/dev/null 2>&1 ); check "preflight fails when the marker is not git-ignored" $? 1
# (b) worktree outside the configured root → fail
( cd "$MAIN" && git worktree add -q -b featx "$WORK/elsewhere" origin/main )
( cd "$WORK/elsewhere" && bash "$CLI" preflight >/dev/null 2>&1 ); check "preflight fails when worktree is outside the root" $? 1
# (c) behind the default branch → fail, unless SHIP_FEATURE_ALLOW_BEHIND
( cd "$MAIN" && git checkout -q main && git commit -q --allow-empty -m "advance main" && git push -q origin main )
( cd "$MAIN/.claude/worktrees/feat" && git fetch -q origin && bash "$CLI" preflight >/dev/null 2>&1 ); check "preflight fails when behind the default branch" $? 1
( cd "$MAIN/.claude/worktrees/feat" && SHIP_FEATURE_ALLOW_BEHIND=1 bash "$CLI" preflight >/dev/null 2>&1 ); check "preflight passes behind with SHIP_FEATURE_ALLOW_BEHIND" $? 0

# --- relay passthrough: exit code + stdout preserved -------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
make_relay() { printf '#!/usr/bin/env bash\necho "RELAY-STDOUT-MARKER"\nexit %s\n' "$1" > "$BIN/pr-review-relay"; chmod +x "$BIN/pr-review-relay"; }
for code in 0 3 4; do
  make_relay "$code"
  out=$(PATH="$BIN:$PATH" bash "$CLI" relay --author claude 2>/dev/null); rc=$?
  check "relay passthrough preserves exit $code" "$rc" "$code"
  printf '%s' "$out" | grep -q "RELAY-STDOUT-MARKER" && { echo "  ok   [-] relay preserves stdout (exit $code)"; PASS=$((PASS+1)); } || { echo "  FAIL relay dropped stdout (exit $code)"; FAIL=$((FAIL+1)); }
done
# relay: dependency missing → clear failure
( PATH="/usr/bin:/bin" bash "$CLI" relay >/dev/null 2>&1 ); check "relay fails clearly when pr-review-relay is absent" $? 1

# --- privacy scan: planted term caught; clean tree passes --------------------
SREPO="$WORK/scanrepo"; git init -q "$SREPO"
( cd "$SREPO" && echo "hello world" > a.txt && git add a.txt && git commit -q -m "clean commit" )
printf 'SECRET-SLUG-XYZ\n' > "$WORK/deny.txt"
( cd "$SREPO" && bash "$SCAN" "$WORK/deny.txt" >/dev/null 2>&1 ); check "scan passes on a clean repo" $? 0
( cd "$SREPO" && echo "leak: SECRET-SLUG-XYZ" > b.txt && git add b.txt && git commit -q -m "oops" && bash "$SCAN" "$WORK/deny.txt" >/dev/null 2>&1 ); check "scan catches a planted term in history" $? 1
# planted term in a COMMIT MESSAGE (not file contents) is also caught
SREPO2="$WORK/scanrepo2"; git init -q "$SREPO2"
( cd "$SREPO2" && git commit -q --allow-empty -m "mentions SECRET-SLUG-XYZ" && bash "$SCAN" "$WORK/deny.txt" >/dev/null 2>&1 ); check "scan catches a planted term in a commit message" $? 1
# planted term in a FILENAME is also caught
SREPO3="$WORK/scanrepo3"; git init -q "$SREPO3"
( cd "$SREPO3" && : > "SECRET-SLUG-XYZ-name.txt" && git add . && git commit -q -m "add file" && bash "$SCAN" "$WORK/deny.txt" >/dev/null 2>&1 ); check "scan catches a deny-listed term in a filename" $? 1

# --- install.sh under a throwaway HOME (exercises symlinks + AGENTS.md awk) ---
FAKEHOME="$WORK/home"; mkdir -p "$FAKEHOME"
( cd "$HERE/.." && HOME="$FAKEHOME" bash install.sh >/dev/null 2>&1 ); check "install.sh succeeds under a clean HOME" $? 0
if [ -f "$FAKEHOME/.config/ship-feature/WORKFLOW.md" ] && [ -f "$FAKEHOME/.local/bin/ship-feature" ] \
   && [ -f "$FAKEHOME/.claude/skills/ship-feature/SKILL.md" ] \
   && grep -qF '# >>> ship-feature >>>' "$FAKEHOME/.codex/AGENTS.md" 2>/dev/null; then
  echo "  ok   [-] install wired WORKFLOW + CLI + skill + Codex block"; PASS=$((PASS+1))
else echo "  FAIL install did not wire everything"; FAIL=$((FAIL+1)); fi
# The plans directory is step 1 of the pipeline, so it must exist before the
# first plan is written — not be created by some later command that happens to
# run first.
check "install.sh creates the plans directory" "$([ -d "$FAKEHOME/.config/ship-feature/plans" ] && echo yes || echo no)" yes
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
( cd "$HERE/.." && HOME="$FAKEHOME" bash install.sh >/dev/null 2>&1 )
check "install.sh re-secures an existing loose plans directory" "$(dir_mode "$FAKEHOME/.config/ship-feature/plans")" "drwx------"
# Fail-closed: a FILE where the plans directory belongs must make the install
# fail loudly. Reporting success without it is the dangerous outcome — the next
# plan goes somewhere volatile and nobody is told.
FAKEHOME3="$WORK/home3"; mkdir -p "$FAKEHOME3/.config/ship-feature"
: > "$FAKEHOME3/.config/ship-feature/plans"
( cd "$HERE/.." && HOME="$FAKEHOME3" bash install.sh >/dev/null 2>&1 )
check "install.sh fails when the plans path is a file" $? 1
# A `plans` SYMLINK must not have its target tightened: chmod follows the link,
# and an installer silently changing permissions outside its own tree is not
# acceptable however well meant.
FAKEHOME4="$WORK/home4"; mkdir -p "$FAKEHOME4/.config/ship-feature" "$WORK/shared-plans"
chmod 775 "$WORK/shared-plans"
ln -s "$WORK/shared-plans" "$FAKEHOME4/.config/ship-feature/plans"
( cd "$HERE/.." && HOME="$FAKEHOME4" bash install.sh >/dev/null 2>&1 )
check "install.sh leaves a symlinked plans target alone" "$(dir_mode "$WORK/shared-plans")" "drwxrwxr-x"
( cd "$HERE/.." && HOME="$FAKEHOME" bash install.sh >/dev/null 2>&1 )
# grep -c prints "0" and exits 1 on no match; capture stdout, don't append via `|| echo 0`.
n=$(grep -cF '# >>> ship-feature >>>' "$FAKEHOME/.codex/AGENTS.md" 2>/dev/null); [ -n "$n" ] || n=0
check "install.sh is idempotent (exactly one Codex block)" "$n" 1

# The two messages that steer a user away from the volatile path — run for real
# against a stubbed reviewer, not grepped out of the source. A source match can
# pass while the line is unreachable, or while the path it prints is wrong; this
# asserts the message a user actually sees AND that the directory in it follows
# SHIP_FEATURE_CONFIG rather than being hard-coded to $HOME.
printf '#!/usr/bin/env bash\ncat >/dev/null 2>&1\necho "stub review"\n' > "$BIN/codex"
chmod +x "$BIN/codex"
# Its own config dir: the shared $CFGDIR is created further down this file, and
# depending on it would tie these assertions to the order of unrelated blocks.
PLANCFG="$WORK/plancfg"; mkdir -p "$PLANCFG"
printf 'SHIP_FEATURE_REVIEWERS=codex\n' > "$PLANCFG/config"
# The plans directory is overridden EXPLICITLY. Deriving it from
# SHIP_FEATURE_CONFIG looked tidier and was wrong: that variable is routinely
# `/dev/null` to mean "no config", which would put plans in `/dev`.
PLANDIR="$WORK/plancfg/plans"
PLANWORK="$WORK/planmsg"; mkdir -p "$PLANWORK"; printf 'a plan\n' > "$PLANWORK/plan.md"
err=$( cd "$PLANWORK" && PATH="$BIN:$PATH" SHIP_FEATURE_CONFIG="$PLANCFG/config" SHIP_FEATURE_PLANS_DIR="$PLANDIR" \
       bash "$CLI" plan-review --reviewers codex 2>&1 >/dev/null )
case "$err" in
  *"keep plans in $PLANDIR"*)
    echo "  ok   [-] reading ./plan.md warns, naming the configured plans directory"; PASS=$((PASS+1));;
  *) echo "  FAIL ./plan.md warning missing or names the wrong directory: $err"; FAIL=$((FAIL+1));;
esac
PLANEMPTY="$WORK/planempty"; mkdir -p "$PLANEMPTY"
err=$( cd "$PLANEMPTY" && PATH="$BIN:$PATH" SHIP_FEATURE_CONFIG="$PLANCFG/config" SHIP_FEATURE_PLANS_DIR="$PLANDIR" \
       bash "$CLI" plan-review --reviewers codex </dev/null 2>&1 >/dev/null )
case "$err" in
  *"no plan given"*"$PLANDIR"*)
    echo "  ok   [-] the no-plan error names the configured plans directory"; PASS=$((PASS+1));;
  *) echo "  FAIL no-plan error missing or names the wrong directory: $err"; FAIL=$((FAIL+1));;
esac
# Upgrade-safe: an existing install that pulls the new workflow has no plans
# directory until install.sh runs again, and the first plan write would fail.
# The CLI creates it on demand.
rmdir "$PLANDIR" 2>/dev/null
( cd "$PLANEMPTY" && PATH="$BIN:$PATH" SHIP_FEATURE_CONFIG="$PLANCFG/config" SHIP_FEATURE_PLANS_DIR="$PLANDIR" \
  bash "$CLI" plan-review --reviewers codex </dev/null >/dev/null 2>&1 )
check "the CLI creates the plans directory on demand" "$([ -d "$PLANDIR" ] && echo yes || echo no)" yes
check "and creates it owner-only" "$(dir_mode "$PLANDIR")" "drwx------"
rm -f "$BIN/codex"
# The old wording gone, not merely the new wording present: an added line and a
# surviving one look identical to a grep for the new text, and very different to
# somebody reading the error.
if grep -q 'create a non-empty ./plan.md' "$CLI"; then
  echo "  FAIL bin/ship-feature still tells users to create ./plan.md"; FAIL=$((FAIL+1))
else
  echo "  ok   [-] bin/ship-feature no longer tells users to create ./plan.md"; PASS=$((PASS+1))
fi

# --- generic scanner: proves it catches each claimed category ----------------
bash "$HERE/../scripts/scan-generic.sh" "$HERE/fixtures/leaky.sample" >/dev/null 2>&1; check "generic scan flags the leaky fixture (email + home path)" $? 1
echo "just some ordinary text" > "$WORK/clean.txt"
bash "$HERE/../scripts/scan-generic.sh" "$WORK/clean.txt" >/dev/null 2>&1; check "generic scan passes a clean file" $? 0
printf 'contact us at hello@example.com\n' > "$WORK/dummy.txt"
bash "$HERE/../scripts/scan-generic.sh" "$WORK/dummy.txt" >/dev/null 2>&1; check "generic scan ignores reserved example.com email" $? 0

# --- cmd_relay injects SHIP_FEATURE_REVIEWERS from config (and honors explicit override) ------
printf '#!/usr/bin/env bash\necho "ARGS: $*"\nexit 0\n' > "$BIN/pr-review-relay"; chmod +x "$BIN/pr-review-relay"
CFGDIR="$WORK/cfg"; mkdir -p "$CFGDIR"; printf 'SHIP_FEATURE_REVIEWERS=codex,cursor\n' > "$CFGDIR/config"
out=$(PATH="$BIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config" bash "$CLI" relay --author claude 2>/dev/null)
printf '%s' "$out" | grep -q -- "--reviewers codex,cursor" && { echo "  ok   [-] relay injects configured reviewers when omitted"; PASS=$((PASS+1)); } || { echo "  FAIL relay did not inject configured reviewers"; FAIL=$((FAIL+1)); }
out=$(PATH="$BIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config" bash "$CLI" relay --author claude --reviewers x,y 2>/dev/null)
if printf '%s' "$out" | grep -q -- "--reviewers x,y" && ! printf '%s' "$out" | grep -q "codex,cursor"; then echo "  ok   [-] explicit --reviewers overrides config"; PASS=$((PASS+1)); else echo "  FAIL explicit --reviewers did not override config"; FAIL=$((FAIL+1)); fi
# the --reviewers= form is rejected with a clear error (relay doesn't accept it)
( PATH="$BIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config" bash "$CLI" relay --author claude --reviewers=x >/dev/null 2>&1 ); check "relay rejects the --reviewers= form" $? 1
# an explicitly empty env value disables config injection (env-defined wins)
out=$(PATH="$BIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config" SHIP_FEATURE_REVIEWERS= bash "$CLI" relay --author claude 2>/dev/null)
if ! printf '%s' "$out" | grep -q -- "--reviewers"; then echo "  ok   [-] empty SHIP_FEATURE_REVIEWERS env disables injection"; PASS=$((PASS+1)); else echo "  FAIL empty env did not disable injection"; FAIL=$((FAIL+1)); fi

# --- install.sh --copy produces a real WORKFLOW.md (not a symlink) ------------
FAKEHOME2="$WORK/home2"; mkdir -p "$FAKEHOME2"
( cd "$HERE/.." && HOME="$FAKEHOME2" bash install.sh --copy >/dev/null 2>&1 ); check "install.sh --copy succeeds" $? 0
if [ -f "$FAKEHOME2/.config/ship-feature/WORKFLOW.md" ] && [ ! -L "$FAKEHOME2/.config/ship-feature/WORKFLOW.md" ]; then echo "  ok   [-] --copy installs a real WORKFLOW.md (not a symlink)"; PASS=$((PASS+1)); else echo "  FAIL --copy did not produce a real file"; FAIL=$((FAIL+1)); fi

# --- scan catches a deny-listed term in a ref (branch) name ------------------
SREPO5="$WORK/scanrepo5"; git init -q "$SREPO5"
( cd "$SREPO5" && git commit -q --allow-empty -m init && git branch "SECRET-SLUG-XYZ-branch" && bash "$SCAN" "$WORK/deny.txt" >/dev/null 2>&1 ); check "scan catches a deny-listed term in a ref name" $? 1

# --- scan-generic scans a SYMLINK's target string (committed data), not the pointee ----------
# Build the target from a var so this test file doesn't itself contain a literal home path (which the
# repo-wide scan would flag).
lu="privuser"; ln -s "/home/$lu/secret" "$WORK/leaky-link" 2>/dev/null
bash "$HERE/../scripts/scan-generic.sh" "$WORK/leaky-link" >/dev/null 2>&1; check "generic scan flags a home path in a symlink target" $? 1

# --- scan-personal-data catches a term inside a BINARY blob (no -I) ---------------------------
SREPO6="$WORK/scanrepo6"; git init -q "$SREPO6"
( cd "$SREPO6" && printf 'SECRET-SLUG-XYZ\000\001\002binary' > bin.dat && git add bin.dat && git commit -q -m "add binary" && bash "$SCAN" "$WORK/deny.txt" >/dev/null 2>&1 ); check "scan catches a deny-listed term inside a binary blob" $? 1

# --- load_config strips an inline comment from a value ---------------------------------------
printf 'SHIP_FEATURE_REVIEWERS=codex,cursor  # my quorum\n' > "$CFGDIR/config2"
out=$(PATH="$BIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config2" bash "$CLI" relay --author claude 2>/dev/null)
if printf '%s' "$out" | grep -q -- "--reviewers codex,cursor" && ! printf '%s' "$out" | grep -q "quorum"; then echo "  ok   [-] config value inline comment is stripped"; PASS=$((PASS+1)); else echo "  FAIL inline comment not stripped"; FAIL=$((FAIL+1)); fi


# --- preflight fails on a DIVERGED branch (own commit + default advanced) ---------------------
( cd "$MAIN/.claude/worktrees/feat" && git commit -q --allow-empty -m "feature work" && bash "$CLI" preflight >/dev/null 2>&1 ); check "preflight fails on a diverged branch" $? 1

# --- plan-review: fan a plan out to a panel of stubbed reviewers -------------
# Stub the reviewer CLIs so no network/real agent is touched. Each echoes a marker
# plus its argv (so the argv/read-only contract can be asserted). cursor's binary is
# `cursor-agent`; the rest match their reviewer name.
PBIN="$WORK/pbin"; mkdir -p "$PBIN"
# The stub also surfaces the OPENCODE_CONFIG_CONTENT env (how kimi3 pins read-only — the
# highest-precedence config layer), the OPENCODE_CONFIG env (must be empty — kimi3 unsets it),
# and CWD (must be isolated, outside the checkout). Harmless for reviewers that don't set them.
make_reviewer() {
  # $1 = review tag, $2 = exit code, $3 = binary name on PATH
  cat > "$PBIN/$3" <<STUB
#!/usr/bin/env bash
echo "REVIEW-$1 argv=[\$*] OPENCODE_CONFIG_CONTENT=[\${OPENCODE_CONFIG_CONTENT:-}] OPENCODE_CONFIG=[\${OPENCODE_CONFIG:-}] OPENCODE_CONFIG_DIR=[\${OPENCODE_CONFIG_DIR:-}] CWD=[\${PWD}]"
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
exit ${2:-0}
STUB
  chmod +x "$PBIN/$3"
}
make_reviewer claude 0 claude
make_reviewer codex  0 codex
# kimi3 is invoked through the `opencode` binary (opencode run --agent plan), so the stub
# is named `opencode` but tags its output REVIEW-kimi3.
make_reviewer kimi3  0 opencode
make_reviewer cursor 0 cursor-agent
# grok45high is invoked through the `grok` binary
make_reviewer grok45high 0 grok
# antigravity/gemini reviewer (the `gemini` CLI). A richer stub than make_reviewer: it also reports
# its CWD and whether the isolated, locked-down `.gemini/settings.json` (write tools excluded + hooks
# off) is present in that CWD — so the read-only isolation contract can be asserted, not just argv.
cat > "$PBIN/gemini" <<'GEMINISTUB'
#!/usr/bin/env bash
# The seat runs `gemini --version` first and refuses to review against a tool registry it
# has not been audited against. STUB_GEMINI_VERSION lets a test drive that gate.
case "${1:-}" in --version|-v) echo "${STUB_GEMINI_VERSION:-0.26.0}"; exit 0;; esac
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
echo "GEMINI-ISO cwd=$PWD locked=$locked homeiso=$homeiso credsafe=$credsafe sysiso=$sysiso xdg=${XDG_CONFIG_HOME-UNSET} envstop=$envstop gca=$gca homecreds=$homecreds credmode=$credmode lockedsame=$lockedsame"
echo "REVIEW-gemini argv=[$*]"
exit 0
GEMINISTUB
chmod +x "$PBIN/gemini"

# clean run with an explicit panel → exit 0, both reviews on stdout
out=$(printf 'Step 1: X\nStep 2: Y\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers codex,kimi3 2>/dev/null); rc=$?
check "plan-review clean run exits 0" "$rc" 0
printf '%s' "$out" | grep -q "REVIEW-codex" && printf '%s' "$out" | grep -q "REVIEW-kimi3" \
  && { echo "  ok   [-] plan-review prints each reviewer's output"; PASS=$((PASS+1)); } \
  || { echo "  FAIL plan-review dropped a reviewer's output"; FAIL=$((FAIL+1)); }

# read-only argv contract: EVERY supported reviewer must carry its read-only flag, so the
# "nothing is written" guarantee is real. A dropped flag here is a security regression.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude,codex,cursor,kimi3 2>/dev/null)
# claude's own line must carry BOTH --permission-mode plan AND --safe-mode (safe-mode
# stops checkout hooks/plugins/MCP from loading). Grep claude's line specifically so
# another reviewer's flags can't satisfy this by accident.
cl=$(printf '%s' "$out" | grep 'REVIEW-claude')
printf '%s' "$cl" | grep -q -- "--permission-mode plan" && printf '%s' "$cl" | grep -q -- "--safe-mode" && { echo "  ok   [-] claude runs read-only (--permission-mode plan --safe-mode)"; PASS=$((PASS+1)); } || { echo "  FAIL claude not fully read-only (plan + safe-mode) in plan-review"; FAIL=$((FAIL+1)); }
printf '%s' "$out" | grep 'REVIEW-codex' | grep -q -- "--sandbox read-only" && { echo "  ok   [-] codex runs read-only (--sandbox read-only)"; PASS=$((PASS+1)); } || { echo "  FAIL codex not read-only in plan-review"; FAIL=$((FAIL+1)); }
# Grep cursor's own line, like claude's check above. Whole-stdout matching is satisfied by ANY
# reviewer's line carrying the flag, so it would keep passing if cursor silently lost it while a
# future reviewer happened to use the same one. Today's stubs echo argv, not stdin, so the plan
# text itself cannot trigger it — the point is not to depend on that staying true.
cu=$(printf '%s' "$out" | grep 'REVIEW-cursor')
printf '%s' "$cu" | grep -q -- "--mode=ask"                    && { echo "  ok   [-] cursor runs in ask (Q&A) mode"; PASS=$((PASS+1)); } || { echo "  FAIL cursor not in ask mode"; FAIL=$((FAIL+1)); }
# cursor-agent's own default model is "Auto", which routes to the frontier models and may pick a
# CLAUDE one — so the agent that usually wrote the plan would be grading it while the panel reports
# an independent "Cursor" reviewer. The pin is what keeps the panel honest, so it is asserted.
printf '%s' "$cu" | grep -q -- "--model composer-2.5"  && { echo "  ok   [-] cursor model is pinned (not Auto)"; PASS=$((PASS+1)); } || { echo "  FAIL cursor model not pinned: $cu"; FAIL=$((FAIL+1)); }
# kimi3's read-only guarantee: OPENCODE_CONFIG_CONTENT (highest-precedence config layer)
# DENIES `edit` AND `bash` (removing both tools — no write, no shell), OPENCODE_CONFIG is
# unset (empty), it runs --pure, and never the all-allow build agent. The `plan` agent alone
# denies edit but leaves bash allowed — not enough — so the CONTENT denial is what makes it
# real. Assert all of it on kimi3's line.
#
# The cwd is asserted by the PAIR below, not by one line: kimi3 READS THE CHECKOUT, because a
# reviewer that cannot open the code can only review prose — it used to run in an empty dir and
# returned empty reviews twice on 2026-08-14, having spent its turn looking for the repo. It
# falls back to an isolated dir only when the checkout carries its own opencode config, which is
# the one thing the permission denial above cannot pin down.
km=$(printf '%s' "$out" | grep 'REVIEW-kimi3')
printf '%s' "$km" | grep -q -- "--agent plan" && printf '%s' "$km" | grep -q -- "kimi-k3" && { echo "  ok   [-] kimi3 runs opencode plan agent (kimi-k3)"; PASS=$((PASS+1)); } || { echo "  FAIL kimi3 not on opencode plan agent"; FAIL=$((FAIL+1)); }
printf '%s' "$km" | grep -q -- "--pure" && { echo "  ok   [-] kimi3 runs --pure (no checkout plugins)"; PASS=$((PASS+1)); } || { echo "  FAIL kimi3 missing --pure"; FAIL=$((FAIL+1)); }
printf '%s' "$km" | grep -q 'OPENCODE_CONFIG_CONTENT=\[.*"edit":"deny".*"bash":"deny".*\]' && { echo "  ok   [-] kimi3 read-only via OPENCODE_CONFIG_CONTENT (edit+bash denied)"; PASS=$((PASS+1)); } || { echo "  FAIL kimi3 not hard read-only (OPENCODE_CONFIG_CONTENT must deny edit AND bash)"; FAIL=$((FAIL+1)); }
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
  printf '%s' "$km" | grep -q "\"$k\":\"deny\"" \
    && { echo "  ok   [-] kimi3 denies $k"; PASS=$((PASS+1)); } \
    || { echo "  FAIL kimi3 does not deny $k"; FAIL=$((FAIL+1)); }
done
printf '%s' "$km" | grep -q 'OPENCODE_CONFIG=\[\]' && { echo "  ok   [-] kimi3 unsets inherited OPENCODE_CONFIG"; PASS=$((PASS+1)); } || { echo "  FAIL kimi3 left OPENCODE_CONFIG set (could weaken perms)"; FAIL=$((FAIL+1)); }
# OPENCODE_CONFIG_DIR is the other half of "unsets any inherited OPENCODE_CONFIG*", and it was
# only the comment that said so: the code unset one variable. A config DIR carries agents, MCP
# servers and model settings just as a config file does.
printf '%s' "$km" | grep -q 'OPENCODE_CONFIG_DIR=\[\]' && { echo "  ok   [-] kimi3 unsets inherited OPENCODE_CONFIG_DIR"; PASS=$((PASS+1)); } || { echo "  FAIL kimi3 left OPENCODE_CONFIG_DIR set (agents/MCP could load)"; FAIL=$((FAIL+1)); }
kcwd=$(printf '%s' "$km" | sed -n 's/.*CWD=\[\([^]]*\)\].*/\1/p'); case "$kcwd" in "") echo "  FAIL kimi3 cwd not captured"; FAIL=$((FAIL+1));; "$PWD") echo "  ok   [-] kimi3 reads the checkout"; PASS=$((PASS+1));; *) echo "  FAIL kimi3 ran outside the checkout ($kcwd) — it can only review prose from there"; FAIL=$((FAIL+1));; esac
printf '%s' "$km" | grep -q -- "--agent build"         && { echo "  FAIL kimi3 uses the all-allow build agent"; FAIL=$((FAIL+1)); } || { echo "  ok   [-] kimi3 never uses the all-allow build agent"; PASS=$((PASS+1)); }
# The other half of the cwd contract: a checkout that ships its OWN opencode config must push
# the seat back into an isolated dir, and must SAY so. Permissions are pinned by the deny above
# and cannot be overridden, but a repo config also carries MCP servers, agents and model
# routing, and no permission key covers those — so the tree being reviewed would otherwise get
# to reconfigure the reviewer reading it.
ocfg_repo="$WORK/ocfg"; mkdir -p "$ocfg_repo"
( cd "$ocfg_repo" && git init -q . && printf '{}\n' > opencode.json )
ocfg_out=$(cd "$ocfg_repo" && printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers kimi3 2>/dev/null)
ocfg_cwd=$(printf '%s' "$ocfg_out" | grep 'REVIEW-kimi3' | sed -n 's/.*CWD=\[\([^]]*\)\].*/\1/p')
case "$ocfg_cwd" in
  "$ocfg_repo"|"$ocfg_repo"/*) echo "  FAIL kimi3 read a checkout carrying its own opencode.json ($ocfg_cwd)"; FAIL=$((FAIL+1));;
  "") echo "  FAIL kimi3 cwd not captured in the repo-config case"; FAIL=$((FAIL+1));;
  *) echo "  ok   [-] kimi3 falls back to an isolated cwd when the checkout has an opencode config"; PASS=$((PASS+1));;
esac
printf '%s' "$ocfg_out" | grep -q 'opencode.json would configure the reviewer' \
  && { echo "  ok   [-] kimi3 announces the degraded review"; PASS=$((PASS+1)); } \
  || { echo "  FAIL kimi3 degraded silently — a prose-only review must say so"; FAIL=$((FAIL+1)); }
# From a SUBDIRECTORY the config is still found: opencode discovers config by walking up, so a
# check that only looked at $PWD would miss it and hand the reviewer a config we refused. This
# is the case the walk-up exists for, and it is also this workflow's normal shape — plan-review
# usually runs inside .claude/worktrees/<name>.
mkdir -p "$ocfg_repo/sub/deeper"
sub_out=$(cd "$ocfg_repo/sub/deeper" && printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers kimi3 2>/dev/null)
sub_cwd=$(printf '%s' "$sub_out" | grep 'REVIEW-kimi3' | sed -n 's/.*CWD=\[\([^]]*\)\].*/\1/p')
case "$sub_cwd" in
  "$ocfg_repo"|"$ocfg_repo"/*) echo "  FAIL kimi3 missed an opencode config in a parent directory ($sub_cwd)"; FAIL=$((FAIL+1));;
  "") echo "  FAIL kimi3 cwd not captured in the subdirectory case"; FAIL=$((FAIL+1));;
  *) echo "  ok   [-] kimi3 finds an opencode config above the cwd"; PASS=$((PASS+1));;
esac
printf '%s' "$sub_out" | grep -q 'would configure the reviewer' \
  && { echo "  ok   [-] kimi3 announces the degraded review from a subdirectory too"; PASS=$((PASS+1)); } \
  || { echo "  FAIL kimi3 degraded silently from a subdirectory"; FAIL=$((FAIL+1)); }

# All THREE config names trigger the fallback. The function checks opencode.json, opencode.jsonc
# and .opencode; only the first was exercised, so a typo in either of the others was free.
for cfgname in opencode.jsonc .opencode; do
  rm -rf "${ocfg_repo:?}/opencode.json" "${ocfg_repo:?}/opencode.jsonc" "${ocfg_repo:?}/.opencode"
  if [ "$cfgname" = .opencode ]; then mkdir -p "$ocfg_repo/.opencode"; else printf '{}\n' > "$ocfg_repo/$cfgname"; fi
  n_cwd=$(cd "$ocfg_repo" && printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers kimi3 2>/dev/null \
          | grep 'REVIEW-kimi3' | sed -n 's/.*CWD=\[\([^]]*\)\].*/\1/p')
  case "$n_cwd" in
    "$ocfg_repo"|"$ocfg_repo"/*|"") echo "  FAIL $cfgname did not trigger the isolated fallback ($n_cwd)"; FAIL=$((FAIL+1));;
    *) echo "  ok   [-] $cfgname triggers the isolated fallback"; PASS=$((PASS+1));;
  esac
done
rm -rf "${ocfg_repo:?}/.opencode"; printf '{}\n' > "$ocfg_repo/opencode.json"

# A LINKED WORKTREE at <repo>/.claude/worktrees/<name> is its own git toplevel, so a walk that
# stops at the toplevel never sees the main checkout's config — while opencode, running in the
# worktree, is inside that repo. This is the exact layout ship-feature creates, so it is checked
# explicitly rather than by walking past the root (which would degrade reviews over configs
# opencode never loads).
wt_main="$WORK/wtmain"; mkdir -p "$wt_main"
( cd "$wt_main" && git init -q . && git commit -q --allow-empty -m init && printf '{}\n' > opencode.json \
  && git worktree add -q ".claude/worktrees/w" -b wtprobe >/dev/null 2>&1 )
wt_cwd=$(cd "$wt_main/.claude/worktrees/w" && printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers kimi3 2>/dev/null \
         | grep 'REVIEW-kimi3' | sed -n 's/.*CWD=\[\([^]]*\)\].*/\1/p')
case "$wt_cwd" in
  "$wt_main"/*|"") echo "  FAIL kimi3 missed the MAIN repo's opencode.json from a linked worktree ($wt_cwd)"; FAIL=$((FAIL+1));;
  *) echo "  ok   [-] kimi3 finds the main checkout's opencode config from a linked worktree"; PASS=$((PASS+1));;
esac

# The $HOME bound, which the code comment calls load-bearing: `~/.opencode` exists on any
# machine that has run opencode, so a walk that does not stop at $HOME matches it for EVERY
# checkout under $HOME and degrades every review to prose. Point HOME at a temp dir that has
# one, put the checkout beneath it, and the seat must still read the checkout.
home_probe="$WORK/homeprobe"; mkdir -p "$home_probe/.opencode" "$home_probe/repo"
( cd "$home_probe/repo" && git init -q . )
hp_cwd=$(cd "$home_probe/repo" && printf 'plan\n' | PATH="$PBIN:$PATH" HOME="$home_probe" bash "$CLI" plan-review --reviewers kimi3 2>/dev/null \
         | grep 'REVIEW-kimi3' | sed -n 's/.*CWD=\[\([^]]*\)\].*/\1/p')
case "$hp_cwd" in
  "$home_probe/repo") echo "  ok   [-] kimi3 ignores ~/.opencode and still reads the checkout"; PASS=$((PASS+1));;
  "") echo "  FAIL kimi3 cwd not captured in the HOME-bound case"; FAIL=$((FAIL+1));;
  *) echo "  FAIL a config at \$HOME degraded the review ($hp_cwd) — every checkout under \$HOME would go prose-only"; FAIL=$((FAIL+1));;
esac

# FAIL CLOSED: config present and no isolated dir available → the seat is SKIPPED, never run in
# the checkout whose config we just refused. The old code left ro_cwd empty and fell through to
# $PWD while still announcing an isolated review — a reviewer that lies about what it read.
mkfail="$WORK/mkfail"; mkdir -p "$mkfail"
# The stub lets the FIRST mktemp through: that one creates STATUS_DIR, and failing it aborts
# plan-review before the seat is ever reached — the test would then pass without exercising the
# branch at all. Everything after it fails, which is the seat's own isolated dir.
cat > "$mkfail/mktemp" <<STUB
#!/usr/bin/env bash
if [ ! -e "$mkfail/used" ]; then : > "$mkfail/used"; exec /usr/bin/mktemp "\$@"; fi
exit 1
STUB
chmod +x "$mkfail/mktemp"
fc_out=$(cd "$ocfg_repo" && printf 'plan\n' | PATH="$mkfail:$PBIN:$PATH" bash "$CLI" plan-review --reviewers kimi3 2>&1); fc_rc=$?
if printf '%s' "$fc_out" | grep -q 'REVIEW-kimi3'; then
  echo "  FAIL the seat ran with no isolated cwd — in the checkout it was supposed to avoid"; FAIL=$((FAIL+1))
else
  echo "  ok   [-] kimi3 is skipped rather than run in a checkout it must not read"; PASS=$((PASS+1))
fi
printf '%s' "$fc_out" | grep -q 'no isolated cwd could be created' \
  && { echo "  ok   [-] the skipped seat says why"; PASS=$((PASS+1)); } \
  || { echo "  FAIL the seat was skipped silently"; FAIL=$((FAIL+1)); }

# --- the config file carries the MODEL PINS too -----------------------------------------------
# The panel used to be described in two places: who sits on it in this file, what they actually
# run in the shell profile. A seat and its model could then drift apart, and a run with no shell
# profile (cron, a fresh machine) silently got the bundled default instead of the pinned model.
printf 'KIMI3_REVIEW_MODEL=openrouter/z-ai/glm-5.2\n' > "$CFGDIR/config3"
mout=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config3" bash "$CLI" plan-review --reviewers kimi3 2>/dev/null | grep 'REVIEW-kimi3')
printf '%s' "$mout" | grep -q -- "-m openrouter/z-ai/glm-5.2" \
  && { echo "  ok   [-] the config file pins the kimi3 model"; PASS=$((PASS+1)); } \
  || { echo "  FAIL the config file's model pin was ignored (seat fell back to the bundled default)"; FAIL=$((FAIL+1)); }
# Environment still wins over the file, exactly like the SHIP_FEATURE_* keys.
eout=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config3" KIMI3_REVIEW_MODEL=openrouter/moonshotai/kimi-k3 bash "$CLI" plan-review --reviewers kimi3 2>/dev/null | grep 'REVIEW-kimi3')
printf '%s' "$eout" | grep -q -- "-m openrouter/moonshotai/kimi-k3" \
  && { echo "  ok   [-] the environment still overrides the config file's model pin"; PASS=$((PASS+1)); } \
  || { echo "  FAIL the config file overrode an explicit environment model"; FAIL=$((FAIL+1)); }
# pr-review-relay is a CHILD PROCESS, so its variable has to be EXPORTED, not merely assigned —
# a plain shell variable does not cross that boundary and the relay would keep its own default.
# The stub is swapped for one that echoes its ENVIRONMENT, then RESTORED. Leaving it in place
# would hand every later relay test a stub that prints no argv, and they would pass for the wrong
# reason — a test fixture that quietly breaks its neighbours is worse than the gap it filled.
cp "$BIN/pr-review-relay" "$WORK/relay-stub-backup"
printf '#!/usr/bin/env bash\necho "RELAYENV PR_RELAY_OPENCODE_MODEL=${PR_RELAY_OPENCODE_MODEL:-} CURSOR_REVIEW_MODEL=${CURSOR_REVIEW_MODEL:-}"\nexit 0\n' > "$BIN/pr-review-relay"; chmod +x "$BIN/pr-review-relay"
printf 'PR_RELAY_OPENCODE_MODEL=openrouter/z-ai/glm-5.2\nCURSOR_REVIEW_MODEL=composer-2.5-fast\n' > "$CFGDIR/config4"
rout=$(PATH="$BIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config4" bash "$CLI" relay --author claude 2>/dev/null)
printf '%s' "$rout" | grep -q 'PR_RELAY_OPENCODE_MODEL=openrouter/z-ai/glm-5.2' \
  && { echo "  ok   [-] the relay's model pin reaches the child process"; PASS=$((PASS+1)); } \
  || { echo "  FAIL PR_RELAY_OPENCODE_MODEL did not reach pr-review-relay (not exported?)"; FAIL=$((FAIL+1)); }
# CURSOR_REVIEW_MODEL is the one variable BOTH tools read, which is the whole reason it keeps its
# vendor-shaped name — so it must cross the process boundary too, not just reach plan-review.
printf '%s' "$rout" | grep -q 'CURSOR_REVIEW_MODEL=composer-2.5-fast' \
  && { echo "  ok   [-] the shared cursor pin reaches the child process"; PASS=$((PASS+1)); } \
  || { echo "  FAIL CURSOR_REVIEW_MODEL did not reach pr-review-relay (not exported?)"; FAIL=$((FAIL+1)); }
cp "$WORK/relay-stub-backup" "$BIN/pr-review-relay"; chmod +x "$BIN/pr-review-relay"
# The remaining two seats, from the file and with the environment still winning. Each is its own
# case arm in load_config, so a missing one fails silently on exactly one reviewer.
printf 'CURSOR_REVIEW_MODEL=composer-2.5-fast\nGROK45HIGH_REVIEW_MODEL=grok-9.9\n' > "$CFGDIR/config5"
pout=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config5" bash "$CLI" plan-review --reviewers cursor,grok45high 2>/dev/null)
printf '%s' "$pout" | grep 'REVIEW-cursor' | grep -q -- "--model composer-2.5-fast" \
  && { echo "  ok   [-] the config file pins the cursor model"; PASS=$((PASS+1)); } \
  || { echo "  FAIL the config file's cursor pin was ignored"; FAIL=$((FAIL+1)); }
printf '%s' "$pout" | grep 'REVIEW-grok45high' | grep -q -- "-m grok-9.9" \
  && { echo "  ok   [-] the config file pins the grok45high model"; PASS=$((PASS+1)); } \
  || { echo "  FAIL the config file's grok45high pin was ignored"; FAIL=$((FAIL+1)); }
pout2=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/config5" CURSOR_REVIEW_MODEL=composer-2.5 GROK45HIGH_REVIEW_MODEL=grok-4.6 bash "$CLI" plan-review --reviewers cursor,grok45high 2>/dev/null)
# Anchored on the argv closing bracket: bare "composer-2.5" is a PREFIX of the "composer-2.5-fast"
# the config file sets, so an unanchored grep would pass whether the override worked or not —
# precisely the bug this case exists to catch.
printf '%s' "$pout2" | grep 'REVIEW-cursor' | grep -q -- "--model composer-2.5]" \
  && printf '%s' "$pout2" | grep 'REVIEW-grok45high' | grep -q -- "-m grok-4.6" \
  && { echo "  ok   [-] the environment overrides the cursor and grok45high pins"; PASS=$((PASS+1)); } \
  || { echo "  FAIL the config file overrode an explicit environment model"; FAIL=$((FAIL+1)); }

# --- the SHARED panel config (pr-review-relay's file) is the last fallback ---------------------
# Both tools drive the same seats on the same accounts, so the model a seat runs belongs to the
# machine, not to whichever tool is invoking it. The relay's file has carried MODEL_kimi3 since
# 2026-08-14; reading it here is what makes one file the answer instead of two that drift.
printf 'MODEL_kimi3=openrouter/moonshotai/kimi-k3\nMODEL_grok45high=grok-9.9\nMODEL_cursor=composer-9.9\n' > "$CFGDIR/shared1"
sh1=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared1" bash "$CLI" plan-review --reviewers kimi3,grok45high,cursor 2>/dev/null)
printf '%s' "$sh1" | grep 'REVIEW-kimi3' | grep -q -- "-m openrouter/moonshotai/kimi-k3" \
  && printf '%s' "$sh1" | grep 'REVIEW-grok45high' | grep -q -- "-m grok-9.9" \
  && { echo "  ok   [-] the shared relay config pins the models"; PASS=$((PASS+1)); } \
  || { echo "  FAIL the shared relay config was not read"; FAIL=$((FAIL+1)); }
# All three mapped seats, not just two: each is its own case arm, so a missing one fails
# silently on exactly one reviewer.
printf '%s' "$sh1" | grep 'REVIEW-cursor' | grep -q -- "--model composer-9.9" \
  && { echo "  ok   [-] the shared relay config pins the cursor model too"; PASS=$((PASS+1)); } \
  || { echo "  FAIL MODEL_cursor was not mapped"; FAIL=$((FAIL+1)); }
# MODEL_grok is the RELAY's seat, at medium effort. plan-review's grok45high is a different seat,
# so reading MODEL_grok here would hand a high-effort plan review the relay's pin.
# An EMPTY environment value must not block the shared file. Empty means "no pin", not
# "disable" — the SHIP_FEATURE_* keys use the other rule on purpose. With the wrong one,
# CURSOR_REVIEW_MODEL= left ship-feature on its built-in default while pr-review-relay used the
# shared value: same inputs, two different models.
sh6=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared1" CURSOR_REVIEW_MODEL= bash "$CLI" plan-review --reviewers cursor 2>/dev/null)
printf '%s' "$sh6" | grep 'REVIEW-cursor' | grep -q -- "--model composer-9.9" \
  && { echo "  ok   [-] an empty environment pin does not block the shared file"; PASS=$((PASS+1)); } \
  || { echo "  FAIL an empty env pin blocked the shared config"; FAIL=$((FAIL+1)); }
# A file with NO FINAL NEWLINE keeps its last line. pr-review-relay's parser reads it, so
# dropping it here would make the same file select different models in the two tools.
printf 'MODEL_kimi3=openrouter/moonshotai/kimi-k3' > "$CFGDIR/shared5"
sh7=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared5" bash "$CLI" plan-review --reviewers kimi3 2>/dev/null)
printf '%s' "$sh7" | grep 'REVIEW-kimi3' | grep -q -- "-m openrouter/moonshotai/kimi-k3" \
  && { echo "  ok   [-] a config file with no final newline keeps its last line"; PASS=$((PASS+1)); } \
  || { echo "  FAIL the last line was dropped when the file had no final newline"; FAIL=$((FAIL+1)); }
# Parser parity with pr-review-relay on a BOM'd file: it strips the BOM, so without this the
# first key reads as "\ufeffMODEL_kimi3" here and "MODEL_kimi3" there — one file, two models.
printf '\xef\xbb\xbfMODEL_kimi3=openrouter/moonshotai/kimi-k3\n' > "$CFGDIR/shared6"
sh8=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared6" bash "$CLI" plan-review --reviewers kimi3 2>/dev/null)
printf '%s' "$sh8" | grep 'REVIEW-kimi3' | grep -q -- "-m openrouter/moonshotai/kimi-k3" \
  && { echo "  ok   [-] a UTF-8 BOM does not hide the first key"; PASS=$((PASS+1)); } \
  || { echo "  FAIL a BOM'd shared config was not parsed like the relay parses it"; FAIL=$((FAIL+1)); }
# HOME unset must not abort the command under `set -u`. A caller that passes both paths
# explicitly has every right not to have one.
env -u HOME PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG=/dev/null PR_RELAY_CONFIG="$CFGDIR/shared1" SHIP_FEATURE_PLANS_DIR="$WORK/plans" \
  bash "$CLI" plan-review --reviewers kimi3 </dev/null >/dev/null 2>&1
[ $? -ne 2 ] && { echo "  ok   [-] an unset HOME does not abort the run"; PASS=$((PASS+1)); } || { echo "  FAIL unset HOME aborted (unbound variable)"; FAIL=$((FAIL+1)); }
# WHO sits on the panel comes from the shared file too. It was duplicated in both configs —
# identical today, free to drift tomorrow, and a panel that differs between the plan gate and the
# PR gate is something you discover from a verdict.
printf 'REVIEWERS=codex,grok\nPLAN_REVIEWERS=codex,kimi3\n' > "$CFGDIR/shared7"
sh9=$(PATH="$BIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared7" bash "$CLI" relay --author claude 2>/dev/null)
printf '%s' "$sh9" | grep -q -- "--reviewers codex,grok" \
  && { echo "  ok   [-] the shared file names the relay panel"; PASS=$((PASS+1)); } \
  || { echo "  FAIL REVIEWERS was not read from the shared file"; FAIL=$((FAIL+1)); }
sh10=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared7" bash "$CLI" plan-review 2>/dev/null)
printf '%s' "$sh10" | grep -q 'REVIEW-kimi3' && printf '%s' "$sh10" | grep -q 'REVIEW-codex' \
  && ! printf '%s' "$sh10" | grep -q 'REVIEW-grok45high' \
  && { echo "  ok   [-] the shared file names the plan-review panel"; PASS=$((PASS+1)); } \
  || { echo "  FAIL PLAN_REVIEWERS was not read from the shared file"; FAIL=$((FAIL+1)); }
# ship-feature's own config still wins, so one tool can differ on purpose.
printf 'SHIP_FEATURE_PLAN_REVIEWERS=codex\n' > "$CFGDIR/shared8"
sh11=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/shared8" PR_RELAY_CONFIG="$CFGDIR/shared7" bash "$CLI" plan-review 2>/dev/null)
printf '%s' "$sh11" | grep -q 'REVIEW-codex' && ! printf '%s' "$sh11" | grep -q 'REVIEW-kimi3' \
  && { echo "  ok   [-] ship-feature's own panel beats the shared one"; PASS=$((PASS+1)); } \
  || { echo "  FAIL the shared panel overrode ship-feature's own"; FAIL=$((FAIL+1)); }
# An explicitly EMPTY environment value still disables the injected quorum — that is what the
# ${VAR+x} rule is for, and it must survive a value sitting in the shared file.
sh12=$(PATH="$BIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared7" SHIP_FEATURE_REVIEWERS= bash "$CLI" relay --author claude 2>/dev/null)
printf '%s' "$sh12" | grep -q -- "--reviewers" \
  && { echo "  FAIL an empty SHIP_FEATURE_REVIEWERS no longer disables the injected quorum"; FAIL=$((FAIL+1)); } \
  || { echo "  ok   [-] an empty environment quorum still disables injection"; PASS=$((PASS+1)); }
# LAST value wins within the shared file, as in pr-review-relay's own parser. Guarding only on
# "is it set" kept the FIRST line here while the relay kept the last — a valid file handing the
# two tools different panels, which is the thing reading one file is supposed to prevent.
printf 'REVIEWERS=codex\nMODEL_kimi3=openrouter/z-ai/glm-5.2\nREVIEWERS=codex,grok\nMODEL_kimi3=openrouter/moonshotai/kimi-k3\n' > "$CFGDIR/shared9"
sh13=$(PATH="$BIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared9" bash "$CLI" relay --author claude 2>/dev/null)
printf '%s' "$sh13" | grep -q -- "--reviewers codex,grok" \
  && { echo "  ok   [-] a repeated key takes the LAST value, like the relay"; PASS=$((PASS+1)); } \
  || { echo "  FAIL a repeated key kept the first value (the relay would keep the last)"; FAIL=$((FAIL+1)); }
sh14=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared9" bash "$CLI" plan-review --reviewers kimi3 2>/dev/null)
printf '%s' "$sh14" | grep 'REVIEW-kimi3' | grep -q -- "-m openrouter/moonshotai/kimi-k3" \
  && { echo "  ok   [-] a repeated model pin takes the LAST value too"; PASS=$((PASS+1)); } \
  || { echo "  FAIL a repeated model pin kept the first value"; FAIL=$((FAIL+1)); }
# The empty-environment contract, on the OTHER key. PLAN_REVIEWERS is its own line of code, so a
# typo there would pass every test above.
sh15=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared7" SHIP_FEATURE_PLAN_REVIEWERS= SHIP_FEATURE_REVIEWERS=codex bash "$CLI" plan-review 2>/dev/null)
printf '%s' "$sh15" | grep -q 'REVIEW-codex' && ! printf '%s' "$sh15" | grep -q 'REVIEW-kimi3' \
  && { echo "  ok   [-] an empty plan panel falls back to the quorum, not to the shared file"; PASS=$((PASS+1)); } \
  || { echo "  FAIL an empty SHIP_FEATURE_PLAN_REVIEWERS did not survive the shared file"; FAIL=$((FAIL+1)); }
# Closing the 2x2: a SET environment quorum must beat the shared file on the relay side too.
sh16=$(PATH="$BIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared7" SHIP_FEATURE_REVIEWERS=claude,codex bash "$CLI" relay --author claude 2>/dev/null)
printf '%s' "$sh16" | grep -q -- "--reviewers claude,codex" \
  && { echo "  ok   [-] an environment quorum beats the shared file"; PASS=$((PASS+1)); } \
  || { echo "  FAIL the shared file overrode an explicit environment quorum"; FAIL=$((FAIL+1)); }
printf 'MODEL_grok=grok-0.0\n' > "$CFGDIR/shared4"
sh5=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared4" bash "$CLI" plan-review --reviewers grok45high 2>/dev/null)
printf '%s' "$sh5" | grep 'REVIEW-grok45high' | grep -q -- "-m grok-0.0" \
  && { echo "  FAIL MODEL_grok leaked onto the grok45high seat"; FAIL=$((FAIL+1)); } \
  || { echo "  ok   [-] MODEL_grok is left to the relay's own seat"; PASS=$((PASS+1)); }
# ship-feature's OWN config wins over the shared one — a per-tool override has to be possible,
# or consolidating would mean losing the ability to differ on purpose.
printf 'KIMI3_REVIEW_MODEL=openrouter/z-ai/glm-5.2\n' > "$CFGDIR/shared2"
sh2=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/shared2" PR_RELAY_CONFIG="$CFGDIR/shared1" bash "$CLI" plan-review --reviewers kimi3 2>/dev/null)
printf '%s' "$sh2" | grep 'REVIEW-kimi3' | grep -q -- "-m openrouter/z-ai/glm-5.2" \
  && { echo "  ok   [-] ship-feature's own config beats the shared one"; PASS=$((PASS+1)); } \
  || { echo "  FAIL the shared config overrode ship-feature's own"; FAIL=$((FAIL+1)); }
# And the environment still beats both.
sh3=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_CONFIG="$CFGDIR/shared2" PR_RELAY_CONFIG="$CFGDIR/shared1" KIMI3_REVIEW_MODEL=opencode-go/kimi-k3 bash "$CLI" plan-review --reviewers kimi3 2>/dev/null)
printf '%s' "$sh3" | grep 'REVIEW-kimi3' | grep -q -- "-m opencode-go/kimi-k3" \
  && { echo "  ok   [-] the environment beats both config files"; PASS=$((PASS+1)); } \
  || { echo "  FAIL a config file overrode an explicit environment model"; FAIL=$((FAIL+1)); }
# MODEL_opencode is NOT mapped: that seat is pr-review-relay's own, and it reads this same file.
# Exporting PR_RELAY_OPENCODE_MODEL from here would beat the relay's own config, which is the
# opposite of consolidating.
printf 'MODEL_opencode=openrouter/should-not-be-used\n' > "$CFGDIR/shared3"
printf '#!/usr/bin/env bash\necho "RELAYENV PR_RELAY_OPENCODE_MODEL=${PR_RELAY_OPENCODE_MODEL:-unset}"\nexit 0\n' > "$BIN/pr-review-relay.shared"; chmod +x "$BIN/pr-review-relay.shared"
cp "$BIN/pr-review-relay" "$WORK/relay-stub-backup2"; cp "$BIN/pr-review-relay.shared" "$BIN/pr-review-relay"
sh4=$(PATH="$BIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared3" bash "$CLI" relay --author claude 2>/dev/null)
cp "$WORK/relay-stub-backup2" "$BIN/pr-review-relay"; chmod +x "$BIN/pr-review-relay"
printf '%s' "$sh4" | grep -q 'PR_RELAY_OPENCODE_MODEL=unset' \
  && { echo "  ok   [-] MODEL_opencode is left to pr-review-relay itself"; PASS=$((PASS+1)); } \
  || { echo "  FAIL ship-feature exported the relay's own seat model over its config"; FAIL=$((FAIL+1)); }

# REGRESSION (Codex round 3): a HOSTILE inherited OPENCODE_CONFIG_CONTENT that re-enables
# edit/bash must be overridden by our deny (we own the highest-precedence layer).
hostile=$(printf 'plan\n' | PATH="$PBIN:$PATH" OPENCODE_CONFIG_CONTENT='{"permission":{"edit":"allow","bash":"allow"}}' bash "$CLI" plan-review --reviewers kimi3 2>/dev/null | grep 'REVIEW-kimi3')
printf '%s' "$hostile" | grep -q 'OPENCODE_CONFIG_CONTENT=\[.*"edit":"deny".*"bash":"deny".*\]' && ! printf '%s' "$hostile" | grep -q '"edit":"allow"' && { echo "  ok   [-] kimi3 overrides a hostile inherited OPENCODE_CONFIG_CONTENT"; PASS=$((PASS+1)); } || { echo "  FAIL a hostile OPENCODE_CONFIG_CONTENT survived (read-only bypass)"; FAIL=$((FAIL+1)); }

# CURSOR_REVIEW_MODEL is the documented way out if Cursor retires the pinned id, so it is part of
# the contract rather than a convenience: a pin that could not be overridden would be a dead end.
cuo=$(printf 'plan\n' | PATH="$PBIN:$PATH" CURSOR_REVIEW_MODEL=cursor-grok-4.5-high bash "$CLI" plan-review --reviewers cursor 2>/dev/null | grep 'REVIEW-cursor')
printf '%s' "$cuo" | grep -q -- "--model cursor-grok-4.5-high" && { echo "  ok   [-] CURSOR_REVIEW_MODEL overrides the pinned default"; PASS=$((PASS+1)); } || { echo "  FAIL CURSOR_REVIEW_MODEL ignored: $cuo"; FAIL=$((FAIL+1)); }

# KIMI3_REVIEW_MODEL is the documented way to route kimi3 at a pay-as-you-go model (e.g. an
# OpenRouter id) instead of the bundled OpenCode Go tier — same contract as CURSOR_REVIEW_MODEL
# above: a pin that could not be overridden would be a dead end.
kmo=$(printf 'plan\n' | PATH="$PBIN:$PATH" KIMI3_REVIEW_MODEL=openrouter/z-ai/glm-5.2 bash "$CLI" plan-review --reviewers kimi3 2>/dev/null | grep 'REVIEW-kimi3')
printf '%s' "$kmo" | grep -q -- "-m openrouter/z-ai/glm-5.2" && { echo "  ok   [-] KIMI3_REVIEW_MODEL overrides the pinned default"; PASS=$((PASS+1)); } || { echo "  FAIL KIMI3_REVIEW_MODEL ignored: $kmo"; FAIL=$((FAIL+1)); }

# GROK45HIGH_REVIEW_MODEL is the documented way to pin grok45high at a different Grok version —
# same contract as CURSOR_REVIEW_MODEL/KIMI3_REVIEW_MODEL above: a pin that could not be
# overridden would be a dead end when xAI ships the next model.
gmo=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_FORCE_SANDBOX_PROBE=ok GROK45HIGH_REVIEW_MODEL=grok-4.7 bash "$CLI" plan-review --reviewers grok45high 2>/dev/null | grep 'REVIEW-grok45high')
printf '%s' "$gmo" | grep -q -- "-m grok-4.7" && { echo "  ok   [-] GROK45HIGH_REVIEW_MODEL overrides the pinned default"; PASS=$((PASS+1)); } || { echo "  FAIL GROK45HIGH_REVIEW_MODEL ignored: $gmo"; FAIL=$((FAIL+1)); }

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
TBIN="$WORK/tbin"; mkdir -p "$TBIN"
cat > "$TBIN/timeout" <<'TSTUB'
#!/usr/bin/env bash
printf '%s\n' "$1" > "$TIMEOUT_SEEN"
shift
exec "$@"
TSTUB
chmod +x "$TBIN/timeout"

# $1 = expected seconds, $2 = description, rest = env assignments
timeout_case() {
  local want="$1" desc="$2"; shift 2
  local seen="$WORK/timeout_seen.$want.$$"
  : > "$seen"
  ( printf 'plan\n' | env "$@" TIMEOUT_SEEN="$seen" PATH="$TBIN:$PBIN:$PATH" \
      bash "$CLI" plan-review --reviewers codex >/dev/null 2>&1 )
  local got; got="$(cat "$seen" 2>/dev/null || true)"
  if [ "$got" = "$want" ]; then echo "  ok   [-] $desc"; PASS=$((PASS+1))
  else echo "  FAIL $desc — timeout ran with '$got', want '$want'"; FAIL=$((FAIL+1)); fi
}

# EVERY fixture below uses a value that appears nowhere else, so each assertion identifies WHICH
# source won. Asserting 500 against a shared file that also says 500 would pass without proving
# anything — the built-in default is 500 too.
printf 'AGENT_TIMEOUT=470\n' > "$CFGDIR/shared-t1"

# 1. The shared file reaches plan-review at all. This is the bug.
timeout_case 470 "AGENT_TIMEOUT in the shared relay config reaches plan-review" \
  PR_RELAY_CONFIG="$CFGDIR/shared-t1" SHIP_FEATURE_CONFIG=/dev/null

# 2. Rung 1 beats the shared file.
timeout_case 410 "SHIP_FEATURE_PLAN_TIMEOUT in the environment beats the shared file" \
  PR_RELAY_CONFIG="$CFGDIR/shared-t1" SHIP_FEATURE_CONFIG=/dev/null SHIP_FEATURE_PLAN_TIMEOUT=410

# 3. Rung 2: ship-feature's own file beats the shared one, and loses to the environment.
printf 'SHIP_FEATURE_PLAN_TIMEOUT=420\n' > "$CFGDIR/own-t1"
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

# 7. LAST value wins inside the shared file, as in pr-review-relay's own parser. This is what the
# from_env_* flag being set BEFORE the loop protects: an inline "is it already set" test in the case
# arm would keep the FIRST line here while the relay kept the last — one valid file, two timeouts.
printf 'AGENT_TIMEOUT=430\nAGENT_TIMEOUT=440\n' > "$CFGDIR/shared-t2"
timeout_case 440 "the last AGENT_TIMEOUT in the shared file wins" \
  PR_RELAY_CONFIG="$CFGDIR/shared-t2" SHIP_FEATURE_CONFIG=/dev/null

# 8. A bad value from the SHARED FILE is rejected exactly like a bad environment value — validation
# happens after resolution, so there is no path that skips it. `timeout 0` DISABLES the limit rather
# than tightening it, which is why zero is refused rather than clamped.
printf 'AGENT_TIMEOUT=nonsense\n' > "$CFGDIR/shared-t3"
( printf 'p\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-t3" SHIP_FEATURE_CONFIG=/dev/null \
    bash "$CLI" plan-review --reviewers codex >/dev/null 2>&1 )
check "a non-numeric AGENT_TIMEOUT in the shared file is rejected" $? 1
printf 'AGENT_TIMEOUT=0\n' > "$CFGDIR/shared-t4"
( printf 'p\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-t4" SHIP_FEATURE_CONFIG=/dev/null \
    bash "$CLI" plan-review --reviewers codex >/dev/null 2>&1 )
check "a zero AGENT_TIMEOUT in the shared file is rejected" $? 1

# 9. The mapping must NOT cross into the pr-review-relay child. The relay reads this same file
# itself, so an exported value from here would beat its own config — the failure MODEL_opencode's
# test guards against, in a second form. Includes the case a plain assignment does NOT fix: a
# caller that already EXPORTED the name, where the export attribute survives the assignment.
printf 'AGENT_TIMEOUT=470\n' > "$CFGDIR/shared-t5"
printf '#!/usr/bin/env bash\necho "RELAYENV SF=${SHIP_FEATURE_PLAN_TIMEOUT:-unset} PR=${PR_RELAY_AGENT_TIMEOUT:-unset}"\nexit 0\n' > "$BIN/pr-review-relay.tmo"; chmod +x "$BIN/pr-review-relay.tmo"
cp "$BIN/pr-review-relay" "$WORK/relay-stub-backup-tmo"; cp "$BIN/pr-review-relay.tmo" "$BIN/pr-review-relay"
tmo1=$(PATH="$BIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-t5" SHIP_FEATURE_CONFIG=/dev/null bash "$CLI" relay --author claude 2>/dev/null)
tmo2=$(PATH="$BIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/shared-t5" SHIP_FEATURE_CONFIG=/dev/null SHIP_FEATURE_PLAN_TIMEOUT= bash "$CLI" relay --author claude 2>/dev/null)
cp "$WORK/relay-stub-backup-tmo" "$BIN/pr-review-relay"; chmod +x "$BIN/pr-review-relay"
printf '%s' "$tmo1" | grep -q 'SF=unset PR=unset' \
  && { echo "  ok   [-] the mapped timeout is not exported into pr-review-relay"; PASS=$((PASS+1)); } \
  || { echo "  FAIL ship-feature pushed a timeout at the relay: $tmo1"; FAIL=$((FAIL+1)); }
printf '%s' "$tmo2" | grep -q 'SF=unset' \
  && { echo "  ok   [-] an already-exported name does not carry the mapped value into the child"; PASS=$((PASS+1)); } \
  || { echo "  FAIL the export attribute survived and leaked 470 into the relay: $tmo2"; FAIL=$((FAIL+1)); }
# BOTH assigning sites, not just the shared-file one. The first draft of this change put `export -n`
# on load_shared_panel_config and missed the identical trap in load_config, and the test above could
# not see it: it only ever exercised the shared-config path. Cross-review caught it as a Blocker and
# it reproduced exactly — `export SHIP_FEATURE_PLAN_TIMEOUT=` plus a value in ship-feature's own
# config put SF=420 in the child's environment. Two assignments, two chances to leak, two tests.
printf 'SHIP_FEATURE_PLAN_TIMEOUT=420\n' > "$CFGDIR/own-t2"
cp "$BIN/pr-review-relay" "$WORK/relay-stub-backup-tmo3"; cp "$BIN/pr-review-relay.tmo" "$BIN/pr-review-relay"
tmo3=$(PATH="$BIN:$PATH" PR_RELAY_CONFIG=/dev/null SHIP_FEATURE_CONFIG="$CFGDIR/own-t2" SHIP_FEATURE_PLAN_TIMEOUT= bash "$CLI" relay --author claude 2>/dev/null)
cp "$WORK/relay-stub-backup-tmo3" "$BIN/pr-review-relay"; chmod +x "$BIN/pr-review-relay"
printf '%s' "$tmo3" | grep -q 'SF=unset' \
  && { echo "  ok   [-] ship-feature's OWN config does not leak the timeout into the child either"; PASS=$((PASS+1)); } \
  || { echo "  FAIL load_config's assignment kept the export attribute and leaked into the relay: $tmo3"; FAIL=$((FAIL+1)); }


# grok45high: Grok 4.6 high effort, prompt-file (not stdin), read-only ALLOWLIST, runs in the
# checkout so it can verify the plan against the code (parity with claude/codex/cursor).
out=$(printf 'UNIQUE_PLAN_TOKEN_42\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_FORCE_SANDBOX_PROBE=ok bash "$CLI" plan-review --reviewers grok45high 2>/dev/null); rc=$?
check "plan-review grok45high clean exit" "$rc" 0
printf '%s' "$out" | grep -q -- '-m grok-4.6' && printf '%s' "$out" | grep -q -- '--reasoning-effort high' \
  && printf '%s' "$out" | grep -q -- '--permission-mode plan' && printf '%s' "$out" | grep -q -- '--sandbox read-only' \
  && printf '%s' "$out" | grep -qF -- '--tools read_file,list_dir,grep' && printf '%s' "$out" | grep -q -- '--verbatim' \
  && printf '%s' "$out" | grep -qF -- '--disallowed-tools search_tool,use_tool' \
  && printf '%s' "$out" | grep -q -- '--prompt-file' \
  && { echo "  ok   [-] grok45high argv pins model/high/plan/sandbox/tools-allowlist/mcp-off/verbatim/prompt-file"; PASS=$((PASS+1)); } \
  || { echo "  FAIL grok45high argv incomplete"; FAIL=$((FAIL+1)); }
# Read-only means: no shell, no editor, no subagents in the built-in allowlist. Asserted on the
# ARGV LINE ONLY — grepping the whole output would false-fail on a plan that merely mentions one
# of these names, since the stub echoes the plan back.
gargv=$(printf '%s' "$out" | grep 'REVIEW-grok45high' | head -1 | sed -n 's/.*argv=\[\([^]]*\)\].*/\1/p')
printf '%s' "$gargv" | grep -qE -- '(run_terminal_command|search_replace|spawn_subagent|scheduler_)' \
  && { echo "  FAIL grok45high allowlist leaks a write/exec tool"; FAIL=$((FAIL+1)); } \
  || { echo "  ok   [-] grok45high allowlist excludes shell/editor/subagent tools"; PASS=$((PASS+1)); }
# The MCP bridge survives --tools, so it must be removed explicitly. Verified against the real
# CLI: with `--tools read_file` alone the session still exposes search_tool and use_tool.
printf '%s' "$gargv" | grep -qF -- '--disallowed-tools search_tool,use_tool' \
  && { echo "  ok   [-] grok45high removes the MCP bridge explicitly"; PASS=$((PASS+1)); } \
  || { echo "  FAIL grok45high leaves the MCP bridge reachable"; FAIL=$((FAIL+1)); }
printf '%s' "$out" | grep -q 'UNIQUE_PLAN_TOKEN_42' && printf '%s' "$out" | grep -qF -- '--- PLAN ---' \
  && { echo "  ok   [-] grok45high prompt-file contains the plan text"; PASS=$((PASS+1)); } \
  || { echo "  FAIL grok45high prompt-file missing plan content"; FAIL=$((FAIL+1)); }
# Runs in the caller's checkout (no --cwd override, no iso- temp dir): that is what lets it read
# the tree the plan is about.
gk=$(printf '%s' "$out" | grep 'REVIEW-grok45high' | head -1)
gcwd=$(printf '%s' "$gk" | sed -n 's/.*CWD=\[\([^]]*\)\].*/\1/p')
printf '%s' "$out" | grep -q -- '--cwd ' \
  && { echo "  FAIL grok45high still pins --cwd (should inherit the checkout)"; FAIL=$((FAIL+1)); } \
  || { echo "  ok   [-] grok45high does not override cwd"; PASS=$((PASS+1)); }
case "$gcwd" in
  *iso-grok45high*) echo "  FAIL grok45high still runs in an isolated cwd ($gcwd)"; FAIL=$((FAIL+1));;
  "$PWD") echo "  ok   [-] grok45high inherits the caller's cwd (the checkout, in real use)"; PASS=$((PASS+1));;
  *) echo "  FAIL grok45high cwd is neither the caller's nor recognised ($gcwd)"; FAIL=$((FAIL+1));;
esac
# The prompt-file must never land inside the checkout, or it shows up in `git status`.
printf '%s' "$out" | grep -qF -- "--prompt-file $PWD/" \
  && { echo "  FAIL grok45high prompt-file written inside the checkout"; FAIL=$((FAIL+1)); } \
  || { echo "  ok   [-] grok45high prompt-file lives outside the checkout"; PASS=$((PASS+1)); }
# A sandbox that warns and continues must FAIL the round, not pass it. This is the fail-open
# shape: grok exits 0 with a perfectly good review on stdout, while stderr says the OS write
# barrier could not be set up. Before this guard the round was reported clean.
cat > "$PBIN/grok" <<'STUB'
#!/usr/bin/env bash
echo "warning: failed to set up sandbox (bubblewrap not available), continuing unsandboxed" >&2
echo "REVIEW-grok45high argv=[$*] CWD=[${PWD}]"
echo "## Blocker"
echo "None."
exit 0
STUB
chmod +x "$PBIN/grok"
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_FORCE_SANDBOX_PROBE=ok bash "$CLI" plan-review --reviewers grok45high 2>&1); rc=$?
check "plan-review fails when the sandbox warns and continues (fail-closed)" "$rc" 3
printf '%s' "$out" | grep -qi 'sandbox was not enforced' \
  && { echo "  ok   [-] grok45high sandbox fail-open is reported, not swallowed"; PASS=$((PASS+1)); } \
  || { echo "  FAIL sandbox fail-open not surfaced"; FAIL=$((FAIL+1)); }
printf '%s' "$out" | grep -q '## Blocker' \
  && { echo "  FAIL unsandboxed review was printed as a valid review"; FAIL=$((FAIL+1)); } \
  || { echo "  ok   [-] the unsandboxed review is discarded, not printed"; PASS=$((PASS+1)); }
# ...but a benign stderr mentioning "namespace" or "sandbox" must NOT discard a good review.
# The match keys off failure phrasing; a bare token would train people to ignore this signal.
cat > "$PBIN/grok" <<'STUB'
#!/usr/bin/env bash
echo "info: sandbox profile read-only applied; namespace ready" >&2
echo "REVIEW-grok45high argv=[$*] CWD=[${PWD}]"
exit 0
STUB
chmod +x "$PBIN/grok"
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_FORCE_SANDBOX_PROBE=ok bash "$CLI" plan-review --reviewers grok45high 2>&1); rc=$?
check "plan-review keeps the review when stderr mentions the sandbox benignly" "$rc" 0
printf '%s' "$out" | grep -q 'REVIEW-grok45high' \
  && { echo "  ok   [-] benign sandbox log does not discard the review"; PASS=$((PASS+1)); } \
  || { echo "  FAIL benign sandbox log false-failed the round"; FAIL=$((FAIL+1)); }
make_reviewer grok45high 0 grok   # restore

# When the OS sandbox cannot be enforced, grok45high DEGRADES to the old isolated posture —
# text-only review, no checkout — instead of refusing, and says so above the review. Refusing would
# make the reviewer unusable on any Linux without bubblewrap (CI runners included); running it in the
# checkout unsandboxed is the one thing we must never do.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_FORCE_SANDBOX_PROBE=fail bash "$CLI" plan-review --reviewers grok45high 2>&1); rc=$?
check "plan-review still returns a review when the sandbox is unavailable" "$rc" 0
printf '%s' "$out" | grep -qi 'saw the plan text ONLY' \
  && { echo "  ok   [-] degraded grok45high review is labelled text-only"; PASS=$((PASS+1)); } \
  || { echo "  FAIL degraded review not labelled"; FAIL=$((FAIL+1)); }
dg=$(printf '%s' "$out" | grep 'REVIEW-grok45high' | head -1)
printf '%s' "$dg" | grep -qF -- "--deny *" && ! printf '%s' "$dg" | grep -qF -- '--tools read_file' \
  && { echo "  ok   [-] degraded grok45high denies every tool"; PASS=$((PASS+1)); } \
  || { echo "  FAIL degraded grok45high did not fall back to deny-all"; FAIL=$((FAIL+1)); }
printf '%s' "$dg" | grep -qF -- '-m grok-4.6' \
  && { echo "  ok   [-] degraded grok45high pins the default model too"; PASS=$((PASS+1)); } \
  || { echo "  FAIL degraded grok45high did not pin -m grok-4.6"; FAIL=$((FAIL+1)); }
dcwd=$(printf '%s' "$dg" | sed -n 's/.*CWD=\[\([^]]*\)\].*/\1/p')
case "$dcwd" in
  *iso-grok45high*) echo "  ok   [-] degraded grok45high runs outside the checkout"; PASS=$((PASS+1));;
  *) echo "  FAIL degraded grok45high ran in $dcwd"; FAIL=$((FAIL+1));;
esac

# GROK45HIGH_REVIEW_MODEL must reach the degraded path too — not just the normal one, since a
# pin that silently reverts to the default the moment the sandbox is unavailable would be a
# surprise no one asked for.
dgo=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_FORCE_SANDBOX_PROBE=fail GROK45HIGH_REVIEW_MODEL=grok-4.7 bash "$CLI" plan-review --reviewers grok45high 2>&1 | grep 'REVIEW-grok45high')
printf '%s' "$dgo" | grep -qF -- '-m grok-4.7' \
  && { echo "  ok   [-] GROK45HIGH_REVIEW_MODEL overrides the degraded-path model too"; PASS=$((PASS+1)); } \
  || { echo "  FAIL GROK45HIGH_REVIEW_MODEL ignored on the degraded path: $dgo"; FAIL=$((FAIL+1)); }

# bare grok is relay-only (PR panel name), not a plan-reviewer
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers grok,codex 2>&1); rc=$?
check "plan-review bare grok is relay-only (panel still runs codex)" "$rc" 0
printf '%s' "$out" | grep -qi "relay-only" && { echo "  ok   [-] plan-review warns bare grok is relay-only"; PASS=$((PASS+1)); } \
  || { echo "  FAIL bare grok not treated as relay-only"; FAIL=$((FAIL+1)); }
# missing grok binary fails closed when grok45high named — curated PATH so a system
# `grok` cannot mask the miss (same pattern as the missing-gemini test).
rm -f "$PBIN/grok"
MPATH="$PBIN"
for b in bash cat printf timeout gtimeout mktemp tr sed head tail wc rm mkdir chmod; do
  src=$(command -v "$b" 2>/dev/null) || continue
  [ -x "$src" ] || continue
  ln -sf "$src" "$PBIN/$b" 2>/dev/null || true
done
( printf 'plan\n' | PATH="$MPATH" bash "$CLI" plan-review --reviewers grok45high >/dev/null 2>&1 ); check "plan-review missing grok binary → fail (3)" $? 3
make_reviewer grok45high 0 grok   # restore

# antigravity/gemini runs the `gemini` CLI in DEFAULT non-interactive mode (already excludes
# shell/edit/write_file/web_fetch) with `-e none` to disable extensions. It must NOT pass
# `--approval-mode plan` (throws unless experimental.plan is on) nor `yolo` (auto-approves writes).
# Set XDG_CONFIG_HOME so the assertion below can prove the run UNSETS it.
out=$(printf 'plan\n' | XDG_CONFIG_HOME=/tmp/xdg-should-be-unset PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
ag=$(printf '%s' "$out" | grep 'REVIEW-gemini')
printf '%s' "$ag" | grep -q -- "-e none" && { echo "  ok   [-] antigravity runs gemini with extensions off (-e none)"; PASS=$((PASS+1)); } || { echo "  FAIL antigravity/gemini did not pass -e none"; FAIL=$((FAIL+1)); }
printf '%s' "$ag" | grep -q -- "-m gemini-3.1-pro-preview" && { echo "  ok   [-] antigravity pins a working model by default"; PASS=$((PASS+1)); } || { echo "  FAIL antigravity/gemini did not pin the default model"; FAIL=$((FAIL+1)); }
printf '%s' "$ag" | grep -q -- "--approval-mode plan" && { echo "  FAIL gemini uses --approval-mode plan (throws without experimental.plan)"; FAIL=$((FAIL+1)); } || { echo "  ok   [-] antigravity avoids the experimental --approval-mode plan"; PASS=$((PASS+1)); }
printf '%s' "$ag" | grep -q -- "yolo" && { echo "  FAIL gemini uses the auto-approving yolo mode"; FAIL=$((FAIL+1)); } || { echo "  ok   [-] antigravity never uses yolo"; PASS=$((PASS+1)); }
# FAIL-CLOSED isolation: gemini must run from an isolated dir whose locked .gemini/settings.json
# hard-excludes the write tools and disables hooks, so a reviewed checkout's own config can't
# re-enable writes. The stub reports locked=yes only when that settings file is present in its CWD.
iso=$(printf '%s\n' "$out" | grep 'GEMINI-ISO')
printf '%s' "$iso" | grep -q -- "locked=yes" && { echo "  ok   [-] antigravity runs fail-closed (read-only tools.core allowlist, all write tools excluded, hooks off, no MCP)"; PASS=$((PASS+1)); } || { echo "  FAIL antigravity/gemini not isolated with locked read-only settings"; FAIL=$((FAIL+1)); }
# GEMINI_CLI_HOME must be a SEPARATE dir from the workspace so the copied OAuth creds live outside it.
printf '%s' "$iso" | grep -q -- "homeiso=yes" && { echo "  ok   [-] antigravity isolates GEMINI_CLI_HOME separate from the workspace"; PASS=$((PASS+1)); } || { echo "  FAIL antigravity/gemini did not separate GEMINI_CLI_HOME from the workspace"; FAIL=$((FAIL+1)); }
# No OAuth credential file may sit in the workspace tree (else the allowlisted read_file could disclose it).
printf '%s' "$iso" | grep -q -- "credsafe=yes" && { echo "  ok   [-] antigravity keeps OAuth creds out of the workspace"; PASS=$((PASS+1)); } || { echo "  FAIL antigravity/gemini left OAuth creds reachable in the workspace"; FAIL=$((FAIL+1)); }
# XDG_CONFIG_HOME must be UNSET for the run (defence-in-depth against an XDG-honoring gemini).
printf '%s' "$iso" | grep -q -- "xdg=UNSET" && { echo "  ok   [-] antigravity unsets XDG_CONFIG_HOME for the run"; PASS=$((PASS+1)); } || { echo "  FAIL antigravity/gemini did not unset XDG_CONFIG_HOME"; FAIL=$((FAIL+1)); }
# A controlled workspace .gemini/.env must halt gemini's ancestor .env walk (no hostile /tmp/.env).
printf '%s' "$iso" | grep -q -- "envstop=yes" && { echo "  ok   [-] antigravity plants a controlled .env (blocks ancestor .env injection)"; PASS=$((PASS+1)); } || { echo "  FAIL antigravity/gemini did not block ancestor .env lookup"; FAIL=$((FAIL+1)); }
# The SYSTEM scope (highest precedence) + system-defaults must also be redirected under GEMINI_CLI_HOME,
# so /etc/gemini-cli or an inherited hostile GEMINI_CLI_SYSTEM_SETTINGS_PATH can't re-enable anything.
printf '%s' "$iso" | grep -q -- "sysiso=yes" && { echo "  ok   [-] antigravity isolates the SYSTEM settings scope too"; PASS=$((PASS+1)); } || { echo "  FAIL antigravity/gemini did not isolate the system settings scope"; FAIL=$((FAIL+1)); }
# And it must NOT run in the caller's CWD (where a checkout's .gemini/ would live).
# grep -F: $PWD may contain regex metacharacters (e.g. a dotted TMPDIR), so match it as a literal.
printf '%s' "$iso" | grep -Fq -- "cwd=$PWD " && { echo "  FAIL antigravity/gemini ran in the caller CWD (checkout .gemini/ could load)"; FAIL=$((FAIL+1)); } || { echo "  ok   [-] antigravity/gemini ran outside the caller CWD"; PASS=$((PASS+1)); }

# agy and gemini are ALIASES of antigravity: the panel collapses them to a SINGLE gemini invocation.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers antigravity,agy,gemini 2>/dev/null); rc=$?
check "plan-review dedupes antigravity/agy/gemini aliases (exit 0)" "$rc" 0
n=$(printf '%s\n' "$out" | grep -c 'REVIEW-gemini')
[ "$n" = 1 ] && { echo "  ok   [-] antigravity/agy/gemini collapse to one Gemini run"; PASS=$((PASS+1)); } || { echo "  FAIL Gemini ran $n times for the three aliases (want 1)"; FAIL=$((FAIL+1)); }

# SHIP_FEATURE_GEMINI_MODEL overrides the pinned default and reaches the argv.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_GEMINI_MODEL=my-model bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
printf '%s' "$out" | grep 'REVIEW-gemini' | grep -q -- "-m my-model" && { echo "  ok   [-] SHIP_FEATURE_GEMINI_MODEL overrides the model"; PASS=$((PASS+1)); } || { echo "  FAIL SHIP_FEATURE_GEMINI_MODEL did not reach gemini argv"; FAIL=$((FAIL+1)); }

# A model value starting with '-' must be rejected (can't be smuggled in as a gemini flag).
( printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_GEMINI_MODEL=--dangerous bash "$CLI" plan-review --reviewers antigravity >/dev/null 2>&1 ); check "plan-review rejects a model name starting with '-' (1)" $? 1

# --- the gemini seat's fail-closed VERSION GATE ------------------------------------------------
# `tools.core` is an allowlist but NOT a universal one: gemini registers some tools outside that
# filter (delegate_to_agent in v0.26.0), and for those only tools.exclude stands in the way. A
# release that registered another write-capable tool the same way would pass BOTH controls while the
# seat kept claiming it cannot write. There is no CLI call that dumps the active registry, so the
# seat refuses to run against a version nobody has audited. These cases are the tripwire's own test:
# without them the gate could be deleted and every other gemini assertion here would stay green.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" STUB_GEMINI_VERSION=9.99.0 bash "$CLI" plan-review --reviewers antigravity 2>&1); rc=$?
check "plan-review fails the seat on an unaudited gemini version (3)" "$rc" 3
# The seat must fail BEFORE the review runs — a gate that reports a failure but still ran the tool
# is not a gate.
printf '%s' "$out" | grep -q 'REVIEW-gemini' && { echo "  FAIL gemini reviewed anyway on an unaudited version"; FAIL=$((FAIL+1)); } || { echo "  ok   [-] an unaudited gemini version never reaches the review"; PASS=$((PASS+1)); }
printf '%s' "$out" | grep -qi 'audited' && { echo "  ok   [-] the unaudited-version failure says why"; PASS=$((PASS+1)); } || { echo "  FAIL the unaudited-version failure gave no reason"; FAIL=$((FAIL+1)); }
# Auditing a new release and listing it opens the gate — major.minor, so patch releases ride along.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" STUB_GEMINI_VERSION=9.99.7 SHIP_FEATURE_GEMINI_TESTED_VERSIONS='0.26 9.99' bash "$CLI" plan-review --reviewers antigravity 2>/dev/null); rc=$?
check "plan-review accepts a gemini version listed as audited (0)" "$rc" 0
printf '%s' "$out" | grep -q 'REVIEW-gemini' && { echo "  ok   [-] an audited gemini version runs the review"; PASS=$((PASS+1)); } || { echo "  FAIL an audited gemini version still did not review"; FAIL=$((FAIL+1)); }
# The list is read from the config file too, not only the environment.
printf 'SHIP_FEATURE_GEMINI_TESTED_VERSIONS=9.99\n' > "$CFGDIR/gemver"
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" STUB_GEMINI_VERSION=9.99.0 SHIP_FEATURE_CONFIG="$CFGDIR/gemver" bash "$CLI" plan-review --reviewers antigravity 2>/dev/null); rc=$?
check "the config file can widen the audited gemini versions (0)" "$rc" 0

# MODEL_gemini in the SHARED relay config pins this seat too — one file for the whole panel. The key
# is MODEL_gemini and not MODEL_antigravity on purpose: the relay maps MODEL_antigravity onto its own
# `agy` seat, a different binary that accepts different model ids.
printf 'MODEL_gemini=gemini-9.9-test\n' > "$CFGDIR/sharedgem"
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/sharedgem" bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
printf '%s' "$out" | grep 'REVIEW-gemini' | grep -q -- "-m gemini-9.9-test" && { echo "  ok   [-] MODEL_gemini in the shared config pins the gemini seat"; PASS=$((PASS+1)); } || { echo "  FAIL MODEL_gemini was not mapped"; FAIL=$((FAIL+1)); }
# The environment still wins over the shared file, like every other pin.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" PR_RELAY_CONFIG="$CFGDIR/sharedgem" SHIP_FEATURE_GEMINI_MODEL=env-wins bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
printf '%s' "$out" | grep 'REVIEW-gemini' | grep -q -- "-m env-wins" && { echo "  ok   [-] the environment outranks MODEL_gemini"; PASS=$((PASS+1)); } || { echo "  FAIL MODEL_gemini overrode the environment"; FAIL=$((FAIL+1)); }

# A CLI is free to print a banner around its version number. The gate fails CLOSED, so a fragile
# parse does not leak — it bricks the seat on a version that WAS audited, and the failure blames the
# gate rather than the parse. Assert the number is picked out of the noise.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" STUB_GEMINI_VERSION='gemini-cli version 0.26.0 (build deadbeef)' bash "$CLI" plan-review --reviewers antigravity 2>/dev/null); rc=$?
check "the version gate reads a version printed with a banner (0)" "$rc" 0

# --- the OAuth credential path ------------------------------------------------------------------
# GEMINI_CLI_HOME also moves where gemini looks for its OAuth creds, so the seat copies the real ones
# in. That copy is the only place this isolation handles a live secret, and until now the suite only
# asserted the creds were ABSENT from the workspace — never that the copy itself behaves.
FAKEHOME="$WORK/fakehome"; mkdir -p "$FAKEHOME/.gemini"
printf '{"fake":"oauth"}' > "$FAKEHOME/.gemini/oauth_creds.json"
printf '{"fake":"accounts"}' > "$FAKEHOME/.gemini/google_accounts.json"
chmod 644 "$FAKEHOME/.gemini/oauth_creds.json"        # deliberately loose: the copy must tighten it

# No environment auth selected -> the OAuth fallback runs.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" HOME="$FAKEHOME" bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
iso=$(printf '%s\n' "$out" | grep 'GEMINI-ISO')
printf '%s' "$iso" | grep -q -- "homecreds=yes" && { echo "  ok   [-] the OAuth creds are copied into the isolated home"; PASS=$((PASS+1)); } || { echo "  FAIL the OAuth creds were not copied into GEMINI_CLI_HOME"; FAIL=$((FAIL+1)); }
# 0600, not the source's 0644: the copy lands in a temp dir and must not widen the secret.
printf '%s' "$iso" | grep -q -- "credmode=-rw-------" && { echo "  ok   [-] the copied creds are 0600 regardless of the source mode"; PASS=$((PASS+1)); } || { echo "  FAIL the copied OAuth creds did not end up 0600"; FAIL=$((FAIL+1)); }
printf '%s' "$iso" | grep -q -- "gca=true" && { echo "  ok   [-] the OAuth fallback opts into GOOGLE_GENAI_USE_GCA"; PASS=$((PASS+1)); } || { echo "  FAIL the OAuth fallback did not set GOOGLE_GENAI_USE_GCA"; FAIL=$((FAIL+1)); }
# Copied, never reachable from the workspace: the allowlisted read_file is scoped to the workspace,
# so this is what stops a hostile plan from asking the reviewer to read the token back out.
printf '%s' "$iso" | grep -q -- "credsafe=yes" && { echo "  ok   [-] the copied creds stay outside the workspace"; PASS=$((PASS+1)); } || { echo "  FAIL the copied OAuth creds were reachable from the workspace"; FAIL=$((FAIL+1)); }
# The USER scope must read the SAME locked file as the workspace scope, or it could re-enable a tool.
printf '%s' "$iso" | grep -q -- "lockedsame=yes" && { echo "  ok   [-] the user scope reads the same locked settings as the workspace"; PASS=$((PASS+1)); } || { echo "  FAIL the user-scope settings differ from the workspace ones"; FAIL=$((FAIL+1)); }
# COPY, not symlink: gemini's own token refresh writes this file, and a symlink would send that write
# through to the user's real ~/.gemini.
[ -s "$FAKEHOME/.gemini/oauth_creds.json" ] && { echo "  ok   [-] the user's real creds are left intact"; PASS=$((PASS+1)); } || { echo "  FAIL the user's real OAuth creds were disturbed"; FAIL=$((FAIL+1)); }

# GEMINI_API_KEY selected -> no OAuth fallback. GCA outranks an API key inside gemini, so copying
# stale creds here would break an otherwise valid key run.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" HOME="$FAKEHOME" GEMINI_API_KEY=k bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
iso=$(printf '%s\n' "$out" | grep 'GEMINI-ISO')
printf '%s' "$iso" | grep -q -- "homecreds=no" && printf '%s' "$iso" | grep -q -- "gca=UNSET" \
  && { echo "  ok   [-] GEMINI_API_KEY suppresses the OAuth fallback"; PASS=$((PASS+1)); } \
  || { echo "  FAIL GEMINI_API_KEY did not suppress the OAuth fallback"; FAIL=$((FAIL+1)); }

# Vertex selected the way v0.26.0 actually selects it.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" HOME="$FAKEHOME" GOOGLE_GENAI_USE_VERTEXAI=true bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
iso=$(printf '%s\n' "$out" | grep 'GEMINI-ISO')
printf '%s' "$iso" | grep -q -- "homecreds=no" && printf '%s' "$iso" | grep -q -- "gca=UNSET" \
  && { echo "  ok   [-] GOOGLE_GENAI_USE_VERTEXAI suppresses the OAuth fallback"; PASS=$((PASS+1)); } \
  || { echo "  FAIL Vertex did not suppress the OAuth fallback"; FAIL=$((FAIL+1)); }

# GOOGLE_API_KEY ALONE selects no auth method in gemini-cli v0.26.0. Treating it as one used to
# suppress the fallback and leave the run with no credentials at all — an opaque auth failure for
# anyone who had that variable exported for some other Google tool.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" HOME="$FAKEHOME" GOOGLE_API_KEY=k bash "$CLI" plan-review --reviewers antigravity 2>/dev/null)
iso=$(printf '%s\n' "$out" | grep 'GEMINI-ISO')
printf '%s' "$iso" | grep -q -- "homecreds=yes" && printf '%s' "$iso" | grep -q -- "gca=true" \
  && { echo "  ok   [-] GOOGLE_API_KEY alone does not count as selected auth"; PASS=$((PASS+1)); } \
  || { echo "  FAIL GOOGLE_API_KEY alone suppressed the OAuth fallback"; FAIL=$((FAIL+1)); }

# No creds to copy at all -> the seat still runs (auth simply rides whatever the environment has).
EMPTYHOME="$WORK/emptyhome"; mkdir -p "$EMPTYHOME"
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" HOME="$EMPTYHOME" bash "$CLI" plan-review --reviewers antigravity 2>/dev/null); rc=$?
check "the seat runs when there are no OAuth creds to copy (0)" "$rc" 0
printf '%s\n' "$out" | grep 'GEMINI-ISO' | grep -q -- "gca=UNSET" && { echo "  ok   [-] no creds copied means no GCA opt-in"; PASS=$((PASS+1)); } || { echo "  FAIL GCA was opted into with no creds copied"; FAIL=$((FAIL+1)); }

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
( printf 'plan\n' | env -i PATH="$WORK/pbin-nogemini" HOME="$HOME" SHIP_FEATURE_CONFIG=/dev/null bash "$CLI" plan-review --reviewers codex,antigravity >/dev/null 2>&1 ); check "plan-review fails the quorum when the gemini CLI is missing (3)" $? 3

# default panel comes from SHIP_FEATURE_REVIEWERS when --reviewers is omitted
out=$(printf 'a plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_REVIEWERS=claude,cursor bash "$CLI" plan-review 2>/dev/null); rc=$?
check "plan-review uses SHIP_FEATURE_REVIEWERS by default" "$rc" 0
printf '%s' "$out" | grep -q "REVIEW-claude" && printf '%s' "$out" | grep -q "REVIEW-cursor" \
  && { echo "  ok   [-] plan-review ran the configured default panel"; PASS=$((PASS+1)); } \
  || { echo "  FAIL plan-review did not run the configured panel"; FAIL=$((FAIL+1)); }

# SHIP_FEATURE_PLAN_REVIEWERS overrides the shared quorum for plan-review (a smaller panel
# than the PR cross-review). When both are set, the plan-specific one wins.
out=$(printf 'a plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_REVIEWERS=claude,codex,cursor,kimi3 SHIP_FEATURE_PLAN_REVIEWERS=claude,codex bash "$CLI" plan-review 2>/dev/null); rc=$?
check "plan-review prefers SHIP_FEATURE_PLAN_REVIEWERS" "$rc" 0
if printf '%s' "$out" | grep -q "REVIEW-claude" && printf '%s' "$out" | grep -q "REVIEW-codex" && ! printf '%s' "$out" | grep -q "REVIEW-cursor"; then
  echo "  ok   [-] the plan-specific panel wins over the quorum"; PASS=$((PASS+1))
else echo "  FAIL plan-review did not prefer SHIP_FEATURE_PLAN_REVIEWERS"; FAIL=$((FAIL+1)); fi

# a reviewer that returns an EMPTY review → not clean (exit 3)
printf '#!/usr/bin/env bash\nexit 0\n' > "$PBIN/codex"; chmod +x "$PBIN/codex"
( printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers codex,kimi3 >/dev/null 2>&1 ); check "plan-review empty review → not clean (3)" $? 3
make_reviewer codex 0 codex   # restore

# a NON-ZERO reviewer exit → not clean (exit 3)
make_reviewer codex 1 codex
( printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers codex >/dev/null 2>&1 ); check "plan-review non-zero reviewer → not clean (3)" $? 3
make_reviewer codex 0 codex   # restore

# a supported reviewer from the panel whose CLI is missing → fail (3): the panel is the
# quorum, so it never quietly passes on a thinned set.
( printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers codex,doesnotexist >/dev/null 2>&1 ); check "plan-review missing panel reviewer → fail (3)" $? 3

# bare opencode and bare grok are RELAY-ONLY: skipped with a warning, the rest of the panel still runs (0)
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers opencode,grok,codex 2>&1); rc=$?
check "plan-review skips relay-only agents, runs the rest" "$rc" 0
printf '%s' "$out" | grep -qi "relay-only" && { echo "  ok   [-] plan-review warns that opencode/grok are relay-only"; PASS=$((PASS+1)); } || { echo "  FAIL plan-review did not warn about relay-only agents"; FAIL=$((FAIL+1)); }

# a panel of ONLY relay-only agents → nobody supported ran → clear error (1)
( printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers opencode,grok >/dev/null 2>&1 ); check "plan-review with only relay-only agents → error (1)" $? 1

# no panel at all (unset + none passed) → usage error (1)
( printf 'plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_REVIEWERS= bash "$CLI" plan-review >/dev/null 2>&1 ); check "plan-review with no panel → usage error (1)" $? 1

# an empty plan → error (1)
( printf '' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers codex >/dev/null 2>&1 ); check "plan-review on an empty plan → error (1)" $? 1

# a plan passed as a FILE argument is reviewed
printf 'Plan from a file\n' > "$WORK/aplan.md"
out=$(PATH="$PBIN:$PATH" bash "$CLI" plan-review "$WORK/aplan.md" --reviewers codex 2>/dev/null); rc=$?
check "plan-review reads a plan from a file argument" "$rc" 0
printf '%s' "$out" | grep -q "REVIEW-codex" && { echo "  ok   [-] plan-review reviewed the file's contents"; PASS=$((PASS+1)); } || { echo "  FAIL plan-review did not review the file"; FAIL=$((FAIL+1)); }

# a file given after `--` is still reviewed (not dropped)
out=$(PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers codex -- "$WORK/aplan.md" 2>/dev/null); rc=$?
check "plan-review honors a file after --" "$rc" 0
printf '%s' "$out" | grep -q "REVIEW-codex" && { echo "  ok   [-] plan-review reviewed the file passed after --"; PASS=$((PASS+1)); } || { echo "  FAIL plan-review dropped the file after --"; FAIL=$((FAIL+1)); }

# an EMPTY stdin pipe must fall back to ./plan.md, not shadow it with "empty plan"
PDIR="$WORK/plandir"; mkdir -p "$PDIR"; printf 'plan.md content\n' > "$PDIR/plan.md"
out=$( cd "$PDIR" && printf '' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers codex 2>/dev/null ); rc=$?
check "plan-review falls back to ./plan.md on empty stdin" "$rc" 0
printf '%s' "$out" | grep -q "REVIEW-codex" && { echo "  ok   [-] plan-review reviewed ./plan.md"; PASS=$((PASS+1)); } || { echo "  FAIL plan-review did not fall back to ./plan.md"; FAIL=$((FAIL+1)); }

# a missing file argument fails clearly
( PATH="$PBIN:$PATH" bash "$CLI" plan-review "$WORK/nope.md" --reviewers codex >/dev/null 2>&1 ); check "plan-review fails on a missing file" $? 1

# explicit `-` reads stdin (even conceptually on a TTY) and does NOT fall back to plan.md
out=$( cd "$PDIR" && printf 'STDIN PLAN VIA DASH\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review - --reviewers codex 2>/dev/null ); rc=$?
check "plan-review reads stdin on explicit -" "$rc" 0
printf '%s' "$out" | grep -q "REVIEW-codex" && { echo "  ok   [-] plan-review reviewed the '-' stdin plan"; PASS=$((PASS+1)); } || { echo "  FAIL plan-review did not read '-' stdin"; FAIL=$((FAIL+1)); }

# an explicit but EMPTY plan file fails with a file-specific message (exit 1)
: > "$WORK/blank.md"
( PATH="$PBIN:$PATH" bash "$CLI" plan-review "$WORK/blank.md" --reviewers codex >/dev/null 2>&1 ); check "plan-review rejects an empty explicit file (1)" $? 1

# the --reviewers= form is rejected (two-token only), matching relay
( printf 'p\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers=codex >/dev/null 2>&1 ); check "plan-review rejects the --reviewers= form" $? 1

# a trailing --reviewers with no value → clean usage error, NOT a set -u crash
( printf 'p\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers >/dev/null 2>&1 ); check "plan-review: bare --reviewers → usage error (1)" $? 1
# an explicitly EMPTY --reviewers "" is a usage error, not a silent fall-through to the env panel
( printf 'p\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_REVIEWERS=codex bash "$CLI" plan-review --reviewers '' >/dev/null 2>&1 ); check "plan-review: --reviewers '' → usage error, no env fallback (1)" $? 1
# --reviewers immediately followed by a flag is also a usage error (not a reviewer named --parallel)
( printf 'p\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers --parallel >/dev/null 2>&1 ); check "plan-review: --reviewers <flag> → usage error (1)" $? 1

# a numerically-zero timeout is rejected (GNU `timeout 0` would DISABLE the timeout)
( printf 'p\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_PLAN_TIMEOUT=00 bash "$CLI" plan-review --reviewers codex >/dev/null 2>&1 ); check "plan-review rejects a zero timeout (00)" $? 1

# the reviewer list is NOT glob-expanded: a wildcard in a dir with matching files stays
# literal (→ unknown reviewer → fail 3), it does not become those filenames.
GDIR="$WORK/globdir"; mkdir -p "$GDIR"; : > "$GDIR/aaa"; : > "$GDIR/abb"
( cd "$GDIR" && printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers 'a*' >/dev/null 2>&1 ); check "plan-review does not glob-expand the reviewer list" $? 3

# `help` prints the header comment block, and it must name every command. It used to print a
# hardcoded line range, so documenting a new flag in the header silently truncated help mid-
# sentence and dropped the last command — invisible unless someone reads the output. There was no
# test at all; this is it.
help_out=$(bash "$CLI" help 2>&1); check "help exits 0" $? 0
for _c in preflight relay plan-review help; do
  printf '%s' "$help_out" | grep -q "ship-feature $_c"; check "help documents the '$_c' command" $? 0
done

# The default really is CONCURRENT, not merely "produces the same output as parallel would".
# Counting reviews cannot tell the two apart — a sequential run prints the same three. Three
# reviewers that each sleep 1s take ~1s together and ~3s one after another, so the wall clock is
# the only honest witness. Generous bounds: this must not go flaky on a loaded machine.
# NB: the `kimi3` reviewer runs the `opencode` binary — stub the tool names, not the seat names.
OVERLAP_LOG="$WORK/overlap.log"
for _slow in claude codex opencode; do
  cat > "$PBIN/$_slow" <<SLOWSTUB
#!/usr/bin/env bash
echo "start" >> "$OVERLAP_LOG"
sleep 1
echo "end" >> "$OVERLAP_LOG"
echo "REVIEW-$_slow"
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
overlap_run() {   # $1 = extra args; echoes the run's stdout, leaves the log in $OVERLAP_LOG
  : > "$OVERLAP_LOG"
  printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude,codex,kimi3 $1 2>/dev/null
}

out=$(overlap_run "")
n=$(printf '%s' "$out" | grep -c "REVIEW-"); check "plan-review (default) still ran all three slow reviewers" "$n" 3
shape=$(tr '\n' ' ' < "$OVERLAP_LOG")
check "plan-review (default) overlaps the reviewers" "$shape" "start start start end end end "

out=$(overlap_run "--sequential")
n=$(printf '%s' "$out" | grep -c "REVIEW-"); check "plan-review --sequential ran all three slow reviewers" "$n" 3
shape=$(tr '\n' ' ' < "$OVERLAP_LOG")
check "plan-review --sequential never overlaps them" "$shape" "start end start end start end "

# "The last flag wins" is a documented promise, so it gets a test in both orders — using the
# same overlap shape, which is what the promise is actually about.
out=$(overlap_run "--sequential --parallel")
shape=$(tr '\n' ' ' < "$OVERLAP_LOG")
check "plan-review --sequential --parallel ends up parallel" "$shape" "start start start end end end "

out=$(overlap_run "--parallel --sequential")
shape=$(tr '\n' ' ' < "$OVERLAP_LOG")
check "plan-review --parallel --sequential ends up sequential" "$shape" "start end start end start end "

make_reviewer claude 0 claude; make_reviewer codex 0 codex; make_reviewer kimi3 0 opencode   # restore

# Parallel is the DEFAULT, so the flagless run must behave like the --parallel one: reviews are
# buffered and emitted in panel order after the barrier, and the banner does not say "sequential".
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude,codex,kimi3 2>&1); rc=$?
check "plan-review runs the panel in parallel with no flag (0)" "$rc" 0
n=$(printf '%s' "$out" | grep -c "REVIEW-"); check "plan-review (default) ran all three reviewers" "$n" 3
n=$(printf '%s' "$out" | grep -c -- "— sequential"); check "plan-review (default) does not announce sequential" "$n" 0

# --sequential is the opt-out: still clean, still every reviewer, and it says so on the banner.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude,codex,kimi3 --sequential 2>&1); rc=$?
check "plan-review --sequential clean run exits 0" "$rc" 0
n=$(printf '%s' "$out" | grep -c "REVIEW-"); check "plan-review --sequential ran all three reviewers" "$n" 3
n=$(printf '%s' "$out" | grep -c -- "— sequential"); check "plan-review --sequential announces the mode" "$n" 1

# --parallel: clean run exits 0 and prints every reviewer (order-independent)
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude,codex,kimi3 --parallel 2>/dev/null); rc=$?
check "plan-review --parallel clean run exits 0" "$rc" 0
n=$(printf '%s' "$out" | grep -c "REVIEW-"); check "plan-review --parallel ran all three reviewers" "$n" 3

# --parallel is still fail-closed: one empty reviewer fails the whole round (3)
printf '#!/usr/bin/env bash\nexit 0\n' > "$PBIN/codex"; chmod +x "$PBIN/codex"
( printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude,codex,kimi3 --parallel >/dev/null 2>&1 ); check "plan-review --parallel stays fail-closed (3)" $? 3
make_reviewer codex 0 codex   # restore

# The EXIT trap must actually delete STATUS_DIR. It expands "$STATUS_DIR" when it fires, which is
# after cmd_plan_review has returned — so if that variable is ever made function-local again, the
# name is unbound by then, `set -u` aborts the trap body, and every run leaves its directory (with
# each reviewer's buffered review in it) behind forever. That regression is invisible except for a
# stderr line, which is why it survived ~310 leaks a day until someone counted /tmp.
# Give the CLI its own TMPDIR so this measures only what plan-review created, and keep the panel to
# codex: kimi3 forces TMPDIR=/tmp for its own isolated cwd, which would muddy the count.
leakdir="$WORK/leak"; mkdir -p "$leakdir"
leakerr="$WORK/leak.err"
( printf 'plan\n' | PATH="$PBIN:$PATH" TMPDIR="$leakdir" bash "$CLI" plan-review --reviewers codex >/dev/null 2>"$leakerr" ); leakrc=$?
# Assert the run actually SUCCEEDED first. Without this the other two assertions pass vacuously:
# a `die` before mktemp -d would leave nothing behind and print no unbound-variable line, so a
# broken CLI would look like a clean one and the cleanup path would never be exercised at all.
check "plan-review leak probe ran successfully" "$leakrc" 0
# Numeric compare: `wc -l` can emit padded output, so a string test against "0" would false-fail.
leftovers=$(find "$leakdir" -mindepth 1 | wc -l)
[ "$leftovers" -eq 0 ] \
  && { echo "  ok   [-] plan-review removes its temp dir on exit"; PASS=$((PASS+1)); } \
  || { echo "  FAIL plan-review leaked $leftovers entries under its TMPDIR: $(find "$leakdir" -mindepth 1 -maxdepth 1)"; FAIL=$((FAIL+1)); }
# Secondary, and only that: a fix which merely silenced the message would still pass this one.
grep -q 'unbound variable' "$leakerr" \
  && { echo "  FAIL plan-review printed an unbound-variable error: $(grep 'unbound variable' "$leakerr")"; FAIL=$((FAIL+1)); } \
  || { echo "  ok   [-] plan-review exits without an unbound-variable error"; PASS=$((PASS+1)); }

# Interrupt teardown: ^C during --parallel must kill the reviewer's deep descendants
# (subshell -> $() -> timeout -> agent), not leak them. A slow stub holds a `sleep`
# grandchild; we record every descendant PID, SIGINT the CLI, then assert they're gone.
# pgrep is required for kill_tree; skip cleanly where it's absent rather than false-fail.
if command -v pgrep >/dev/null 2>&1; then
  _descendants() { local p="$1" c; for c in $(pgrep -P "$p" 2>/dev/null); do echo "$c"; _descendants "$c"; done; }
  printf 'a plan\n' > "$WORK/intplan.md"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$PBIN/codex"; chmod +x "$PBIN/codex"   # a "slow agent"
  PATH="$PBIN:$PATH" bash "$CLI" plan-review "$WORK/intplan.md" --reviewers codex --parallel >/dev/null 2>&1 &
  cli=$!
  # Wait (up to ~4s) for the sleep grandchild to materialize under the CLI.
  sleeppids=""
  for _i in $(seq 1 20); do
    for k in $(_descendants "$cli"); do case "$(ps -o comm= -p "$k" 2>/dev/null)" in *sleep) sleeppids="$sleeppids $k";; esac; done
    [ -n "$sleeppids" ] && break; sleep 0.2
  done
  kill -INT "$cli" 2>/dev/null; wait "$cli" 2>/dev/null; sleep 0.5
  if [ -z "$sleeppids" ]; then
    echo "  FAIL interrupt test: reviewer subtree never materialized (inconclusive)"; FAIL=$((FAIL+1))
  else
    alive=0; for p in $sleeppids; do kill -0 "$p" 2>/dev/null && alive=1; done
    if [ "$alive" = 0 ]; then echo "  ok   [-] ^C during --parallel kills the reviewer's descendants"; PASS=$((PASS+1))
    else echo "  FAIL interrupt left a reviewer descendant alive"; FAIL=$((FAIL+1)); for p in $sleeppids; do kill -9 "$p" 2>/dev/null; done; fi
  fi
  make_reviewer codex 0 codex   # restore
else
  echo "  ok   [-] interrupt teardown test skipped (no pgrep)"; PASS=$((PASS+1))
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
sf_check_isolated \
  && { echo "  ok   [-] the git isolation is still in force after the whole suite"; PASS=$((PASS+1)); } \
  || { echo "  FAIL the git isolation was lost partway through the run"; FAIL=$((FAIL+1)); }

# 0b. init.templateDir="" was in the first draft of sf_isolate_git and broke `>> .git/info/exclude`,
#     which is how the worktree marker gets ignored. It was removed with only a comment as memory —
#     this is the assertion that fires if someone "helps" the function again.
( T="$WORK/tpl"; rm -rf "$T"; mkdir -p "$T"; cd "$T" || exit 1
  sf_isolate_git
  git init -q . 2>/dev/null || exit 4          # tell "init itself broke" from "no info dir"
  echo x >> .git/info/exclude 2>/dev/null || exit 3 ) >/dev/null 2>&1
t0b=$?
case "$t0b" in
  0) echo "  ok   [-] git init still produces .git/info (no empty templateDir)"; PASS=$((PASS+1));;
  3) echo "  FAIL .git/info missing — init.templateDir was probably reintroduced"; FAIL=$((FAIL+1));;
  *) echo "  FAIL .git/info check could not run (git init failed, rc=$t0b)"; FAIL=$((FAIL+1));;
esac

# 1. Signing off at the COMMIT level, against a genuinely planted ambient gpgsign.
#    Asserted as exactly %G? = N, not "not G": a signature that fails verification reports E/B/R,
#    which would slip past a denylist while still meaning isolation failed.
( H="$WORK/h1"; mkdir -p "$H"; cd "$H" || exit 1
  git init -q . 2>/dev/null
  export GIT_CONFIG_PARAMETERS="'commit.gpgsign=true'"
  [ "$(git config --get commit.gpgsign 2>/dev/null)" = "true" ] || { echo PLANT_DEAD; exit 3; }
  sf_isolate_git
  git commit -q --allow-empty -m one 2>/dev/null || { echo COMMIT_DEAD; exit 4; }
  git log -1 --format='%G?' 2>/dev/null | tail -1 ) > "$WORK/h1.out" 2>/dev/null
h1=$?; h1v="$(tail -1 "$WORK/h1.out" 2>/dev/null)"
[ "$h1" = 0 ] && [ "$h1v" = "N" ] \
  && { echo "  ok   [-] a planted ambient commit.gpgsign is defeated (%G? = N)"; PASS=$((PASS+1)); } \
  || { echo "  FAIL git isolation: planted signing survived (rc=$h1 out='$h1v')"; FAIL=$((FAIL+1)); }

# 2. GIT_CONFIG_PARAMETERS specifically: it OVERRIDES GIT_CONFIG_COUNT, so if the unset loop is
#    deleted while the exports stay, the controlled values are silently ignored. The control
#    proves the override is live before isolation runs.
( cd "$WORK" || exit 1
  export GIT_CONFIG_PARAMETERS="'commit.gpgsign=true'"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
  [ "$(git config --get commit.gpgsign 2>/dev/null)" = "true" ] || { echo PLANT_DEAD; exit 3; }
  sf_isolate_git
  [ -z "${GIT_CONFIG_PARAMETERS:-}" ] || { echo STILL_SET; exit 4; }
  git config --get commit.gpgsign 2>/dev/null | tail -1 ) > "$WORK/h2.out" 2>/dev/null
h2=$?; h2v="$(tail -1 "$WORK/h2.out" 2>/dev/null)"
[ "$h2" = 0 ] && [ "$h2v" = "false" ] \
  && { echo "  ok   [-] GIT_CONFIG_PARAMETERS beats GIT_CONFIG_COUNT, and is cleared first"; PASS=$((PASS+1)); } \
  || { echo "  FAIL git isolation: GIT_CONFIG_PARAMETERS override not neutralised (rc=$h2 out='$h2v')"; FAIL=$((FAIL+1)); }

# 3. A planted core.hooksPath must not reach fixture commits. Without this, deleting
#    GIT_CONFIG_KEY_2 would go unnoticed — the same rot the tag.gpgsign check exists to prevent.
( H="$WORK/h3"; HK="$WORK/h3hooks"; mkdir -p "$H" "$HK"; cd "$H" || exit 1
  # The hook prints a unique marker, so the control proves the commit failed BECAUSE OF THE HOOK
  # rather than for any other reason — otherwise "the commit failed" is satisfied by a broken
  # fixture and the post-isolation success does all the work.
  printf '#!/bin/sh\necho SF_HOOK_MARKER >&2\nexit 1\n' > "$HK/pre-commit"; chmod +x "$HK/pre-commit"
  git init -q . 2>/dev/null
  export GIT_CONFIG_PARAMETERS="'core.hooksPath=$HK'"
  cerr=$(git commit --allow-empty -m blocked 2>&1); crc=$?
  [ "$crc" != 0 ] || { echo PLANT_DEAD_COMMIT_SUCCEEDED; exit 3; }
  case "$cerr" in *SF_HOOK_MARKER*) ;; *) echo "PLANT_DEAD_NOT_THE_HOOK"; exit 3;; esac
  sf_isolate_git
  git commit -q --allow-empty -m allowed 2>/dev/null || { echo STILL_BLOCKED; exit 4; }
  echo OK ) > "$WORK/h3.out" 2>/dev/null
h3=$?
[ "$h3" = 0 ] \
  && { echo "  ok   [-] a planted core.hooksPath cannot block a fixture commit"; PASS=$((PASS+1)); } \
  || { echo "  FAIL git isolation: hostile hooksPath (rc=$h3 out='$(tail -1 "$WORK/h3.out" 2>/dev/null)')"; FAIL=$((FAIL+1)); }

# 3b. The original bug is a developer with commit.gpgsign=true in ~/.gitconfig — no hook, no
#     GIT_CONFIG_PARAMETERS. Test 1 plants the strictly stronger override, so this plants the plain
#     global one via GIT_CONFIG_GLOBAL, which is how git reads a user config without touching theirs.
( H="$WORK/h3b"; G="$WORK/h3b.gitconfig"; mkdir -p "$H"; cd "$H" || exit 1
  # A fresh shell first: the suite already exported GIT_CONFIG_COUNT, and env config OUTRANKS the
  # global file, so the plant would be defeated before isolation ever ran and the case would report
  # PLANT_DEAD. Clearing git's own env list is what "a developer's plain shell" actually looks like.
  while IFS= read -r _v; do [ -n "$_v" ] && unset "$_v"; done < <(git rev-parse --local-env-vars)
  printf '[commit]\n\tgpgsign = true\n' > "$G"
  export GIT_CONFIG_GLOBAL="$G"
  git init -q . 2>/dev/null
  [ "$(git config --get commit.gpgsign 2>/dev/null)" = "true" ] || { echo PLANT_DEAD; exit 3; }
  sf_isolate_git
  git commit -q --allow-empty -m global 2>/dev/null || { echo COMMIT_DEAD; exit 4; }
  git log -1 --format='%G?' 2>/dev/null | tail -1 ) > "$WORK/h3b.out" 2>/dev/null
h3b=$?; h3bv="$(tail -1 "$WORK/h3b.out" 2>/dev/null)"
[ "$h3b" = 0 ] && [ "$h3bv" = "N" ] \
  && { echo "  ok   [-] a plain global commit.gpgsign is defeated too (%G? = N)"; PASS=$((PASS+1)); } \
  || { echo "  FAIL git isolation: global-config signing survived (rc=$h3b out='$h3bv')"; FAIL=$((FAIL+1)); }

# 3c. core.excludesFile is the sharpest of the remaining ambient settings and had no plant: a global
#     ignore rule for a pattern a fixture uses makes that file invisible to `git add`, and the test
#     that needed it fails for a reason nobody would guess. (`*.dat` is not hypothetical — the
#     binary-scan fixture commits a .dat file.) The other three neutralised keys —
#     core.attributesFile, core.fsmonitor, color.ui — are asserted through this same function being
#     in force, not individually; excludesFile is the one with a demonstrated failure.
( H="$WORK/h3c"; IG="$WORK/h3c.ignore"; mkdir -p "$H"; cd "$H" || exit 1
  while IFS= read -r _v; do [ -n "$_v" ] && unset "$_v"; done < <(git rev-parse --local-env-vars)
  printf '*.dat\n' > "$IG"
  export GIT_CONFIG_GLOBAL="$IG.cfg"
  printf '[core]\n\texcludesFile = %s\n' "$IG" > "$IG.cfg"
  git init -q . 2>/dev/null
  : > payload.dat
  git add payload.dat 2>/dev/null
  git diff --cached --name-only 2>/dev/null | grep -q payload.dat && { echo PLANT_DEAD; exit 3; }
  sf_isolate_git
  git add payload.dat 2>/dev/null
  git diff --cached --name-only 2>/dev/null | grep -q payload.dat || { echo STILL_IGNORED; exit 4; }
  echo OK ) > "$WORK/h3c.out" 2>/dev/null
h3c=$?
[ "$h3c" = 0 ] \
  && { echo "  ok   [-] a planted core.excludesFile cannot hide a fixture's file"; PASS=$((PASS+1)); } \
  || { echo "  FAIL git isolation: excludesFile (rc=$h3c out='$(tail -1 "$WORK/h3c.out" 2>/dev/null)')"; FAIL=$((FAIL+1)); }

# 3d. The three remaining neutralised keys have no commit-level symptom in this suite, so they get
#     config assertions — the same weight as tag.gpgsign. Without these you could no-op KEY_4..6,
#     keep seven keys so the startup guard still passes, and stay green. color.ui is the one that
#     would bite first: color.ui=always puts ANSI into the `%G?` read above.
( cd "$WORK" || exit 1; sf_isolate_git
  printf '%s|%s|%s' "$(git config --get core.attributesFile 2>/dev/null)" \
                    "$(git config --get core.fsmonitor 2>/dev/null)" \
                    "$(git config --get color.ui 2>/dev/null)" ) > "$WORK/h3d.out" 2>/dev/null
h3dv="$(tail -1 "$WORK/h3d.out" 2>/dev/null)"
[ "$h3dv" = "/dev/null|false|false" ] \
  && { echo "  ok   [-] attributesFile, fsmonitor and color.ui are neutralised too"; PASS=$((PASS+1)); } \
  || { echo "  FAIL git isolation: attributesFile/fsmonitor/color.ui (got '"'"'$h3dv'"'"')"; FAIL=$((FAIL+1)); }

# 4. tag.gpgsign has no commit-level effect in this suite, which is exactly why it would rot
#    unnoticed. A config assertion is the right weight for it.
( cd "$WORK" || exit 1; sf_isolate_git; git config --get tag.gpgsign 2>/dev/null | tail -1 ) > "$WORK/h4.out" 2>/dev/null
[ "$(tail -1 "$WORK/h4.out" 2>/dev/null)" = "false" ] \
  && { echo "  ok   [-] tag.gpgsign is forced off too"; PASS=$((PASS+1)); } \
  || { echo "  FAIL tag.gpgsign not forced off"; FAIL=$((FAIL+1)); }

# 5. A planted GIT_DIR must not capture a fixture's commits — the failure that corrupted a real
#    repository. The control proves the decoy really would have taken it.
( DECOY="$WORK/decoy"; FIX="$WORK/fix5"; rm -rf "$DECOY" "$FIX"; mkdir -p "$DECOY" "$FIX"
  git init -q "$DECOY" 2>/dev/null; git init -q "$FIX" 2>/dev/null
  before=$(git -C "$DECOY" rev-list --all --count 2>/dev/null || echo 0)
  ( cd "$FIX" && GIT_DIR="$DECOY/.git" GIT_WORK_TREE="$DECOY" git commit -q --allow-empty -m captured 2>/dev/null )
  mid=$(git -C "$DECOY" rev-list --all --count 2>/dev/null || echo 0)
  [ "$mid" -gt "$before" ] || { echo PLANT_DEAD; exit 3; }
  ( cd "$FIX" && export GIT_DIR="$DECOY/.git" GIT_WORK_TREE="$DECOY" \
    && sf_isolate_git && git commit -q --allow-empty -m isolated 2>/dev/null )
  after=$(git -C "$DECOY" rev-list --all --count 2>/dev/null || echo 0)
  fixn=$(git -C "$FIX" rev-list --all --count 2>/dev/null || echo 0)
  [ "$after" = "$mid" ] && [ "$fixn" -ge 1 ] && echo OK || echo "LEAKED:$mid->$after fixture=$fixn" ) > "$WORK/h5.out" 2>/dev/null
h5=$?
[ "$h5" = 0 ] && [ "$(tail -1 "$WORK/h5.out" 2>/dev/null)" = "OK" ] \
  && { echo "  ok   [-] a planted GIT_DIR cannot capture a fixture's commit"; PASS=$((PASS+1)); } \
  || { echo "  FAIL git isolation: GIT_DIR capture (rc=$h5 out='$(tail -1 "$WORK/h5.out" 2>/dev/null)')"; FAIL=$((FAIL+1)); }

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
SF_ADAPTERS="adapters/codex/AGENTS.snippet.md adapters/cursor/ship-feature.md adapters/skill/SKILL.md WORKFLOW.md"
# Whitespace is NORMALISED before matching. Without it this test is really a test of line wrapping:
# the first run of it failed on "the plan file is / the source" and "Still two / gates, never three",
# both correct sentences that happened to break across a line. That would have taught the next person
# to reflow prose to please a grep, which is backwards — the adapters are prose for humans and their
# wrapping must stay free.
sf_clause() {  # sf_clause <label> <extended-regex>
  local label="$1" re="$2" f miss=""
  for f in $SF_ADAPTERS; do
    tr '\n' ' ' < "$HERE/../$f" | tr -s ' ' | grep -Eqi -- "$re" || miss="$miss $f"
  done
  [ -z "$miss" ] \
    && { echo "  ok   [-] every adapter states: $label"; PASS=$((PASS+1)); } \
    || { echo "  FAIL adapter consistency: '$label' missing from$miss"; FAIL=$((FAIL+1)); }
}
# The patterns are MULTI-WORD ANCHORS, not single tokens. The first version of this test grepped for
# `qualifying`, `narrow`, `benched`, `dispositions` — words that survive having the rule around them
# deleted or REVERSED, so the test would stay green while the adapter said the opposite. Two reviewers
# caught it independently. Each pattern below has to match a phrase that only the correct rule makes.
sf_clause "always pass the plan with --context-file"  'always pass the plan.{0,40}context-file|context-file.{0,80}always pass the plan'
sf_clause "the plan file is the source of the PR body" 'plan file is the source'
sf_clause "iterate ONLY for a Blocker or qualifying"  'iterate only for a .{0,20}blocker.{0,60}qualifying'
sf_clause "narrow panel = stake + downgraded"         'narrow.{0,200}(stake|open finding).{0,120}downgraded'
sf_clause "the closing round is the full quorum"      'closing.{0,140}full quorum|full quorum again.{0,160}(candidate|merge)'
sf_clause "a new closing finding restarts the cycle" '(closing|final).{0,120}(new qualifying|raises).{0,140}initial|initial round of another cycle'
sf_clause "never publish the derived context file"   '(never|not) .{0,20}(gh pr edit|re-publish).{0,120}derived|derived file to the pr body'
sf_clause "exit 4 = escalate, never --reset"          'exit .?4.?.{0,120}(escalat|stop)'
sf_clause "a clean round 1 IS the closing round"      'round 1 was already clean|clean initial round is the closing round'
sf_clause "exit 0 = DISPATCHED, and benched still exits 0" '(dispatched reviewer ran|supposed to dispatch).{0,400}benched'
sf_clause "non-qualifying findings are left unfixed"  'non-qualifying findings are recorded and left unfixed'
sf_clause "post dispositions BEFORE re-running"       'post (the )?dispositions before re-running'
sf_clause "keep the relay marker out of that comment" '(do .{0,4}not.{0,4} put|keep|must not contain).{0,80}marker text.{0,180}delet'
sf_clause "disputes are routed to Gate 2 with both positions" 'disput.{0,80}gate 2.{0,60}both positions|disput.{0,80}both positions'
sf_clause "and that is not a third gate"                     'two.{0,12}gates, (never|not) three'
sf_clause "the plan is immutable once approved"              'immutable once approved'
sf_clause "the initial quorum excludes the author"           'except the author'
sf_clause "the author classifies findings in writing"        'author classifies( each finding)? in writing'

# --- plan-review (step 2) gets the SAME discipline, in its own terms ----------------------------
# A real session ran 13 rounds of plan-review before the panel agreed (~1h15m burned on convergence,
# not the plan) because step 2 only ever said "iterate (approx 2 rounds)" — a suggestion, not a rule.
# "plan-qualifying" is asserted as a term DISTINCT from step 5's "qualifying Should-fix" (PR-qualifying:
# correctness/safety/deployability/verification) — the two must not collapse into one grep-satisfying
# phrase, or an adapter could state step 5's rule alone and wrongly pass for step 2's.
sf_clause "plan-review round excludes exit 3"                'exit .?3.?.{0,200}does.{0,6}not.{0,6}count as a round'
sf_clause "two consecutive exit-3s stop retrying and drop that reviewer" 'two consecutive attempts.{0,120}stop retrying.{0,160}drop that reviewer'
sf_clause "a reduced panel is escalated to the human, not silent" '(tell the human|human.{0,20}call).{0,160}reduced panel|reduced panel.{0,160}(tell the human|human.{0,20}call)'
sf_clause "plan-review cap is 2 rounds"                       '(2|two).{0,10}round.{0,40}cap|cap.{0,20}(2|two).{0,10}round'
sf_clause "a clean round 1 skips a wasted round 2"            'clean round 1|round 1 .{0,60}(raises no|no blocker).{0,120}gate 1'
sf_clause "round 2 runs the same full panel, never narrowed" 'same full panel.{0,60}never.{0,10}narrow|never.{0,10}narrow.{0,120}same full panel'
sf_clause "plan-qualifying is compared against PR-qualifying/qualifying Should-fix" 'plan-qualifying.{0,300}(qualifying should-fix|pr-qualifying)|(qualifying should-fix|pr-qualifying).{0,300}plan-qualifying'
sf_clause "plan-qualifying must not be conflated with PR-qualifying"       '(not the same as|must not be conflated|distinct term|do not conflate)'
sf_clause "plan-qualifying covers a missing edge case"                    'materially incomplete.{0,160}missing edge case|missing edge case.{0,160}materially incomplete'
sf_clause "plan-qualifying covers an unhandled failure mode"              'materially incomplete.{0,160}failure mode|failure mode.{0,160}materially incomplete'
sf_clause "plan-qualifying covers missing verification"                   'materially incomplete.{0,160}verification|verification.{0,160}materially incomplete'
sf_clause "round 2 still open -> disagreement summary -> Gate 1" 'round 2.{0,300}disagreement summary.{0,200}gate 1|disagreement summary.{0,300}round 2'
sf_clause "disagreement summary states objection + classification + reason" 'objection.{0,60}classification.{0,60}reason|disagreement summary.{0,400}(objection|classification|reason).{0,120}(objection|classification|reason).{0,120}(objection|classification|reason)'
sf_clause "a human-authorized round is not a third autonomous round" 'human-authorized.{0,80}not a third autonomous'
sf_clause "a human-authorized round resolves clean or re-escalates" 'human-authorized.{0,200}(resolves cleanly|resolve).{0,160}(disagreement summary|gate 1)'
sf_clause "Gate 1 accepts the plan plus a disagreement summary" 'plan plus a disagreement summary|plan.{0,20}disagreement summary'
sf_clause "dropping the last reviewer is not a completed round" 'zero reviewers.{0,120}(not a completed round|isn.t a completed round)'

# And the TOOL, not only the documents. `bin/ship-feature` prints the loop rule to the operator on
# every relay run, which out-ranks any document nobody re-reads — so a revert of that one string must
# turn the suite red too. It was not covered until a reviewer pointed out that it silently stays green.
#
# Matched against the `echo` LINE ONLY, not the whole file: the explanatory comment above that `case`
# arm also contains the words, so a whole-file grep stays green when the operator-facing string is
# reverted — the test would then be asserting my own comment, which is the greenwash this whole
# section exists to remove. A reviewer caught it; grep the message, not the prose about it.
sf_tool_clause() {  # sf_tool_clause <label> <extended-regex>
  local label="$1" re="$2"
  grep -E '^[[:space:]]*0\)[[:space:]]*echo' "$CLI" | grep -Eqi -- "$re" \
    && { echo "  ok   [-] bin/ship-feature's exit-0 message states: $label"; PASS=$((PASS+1)); } \
    || { echo "  FAIL adapter consistency: '$label' missing from bin/ship-feature's exit-0 message"; FAIL=$((FAIL+1)); }
}
sf_tool_clause "every DISPATCHED reviewer ran"          'every dispatched reviewer ran'
sf_tool_clause "check the startup lines for a benched seat" 'startup lines for a benched seat'
sf_tool_clause "resolve UNDISPUTED qualifying Should-fix" 'undisputed qualifying should-fix'

# Same idea, for `cmd_plan_review`'s exit-0 message: it used to unconditionally say "revise the plan",
# which itself pushed unbounded revision loops. Matched against that ECHO LINE ONLY (not the whole
# file, for the same greenwash reason as sf_tool_clause above), so a revert of the operator-facing
# string turns the suite red even though the surrounding comments still describe the rule correctly.
sf_plan_tool_clause() {  # sf_plan_tool_clause <label> <extended-regex>
  local label="$1" re="$2"
  grep -E 'Plan review done' "$CLI" | grep -Eqi -- "$re" \
    && { echo "  ok   [-] bin/ship-feature's plan-review exit-0 message states: $label"; PASS=$((PASS+1)); } \
    || { echo "  FAIL adapter consistency: '$label' missing from bin/ship-feature's plan-review exit-0 message"; FAIL=$((FAIL+1)); }
}
# Every adapter must name the durable plans directory, and none may still suggest a
# bare `plan.md`. The adapters are what an agent actually loads — WORKFLOW.md is
# canonical, but nobody reads it first — so a rule that lives only there reaches
# nobody, and the plan goes back to the scratchpad that a reboot wipes.
for adapter in adapters/codex/AGENTS.snippet.md adapters/cursor/ship-feature.md adapters/skill/SKILL.md; do
  if grep -qF '~/.config/ship-feature/plans/' "$HERE/../$adapter"; then
    echo "  ok   [-] $adapter names the durable plans directory"; PASS=$((PASS+1))
  else
    echo "  FAIL $adapter does not name ~/.config/ship-feature/plans/"; FAIL=$((FAIL+1))
  fi
  # Say so, because no CLI path can run before it: the agent writes the plan
  # first, and an install updated by `git pull` alone never re-runs install.sh.
  if grep -qF 'mkdir -p' "$HERE/../$adapter"; then
    echo "  ok   [-] $adapter tells the agent to create the directory"; PASS=$((PASS+1))
  else
    echo "  FAIL $adapter does not say to create the plans directory"; FAIL=$((FAIL+1))
  fi
  if grep -qE '<plan\.md>|`plan\.md`|\./plan\.md' "$HERE/../$adapter"; then
    echo "  FAIL $adapter still suggests a bare plan.md"; FAIL=$((FAIL+1))
  else
    echo "  ok   [-] $adapter no longer suggests a bare plan.md"; PASS=$((PASS+1))
  fi
done

sf_plan_tool_clause "clean round goes straight to Gate 1"     'straight to gate 1'
sf_plan_tool_clause "cap is 2 rounds"                         'cap.{0,10}(2|two) rounds'
sf_plan_tool_clause "do not run a round 3 on your own"        'do not run a round 3'
sf_plan_tool_clause "write a disagreement summary instead"    'disagreement summary'

# The exit-3 (NOT clean) message gets the same treatment: it used to say "Fix and re-run" with no
# mention of the two-consecutive-failure drop rule, which itself invites retrying the same reviewer
# forever.
sf_plan_tool_clause_notclean() {  # same pattern as sf_plan_tool_clause, but for the "NOT clean" line
  local label="$1" re="$2"
  grep -E 'Plan review NOT clean' "$CLI" | grep -Eqi -- "$re" \
    && { echo "  ok   [-] bin/ship-feature's plan-review exit-3 message states: $label"; PASS=$((PASS+1)); } \
    || { echo "  FAIL adapter consistency: '$label' missing from bin/ship-feature's plan-review exit-3 message"; FAIL=$((FAIL+1)); }
}
sf_plan_tool_clause_notclean "drop the reviewer on a second consecutive attempt" 'second consecutive attempt.{0,60}drop'
sf_plan_tool_clause_notclean "tell the human about the reduced panel"           'reduced panel'

echo "-------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
# FAIL is checked FIRST: when a case fails, PASS is naturally short of the total, and reporting that
# as "a test was silently dropped" sends the reader after the wrong problem.
[ "$FAIL" = 0 ] || exit 1
# Hard-coded, deliberately NOT overridable from the environment. An ambient SF_EXPECTED_PASS would
# let the very thing this suite now guarantees — that its result does not depend on the environment
# it is run in — be switched off from outside, and would hide a removed test.
EXPECTED=290
if [ "$PASS" != "$EXPECTED" ]; then
  echo "  ! expected PASS=$EXPECTED, got $PASS — a test was added or silently dropped" >&2
  exit 1
fi
