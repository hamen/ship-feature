# Changelog

All notable changes to **ship-feature** are documented here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Plan-review (step 2) gets a 2-round cap and a disagreement-summary escalation to Gate 1** — the
  same discipline step 5's cross-review got in v0.3.0, in its own terms. `WORKFLOW.md` previously said
  only "iterate ≈2 rounds," which is a suggestion, not a rule: a real session ran **13 rounds** of
  plan-review before the panel agreed, burning roughly an hour and a quarter on convergence rather than
  the plan itself. Now: a round is one `plan-review` invocation where every dispatched reviewer
  responded (exit `3` doesn't count, and doesn't retry the same reviewer past two consecutive
  failures); a clean round 1 skips straight to Gate 1; a round only reopens for a Blocker or a
  **plan-qualifying** Should-fix (the plan is wrong about the tree, unsafe, or materially incomplete —
  a distinct term from step 5's PR-qualifying Should-fix, since a plan and a PR are different objects
  under review); and if round 2 still has an open plan-qualifying finding, the agent stops — no round
  3 on its own — and takes a **disagreement summary** (objection, classification, reason) to Gate 1,
  where the human decides. `bin/ship-feature`'s plan-review exit-`0` message, `WORKFLOW.md`, and all
  three adapters state the same rule, checked by the same `sf_clause`/`sf_tool_clause` consistency
  suite that already guards step 5's rule.

## [0.3.0] — 2026-08-04

### Added

- **`grok45high` plan-reviewer** — Grok 4.5 with **high** reasoning effort via `grok --prompt-file`
  (headless ignores stdin), `--permission-mode plan`, `--sandbox read-only`. Bare `grok` is
  relay-only at the plan gate (PR cross-review name in pr-review-relay).


### Changed

- **The cross-review panel is given the plan, and the loop stops iterating on findings that do not
  change anything.** Two rules, both measured rather than guessed, and both written into **every**
  adapter — not just `WORKFLOW.md`.

  **1. Always pass the plan** (`--context-file <plan.md>`). The flag already existed in
  `pr-review-relay` and nothing used it: **four PRs shipped in one day without a single reviewer
  seeing the intent it was meant to verify against**, and on one of them the old loop rule ran
  **eight full-quorum rounds** of which the last five found no Blocker at all. Two separate facts —
  they were previously written as one sentence ("eight rounds across four PRs"), which is true of
  neither. A reviewer with only the diff can find bugs; it cannot find *"this is not what we agreed
  to build"*. Measured on `pr-review-relay`
  #23 — same number of findings, different **kind**: the first review to open with "the PR matches
  the plan" and a conformance checklist, a changelog count that had drifted from the suite it
  described, and a rule the implementation had quietly skipped.

  **The byte saving in that experiment was not this.** The B arm also omitted the inline diff
  (`LINK_DIFF_FALLBACK_MAX_BYTES=0`), and that is where the −69 % came from; passing the plan *adds*
  bytes. Only the **kind of finding** is attributable to the plan. Omitting the diff was deferred —
  it needs a changed-file list, because a clean checkout has no deleted file to read — so conflating
  the two here would re-teach exactly the mistake that deferral exists to correct.

  The plan file is the **source** the PR body is generated from; later
  rounds point `--context-file` at a *derived* copy (plan + dispositions), and neither is hand-edited.

  **2. Three named phases, replacing "iterate while any Should-fix exists"** — the rule that produced
  those eight rounds, of which the last five found no Blocker at all. **Initial** round: full quorum.
  **Narrow** rounds: only reviewers with a stake in an open finding, plus any reviewer whose finding
  the author downgraded — otherwise classifying someone out of the panel removes their only way to
  object. **Closing** round: full quorum again, on the SHA that will merge, so the exact-SHA
  guarantee is not quietly traded away for the saving. Iterating happens for a Blocker or a
  **qualifying** Should-fix — a material problem of correctness, safety, deployability or
  verification, which deliberately covers documentation that misinstructs and release configuration,
  not only runtime behaviour.

  Three things that make it hold rather than merely read well:
  - **A round only counts if it completed** — and exit `0` no longer says that, because a **benched**
    (out-of-quota) reviewer is dropped deliberately and still exits `0`. A benched seat in an initial
    or closing round is the human's call *before* the round, not a silent thinning.
  - **Dispositions are posted before re-running.** The relay deletes each reviewer's previous comment
    before posting the next, so an unrecorded finding and its classification are gone by the time the
    human reaches the merge gate. The comment must not contain the relay's own marker text, or the
    next round deletes that too.
  - **A disputed classification does not block the stop** — it travels to **Gate 2** with both
    positions, where the human accepts the downgrade or rejects it and sends the PR back. Still
    **two** gates; what changed is what Gate 2 receives.

