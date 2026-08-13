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
# CURSOR_REVIEW_MODEL, KIMI3_REVIEW_MODEL and GROK45HIGH_REVIEW_MODEL are not SHIP_FEATURE_* keys
# (env-only, shared with pr-review-relay in CURSOR_REVIEW_MODEL's case), so they would not be
# caught by the namespace above — but they are knobs people really do export once
# ship-feature/pr-review-relay are in use, and an exported value would quietly satisfy the
# default-pin assertions below. Clear all three here so the suite stays hermetic no matter who
# runs it.
unset SHIP_FEATURE_WORKTREE_ROOT SHIP_FEATURE_EXCLUDE_MARKER SHIP_FEATURE_DENYLIST SHIP_FEATURE_REVIEWERS SHIP_FEATURE_PLAN_REVIEWERS CURSOR_REVIEW_MODEL KIMI3_REVIEW_MODEL GROK45HIGH_REVIEW_MODEL

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
echo "REVIEW-$1 argv=[\$*] OPENCODE_CONFIG_CONTENT=[\${OPENCODE_CONFIG_CONTENT:-}] OPENCODE_CONFIG=[\${OPENCODE_CONFIG:-}] CWD=[\${PWD}]"
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
# unset (empty), it runs --pure and in an isolated cwd OUTSIDE the checkout, and never the
# all-allow build agent. The `plan` agent alone denies edit but leaves bash allowed — not
# enough — so the CONTENT denial is what makes it real. Assert all of it on kimi3's line.
km=$(printf '%s' "$out" | grep 'REVIEW-kimi3')
printf '%s' "$km" | grep -q -- "--agent plan" && printf '%s' "$km" | grep -q -- "kimi-k3" && { echo "  ok   [-] kimi3 runs opencode plan agent (kimi-k3)"; PASS=$((PASS+1)); } || { echo "  FAIL kimi3 not on opencode plan agent"; FAIL=$((FAIL+1)); }
printf '%s' "$km" | grep -q -- "--pure" && { echo "  ok   [-] kimi3 runs --pure (no checkout plugins)"; PASS=$((PASS+1)); } || { echo "  FAIL kimi3 missing --pure"; FAIL=$((FAIL+1)); }
printf '%s' "$km" | grep -q 'OPENCODE_CONFIG_CONTENT=\[.*"edit":"deny".*"bash":"deny".*\]' && { echo "  ok   [-] kimi3 read-only via OPENCODE_CONFIG_CONTENT (edit+bash denied)"; PASS=$((PASS+1)); } || { echo "  FAIL kimi3 not hard read-only (OPENCODE_CONFIG_CONTENT must deny edit AND bash)"; FAIL=$((FAIL+1)); }
printf '%s' "$km" | grep -q 'OPENCODE_CONFIG=\[\]' && { echo "  ok   [-] kimi3 unsets inherited OPENCODE_CONFIG"; PASS=$((PASS+1)); } || { echo "  FAIL kimi3 left OPENCODE_CONFIG set (could weaken perms)"; FAIL=$((FAIL+1)); }
kcwd=$(printf '%s' "$km" | sed -n 's/.*CWD=\[\([^]]*\)\].*/\1/p'); case "$kcwd" in "$WORK"*|"$PWD"*) echo "  FAIL kimi3 cwd is inside the checkout ($kcwd) — repo opencode.json could load"; FAIL=$((FAIL+1));; "") echo "  FAIL kimi3 cwd not captured"; FAIL=$((FAIL+1));; *) echo "  ok   [-] kimi3 runs in an isolated cwd outside the checkout"; PASS=$((PASS+1));; esac
printf '%s' "$km" | grep -q -- "--agent build"         && { echo "  FAIL kimi3 uses the all-allow build agent"; FAIL=$((FAIL+1)); } || { echo "  ok   [-] kimi3 never uses the all-allow build agent"; PASS=$((PASS+1)); }
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

# agy and opencode are RELAY-ONLY: skipped with a warning, the rest of the panel still runs (0)
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers agy,opencode,grok,codex 2>&1); rc=$?
check "plan-review skips relay-only agents, runs the rest" "$rc" 0
printf '%s' "$out" | grep -qi "relay-only" && { echo "  ok   [-] plan-review warns that agy/opencode/grok are relay-only"; PASS=$((PASS+1)); } || { echo "  FAIL plan-review did not warn about relay-only agents"; FAIL=$((FAIL+1)); }

# a panel of ONLY relay-only agents → nobody supported ran → clear error (1)
( printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers agy,opencode,grok >/dev/null 2>&1 ); check "plan-review with only relay-only agents → error (1)" $? 1

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
EXPECTED=198
if [ "$PASS" != "$EXPECTED" ]; then
  echo "  ! expected PASS=$EXPECTED, got $PASS — a test was added or silently dropped" >&2
  exit 1
fi
