#!/usr/bin/env bash
# install.sh — wire ship-feature into your agents. Idempotent and re-runnable.
#
# It:
#   - installs WORKFLOW.md to ~/.config/ship-feature/WORKFLOW.md (symlink; --copy for a detached copy),
#   - symlinks bin/ship-feature into ~/.local/bin,
#   - installs the workflow skill to ~/.agents/skills/ship-feature and links it for Claude,
#   - installs the Cursor rule,
#   - inserts a marked block into ~/.codex/AGENTS.md (atomic; backs the file up first),
#   - seeds ~/.config/ship-feature/config from config.example only if absent,
#   - checks ~/.local/bin is on PATH and smoke-tests that everything resolves.
#
# Nothing is overwritten without a timestamped backup. Re-run any time.
set -uo pipefail

COPY_WORKFLOW=0
[ "${1:-}" = "--copy" ] && COPY_WORKFLOW=1

REPO="$(cd "$(dirname "$0")" && pwd)"
CFG="$HOME/.config/ship-feature"
BIN="$HOME/.local/bin"
AGENTS_SKILLS="$HOME/.agents/skills"
did=0

say()  { echo "  $*"; did=$((did + 1)); }
link() { ln -sfn "$1" "$2"; say "linked  $2 -> $1"; }
backup(){ [ -e "$1" ] && cp -p "$1" "$1.bak-ship-feature-$(date +%s)" && echo "  backed up $1"; }

mkdir -p "$CFG" "$BIN" "$AGENTS_SKILLS/ship-feature" "$HOME/.claude/skills" "$HOME/.cursor/rules"

# 1) WORKFLOW.md — the path every adapter references.
if [ "$COPY_WORKFLOW" = 1 ]; then
  cp "$REPO/WORKFLOW.md" "$CFG/WORKFLOW.md"; say "copied  $CFG/WORKFLOW.md"
else
  link "$REPO/WORKFLOW.md" "$CFG/WORKFLOW.md"
fi

# 2) CLI on PATH.
link "$REPO/bin/ship-feature" "$BIN/ship-feature"

# 3) The one workflow skill (cross-tool), + Claude's link to it.
link "$REPO/adapters/skill/SKILL.md" "$AGENTS_SKILLS/ship-feature/SKILL.md"
link "$AGENTS_SKILLS/ship-feature" "$HOME/.claude/skills/ship-feature"

# 4) Cursor rule.
link "$REPO/adapters/cursor/ship-feature.md" "$HOME/.cursor/rules/ship-feature.md"

# 5) Codex: insert the marked block into ~/.codex/AGENTS.md (create if missing), idempotently.
AGENTS="$HOME/.codex/AGENTS.md"; mkdir -p "$HOME/.codex"
BLOCK="$(awk '/^# >>> ship-feature >>>/{f=1} f{print} /^# <<< ship-feature <<</{f=0}' "$REPO/adapters/codex/AGENTS.snippet.md")"
if [ -z "$BLOCK" ]; then
  echo "  ! could not read Codex block from snippet — skipping AGENTS.md" >&2
else
  tmp="$(mktemp)"
  if [ -f "$AGENTS" ] && grep -qF '# >>> ship-feature >>>' "$AGENTS"; then
    backup "$AGENTS"
    awk -v block="$BLOCK" '
      /^# >>> ship-feature >>>/ {print block; skip=1; next}
      /^# <<< ship-feature <<</ {skip=0; next}
      skip {next}
      {print}
    ' "$AGENTS" > "$tmp"
    mv "$tmp" "$AGENTS"; say "updated $AGENTS (ship-feature block)"
  else
    [ -f "$AGENTS" ] && backup "$AGENTS"
    { [ -f "$AGENTS" ] && cat "$AGENTS"; printf '\n%s\n' "$BLOCK"; } > "$tmp"
    mv "$tmp" "$AGENTS"; say "appended ship-feature block to $AGENTS"
  fi
fi

# 6) config seed (never clobber a real config).
if [ ! -f "$CFG/config" ]; then cp "$REPO/config.example" "$CFG/config"; say "seeded  $CFG/config (from config.example)"; else echo "  = kept existing $CFG/config"; fi

# 7) PATH check + smoke test.
case ":$PATH:" in *":$BIN:"*) : ;; *) echo "  ! $BIN is not on your PATH — add it so 'ship-feature' is found." >&2 ;; esac
echo "--- smoke test ---"
"$BIN/ship-feature" help >/dev/null 2>&1 && echo "  ✓ ship-feature runs" || echo "  ! ship-feature failed to run" >&2
[ -f "$CFG/WORKFLOW.md" ] && echo "  ✓ WORKFLOW.md resolves at $CFG/WORKFLOW.md" || echo "  ! WORKFLOW.md missing" >&2
[ -f "$HOME/.claude/skills/ship-feature/SKILL.md" ] && echo "  ✓ Claude skill resolves" || echo "  ! Claude skill missing" >&2
[ -f "$HOME/.cursor/rules/ship-feature.md" ] && echo "  ✓ Cursor rule resolves" || echo "  ! Cursor rule missing" >&2
grep -qF '# >>> ship-feature >>>' "$AGENTS" 2>/dev/null && echo "  ✓ Codex AGENTS.md block present" || echo "  ! Codex block missing" >&2

echo "✔ install complete ($did change(s)). Add a line to your global CLAUDE.md pointing at the ship-feature skill for any feature/fix."