- **The documents are now tested against each other instead of trusted to match.** Editing
  `WORKFLOW.md` was never the propagation: each adapter restates the rules in its own words, and
  `~/.codex/AGENTS.md` receives a **copy** of its block rather than a symlink. All three had been
  left on the old "iterate while any Blocker/Should-fix remains" long after the rule moved on, and
  nothing would ever have said so.

  **18 clauses** are asserted across `WORKFLOW.md` **and** all three adapters — both directions, since
  `WORKFLOW.md` reverting while the adapters hold leaves agents on mixed rules just as effectively.
  Plus **3 clauses on `bin/ship-feature`'s exit-`0` message**, because what the tool prints on every
  run out-ranks a document nobody re-reads. Reverting any one of those five files turns the suite red
  — 18 times for a document, 3 for the tool.

  Matching is whitespace-normalised and phrased as multi-word anchors, so the check is about the rules
  rather than about line wrapping or exact wording. Three earlier versions of this test were quietly
  useless and each was caught by a reviewer: single-token greps that survive the rule being *reversed*;
  a tool check that grepped the whole file and so matched the explanatory comment instead of the
  message; and the `WORKFLOW.md` entry appended *after* the clause calls, where it checked nothing at
  all.

  **After merging, re-run `install.sh`** — the symlinked targets (WORKFLOW.md, the Cursor rule, the
  skill) follow the local checkout once it is fast-forwarded, but the Codex block is a copy and does
  not.

- **The `cursor` plan reviewer's pinned model moved from `cursor-grok-4.5-high` to `composer-2.5`.**
  The pin itself landed first (see *Fixed*) with Cursor's Grok build as the default. That was the
  wrong choice: `grok45high` is a supported plan reviewer, so a Cursor-branded Grok put **two
  Grok-family readers** on a panel reporting two independent ones — the same defect as `Auto`
  picking Claude, one row down. Composer 2.5 is Cursor's own model: Cursor-branded quota pool, and
  not Claude, GPT, Codex or Grok, so every reviewer stays on the model its own vendor built.
  `pr-review-relay` made the same move, so one `CURSOR_REVIEW_MODEL` export still configures both.

- **`grok45high` now reviews with the code in front of it.** It used to run in an isolated empty cwd
  with `--deny '*'`, so it could only review the plan's prose — it would open its review saying it
  could not read the tree, while `codex` and `cursor` were finding blockers that only reading the code
  reveals (a stale line reference, a client call that would crash, a CI step the change would turn
  red). It now runs in **your checkout**, like `claude`, `codex` and `cursor`.
  Read-only is enforced by an **allowlist** — `--tools read_file,list_dir,grep` — rather than a
  denylist: an unknown tool name is accepted silently by the CLI, so a denylist typo would fail open.
  That covers the built-ins (`run_terminal_command`, `search_replace`, `spawn_subagent`,
  `scheduler_*`).
  **The MCP bridge survives the built-in allowlist**, so it is removed explicitly with
  `--disallowed-tools search_tool,use_tool`. Verified against the CLI: with `--tools read_file` alone
  the session still exposes `search_tool` and `use_tool` — every MCP server configured on the machine
  stays reachable, including ones that write. With both removed it reports exactly
  `read_file`/`list_dir`/`grep`.
  `--permission-mode plan` and `--sandbox read-only` are unchanged.
