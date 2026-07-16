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
# A real (non-symlink) file it would replace is backed up first; managed symlinks are replaced in place.
# Failed steps are counted and make the installer exit non-zero. Re-run any time.
set -uo pipefail

COPY_WORKFLOW=0
[ "${1:-}" = "--copy" ] && COPY_WORKFLOW=1

REPO="$(cd "$(dirname "$0")" && pwd)"
CFG="$HOME/.config/ship-feature"
BIN="$HOME/.local/bin"
AGENTS_SKILLS="$HOME/.agents/skills"
did=0; fails=0

say()  { echo "  $*"; did=$((did + 1)); }
backup(){ [ -e "$1" ] && [ ! -L "$1" ] && cp -pR "$1" "$1.bak-ship-feature-$(date +%s)" && echo "  backed up $1"; }
link() {
  local src="$1" dst="$2"
  # A real (non-symlink) file OR directory in the way is backed up and removed first, so we never
  # `cp -p` a directory (fails) or create a link *inside* an existing dir. Our own symlinks are replaced.
  # Only remove the destination AFTER a confirmed-successful backup — never destroy an un-backed-up file.
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    if backup "$dst"; then rm -rf "$dst"; else echo "  ! refusing to replace $dst (backup failed)" >&2; fails=$((fails + 1)); return; fi
  fi
  if ln -sfn "$src" "$dst"; then say "linked  $dst -> $src"; else echo "  ! failed to link $dst" >&2; fails=$((fails + 1)); fi
}

mkdir -p "$CFG" "$BIN" "$AGENTS_SKILLS/ship-feature" "$HOME/.claude/skills" "$HOME/.cursor/rules"

# 1) WORKFLOW.md — the path every adapter references.
if [ "$COPY_WORKFLOW" = 1 ]; then
  wf_ok=1
  # Back up a real file first (abort the copy if the backup fails — never overwrite un-backed-up data).
  if [ -e "$CFG/WORKFLOW.md" ] && [ ! -L "$CFG/WORKFLOW.md" ]; then
    backup "$CFG/WORKFLOW.md" || { echo "  ! refusing to replace $CFG/WORKFLOW.md (backup failed)" >&2; fails=$((fails + 1)); wf_ok=0; }
  fi
  if [ "$wf_ok" = 1 ]; then
    rm -f "$CFG/WORKFLOW.md"   # drop an existing symlink so `cp` writes a real file, not THROUGH the link
    if cp "$REPO/WORKFLOW.md" "$CFG/WORKFLOW.md"; then say "copied  $CFG/WORKFLOW.md"; else echo "  ! failed to copy WORKFLOW.md" >&2; fails=$((fails + 1)); fi
  fi
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
  if [ -f "$AGENTS" ] && grep -qF '# >>> ship-feature >>>' "$AGENTS" && ! grep -qF '# <<< ship-feature <<<' "$AGENTS"; then
    # Start marker present but end marker missing: editing would truncate everything after it. Refuse.
    echo "  ! $AGENTS has the ship-feature start marker but no end marker — fix it by hand (refusing to edit)." >&2
    fails=$((fails + 1)); rm -f "$tmp"
  elif [ -f "$AGENTS" ] && grep -qF '# >>> ship-feature >>>' "$AGENTS"; then
    # Abort the edit if the backup fails — never overwrite an un-backed-up AGENTS.md.
    if ! backup "$AGENTS"; then
      echo "  ! refusing to edit $AGENTS (backup failed)" >&2; fails=$((fails + 1)); rm -f "$tmp"
    # Pass the multiline block via the environment, not `awk -v` (BSD/macOS awk mangles/rejects a
    # multiline -v value — which silently produced an EMPTY AGENTS.md). Verify awk succeeded and the
    # result is non-empty BEFORE replacing the file.
    elif SF_BLOCK="$BLOCK" awk '
         /^# >>> ship-feature >>>/ {print ENVIRON["SF_BLOCK"]; skip=1; next}
         /^# <<< ship-feature <<</ {skip=0; next}
         skip {next}
         {print}
       ' "$AGENTS" > "$tmp" && [ -s "$tmp" ]; then
      mv "$tmp" "$AGENTS"; say "updated $AGENTS (ship-feature block)"
    else
      echo "  ! failed to update ship-feature block in $AGENTS (awk)" >&2; fails=$((fails + 1)); rm -f "$tmp"
    fi
  else
    if [ -f "$AGENTS" ] && ! backup "$AGENTS"; then
      echo "  ! refusing to edit $AGENTS (backup failed)" >&2; fails=$((fails + 1)); rm -f "$tmp"
    elif { [ -f "$AGENTS" ] && cat "$AGENTS"; printf '\n%s\n' "$BLOCK"; } > "$tmp" && [ -s "$tmp" ]; then
      mv "$tmp" "$AGENTS"; say "appended ship-feature block to $AGENTS"
    else
      echo "  ! failed to write $AGENTS" >&2; fails=$((fails + 1)); rm -f "$tmp"
    fi
  fi
fi

# 6) config seed (never clobber a real config).
if [ ! -f "$CFG/config" ]; then
  if cp "$REPO/config.example" "$CFG/config"; then say "seeded  $CFG/config (from config.example)"; else echo "  ! failed to seed $CFG/config" >&2; fails=$((fails + 1)); fi
else echo "  = kept existing $CFG/config"; fi

# 7) PATH check + smoke test.
case ":$PATH:" in *":$BIN:"*) : ;; *) echo "  ! $BIN is not on your PATH — add it so 'ship-feature' is found." >&2 ;; esac
echo "--- smoke test ---"
smoke() { if eval "$1"; then echo "  ✓ $2"; else echo "  ! $2 — FAILED" >&2; fails=$((fails + 1)); fi; }
smoke '"$BIN/ship-feature" help >/dev/null 2>&1'            "ship-feature runs"
smoke '[ -f "$CFG/WORKFLOW.md" ]'                           "WORKFLOW.md resolves at $CFG/WORKFLOW.md"
smoke '[ -f "$HOME/.claude/skills/ship-feature/SKILL.md" ]' "Claude skill resolves"
smoke '[ -f "$HOME/.cursor/rules/ship-feature.md" ]'        "Cursor rule resolves"
smoke 'grep -qF "# >>> ship-feature >>>" "$AGENTS" 2>/dev/null' "Codex AGENTS.md block present"

if [ "$fails" -gt 0 ]; then
  echo "✖ install finished with $fails failure(s) — see the ! lines above." >&2
  exit 1
fi
echo "✔ install complete ($did change(s)). Add a line to your global CLAUDE.md pointing at the ship-feature skill for any feature/fix."
