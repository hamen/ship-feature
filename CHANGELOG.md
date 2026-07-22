# Changelog

All notable changes to **ship-feature** are documented here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`ship-feature plan-review`** — step 2 as a first-class command. It fans an implementation plan (a file
  argument, stdin, or `./plan.md`) out to a panel of agents for a **read-only** review and prints each
  review to the terminal; nothing is written or posted. The panel defaults to `SHIP_FEATURE_REVIEWERS`
  and is overridable with `--reviewers`; `--parallel` runs them concurrently. Fail-closed exit codes
  mirror the relay: `0` every reviewer responded, `3` a reviewer failed/timed out/returned empty (a
  supported reviewer from the panel whose CLI is missing also fails — the panel is the quorum), `1` usage
  error.
  - **Read-only is enforced, not just asked.** Supported reviewers are only those that can be constrained:
    `claude --permission-mode plan`, `codex --sandbox read-only`, `cursor --mode=ask` (Q&A),
    `qwen --approval-mode plan` (qwen's read-only mode — denies edit/write/shell) plus `--safe-mode` (which
    also blocks any checkout config/hooks/MCP from executing). Each flag is guarded by an argv-contract
    test that also asserts qwen never uses the auto-approving `yolo` mode. `agy` and `opencode` are **relay-only** and
    skipped with a warning — `agy` has no read-only mode (its relay flag disables all permissions) and
    `opencode` needs the file-attach path — so the "nothing is written" guarantee holds for everything
    that runs.
  - Portable `timeout` (falls back to `gtimeout`, then runs without a limit on stock macOS); the reviewer
    list is not glob-expanded; `--reviewers` with no value / a following flag is a clean usage error;
    a file after `--` is honored; an empty stdin pipe falls back to `./plan.md`; a zero timeout is
    rejected. Timeout via `SHIP_FEATURE_PLAN_TIMEOUT` (default 300s).

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