- **`grok45high` now fails the round when the read-only sandbox is not enforced.** `--sandbox read-only`
  can warn and continue unenforced when its setup fails; the warning was only inspected on a **nonzero**
  exit, so the one shape worth catching — a clean review on stdout, a sandbox complaint on stderr, exit
  `0` — was reported as a passing round. stderr is now inspected regardless of the exit code, the review
  is **discarded** rather than printed, and the round fails with `3`.
  Detection alone is only a signal, though: by the time the warning arrives the checkout's hooks have
  already run. So the barrier is checked **before** Grok starts — on Linux, bubblewrap present and
  unprivileged user namespaces enabled. When it cannot be enforced the reviewer **degrades** to its
  previous posture (isolated empty cwd, every tool denied) and labels the review as text-only, rather
  than refusing outright — refusing would make `grok45high` unusable on any Linux without bubblewrap,
  CI runners included. The stderr match keys off failure phrasing
  ("continuing without enforcement", "failed to set up sandbox"), not the bare words "sandbox" or
  "namespace", which appear in healthy logs. Both paths have regression tests, including one asserting a
  benign sandbox log does **not** discard a good review.
  **Trade-offs, stated:** a checkout-scoped `.grok` is now loaded, exactly as `CLAUDE.md`, `AGENTS.md`
  and the cursor config already are for the other three in-checkout reviewers; Grok has no
  `--safe-mode` equivalent, so checkout hooks/plugins can still load, and `--sandbox read-only` can
  warn and continue unenforced if its setup fails — it is a layer, not the guarantee. `kimi3` stays
  isolated.

- **plan-review: replaced `qwen` with `kimi3` (Kimi K3 via opencode).** `kimi3` runs Kimi K3 through
  opencode, pinned **genuinely read-only** by a temp `OPENCODE_CONFIG` that denies the `edit` **and**
  `bash` permissions — removing both tools, so the model can't write even via shell. The denial is set
  through **`OPENCODE_CONFIG_CONTENT`, opencode's highest-precedence config layer** (applied last, so it
  wins over any merged global/checkout config — verified it overrides even a project `opencode.json` that
  sets `edit`/`bash` `"allow"`); inherited `OPENCODE_CONFIG*` are unset so a hostile environment can't
  pre-seed an `"allow"`, and it runs in an isolated cwd created outside the checkout so the repo's own
  `opencode.json` is never discovered. Plus `--pure` (no external plugins) and `--agent plan` as defense
  in depth. The guarantee is "your checkout is untouched", not "nothing touches disk" — like every
  reviewer, opencode still writes its own session data under its data dir. `qwen` is no longer a supported
  plan reviewer; `agy` and the **bare** `opencode` name stay relay-only (a plain `opencode run` uses the
  all-allow `build` agent). Read-only contract tests assert `kimi3` runs `--pure` + `--agent plan`, pins
  `edit`+`bash` deny via `OPENCODE_CONFIG_CONTENT`, unsets `OPENCODE_CONFIG`, runs in an isolated cwd, and
  **overrides a hostile inherited `OPENCODE_CONFIG_CONTENT`** — never the `build` agent.

### Fixed

- **`plan-review` no longer leaks its temp directory on every run.** `STATUS_DIR` was a function
  local, but the `EXIT` trap expands `"$STATUS_DIR"` when it fires — after `cmd_plan_review` has
  returned. By then the local is gone, `set -u` aborts the trap body on the unbound name, and the
  `rm` never runs. Every invocation left behind a directory holding that run's buffered artifacts:
  each reviewer's full review (`out_k_*`), plus `err_k_*`, `diag_k_*` and status files. On the
  machine where this was found: **931 orphaned directories, 32 MB, roughly 310 a day.** The only
  outward sign was a `STATUS_DIR: unbound variable` line on stderr after an otherwise successful
  run — which read as noise, not as the cleanup failing out loud. `STATUS_DIR` is now a plain
  global. Covered by a regression test that asserts the directory is actually gone, not merely that
  the message stopped: it fails on the old code (2 failures) and passes on the new.
