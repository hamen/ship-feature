# ship-feature

**One gated workflow for shipping any repository change — followed by whichever AI agent you drive
(Claude, Codex, Cursor).** Plan → plan-review → implement → cross-review → merge → verify, with two
human approval gates and the agent never merging its own work.

The process lives in one place — [`WORKFLOW.md`](WORKFLOW.md) — and each agent gets a thin adapter that
points at it, so you stop re-explaining "how we ship" every session.

## 🆕 What's new

**v0.1.0** — first release: the canonical `WORKFLOW.md`, a `ship-feature` CLI (`preflight` +
a transparent `relay` wrapper), thin adapters for Claude / Codex / Cursor, an idempotent `install.sh`,
and a two-layer privacy guard. Full history in the [CHANGELOG](CHANGELOG.md).

## Why

Agents reinvent your release/PR process every session — worktree or not, which review, when to merge.
`ship-feature` encodes it once, as instructions an agent actually follows, with the irreversible steps
(approve the plan, merge) held behind explicit human gates.

## The workflow

See [`WORKFLOW.md`](WORKFLOW.md) for the authoritative version. In short:

1. **Plan** it. 2. A second agent **reviews the plan**. 3. 🚦 **Human approves the plan.**
4. **Implement in a worktree → PR.** 5. **Cross-review + tests**; iterate while any Blocker/Should-fix
remains. 6. 🚦 **Human merges.** 7. **Verify** on the merge commit.

## Install

Requires [`pr-review-relay`](https://github.com/hamen/pr-review-relay) on your `PATH` (the cross-review
step). Then:

```bash
git clone https://github.com/hamen/ship-feature
cd ship-feature
./install.sh          # or ./install.sh --copy to detach WORKFLOW.md from the clone
```

`install.sh` is idempotent: it symlinks the CLI, installs `WORKFLOW.md` to `~/.config/ship-feature/`, the
workflow skill to `~/.agents/skills/`, a Cursor rule, and a marked block in `~/.codex/AGENTS.md`
(backing up anything it changes). Add a line to your global agent instructions telling it to follow the
ship-feature skill for any feature/fix.

## The CLI

- `ship-feature preflight` — assert you're in a feature worktree branched off the default branch, with
  the worktree marker git-excluded (run before you start implementing).
- `ship-feature relay [args…]` — a **transparent** wrapper over `pr-review-relay` that preserves its
  stdout and exact exit code, and reminds you what each code means (`0` = everyone ran, not "clean"; `3`
  = re-run; `4` = escalate).

State/resume (`new`/`status`) is intentionally deferred — the CLI stays a thin helper; the agent drives
the process from `WORKFLOW.md`.

## Keeping it clean (privacy)

This repo is generic — no private, project-specific data. Two guards:

- **`scripts/scan-generic.sh`** (CI) — catches real emails and absolute home paths; needs no config, runs
  on fork PRs.
- **`scripts/scan-personal-data.sh`** (local, pre-publication) — greps full history, commit metadata,
  filenames, and ref names against a **private** newline-delimited deny-list file (never `source`-d).

Your machine-specific values live in `~/.config/ship-feature/config` (gitignored) — see
[`config.example`](config.example).

## License

[MIT](LICENSE).
