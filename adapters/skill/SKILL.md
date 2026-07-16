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

1. **Plan** it, then have a second agent **review the plan** (`codex exec --sandbox read-only`).
2. 🚦 **Stop for the human to approve the plan.** Do not write to the source repository before that.
3. Implement in a **git worktree** (never the main tree), stage explicit paths, open a **PR**. Run
   `ship-feature preflight` first.
4. Run the **cross-review**: `ship-feature relay --author <self>` (transparent wrapper over
   `pr-review-relay`). Branch on its exit code — `0` means everyone ran, **not** that reviews are clean;
   read the verdicts. Keep iterating while any **Blocker** or **Should-fix** exists; stop only at full
   agreement or **Nits-only**.
5. 🚦 **Stop for the human to merge.** Never self-merge.
6. **Verify** the tests on the merge commit.

For a trivial change, the human may say `--light` (may skip only the plan review — never the worktree,
tests, cross-review, or merge gate).

Read `WORKFLOW.md` now and follow it step by step.
