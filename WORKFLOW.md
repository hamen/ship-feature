# ship-feature — the workflow

The canonical, single source of truth for how to ship **any** repository change. Every adapter (Claude,
Codex, Cursor) points here. Follow it top to bottom for a new feature or fix.

This is a **gated pipeline**: two points require an explicit human decision, and the agent must stop and
wait at each. The agent never merges its own work.

---

## The two human gates

A **human gate** means: *explicit human approval, recorded in the active conversation, before the agent
proceeds.* The agent's native plan/ask mode is only a convenience that helps enforce this — it is not the
gate itself. Before Gate 1, the agent may write the **plan** and workflow metadata, but must not write to
the **source repository**.

- **Gate 1 — approve the plan** (before any source change).
- **Gate 2 — merge** (only the human merges).

---

## The pipeline

### 1. Plan
Write a short, concrete plan: the problem, the approach, the files you expect to touch, and how success is
verified. Keep it in a plan file (not the repo).

### 2. Plan review
Have a second agent — or a panel — review the plan before writing code. Use the `plan-review` command,
which fans the plan out to your reviewer panel read-only and prints each review:

```
ship-feature plan-review plan.md --reviewers codex,kimi3    # or pipe it: cat plan.md | ship-feature plan-review
```

With no `--reviewers` it uses `SHIP_FEATURE_PLAN_REVIEWERS`, then `SHIP_FEATURE_REVIEWERS` (your quorum);
with no file and no stdin it reads
`./plan.md`. Reviewers run **read-only** and nothing is written or posted — supported: `claude`
(`--permission-mode plan --safe-mode`), `codex` (`--sandbox read-only`), `cursor` (ask mode, pinned to
`$CURSOR_REVIEW_MODEL` — default `composer-2.5`, Cursor's own model — so Cursor's `Auto` cannot
quietly route the review to a Claude model and have Claude grade a plan Claude wrote, and so the
seat stays out of `grok45high`'s family too), `kimi3`
(Kimi K3 via opencode, pinned read-only by `OPENCODE_CONFIG_CONTENT` — the highest-precedence config
layer — denying `edit`+`bash`, with inherited `OPENCODE_CONFIG*` unset, an isolated cwd, plus `--pure`
and `--agent plan`), `grok45high` (Grok 4.5 high effort via `grok --prompt-file`, running in your
checkout with a read-only tool allowlist `--tools read_file,list_dir,grep`, the MCP bridge removed
(`--disallowed-tools search_tool,use_tool`), `--permission-mode plan`, `--sandbox read-only`); `agy`, bare `opencode`, and bare `grok`
are relay-only and skipped with a warning (use `grok45high` for plan review).

Reviewers that run in the checkout — `claude`, `codex`, `cursor`, `grok45high` — can read the tree, so
they check the plan against the code (a stale line number, a test the change would turn red). `kimi3`
stays isolated. `grok45high` needs a working OS sandbox to read the tree: where one cannot be applied
(Linux without bubblewrap) it degrades to an isolated, text-only review and says so above its output.

What "read-only" means here, precisely: each reviewer is pinned to its CLI's read-only mode and none of
them is given a way to write your checkout or post anywhere. It is not a sandbox escape proof. Except for
`claude --safe-mode`, an in-checkout reviewer loads that checkout's own agent config (`CLAUDE.md`,
`AGENTS.md`, `.cursor`, `.grok`) and whatever hooks or plugins it declares — the same trust you already
extend by opening the repo in that agent. Review a plan for a repository you do not trust with `kimi3`,
or not at all.
Exit `0` = every reviewer responded, `3` = a
reviewer failed/timed out/returned empty (re-run — see the two-consecutive-failure rule below), `1` =
usage error. The single-reviewer default still works too: `cat plan.md | codex exec --sandbox read-only`.

Read the feedback and revise — but only within the cap below, not without limit. The reviewers catch
wrong assumptions and stale facts before they become code.

**Loop-termination rule.** A plan under review that keeps drawing new objections to each revision can
spin as long as an unreviewed PR can — one real round ran **13 rounds** before the panel agreed, burning
roughly an hour and a quarter on convergence instead of on the plan. Plan-review gets the same discipline
as step 5's cross-review, in its own terms: this is a **plan** under read-only review before any code
exists, not a **PR** under cross-review, so "plan-qualifying" below is a distinct term from step 5's
"qualifying Should-fix" (correctness / safety / deployability / verification) — do not conflate the two.

- **A round** is one `plan-review` invocation where every dispatched reviewer returned a review (exit
  `0`). Exit `3` (a reviewer failed, timed out, or returned empty) does **not** count as a round —
  re-run it. If the **same** reviewer hits exit `3` on **two consecutive attempts** at the same round,
  stop retrying that reviewer, drop that reviewer for the round, and proceed with the remaining panel
  — but **tell the human about the reduced panel** before Gate 1, the same way a benched reviewer in
  step 5's initial or closing round is the human's call, not a silent substitution. **If dropping the
  reviewer leaves zero reviewers, that is not a completed round at all** — stop and take the failure
  itself to Gate 1 (a plan nobody reviewed is not "the agreed plan").
