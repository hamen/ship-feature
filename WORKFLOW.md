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
ship-feature plan-review plan.md --reviewers codex,qwen     # or pipe it: cat plan.md | ship-feature plan-review
```

With no `--reviewers` it uses `SHIP_FEATURE_PLAN_REVIEWERS` (falling back to `SHIP_FEATURE_REVIEWERS`,
your quorum); with no file and no stdin it reads `./plan.md`. Reviewers run **read-only** and nothing is
written or posted — supported: `claude` (`--permission-mode plan`), `codex` (`--sandbox read-only`),
`cursor` (ask mode), `qwen` (`--approval-mode plan` + `--safe-mode`), and `antigravity`/`gemini` via the
`gemini` CLI. The gemini run is fail-closed: an isolated `GEMINI_CLI_HOME` **and** working dir with a
locked `.gemini/settings.json` that hard-excludes the write tools (`run_shell_command`, `replace`,
`write_file`, `web_fetch`, `save_memory`), disables hooks, and declares no MCP — so neither the user's
real `~/.gemini` nor a reviewed checkout's `.gemini/` contributes any `mcpServers`, hooks, or
`tools.allowed` (the gemini analog of claude/qwen `--safe-mode`; default non-interactive mode + `-e none`
on top). Model pinned to `gemini-3.1-pro-preview`, override with `SHIP_FEATURE_GEMINI_MODEL`. **Tradeoff:**
because the run is fully isolated, gemini reviews the plan text only — it has no access to the checkout's
files (deep codebase fact-checking is the PR cross-review's job). The `antigravity` name maps to the
`gemini` CLI **here** but to `agy` in `relay` — only `gemini` has a read-only mode. `opencode` is
relay-only and skipped with a warning. Exit `0` = every reviewer responded, `3` = a reviewer
failed/timed out/returned empty (re-run), `1` = usage error. The single-reviewer default still works too:
`cat plan.md | codex exec --sandbox read-only`.

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
