# Changelog

All notable changes to **ship-feature** are documented here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
