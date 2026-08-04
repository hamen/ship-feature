---
name: ship-feature
description: >
  The standard gated workflow for shipping ANY repository change: plan → plan-review → implement →
  cross-review → merge → verify, with two human approval gates. Use whenever the user asks to implement,
  build, add, fix, or ship a change to a repo ("new feature", "let's implement X", "ship X", "fix this
  bug and open a PR"). Do NOT use for read-only work: diagnosis, code review, or answering questions.
allowed-tools: Bash, Read, Edit, Write
---

# ship-feature

Follow the canonical workflow in **`~/.config/ship-feature/WORKFLOW.md`** (installed by this project).
It is the single source of truth — do not restate or fork it here.

The essentials you must honor:

1. **Plan** it, then **review the plan** with a panel: `ship-feature plan-review <file> --reviewers <your agents>`
   (defaults to `SHIP_FEATURE_PLAN_REVIEWERS`, then `SHIP_FEATURE_REVIEWERS`; read-only; exit `0` clean, `3` re-run). A single reviewer via
   `codex exec --sandbox read-only` still works.
2. 🚦 **Stop for the human to approve the plan.** Do not write to the source repository before that.
3. Implement in a **git worktree** (never the main tree), stage explicit paths, open a **PR**. Run
   `ship-feature preflight` first.
4. Run the **cross-review**: `ship-feature relay --author <self> --reviewers <your agents> --context-file <plan.md>`
   (name the reviewers you have — the quorum — so a missing one fails rather than thinning the panel;
   e.g. `claude,codex,cursor`). **Always pass the plan** with `--context-file`: a reviewer that cannot
   see the intent can find bugs but not *"this is not what we agreed to build"*.
   The **plan file is the source** the PR body is generated from, and is **immutable once approved** —
   write and revise it freely before Gate 1, never after; for later rounds point `--context-file` at a
   derived copy (plan + dispositions), which is generated, never hand-edited.
   Iterate only for a **Blocker** or a **qualifying** Should-fix — a material problem of correctness,
   safety, deployability, or verification. Round 1 is the full quorum (**every configured reviewer except the author** — the relay skips the
   author, so the examples above list it too); rounds 2+ are **narrow** (only
   reviewers with a stake in an open finding, plus any whose finding you downgraded); the **closing**
   round is the full quorum again, on the SHA that will merge — **unless round 1 was already clean**,
   in which case it IS the closing round and a second full panel is waste. Branch on the exit code —
   `0` means every DISPATCHED reviewer ran, **not** that everyone ran and not that reviews are clean:
   a **benched** (out-of-quota) reviewer is dropped and still exits `0`, so check the startup lines.
   A benched seat in an initial or closing round is the human's call before the round.
   **Non-qualifying findings are recorded and left unfixed** until a follow-up PR — fixing one creates
   a commit after the reviewed SHA, and then the merged code is not the code anyone reviewed.
   **The author classifies each finding in writing**, naming it and the reason.
   **Post dispositions before re-running** — the relay deletes each reviewer's previous comment, so an
   unposted finding and its classification are lost; keep the relay's marker text
   (`<Name> review (automated cross-review)`) out of that comment or it is deleted too.
5. 🚦 **Stop for the human to merge.** Never self-merge. Disputed classifications do not block the
   stop — they go to this gate with both positions. Still two gates, never three.
6. **Verify** the tests on the merge commit.

For a trivial change, the human may say `--light` (may skip only the plan review — never the worktree,
tests, cross-review, or merge gate).

Read `WORKFLOW.md` now and follow it step by step.
