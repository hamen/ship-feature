# ship-feature

![ship-feature workflow pipeline](assets/header.png)

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/shell-bash-89e051?logo=gnu-bash&logoColor=white)](bin/ship-feature)
[![tests](https://github.com/hamen/ship-feature/actions/workflows/test.yml/badge.svg)](https://github.com/hamen/ship-feature/actions/workflows/test.yml)
[![Works with Claude](https://img.shields.io/badge/works%20with-Claude%20Code-blueviolet?logo=anthropic&logoColor=white)](https://docs.anthropic.com/en/docs/claude-code)
[![Works with Codex](https://img.shields.io/badge/works%20with-Codex%20CLI-green?logo=openai&logoColor=white)](https://github.com/openai/codex)
[![Works with Cursor](https://img.shields.io/badge/works%20with-Cursor-0098FF?logo=cursor&logoColor=white)](https://cursor.com)
[![Works with Antigravity](https://img.shields.io/badge/works%20with-Antigravity-orange)](https://antigravity.dev)
[![Powered by pr-review-relay](https://img.shields.io/badge/powered%20by-pr--review--relay-8b5cf6)](https://github.com/hamen/pr-review-relay)

**One gated workflow for shipping any repository change — followed by whichever AI agent you drive.**

</div>

---

Plan → review → implement → cross-review → merge → verify, with **two human approval gates** and the
agent **never merging its own work**. The process lives in one place — [`WORKFLOW.md`](WORKFLOW.md) — and
each driver agent (Claude, Codex, Cursor) gets a thin adapter that points at it, so you stop re-explaining
"how we ship" every session. Antigravity joins the **cross-review** step through
[`pr-review-relay`](https://github.com/hamen/pr-review-relay).

## 🆕 What's new

**v0.3.0** — **the review panel is given the plan, and stops iterating on findings that change
nothing.** Reviewers used to see only the diff, so they could find bugs but never *"this is not what
we agreed to build"* — `--context-file` now carries the plan on every round. And the loop runs in
three named phases (full panel → narrow fix rounds → a closing full panel on the SHA that merges)
instead of iterating on every Should-fix, which had produced eight full-quorum rounds on one PR where
the last five found no Blocker. Both rules live in `WORKFLOW.md`, all three adapters **and** the CLI's
own message — and a consistency suite now fails if any of those five drift apart, in either direction.

**v0.2.0** — the `grok45high` plan reviewer, model pins that keep every seat on its own vendor's
model, and a test suite that no longer inherits the ambient git environment.

**v0.1.0** — first release: the canonical `WORKFLOW.md`, a `ship-feature` CLI (`preflight` +
a transparent `relay` wrapper), thin adapters for Claude / Codex / Cursor, an idempotent `install.sh`,
and a two-layer privacy guard. Full history in the [CHANGELOG](CHANGELOG.md).

## Why

Agents reinvent your release/PR process every session — worktree or not, which review, when to merge.
`ship-feature` encodes it once, as instructions an agent actually follows, with the irreversible steps
(approve the plan, merge) held behind explicit human gates.

## The workflow

The authoritative version is [`WORKFLOW.md`](WORKFLOW.md). At a glance:

| Step | What happens | Gate |
|:----:|--------------|:--|
| 1 | **Plan** the change | |
| 2 | A second agent **reviews the plan** | |
| 3 | You **approve the plan** | 🚦 **human gate** |
| 4 | **Implement** in a worktree → open a **PR** | |
| 5 | **Cross-review + tests** — the panel gets the **plan**, and iterates only for a Blocker or a *qualifying* Should-fix | |
| 6 | You **merge** | 🚦 **human gate** |
| 7 | **Verify** on the merge commit | |

The two 🚦 gates are the only places the agent stops and waits for you — and the agent never merges its
own work. Everything else runs on its own.

**Step 5 in one paragraph.** The reviewers are given the **plan** (`--context-file`), not just the
diff, so they can say *"this is not what we agreed to build"* and not only *"this line is wrong"*.
Round 1 is the full panel; the fix rounds are **narrow** — the reviewers with a stake in an open
finding, plus anyone whose finding you downgraded, so nobody is classified out of their own
objection; the closing round is the full panel again, on the SHA that will merge, unless round 1 was
already clean and there was nothing to fix. Iterating happens for
a **Blocker** or a **qualifying** Should-fix (correctness, safety, deployability, verification), not
for every remark. Anything the author downgrades is written down, and if the reviewer still disagrees
it goes to you at the merge gate — which is a change to what that gate *receives*, not a third gate.

## Install

Requires [**`pr-review-relay`**](https://github.com/hamen/pr-review-relay) on your `PATH` — it powers the
cross-review step (step 5). Then:

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
- `ship-feature plan-review [<file>] [--reviewers a,b,c] [--parallel]` — step 2: fan an implementation
  plan (a file, stdin, or `./plan.md`) out to a panel of agents for a **read-only** review and print each
  one. Read-only means each reviewer is pinned to its CLI's read-only mode and none is given a way to
  write your checkout or post anywhere — see [`WORKFLOW.md`](WORKFLOW.md) for what that does and does not
  guarantee for reviewers that run inside the checkout. Defaults the panel to `SHIP_FEATURE_PLAN_REVIEWERS`, then `SHIP_FEATURE_REVIEWERS`; nothing is
  written or posted. Supported reviewers
  are the ones that can actually be constrained: `claude` (`--permission-mode plan --safe-mode`), `codex`
  (`--sandbox read-only`), `cursor` (ask/Q&A mode, pinned to `--model composer-2.5`; see
  [Why the Cursor model is pinned](#why-the-cursor-model-is-pinned)), `kimi3` (Kimi K3 via opencode: `OPENCODE_CONFIG_CONTENT`
  — opencode's highest-precedence config layer — denies the `edit`+`bash` permissions so it can't write
  even via shell and can't be overridden by a merged global/checkout config; inherited `OPENCODE_CONFIG*`
  are unset, it runs in an isolated cwd outside the checkout, plus `--pure` and `--agent plan`),
  `grok45high` (Grok 4.5 high effort: `grok --prompt-file` — headless Grok ignores stdin — running in
  your checkout like `claude`/`codex`/`cursor`, held read-only by a tool **allowlist**
  `--tools read_file,list_dir,grep`, with the MCP bridge removed explicitly
  (`--disallowed-tools search_tool,use_tool` — it survives the built-in allowlist), plus
  `--permission-mode plan` and `--sandbox read-only`).
  `--safe-mode` on claude also stops
  any hooks/plugins/MCP in the checkout from loading. `agy`, bare `opencode`, and bare `grok` are
  relay-only and skipped with a warning (agy has no read-only mode; a plain `opencode run` uses the
  all-allow `build` agent — only the `kimi3` reviewer pins the read-only opencode `plan` agent; bare
  `grok` is the PR-relay name — use `grok45high` here). The
  panel is your quorum — a supported reviewer whose CLI is missing **fails** the round rather than
  thinning it. Exit `0` = every reviewer responded, `3` = one failed/timed out/returned empty (re-run),
  `1` = usage error. Per-reviewer timeout is `SHIP_FEATURE_PLAN_TIMEOUT` (env-only), which falls back to
  `PR_RELAY_AGENT_TIMEOUT`, then 300s. Lets you say "review this plan with codex and kimi3" as one command.
- `ship-feature relay [args…]` — a **transparent** wrapper over
  [`pr-review-relay`](https://github.com/hamen/pr-review-relay) that preserves its stdout and exact exit
  code, and reminds you what each code means: `0` = every **dispatched** reviewer ran — not that
  everyone ran, since a benched (out-of-quota) seat is dropped and still exits `0` — and not "clean";
  `3` = re-run; `4` = escalate. It injects your configured reviewer quorum when you omit `--reviewers`.

State/resume (`new`/`status`) is intentionally deferred — the CLI stays a thin helper; the agent drives
the process from `WORKFLOW.md`.

## Why the Cursor model is pinned

`plan-review` invokes the Cursor reviewer with `--model "$CURSOR_REVIEW_MODEL"`
(default `composer-2.5`). Left off, `cursor-agent` uses whatever is in your
`~/.cursor/cli-config.json`, which out of the box is **Auto** — and Auto routes to the frontier
models, including Claude's.

That matters more here than anywhere else in the pipeline. `plan-review` is the check on a plan that
an agent — usually Claude — just wrote, immediately before a human approves it. If Auto picks a
Claude model, Claude grades its own plan while the panel prints it as an independent "Cursor"
reviewer. The gate still reports two reviewers; you actually have one. Pinning to a model from a
different family is what keeps the second opinion a second opinion.

It also stops the reviews from billing Cursor's small *Other Models* quota (Claude/GPT) instead of
the much larger Cursor-branded pool — a real problem for a command you run before every change.

The default is **Composer 2.5, Cursor's own model**: Cursor-pool, and not Claude, GPT, Codex or
Grok. Every reviewer on the panel then stays on the model its own vendor built, which keeps them
failing differently from each other and not just from the author.

Override with `CURSOR_REVIEW_MODEL`; `cursor-agent --list-models` shows what your account offers.
**Pick something outside the other reviewers' families.** Setting it back to `auto`, to a
`claude-*` id while Claude writes your plans, or to a `cursor-grok-*` id while `grok45high` is on
your panel, all collapse two nominally independent seats onto one model family — the override
exists for retired model ids, not for going back to Auto.
The variable has no `SHIP_FEATURE_` prefix on purpose: it describes your Cursor account rather than
this tool, [`pr-review-relay`](https://github.com/hamen/pr-review-relay) reads the same one, and a
single export should configure both. Being outside that namespace it is **env-only** — it is never
read from `~/.config/ship-feature/config`.

## Running the tests

```bash
bash test/test-ship-feature.sh
```

Needs **git 2.31+**. The suite isolates its fixtures from your own git environment — signing, hooks,
`core.excludesFile`, and the `GIT_DIR` family that git hands to hooks — using `GIT_CONFIG_COUNT`,
which arrived in 2.31. On an older git it refuses to run rather than applying half the isolation and
reporting green. That isolation is why the suite behaves the same whether or not your commit signing
is on, and why running it from a git hook cannot write into the repository being tested.

## Keeping it clean (privacy)

This repo is generic — no private, project-specific data. Two guards:

- **`scripts/scan-generic.sh`** (CI) — catches real emails and absolute home paths; needs no config, runs
  on fork PRs.
- **`scripts/scan-personal-data.sh`** (local, pre-publication) — greps full history, commit metadata,
  filenames, and ref names against a **private** newline-delimited deny-list file (never `source`-d).

Your machine-specific values live in `~/.config/ship-feature/config` (gitignored) — see
[`config.example`](config.example).

## License

MIT © 2026 [Ivan Morgillo](https://github.com/hamen) — see [LICENSE](LICENSE).
