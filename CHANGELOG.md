# Changelog

All notable changes to **ship-feature** are documented here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **The test suite inherited the ambient git environment**, so its result depended on how the
  machine running it happened to be configured — and, from a git hook, it wrote into the repository
  it was launched from.
  - **Signing.** With `commit.gpgsign = true` and an agent-backed signer (1Password's `op-ssh-sign`),
    every fixture commit really was signed — measured, `%G?` came back `G`. With the agent locked the
    signer returns nothing and the commits fail or block, producing failures unrelated to the code.
    The suite's green was conditional on 1Password being unlocked.
  - **Repo-local environment.** git exports `GIT_DIR` (and friends) to its hooks, and those outrank
    the working directory: with `GIT_DIR` set, a fixture's `cd "$repo" && git init && git commit`
    commits to the **host** repo and leaves the fixture empty. The sibling `pr-review-relay` suite
    did exactly that from its `pre-push` gate — junk commits on the branch being pushed, the branch
    renamed, `HEAD` moved, `user.name` rewritten in the real repository.
  - Isolation is one function, `sf_isolate_git`, applied at suite start and inside every hostile
    subprocess. The variable list comes from `git rev-parse --local-env-vars` — git's own answer, 15
    entries, and it cannot go stale; a hand-written version missed 7 of them. Ordering is
    load-bearing: `GIT_CONFIG_COUNT` is itself on that list, and `GIT_CONFIG_PARAMETERS` (set
    whenever anything up the process tree ran `git -c …`) **overrides** it, so the clearing must come
    first.
  - Also neutralised: `core.hooksPath`, `core.excludesFile` (a global `*.dat` ignore rule silently
    breaks the binary-scan fixture), `core.attributesFile`, `core.fsmonitor` and `color.ui`.
  - **Not** `GIT_CONFIG_GLOBAL=/dev/null`: it discards the whole global config including
    `safe.directory`. **Not** `git config` inside fixtures: tried in `pr-review-relay` and worse than
    the bug, since a fixture whose `git init` fails quietly writes into the host repo's config.
  - git **2.31+** is now required (for `GIT_CONFIG_COUNT`) and the suite refuses to run without it,
    rather than half-applying the isolation while reporting green.
  - Eight checks cover it, each planting the hostility and proving the plant is live before asserting
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

[0.1.0]: https://github.com/hamen/ship-feature/releases/tag/v0.1.0
