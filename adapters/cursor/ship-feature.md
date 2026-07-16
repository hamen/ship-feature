---
description: Gated workflow for shipping any repository change (plan → review → implement → cross-review → merge → verify). Apply when the user asks to implement/build/add/fix/ship a change to a repo.
alwaysApply: false
---

# ship-feature workflow

When asked to **implement / build / add / fix / ship a change to this repository** (not a read-only task
like diagnosis, review, or a question), follow the ship-feature workflow rather than editing straight
away. The canonical process is `~/.config/ship-feature/WORKFLOW.md` — read it and follow it.

Non-negotiable points:
- Plan first; have the plan reviewed; then **stop for explicit human approval before writing to the
  source repo**.
- Implement in a **git worktree**, stage explicit paths, open a PR.
- Cross-review with `ship-feature relay --author cursor --reviewers <your agents>` (explicit list = the
  agents you have, e.g. claude,codex,cursor); keep iterating while any Blocker/Should-fix remains. The
  relay's exit `0` means everyone ran, not that the reviews are clean — read the verdicts.
- **The human merges** — never self-merge.
