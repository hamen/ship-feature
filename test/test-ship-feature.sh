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
if ! GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=sf.probe GIT_CONFIG_VALUE_0=1 \
     git config --get sf.probe >/dev/null 2>&1; then
  echo "ship-feature tests: need git 2.31+ (GIT_CONFIG_COUNT) to isolate the fixtures; found $(git --version)" >&2
  exit 2
fi

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
  export GIT_CONFIG_KEY_3=core.excludesFile   GIT_CONFIG_VALUE_3=/dev/null
  export GIT_CONFIG_KEY_4=core.attributesFile GIT_CONFIG_VALUE_4=/dev/null
  export GIT_CONFIG_KEY_5=core.fsmonitor      GIT_CONFIG_VALUE_5=false
  export GIT_CONFIG_KEY_6=color.ui            GIT_CONFIG_VALUE_6=false
  # A path that does not exist: hooks are then simply never found. An ambient core.hooksPath can
  # otherwise fail or mutate every fixture commit — measured, a planted pre-commit made `git commit`
  # exit 1 until this was set.
  export GIT_CONFIG_KEY_2=core.hooksPath   GIT_CONFIG_VALUE_2="${WORK:-/nonexistent}/no-such-hooks"
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
# CURSOR_REVIEW_MODEL is not a SHIP_FEATURE_* key (it is shared with pr-review-relay, env-only), so
# it would not be caught by the namespace above — but it is a knob people really do export once
# pr-review-relay is in use, and an exported value would quietly satisfy the default-pin assertions
# below. Clear it here so the suite stays hermetic no matter who runs it.
unset SHIP_FEATURE_WORKTREE_ROOT SHIP_FEATURE_EXCLUDE_MARKER SHIP_FEATURE_DENYLIST SHIP_FEATURE_REVIEWERS SHIP_FEATURE_PLAN_REVIEWERS CURSOR_REVIEW_MODEL

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
( cd "$HERE/.." && HOME="$FAKEHOME" bash install.sh >/dev/null 2>&1 )
# grep -c prints "0" and exits 1 on no match; capture stdout, don't append via `|| echo 0`.
n=$(grep -cF '# >>> ship-feature >>>' "$FAKEHOME/.codex/AGENTS.md" 2>/dev/null); [ -n "$n" ] || n=0
check "install.sh is idempotent (exactly one Codex block)" "$n" 1

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


# grok45high: Grok 4.5 high effort, prompt-file (not stdin), read-only ALLOWLIST, runs in the
# checkout so it can verify the plan against the code (parity with claude/codex/cursor).
out=$(printf 'UNIQUE_PLAN_TOKEN_42\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_FORCE_SANDBOX_PROBE=ok bash "$CLI" plan-review --reviewers grok45high 2>/dev/null); rc=$?
check "plan-review grok45high clean exit" "$rc" 0
printf '%s' "$out" | grep -q -- '-m grok-4.5' && printf '%s' "$out" | grep -q -- '--reasoning-effort high' \
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
dcwd=$(printf '%s' "$dg" | sed -n 's/.*CWD=\[\([^]]*\)\].*/\1/p')
case "$dcwd" in
  *iso-grok45high*) echo "  ok   [-] degraded grok45high runs outside the checkout"; PASS=$((PASS+1));;
  *) echo "  FAIL degraded grok45high ran in $dcwd"; FAIL=$((FAIL+1));;
esac

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

# 0. The suite-level call at the top is in force. Every case below calls sf_isolate_git itself, so
#    deleting the ONE call that protects the real fixtures would leave all of them green while the
#    fixture setup ran under whatever a hook handed us. This is the only check that watches it.
[ "${GIT_CONFIG_COUNT:-0}" = 7 ] && [ "$(git config --get commit.gpgsign 2>/dev/null)" = "false" ] \
  && { echo "  ok   [-] the suite-level git isolation is actually in force"; PASS=$((PASS+1)); } \
  || { echo "  FAIL the top-level sf_isolate_git call is missing or ineffective"; FAIL=$((FAIL+1)); }

# 0b. init.templateDir="" was in the first draft of sf_isolate_git and broke `>> .git/info/exclude`,
#     which is how the worktree marker gets ignored. It was removed with only a comment as memory —
#     this is the assertion that fires if someone "helps" the function again.
( T="$WORK/tpl"; rm -rf "$T"; mkdir -p "$T"; cd "$T" || exit 1
  sf_isolate_git; git init -q . 2>/dev/null
  echo x >> .git/info/exclude 2>/dev/null || exit 3 ) >/dev/null 2>&1
[ $? = 0 ] && { echo "  ok   [-] git init still produces .git/info (no empty templateDir)"; PASS=$((PASS+1)); } \
           || { echo "  FAIL .git/info missing — init.templateDir was probably reintroduced"; FAIL=$((FAIL+1)); }

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

echo "-------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
# 104 before this change, plus the 8 isolation checks above. Update this deliberately when adding
# a test — that edit is the review surface for "did a test quietly disappear?".
EXPECTED="${SF_EXPECTED_PASS:-112}"
if [ "$PASS" != "$EXPECTED" ]; then
  echo "  ! expected PASS=$EXPECTED, got $PASS — a test was added or silently dropped" >&2
  exit 1
fi
[ "$FAIL" = 0 ]
