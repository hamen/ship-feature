# Changelog

All notable changes to **ship-feature** are documented here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`grok45high` plan-reviewer** — Grok 4.5 with **high** reasoning effort via `grok --prompt-file`
  (headless ignores stdin), `--permission-mode plan`, `--sandbox read-only`. Bare `grok` is
  relay-only at the plan gate (PR cross-review name in pr-review-relay).


### Changed

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

- **The `cursor` plan reviewer no longer runs on Cursor's `Auto` model.** It is now invoked with
  `--model "${CURSOR_REVIEW_MODEL:-cursor-grok-4.5-high}"`. Without it, `cursor-agent` fell back to
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
