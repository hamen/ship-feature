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

echo "-------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
