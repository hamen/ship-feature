#!/usr/bin/env bash
# scan-personal-data.sh — local pre-publication guard.
#
# Greps the WHOLE repository — every blob in history, commit messages, author/committer identities,
# filenames, and ref (branch/tag) names — for any literal string in a PRIVATE deny-list. Intended to be
# run before flipping a repo public, and as a pre-push hook. Exits non-zero (and prints the hits) if any
# deny-listed term appears anywhere.
#
# The deny-list is a newline-delimited FILE of literal strings (real project slugs, bundle-id prefixes,
# home paths, internal hostnames). It is READ line by line — NEVER shell-`source`d — so its contents can
# never be executed.
#
# Usage:
#   scripts/scan-personal-data.sh [path/to/denylist.txt]
#   SHIP_FEATURE_DENYLIST=... scripts/scan-personal-data.sh
set -uo pipefail

DENYLIST="${1:-${SHIP_FEATURE_DENYLIST:-}}"
[ -n "$DENYLIST" ] || { echo "usage: $0 <denylist-file>  (or set SHIP_FEATURE_DENYLIST)" >&2; exit 2; }
[ -f "$DENYLIST" ] || { echo "deny-list file not found: $DENYLIST" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not inside a git repo" >&2; exit 2; }

# Collect the corpora to search, once.
ALL_COMMITS=$(git rev-list --all 2>/dev/null)
META=$(git log --all --format='%H%n%an%n%ae%n%cn%n%ce%n%s%n%b' 2>/dev/null)
NAMES=$(git log --all --name-only --format='' 2>/dev/null | sort -u)
REFS=$(git for-each-ref --format='%(refname)' 2>/dev/null)

hits=0
while IFS= read -r term || [ -n "$term" ]; do
  # skip blanks and comments
  case "$term" in ''|\#*) continue;; esac
  term="${term#"${term%%[![:space:]]*}"}"; term="${term%"${term##*[![:space:]]}"}"  # trim
  [ -n "$term" ] || continue

  found=""
  # 1) file contents across ALL history (blobs in every commit's tree)
  if [ -n "$ALL_COMMITS" ] && git grep -F -I -n -e "$term" $ALL_COMMITS -- >/dev/null 2>&1; then found="history contents"; fi
  # 2) commit metadata (messages, author/committer name+email)
  [ -z "$found" ] && printf '%s' "$META"  | grep -F -q -e "$term" && found="commit metadata"
  # 3) filenames anywhere in history
  [ -z "$found" ] && printf '%s' "$NAMES" | grep -F -q -e "$term" && found="filename"
  # 4) branch / tag / ref names
  [ -z "$found" ] && printf '%s' "$REFS"  | grep -F -q -e "$term" && found="ref name"

  if [ -n "$found" ]; then
    echo "✖ deny-listed term present ($found): $term" >&2
    hits=$((hits + 1))
  fi
done < "$DENYLIST"

if [ "$hits" -gt 0 ]; then
  echo "✖ scan-personal-data: $hits deny-listed term(s) found — do NOT publish. Scrub history and re-run." >&2
  echo "  Remember to also check GitHub-side PR titles/bodies/comments (not in local refs)." >&2
  exit 1
fi
echo "✔ scan-personal-data: clean (no deny-listed terms in contents, history, metadata, filenames, or refs)."
