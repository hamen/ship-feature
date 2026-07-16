#!/usr/bin/env bash
# scan-generic.sh — deny-list-free leak scan for the categories a secret scanner (e.g. gitleaks) does
# NOT cover by default: real email addresses and absolute home paths. Runnable in CI on fork PRs (needs
# no private list). Exits 1 (and prints the hits) if any are found.
#
# Usage:
#   scripts/scan-generic.sh [file ...]      # scan the given files
#   scripts/scan-generic.sh                 # scan all git-tracked files (minus fixtures + this scanner)
set -uo pipefail

# Real emails, but not RFC-2606 reserved example domains or noreply addresses (those are placeholders).
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+'
EMAIL_ALLOW='@example\.(com|org|net|test)\b|@example\b|noreply@|@localhost'
# Absolute home paths (a leaked developer machine path). No trailing slash required, so a bare
# "/home/user" at end-of-line is still caught. Covers /home, /Users, and /root.
HOME_RE='(/home/|/Users/|/root/)[A-Za-z0-9._-]+'

hits=0
scan_one() {
  local f="$1" line
  [ -f "$f" ] || return 0
  # Extract each email OCCURRENCE (-o), then filter per-address — so a real address on the same line as
  # an allowed placeholder is still caught (line-level filtering would drop the whole line).
  while IFS= read -r line; do
    echo "  ✖ $f:email: $line" >&2; hits=$((hits + 1))
  done < <(grep -oE "$EMAIL_RE" "$f" 2>/dev/null | grep -vE "$EMAIL_ALLOW")
  while IFS= read -r line; do
    echo "  ✖ $f:home-path: $line" >&2; hits=$((hits + 1))
  done < <(grep -nE "$HOME_RE" "$f" 2>/dev/null)
}

if [ "$#" -gt 0 ]; then
  for f in "$@"; do scan_one "$f"; done
else
  # NUL-delimited so paths with spaces/newlines are handled correctly. Fail CLOSED if the tracked-file
  # list can't be enumerated (else an empty set would produce a bogus "clean").
  tmpf=$(mktemp) || { echo "mktemp failed" >&2; exit 2; }
  if ! git ls-files -z > "$tmpf" 2>/dev/null; then rm -f "$tmpf"; echo "✖ git ls-files failed — cannot enumerate tracked files." >&2; exit 1; fi
  while IFS= read -r -d '' f; do
    case "$f" in test/fixtures/*|scripts/scan-generic.sh) continue;; esac
    scan_one "$f"
  done < "$tmpf"
  rm -f "$tmpf"
fi

if [ "$hits" -gt 0 ]; then
  echo "✖ scan-generic: $hits potential leak(s) (real email / home path). Review above." >&2
  exit 1
fi
echo "✔ scan-generic: no real emails or home paths in scanned files."
