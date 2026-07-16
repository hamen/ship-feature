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
# Scope/perf: this is a thorough pre-publication scan meant to run occasionally on a repo you are about
# to publish. The history-content pass greps every commit tree, so cost scales with history size; on a
# very large history prefer a dedicated tool (e.g. gitleaks/trufflehog) for the bulk pass and use this
# for the deny-list terms.
#
# Usage:
#   scripts/scan-personal-data.sh [path/to/denylist.txt]
#   SHIP_FEATURE_DENYLIST=... scripts/scan-personal-data.sh
set -uo pipefail

DENYLIST="${1:-${SHIP_FEATURE_DENYLIST:-}}"
# Fall back to the config file's SHIP_FEATURE_DENYLIST (read with sed, never `source`d).
if [ -z "$DENYLIST" ]; then
  _cfg="${SHIP_FEATURE_CONFIG:-$HOME/.config/ship-feature/config}"
  if [ -f "$_cfg" ]; then
    DENYLIST=$(sed -n 's/^[[:space:]]*SHIP_FEATURE_DENYLIST[[:space:]]*=[[:space:]]*//p' "$_cfg" | tail -n1)
    DENYLIST="${DENYLIST%%[[:space:]]#*}"                       # strip an inline "# comment"
    DENYLIST="${DENYLIST%"${DENYLIST##*[![:space:]]}"}"          # strip trailing whitespace
  fi
fi
[ -n "$DENYLIST" ] || { echo "usage: $0 <denylist-file>  (or set SHIP_FEATURE_DENYLIST / config)" >&2; exit 2; }
[ -f "$DENYLIST" ] || { echo "deny-list file not found: $DENYLIST" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not inside a git repo" >&2; exit 2; }

# Collect the corpora once, into temp FILES. Grepping files (not `printf ... | grep`) avoids a pipefail
# + SIGPIPE interaction where grep exits early on a match, printf dies with SIGPIPE, and the pipeline is
# reported as failure — which would mask a real hit (a false "clean").
TMPD=$(mktemp -d) || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMPD"' EXIT
# Fail CLOSED on git errors: a corrupt repo that makes these commands error must NOT be reported clean.
gitfail() { echo "✖ git operation failed ($1) — cannot scan reliably; failing closed." >&2; exit 2; }
# Integrity: walking all objects errors out on a missing/corrupt blob, so a repo that would make the
# per-term `git grep` silently error (and look "clean") fails closed here instead.
git rev-list --all --objects >/dev/null 2>&1 || gitfail "object enumeration (repo may be corrupt / missing blobs)"
git rev-list --all > "$TMPD/commits" 2>/dev/null || gitfail "rev-list"
git log --all --format='%H%n%an%n%ae%n%cn%n%ce%n%s%n%b%n%N' > "$TMPD/meta" 2>/dev/null || gitfail "log meta"
git log --all --name-only --format='' 2>/dev/null | sort -u > "$TMPD/names" || gitfail "log names"
git for-each-ref --format='%(refname)' > "$TMPD/refs" 2>/dev/null || gitfail "for-each-ref"

hits=0
while IFS= read -r term || [ -n "$term" ]; do
  # skip blanks and comments
  case "$term" in ''|\#*) continue;; esac
  term="${term#"${term%%[![:space:]]*}"}"; term="${term%"${term##*[![:space:]]}"}"  # trim
  [ -n "$term" ] || continue

  found=""
  # 1) file contents across ALL history (blobs in every commit's tree). Batch commits via xargs reading
  #    stdin (portable — GNU `xargs -a` is not on macOS/BSD) so a large history can't blow past ARG_MAX;
  #    check for a matching path rather than trusting exit codes.
  # No `-I`: a deny-listed string inside a binary blob (or a symlink-target blob) must still be caught —
  # `-I` would skip those and report clean.
  if [ -s "$TMPD/commits" ] && [ -n "$(xargs git grep -F -l -e "$term" < "$TMPD/commits" 2>/dev/null | head -n1)" ]; then found="history contents"; fi
  # 2) commit metadata (messages, author/committer name+email)  3) filenames  4) ref names
  [ -z "$found" ] && grep -F -q -e "$term" "$TMPD/meta"  && found="commit metadata"
  [ -z "$found" ] && grep -F -q -e "$term" "$TMPD/names" && found="filename"
  [ -z "$found" ] && grep -F -q -e "$term" "$TMPD/refs"  && found="ref name"

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