- **The `cursor` plan reviewer no longer runs on Cursor's `Auto` model.** It is now invoked with
  `--model`, from a `CURSOR_REVIEW_MODEL` default set once in `cmd_plan_review`. Without it, `cursor-agent` fell back to
  `~/.cursor/cli-config.json`, whose default is `Auto` — which routes to the frontier models and may
  pick a **Claude** one. `plan-review` checks a plan an agent (usually Claude) just wrote, right
  before a human approves it, so Auto could have Claude grading its own plan while the panel reported
  an independent "Cursor" reviewer: two reviewers on the page, one model in reality. Auto also billed
  Cursor's small *Other Models* quota instead of the larger Cursor-branded pool. `CURSOR_REVIEW_MODEL`
  is env-only and intentionally **not** `SHIP_FEATURE_*`-prefixed —
  [`pr-review-relay`](https://github.com/hamen/pr-review-relay) reads the same variable, so one export
  configures both tools. Asserted in the read-only argv contract tests (default **and** override).
- **`test-ship-feature.sh` is hermetic against `CURSOR_REVIEW_MODEL`** — cleared with the other knobs
  at the top of the suite, so an exported value cannot satisfy the default-pin assertion.
- **The `--mode=ask` assertion now greps cursor's own line**, like the `claude` check above it,
  instead of the whole panel output where another reviewer echoing the plan could satisfy it.

### Fixed

- **The test suite inherited the ambient git environment**, so its result depended on how the machine
  running it happened to be configured — and, from a git hook, it wrote into the repository it was
  launched from.
  - **Signing.** With `commit.gpgsign = true` and an agent-backed signer (1Password's `op-ssh-sign`),
    every fixture commit really was signed — measured, `%G?` came back `G`. With the agent locked the
    signer returns nothing and the commits fail or block, producing failures unrelated to the code.
    The suite's green was conditional on 1Password being unlocked.
  - **Repo-local environment.** git exports `GIT_DIR` (and friends) to its hooks, and those outrank
    the working directory: with `GIT_DIR` set, a fixture's `cd "$repo" && git init && git commit`
    commits to the **host** repo and leaves the fixture empty. The sibling `pr-review-relay` suite did
    exactly that from its `pre-push` gate — junk commits on the branch being pushed, the branch
    renamed, `HEAD` moved, `user.name` rewritten in the real repository.
  - Isolation is one function, `sf_isolate_git`, applied at suite start and inside every hostile
    subprocess. The variable list comes from `git rev-parse --local-env-vars` — git's own answer, 15
    entries, and it cannot go stale; a hand-written version missed 7 of them. Ordering is
    load-bearing: `GIT_CONFIG_COUNT` is itself on that list, and `GIT_CONFIG_PARAMETERS` (set whenever
    anything up the process tree ran `git -c …`) **overrides** it, so the clearing must come first.
  - Also neutralised: `core.hooksPath`, `core.excludesFile` (a global `*.dat` ignore rule silently
    breaks the binary-scan fixture), `core.attributesFile`, `core.fsmonitor` and `color.ui`.
  - **Not** `GIT_CONFIG_GLOBAL=/dev/null`: it discards the whole global config including
    `safe.directory`. **Not** `git config` inside fixtures: tried in `pr-review-relay` and worse than
    the bug, since a fixture whose `git init` fails quietly writes into the host repo's config.
  - git **2.31+** is now required (for `GIT_CONFIG_COUNT`) and the suite refuses to run without it,
    rather than half-applying the isolation while reporting green.
  - Nine checks cover it, each planting the hostility and proving the plant is live before asserting
    isolation won. The exit gate asserts an exact `PASS` total, so a test that stops running is
    visible instead of silently absent.

## [0.2.0] — 2026-07-22

### Added

- **`ship-feature plan-review`** — step 2 as a first-class command. It fans an implementation plan (a file
  argument, stdin, or `./plan.md`) out to a panel of agents for a **read-only** review and prints each
  review to the terminal; nothing is written or posted. The panel defaults to `SHIP_FEATURE_PLAN_REVIEWERS`
  (a plan gate often wants a smaller panel than the PR cross-review), falling back to
  `SHIP_FEATURE_REVIEWERS`, and is overridable with `--reviewers`; `--parallel` runs them concurrently.
  Fail-closed exit codes
  mirror the relay: `0` every reviewer responded, `3` a reviewer failed/timed out/returned empty (a
  supported reviewer from the panel whose CLI is missing also fails — the panel is the quorum), `1` usage
  error.
  - **Read-only is enforced, not just asked.** Supported reviewers are only those that can be constrained:
    `claude --permission-mode plan --safe-mode` (safe-mode also stops checkout hooks/plugins/MCP loading),
    `codex --sandbox read-only`, `cursor --mode=ask` (Q&A),
    `qwen --approval-mode plan` (qwen's read-only mode — denies edit/write/shell) plus `--safe-mode` (which
    also blocks any checkout config/hooks/MCP from executing). Each flag is guarded by an argv-contract
    test that also asserts qwen never uses the auto-approving `yolo` mode. `agy` and `opencode` are **relay-only** and
    skipped with a warning — `agy` has no read-only mode (its relay flag disables all permissions) and
    `opencode` needs the file-attach path — so the "nothing is written" guarantee holds for everything
    that runs.
  - Portable `timeout` (falls back to `gtimeout`, then runs without a limit on stock macOS); the reviewer
    list is not glob-expanded; `--reviewers` with no value / an empty value / a following flag is a clean
    usage error; a file after `--` or `-` (stdin) is honored; an empty stdin pipe falls back to
    `./plan.md`; a zero timeout is rejected. Timeout via `SHIP_FEATURE_PLAN_TIMEOUT` (default 300s).
  - `^C` during `--parallel` tears the reviewers down: an interrupt kills each backgrounded reviewer's
    whole descendant tree (subshell → `$()` → `timeout` → agent) by walking PPIDs — a plain group-kill
    would miss the agent because `timeout` re-groups its child — so it stops burning credits instead of
    orphaning the agents. Covered by a regression test.

  This makes "review the plan with codex and qwen" a single command.

## [0.1.0] — 2026-07-16

First release.

### Added

- **`WORKFLOW.md`** — the canonical gated pipeline (plan → plan-review → 🚦 human gate → worktree + PR →
  cross-review → 🚦 human merge → verify), including the semantic definition of the human gates, the
  loop-termination rule (iterate while any Blocker/Should-fix exists; stop only at full agreement or
  Nits-only), the exact-SHA rule, an explicit-reviewer quorum, and the `--light` path.
- **`bin/ship-feature`** — a small Bash 3.2-safe CLI: `preflight` (assert a feature worktree branched off
  `origin/HEAD`, marker git-excluded, ancestry) and `relay` (a transparent pass-through to
  `pr-review-relay` that preserves stdout and the exact exit code).
- **Adapters** — one workflow skill in `~/.agents/skills/` used across tools, plus a Cursor rule and a
  marked block for `~/.codex/AGENTS.md`. Each only points at `WORKFLOW.md`; no duplicated logic.
- **`install.sh`** — idempotent, atomic installer that backs up any global file it modifies, checks
  `~/.local/bin` is on `PATH`, and smoke-tests that every adapter resolves.
- **Privacy guards** — `scripts/scan-generic.sh` (deny-list-free email/home-path scan for CI, works on
  fork PRs) and `scripts/scan-personal-data.sh` (local pre-publication scan of full history, commit
  metadata, filenames, and ref names against a private deny-list file that is never `source`-d).
- **Tests + CI** — `test/test-ship-feature.sh` (real temp repos + stubbed `pr-review-relay`) and a
  GitHub Actions matrix on Ubuntu + macOS that checks out the PR head SHA, runs the suite, `scan-generic.sh`,
  and gitleaks. (`scan-personal-data.sh` needs a private deny-list, so it runs locally pre-publication,
  not in CI.)

[0.3.0]: https://github.com/hamen/ship-feature/releases/tag/v0.3.0
[0.2.0]: https://github.com/hamen/ship-feature/releases/tag/v0.2.0
[0.1.0]: https://github.com/hamen/ship-feature/releases/tag/v0.1.0
