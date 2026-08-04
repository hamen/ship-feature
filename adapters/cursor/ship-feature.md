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
- Cross-review with `ship-feature relay --author cursor --reviewers <your agents> --context-file <plan.md>`
  (explicit list = the agents you have, e.g. claude,codex,cursor). **Always pass the plan** with
  `--context-file`: a reviewer that cannot see the intent can find bugs but not "this is not what we
  agreed to build". The **plan file is the source** the PR body is generated from — never hand-edit
  either; for later rounds point `--context-file` at a derived copy (plan + dispositions).
- Iterate only for a **Blocker** or a **qualifying** Should-fix — a material problem of correctness,
  safety, deployability, or verification. Round 1 is the full quorum; rounds 2+ are **narrow** (only
  reviewers with a stake in an open finding, plus any whose finding you downgraded); the **closing**
  round is the full quorum again, on the SHA that will merge. The relay's exit `0` means everyone ran,
  not that the reviews are clean — and a **benched** (out-of-quota) reviewer still exits `0`, so a
  benched seat in an initial or closing round is the human's call before the round.
- **Post dispositions before re-running** — the relay deletes each reviewer's previous comment, so an
  unposted finding and its classification are lost. Do **not** put the relay's marker text
  (`<Name> review (automated cross-review)`) in that comment, or it gets deleted too.
- Disputed classifications do not block the stop; they go to **Gate 2** with both positions.
  Still two gates, never three.
- **The human merges** — never self-merge.
