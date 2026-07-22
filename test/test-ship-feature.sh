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
# Isolate from the user's real config/env so the suite is deterministic outside CI.
export SHIP_FEATURE_CONFIG=/dev/null
unset SHIP_FEATURE_WORKTREE_ROOT SHIP_FEATURE_EXCLUDE_MARKER SHIP_FEATURE_DENYLIST SHIP_FEATURE_REVIEWERS

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
make_reviewer() { printf '#!/usr/bin/env bash\necho "REVIEW-%s argv=[$*]"\nexit %s\n' "$1" "${2:-0}" > "$PBIN/$3"; chmod +x "$PBIN/$3"; }
make_reviewer claude 0 claude
make_reviewer codex  0 codex
make_reviewer qwen   0 qwen
make_reviewer cursor 0 cursor-agent

# clean run with an explicit panel → exit 0, both reviews on stdout
out=$(printf 'Step 1: X\nStep 2: Y\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers codex,qwen 2>/dev/null); rc=$?
check "plan-review clean run exits 0" "$rc" 0
printf '%s' "$out" | grep -q "REVIEW-codex" && printf '%s' "$out" | grep -q "REVIEW-qwen" \
  && { echo "  ok   [-] plan-review prints each reviewer's output"; PASS=$((PASS+1)); } \
  || { echo "  FAIL plan-review dropped a reviewer's output"; FAIL=$((FAIL+1)); }

# read-only argv contract: EVERY supported reviewer must carry its read-only flag, so the
# "nothing is written" guarantee is real. A dropped flag here is a security regression.
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude,codex,cursor,qwen 2>/dev/null)
# claude's own line must carry BOTH --permission-mode plan AND --safe-mode (safe-mode
# stops checkout hooks/plugins/MCP from loading). Grep claude's line specifically so
# qwen's --safe-mode can't satisfy this by accident.
cl=$(printf '%s' "$out" | grep 'REVIEW-claude')
printf '%s' "$cl" | grep -q -- "--permission-mode plan" && printf '%s' "$cl" | grep -q -- "--safe-mode" && { echo "  ok   [-] claude runs read-only (--permission-mode plan --safe-mode)"; PASS=$((PASS+1)); } || { echo "  FAIL claude not fully read-only (plan + safe-mode) in plan-review"; FAIL=$((FAIL+1)); }
printf '%s' "$out" | grep -q -- "--sandbox read-only"          && { echo "  ok   [-] codex runs read-only (--sandbox read-only)"; PASS=$((PASS+1)); } || { echo "  FAIL codex not read-only in plan-review"; FAIL=$((FAIL+1)); }
printf '%s' "$out" | grep -q -- "--mode=ask"                   && { echo "  ok   [-] cursor runs in ask (Q&A) mode"; PASS=$((PASS+1)); } || { echo "  FAIL cursor not in ask mode"; FAIL=$((FAIL+1)); }
# qwen must use --approval-mode PLAN (read-only: denies edit/write/shell), never yolo
# (which auto-approves them). yolo + a plan review is the exact hole round 2 caught.
printf '%s' "$out" | grep -q -- "--safe-mode --approval-mode plan" && { echo "  ok   [-] qwen runs read-only (--safe-mode --approval-mode plan)"; PASS=$((PASS+1)); } || { echo "  FAIL qwen not in read-only plan mode"; FAIL=$((FAIL+1)); }
printf '%s' "$out" | grep -q -- "--approval-mode yolo"         && { echo "  FAIL qwen still uses the auto-approving yolo mode"; FAIL=$((FAIL+1)); } || { echo "  ok   [-] qwen never uses the auto-approving yolo mode"; PASS=$((PASS+1)); }

# default panel comes from SHIP_FEATURE_REVIEWERS when --reviewers is omitted
out=$(printf 'a plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_REVIEWERS=claude,cursor bash "$CLI" plan-review 2>/dev/null); rc=$?
check "plan-review uses SHIP_FEATURE_REVIEWERS by default" "$rc" 0
printf '%s' "$out" | grep -q "REVIEW-claude" && printf '%s' "$out" | grep -q "REVIEW-cursor" \
  && { echo "  ok   [-] plan-review ran the configured default panel"; PASS=$((PASS+1)); } \
  || { echo "  FAIL plan-review did not run the configured panel"; FAIL=$((FAIL+1)); }

# SHIP_FEATURE_PLAN_REVIEWERS overrides the shared quorum for plan-review (a smaller panel
# than the PR cross-review). When both are set, the plan-specific one wins.
out=$(printf 'a plan\n' | PATH="$PBIN:$PATH" SHIP_FEATURE_REVIEWERS=claude,codex,cursor,qwen SHIP_FEATURE_PLAN_REVIEWERS=claude,codex bash "$CLI" plan-review 2>/dev/null); rc=$?
check "plan-review prefers SHIP_FEATURE_PLAN_REVIEWERS" "$rc" 0
if printf '%s' "$out" | grep -q "REVIEW-claude" && printf '%s' "$out" | grep -q "REVIEW-codex" && ! printf '%s' "$out" | grep -q "REVIEW-cursor"; then
  echo "  ok   [-] the plan-specific panel wins over the quorum"; PASS=$((PASS+1))
else echo "  FAIL plan-review did not prefer SHIP_FEATURE_PLAN_REVIEWERS"; FAIL=$((FAIL+1)); fi

# a reviewer that returns an EMPTY review → not clean (exit 3)
printf '#!/usr/bin/env bash\nexit 0\n' > "$PBIN/codex"; chmod +x "$PBIN/codex"
( printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers codex,qwen >/dev/null 2>&1 ); check "plan-review empty review → not clean (3)" $? 3
make_reviewer codex 0 codex   # restore

# a NON-ZERO reviewer exit → not clean (exit 3)
make_reviewer codex 1 codex
( printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers codex >/dev/null 2>&1 ); check "plan-review non-zero reviewer → not clean (3)" $? 3
make_reviewer codex 0 codex   # restore

# a supported reviewer from the panel whose CLI is missing → fail (3): the panel is the
# quorum, so it never quietly passes on a thinned set.
( printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers codex,doesnotexist >/dev/null 2>&1 ); check "plan-review missing panel reviewer → fail (3)" $? 3

# agy and opencode are RELAY-ONLY: skipped with a warning, the rest of the panel still runs (0)
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers agy,opencode,codex 2>&1); rc=$?
check "plan-review skips relay-only agents, runs the rest" "$rc" 0
printf '%s' "$out" | grep -qi "relay-only" && { echo "  ok   [-] plan-review warns that agy/opencode are relay-only"; PASS=$((PASS+1)); } || { echo "  FAIL plan-review did not warn about relay-only agents"; FAIL=$((FAIL+1)); }

# a panel of ONLY relay-only agents → nobody supported ran → clear error (1)
( printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers agy,opencode >/dev/null 2>&1 ); check "plan-review with only relay-only agents → error (1)" $? 1

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
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude,codex,qwen --parallel 2>/dev/null); rc=$?
check "plan-review --parallel clean run exits 0" "$rc" 0
n=$(printf '%s' "$out" | grep -c "REVIEW-"); check "plan-review --parallel ran all three reviewers" "$n" 3

# --parallel is still fail-closed: one empty reviewer fails the whole round (3)
printf '#!/usr/bin/env bash\nexit 0\n' > "$PBIN/codex"; chmod +x "$PBIN/codex"
( printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers claude,codex,qwen --parallel >/dev/null 2>&1 ); check "plan-review --parallel stays fail-closed (3)" $? 3
make_reviewer codex 0 codex   # restore

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

echo "-------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
