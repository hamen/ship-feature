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
unset SHIP_FEATURE_WORKTREE_ROOT SHIP_FEATURE_EXCLUDE_MARKER SHIP_FEATURE_DENYLIST SHIP_FEATURE_REVIEWERS SHIP_FEATURE_PLAN_REVIEWERS SHIP_FEATURE_GEMINI_MODEL

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
# antigravity/gemini reviewer (the `gemini` CLI). A richer stub than make_reviewer: it also reports
# its CWD and whether the isolated, locked-down `.gemini/settings.json` (write tools excluded + hooks
# off) is present in that CWD — so the read-only isolation contract can be asserted, not just argv.
cat > "$PBIN/gemini" <<'GEMINISTUB'
#!/usr/bin/env bash
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
echo "GEMINI-ISO cwd=$PWD locked=$locked homeiso=$homeiso credsafe=$credsafe sysiso=$sysiso xdg=${XDG_CONFIG_HOME-UNSET} envstop=$envstop"
echo "REVIEW-gemini argv=[$*]"
exit 0
GEMINISTUB
chmod +x "$PBIN/gemini"

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

# opencode is RELAY-ONLY: skipped with a warning, the rest of the panel still runs (0).
# (agy is NO LONGER relay-only — it now aliases the read-only antigravity/gemini reviewer.)
out=$(printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers opencode,codex 2>&1); rc=$?
check "plan-review skips relay-only agents, runs the rest" "$rc" 0
printf '%s' "$out" | grep -qi "relay-only" && { echo "  ok   [-] plan-review warns that opencode is relay-only"; PASS=$((PASS+1)); } || { echo "  FAIL plan-review did not warn about relay-only agents"; FAIL=$((FAIL+1)); }

# a panel of ONLY relay-only agents → nobody supported ran → clear error (1)
( printf 'plan\n' | PATH="$PBIN:$PATH" bash "$CLI" plan-review --reviewers opencode >/dev/null 2>&1 ); check "plan-review with only relay-only agents → error (1)" $? 1

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
