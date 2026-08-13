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

1. **Plan** it into `~/.config/ship-feature/plans/<repo>-<slug>.md` (`mkdir -p` it if missing) — **never** the repo, **never** a session
   scratchpad (`/tmp` is tmpfs on many setups: a reboot destroys it, and the plan has to outlive every
   review round) — then **review the plan** with a panel:
   `ship-feature plan-review <that file> --reviewers <your agents>`
   (defaults to `SHIP_FEATURE_PLAN_REVIEWERS`, then `SHIP_FEATURE_REVIEWERS`; read-only; exit `0` means every
   reviewer responded — not that the reviews are clean, `3` re-run). A single reviewer via
   `codex exec --sandbox read-only` still works.
   **Plan-review has its own 2-round cap**, distinct from the cross-review loop below — its
   **plan-qualifying** term is not the same as, and must not be conflated with, the "qualifying
   Should-fix" used in cross-review. A round is one
   `plan-review` call where every reviewer responded — exit `3` does not count as a round, and if the
   same reviewer hits exit `3` on **two consecutive attempts** at the same round, stop retrying it,
   drop that reviewer for the round, and **tell the human about the reduced panel before Gate 1**
   rather than silently substituting (if that leaves zero reviewers, it isn't a completed round —
   take the failure itself to Gate 1). Iterate only for a Blocker or a **plan-qualifying** Should-fix
   (the plan is wrong about the tree, unsafe, or materially incomplete — a missing edge case, failure
   mode, or verification gap — not a style/approach preference). A clean round 1 skips straight to
   Gate 1; do not spend a round confirming an already-clean plan. Round 2, if it happens, runs against
   **the same full panel — never narrowed**. If round 2 still has an open plan-qualifying finding,
   **stop — do not run a round 3 on your own**; write a disagreement summary (each reviewer's
   objection, your classification, the reason) and bring it to Gate 1 instead of "the agreed plan." A
   human-authorized extra round is not a third autonomous round — it resolves cleanly or produces an
   updated disagreement summary and returns to Gate 1 again.
2. 🚦 **Stop for the human to approve the plan** — the agreed plan, or the plan plus a disagreement
   summary if the plan-review cap was hit with a finding still open (the human then accepts it as
   classified, authorizes one more round with explicit reasoning, or drops the change). Do not write
   to the source repository before that.
3. Implement in a **git worktree** (never the main tree), stage explicit paths, open a **PR**. Run
   `ship-feature preflight` first.
4. Run the **cross-review**: `ship-feature relay --author <self> --reviewers <your agents> --context-file ~/.config/ship-feature/plans/<repo>-<slug>.md`
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
   If the **closing** round raises a new qualifying finding it becomes the INITIAL round of another
   cycle — full, narrow, then a full quorum again on the new candidate; not fix-narrow-stop, which
   merges a SHA no full panel ever saw. **Never `gh pr edit` the derived context file** — the body is
   generated from the plan and only the plan. **Exit `4` is the round cap**: stop and escalate to the
   human; never a reason to merge and never a reason to pass `--reset`.
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
