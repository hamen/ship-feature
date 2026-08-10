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
- **Plan-review has its own 2-round cap** (distinct from the PR cross-review loop below — its
  **plan-qualifying** term is not the same as, and must not be conflated with, the "qualifying
  Should-fix" used in cross-review). A round is
  one `plan-review` call where every reviewer responded — exit `3` does not count as a round, and if
  the same reviewer hits exit `3` on **two consecutive attempts** at the same round, stop retrying it
  and drop that reviewer for the round. Iterate only for a Blocker or a **plan-qualifying** Should-fix
  (the plan is wrong about the tree, unsafe, or materially incomplete — a missing edge case, failure
  mode, or verification gap — not a style/approach preference). A clean round 1 skips straight to
  Gate 1. If round 2 still has an open plan-qualifying finding, **stop — do not run a round 3 on your
  own**; bring the plan plus a disagreement summary (objection, your classification, reason) to Gate 1.
  A human-authorized extra round is not a third autonomous round: it either resolves cleanly, or
  produces an updated disagreement summary and returns to Gate 1 again.
- Implement in a **git worktree**, stage explicit paths, open a PR.
- Cross-review with `ship-feature relay --author codex --reviewers <your agents> --context-file <plan.md>`
  (explicit list = the agents you have, e.g. claude,codex,cursor). **Always pass the plan** with
  `--context-file`: a reviewer that cannot see the intent can find bugs but not "this is not what we
  agreed to build". The **plan file is the source** the PR body is generated from, and is **immutable once approved** —
  write and revise it freely before Gate 1, never after; for later rounds point `--context-file` at a
  derived copy (plan + dispositions), which is generated, never hand-edited.
- Iterate only for a **Blocker** or a **qualifying** Should-fix — a material problem of correctness,
  safety, deployability, or verification. Round 1 is the full quorum (**every configured reviewer except the author** — the relay skips the
  author, so the examples above list it too); rounds 2+ are **narrow** (only
  reviewers with a stake in an open finding, plus any whose finding you downgraded); the **closing**
  round is the full quorum again, on the SHA that will merge — **unless round 1 was already clean**,
  in which case it IS the closing round and a second full panel is waste. Exit `0` means every
  DISPATCHED reviewer ran, NOT that everyone ran and NOT that the reviews are clean: a **benched**
  (out-of-quota) reviewer is dropped and still exits `0`, so check the startup lines — a benched seat
  in an initial or closing round is the human's call before the round.
- **Non-qualifying findings are recorded and left unfixed** until a follow-up PR. Fixing one creates a
  commit after the reviewed SHA, and then the merged code is not the code anyone reviewed.
- **If the closing round raises a new qualifying finding it becomes the INITIAL round of another
  cycle** — full, then narrow, then a full quorum again on the new candidate. Not fix-narrow-stop:
  that merges a SHA no full panel ever saw.
- **Never `gh pr edit` the derived context file.** The PR body is generated from the plan and only
  the plan; a Dispositions section that grows each round would bury the plan under the argument
  about the plan.
- **Exit `4` is the round cap: stop and escalate to the human.** Never a reason to merge, never a
  reason to pass `--reset`.
- **The author classifies each finding in writing**, naming it and the reason.
- **Post dispositions before re-running** — the relay deletes each reviewer's previous comment, so an
  unposted finding and its classification are lost. Do **not** put the relay's marker text
  (`<Name> review (automated cross-review)`) in that comment, or it gets deleted too.
- Disputed classifications do not block the stop; they go to **Gate 2** with both positions.
  Still two gates, never three.
- **The human merges** — never self-merge.
# <<< ship-feature <<<