- **Cap: 2 rounds.** Round 1 is the full configured panel (`SHIP_FEATURE_PLAN_REVIEWERS`, or your
  `--reviewers`). If round 1 raises no Blocker and no plan-qualifying Should-fix, **stop — go straight
  to Gate 1.** Do not spend a second round confirming an already-clean plan. If round 1 raised a
  plan-qualifying finding, revise **once** and run round 2 against **the same full panel — never a
  narrowed one.** A plan-review panel is 2–3 reviewers, too small to narrow the way step 5 narrows a PR
  panel; unlike step 5, there is no narrow phase here at all.
- **Plan-qualifying** means: a **Blocker**, or a **Should-fix** saying the plan is wrong about the
  existing tree, unsafe to execute as written, or **materially incomplete** — a missing edge case, an
  unhandled failure mode, or missing verification that would let a broken change ship. A **Nit**, or a
  Should-fix that only expresses a stylistic or approach preference without any of the above, does not
  reopen a round.
- **If round 2 still has an open plan-qualifying finding, stop — do not run a round 3 on your own.**
  Write a short **disagreement summary**: for each open finding, the reviewer's objection, your
  classification, and the reason. Take that summary to Gate 1 instead of "the agreed plan."
- **A human-authorized extra round is not a third autonomous round.** If the human reviews the
  disagreement summary at Gate 1 and asks for one more pass, that round runs like round 2: it either
  resolves and reaches Gate 1 clean, or it produces an updated disagreement summary and returns to
  Gate 1 again. There is no agent-initiated round beyond the cap — only a human-authorized one.

### 3. 🚦 Gate 1 — human approves the plan
Summarize the plan and **stop**. This is one of two shapes: **the agreed plan** (a clean round, or a
later round resolved every plan-qualifying finding), or **the plan plus a disagreement summary** (the
cap was hit with a plan-qualifying finding still open). In the second shape the human chooses: accept
the plan as you classified it, authorize one more round with explicit reasoning for why, or drop the
change. Do not touch the source repository until the human says go.

### 4. Implement in a worktree, open a PR
- Work in a **git worktree**, never the main working tree. Default root `.claude/worktrees/`, override
  with `SHIP_FEATURE_WORKTREE_ROOT`. Add the worktree marker dir to the repository's `info/exclude` (in a
  linked worktree that's the **common** git dir's exclude, which `ship-feature preflight` checks) so it
  never shows up in anyone's status.
- Branch off the repository's **default branch** (`origin/HEAD`), not a hardcoded name.
- **Stage explicit paths** — never `git add -A`/`git add .` (tools drop stray files).
- One coherent change per PR. Ship tests at the level you touched.
- Open the PR.

Run `ship-feature preflight` to assert the working copy is set up correctly before you start.

### 5. Cross-review + tests
Hand the PR to the **other** agents for review, and run the full test suite / CI against the exact PR
head.

```
# Name the reviewers YOU actually run — adjust the list to the agents you have installed.
# ALWAYS pass the plan: reviewers that cannot see the intent can only find bugs.
ship-feature relay --author <self> --reviewers <your reviewer set> --context-file <plan.md>
```

**Always pass the plan with `--context-file`.** The plan already exists — §2 wrote it for the plan
review — and the flag prepends it as a document every reviewer must verify the PR *against*. Without
it a reviewer can find bugs but cannot find **"this is not what we agreed to build"**: the plan
conformance check, the stale count, the rule the implementation quietly skipped. Measured on
`pr-review-relay` #23: same number of findings, different kind, and the first review to open with
"the PR matches the plan" and a conformance checklist.

**The plan file is the source, and it is immutable once approved.** Write and revise it freely before
Gate 1 — that is what step 1 and step 2 are for — and not after. The PR body is generated from it
(`gh pr edit --body-file <plan.md>`), never hand-edited, so the two cannot drift. When later rounds
need dispositions (below), build a **derived** per-round file — the plan verbatim, plus a
Dispositions section — and point `--context-file` at that. Never hand-edit either one.

**Do not re-publish the derived file to the PR body.** `gh pr edit --body-file` runs for the plan and
only the plan; a Dispositions section that grows every round would bury the plan under the argument
about the plan. Dispositions belong in the round's prompt, where the reviewer reads them, and in the
PR thread, where the human reads them at Gate 2.

**Read the exit code** (`ship-feature relay` preserves it):
- `0` — every dispatched reviewer ran and posted **against a stable SHA**. This does **not** mean the
  reviews are clean — you must READ the verdicts.
- `3` — the round is not trustworthy (a reviewer failed / SHA unreadable / HEAD moved). Re-run.
- `4` — the round cap was hit. Escalate to the human.

**Quorum:** always pass an **explicit reviewer list** (the agents you have) so a missing one is a hard
failure rather than a silently thinned panel — a partial pass must not read as consensus. Set it once in
`~/.config/ship-feature/config` via `SHIP_FEATURE_REVIEWERS` for convenience.

