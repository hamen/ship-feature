<!--
  This block is inserted into ~/.codex/AGENTS.md by ship-feature's install.sh, between the markers
  below. Edit it in the repo (adapters/codex/AGENTS.snippet.md), not in AGENTS.md — re-running install.sh
  replaces the marked block idempotently.
-->
# >>> ship-feature >>>
## ship-feature workflow (default for repository changes)

When the request is to **implement / build / add / fix / ship a change to a repository** (not a read-only
task like diagnosis, review, or a question), follow the ship-feature workflow instead of going straight to
code. The canonical process is `~/.config/ship-feature/WORKFLOW.md` — read it and follow it.

Non-negotiable points:
- Plan first; have it reviewed; then **stop for explicit human approval before writing to the source repo**.
- Implement in a **git worktree**, stage explicit paths, open a PR.
- Cross-review with `ship-feature relay --author codex --reviewers claude,codex,cursor,antigravity`
  (explicit list = quorum); keep iterating while any Blocker/Should-fix remains; exit `0` from the relay
  means everyone ran, NOT that the reviews are clean.
- **The human merges** — never self-merge.
# <<< ship-feature <<<
