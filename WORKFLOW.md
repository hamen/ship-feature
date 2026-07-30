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
reviewer failed/timed out/returned empty (re-run), `1` = usage error. The single-reviewer default still
works too: `cat plan.md | codex exec --sandbox read-only`.

Read the feedback, revise, and iterate (≈2 rounds). The reviewers catch wrong assumptions and stale
facts before they become code.

### 3. 🚦 Gate 1 — human approves the plan
Summarize the agreed plan and **stop**. Do not touch the source repository until the human says go.

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
ship-feature relay --author <self> --reviewers <your reviewer set>   # e.g. claude,codex,cursor
```

**Read the exit code** (`ship-feature relay` preserves it):
- `0` — every dispatched reviewer ran and posted **against a stable SHA**. This does **not** mean the
  reviews are clean — you must READ the verdicts.
- `3` — the round is not trustworthy (a reviewer failed / SHA unreadable / HEAD moved). Re-run.
- `4` — the round cap was hit. Escalate to the human.

**Quorum:** always pass an **explicit reviewer list** (the agents you have) so a missing one is a hard
failure rather than a silently thinned panel — a partial pass must not read as consensus. Set it once in
`~/.config/ship-feature/config` via `SHIP_FEATURE_REVIEWERS` for convenience.

**Loop-termination rule:** the review loop **continues as long as any Blocker or Should-fix exists** —
finding one means keep iterating (fix, push, re-run). It ends **only** when either:
- (a) all reviewers agree with **no** Blocker and **no** Should-fix, or
- (b) only **Nits** remain.

The round cap is an **escalation** threshold, never permission to merge with open Blockers/Should-fix.

**Exact-SHA rule:** capture the PR `headRefOid`; require local `HEAD` to equal it before testing; run the
tests; then re-check that the PR head has not moved. CI must check out the PR **head** SHA
(`github.event.pull_request.head.sha`), not the synthetic merge commit, so "green" maps to the reviewed
code.

### 6. 🚦 Gate 2 — human merges
Summarize the state ("green on the PR head, no open Blockers/Should-fix") and **stop**. The **human**
merges. The agent never self-merges — merge authority stays with the human.

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