**Loop-termination rule.** Iterating on *every* Should-fix produced eight full-quorum rounds on one
PR where the last five found no Blocker. The loop now has **three named phases**:

| phase | panel | purpose |
|---|---|---|
| **Initial** — round 1 | full quorum | find everything |
| **Narrow** — rounds 2…n | reviewers with a stake in an open finding, **plus any whose finding you downgraded** | verify targeted fixes |
| **Closing** — final round | full quorum, on the SHA that will merge | confirm the merge candidate |

**A clean initial round IS the closing round.** If round 1 completes with no Blocker and no qualifying
Should-fix, you are done — there is nothing to fix, so the SHA the panel reviewed is already the SHA
that will merge. Do not run a second full quorum to "close" a round that never opened. The closing
round exists only because *fixing* something creates a SHA nobody reviewed in full.

**If the closing round raises a new qualifying finding, it becomes the initial round of another
cycle** — fix, narrow, then a full quorum again on the new merge candidate. Not fix-narrow-stop: that
would merge a SHA that no full panel ever saw, which is the thing the closing round is for.

- **A round only counts if it completed** — every reviewer **the round was supposed to dispatch**
  produced and posted a review. For an initial or closing round that is every configured reviewer
  except the author; for a narrow round it is the narrow set, not the whole `SHIP_FEATURE_REVIEWERS`
  list. Exit `0` is *not* that statement: a **benched** reviewer (out of quota) is
  dropped deliberately and still exits `0`. A benched seat in an **initial or closing** round is a
  decision for the human **before the round**, taken when the relay announces the bench at startup:
  wait for the quota to reset, or authorise the reduced panel explicitly, recorded in the PR thread
  and repeated at Gate 2. **Narrow rounds are unaffected**: a benched seat there simply means the
  finding it raised stays open until that seat comes back — nothing to decide, nothing to wait for.
- **Iterate only for a Blocker, or a qualifying Should-fix** — one that is a material problem of
  **correctness, safety, deployability, or verification**. That covers documentation that
  misinstructs, release and deploy configuration, packaging, migrations, portability and API
  contracts; it does not cover wording, structure, or coverage of paths the PR does not touch.
- **The author classifies in writing**, naming the finding and the reason.
- **The narrow panel is defined by stake, not by size**: every reviewer that raised a qualifying
  finding, **plus** every reviewer whose finding the author downgraded — otherwise classifying
  someone out of the panel removes their only way to object. Usually that is fewer seats, which is
  where the saving is; if everyone has a stake, it is everyone.
- **A downgraded reviewer must be able to see the downgrade.** Reviewers are told not to read the PR
  discussion, so dispositions travel in the **derived context file** — each finding, its
  classification, the reason, and whether it is disputed.
- **Post the dispositions before re-running.** The relay deletes each reviewer's previous comment
  before posting the next, so the original finding and its classification are gone from the PR by the
  time the human reaches Gate 2 unless they were written down separately. The disposition comment
  **must not contain the relay's own marker text** (`<Name> review (automated cross-review)`), or the
  next round deletes it too.
- **Non-qualifying findings are recorded and left unfixed** until a follow-up PR. Fixing one creates
  a commit after the reviewed SHA, and then the merged code is not the code anyone reviewed.
- **Stop** when the closing round returns no Blocker and no undisputed qualifying Should-fix.
  Documented **disputes do not block the stop** — they travel to Gate 2 as open items.

The round cap (exit `4`) is an **escalation** threshold: stop and hand the open findings to the
human. It is never permission to merge, and never grounds for `--reset`.

**Exact-SHA rule:** capture the PR `headRefOid`; require local `HEAD` to equal it before testing; run the
tests; then re-check that the PR head has not moved. CI must check out the PR **head** SHA
(`github.event.pull_request.head.sha`), not the synthetic merge commit, so "green" maps to the reviewed
code.

### 6. 🚦 Gate 2 — human merges
Summarize the state and **stop**. The **human** merges. The agent never self-merges — merge authority
stays with the human.

The summary must state: green on the PR head; **no open Blockers and no open qualifying Should-fix**;
every remaining finding recorded with its classification; **every disputed classification listed with
both positions**; and any reduced panel that was authorised. The human rules on the disputes as part
of deciding to merge — accept the downgrade and merge, or reject it, which sends the PR back into the
narrow/closing cycle with that finding reclassified as qualifying.

This is still **two** gates, not three: a dispute does not create a new stopping point, it changes
what Gate 2 receives.

### 7. Verify on the merge commit
After the merge, re-run the tests on the merge commit. Red = stop and fix.

### (8. Release — out of scope here)
Releasing to a store / registry is a separate tool's job and is not part of this workflow.

---

## The light path

`--light` is for a trivial change (a typo, a one-line fix) and is **only** valid when the human explicitly
asks for it. It may skip the **plan review** (step 2). It may **never** skip the worktree, the relevant
tests, the cross-review, or the merge gate.

---

## Scope

Single repository, `origin/HEAD` as the base. Multi-repo changes are out of scope — split them into one
PR per repo, each run through this workflow independently.
