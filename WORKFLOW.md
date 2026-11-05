# ship-feature — the workflow

The canonical, single source of truth for how to ship **any** repository change. Every adapter (Claude,
Codex, Cursor) points here.

There are **two lanes**:

- **The light lane — the default.** No plan, one review round by the configured panel, and the agent
  lands its own work with `ship-feature land`. No PR.
- **The careful lane — only for real risk.** The gated pipeline below: a plan, one plan-review round, a
  PR, at most two cross-review rounds, and a human who merges.

Why the light lane is the default: the gated pipeline, run on every change with high round caps, turned
one fix into days of rounds. A panel of several models almost always finds one more thing, so a loop
that iterates until the panel is silent does not converge, and a fix that waits in round 8 helps no
user. Caps that are low by design, and a default lane with one review round, trade a few small bugs
that reach users for changes that ship the same day. The careful lane keeps the full gates where a bug
costs money, data or trust.

---

## The light lane (default)

Use it for every change that is not on the careful-lane list.

1. **Worktree and branch** off the default branch (`origin/HEAD`), as in step 4 below. Stage explicit
   paths. The repository's pre-push hook runs the tests, a linter and a formatter check.
2. **Implement**, with tests at the level you touched. Commit.
3. **Review once**, with the configured panel, on the branch diff — no PR needed:
   `ship-feature review --author <self> --base origin/<default>`
   (a pass-through to `review-local`, which ships in `relay/`). Do not pass `--reviewers`: the panel
   is `REVIEWERS` in `~/.config/pr-review-relay/config`, and its seats run in parallel, so a round
   takes as long as the slowest seat. Read the startup lines and name the seats that ran: a seat whose
   CLI is not installed is skipped, and the round still exits `0` with the others. A seat that fails
   (timeout, quota, no usable review) makes the round exit `3`, and so does a round where no seat ran.
   If the same seat fails twice, run the remaining seats with `--reviewers` and tell the human which
   seat was dropped. One round, however many seats: more seats find more, and the rule in step 4
   decides what gets fixed. Wrap the round in `ship-feature seat-audit snapshot` and `check` (see
   step 5 of the careful lane): a seat that wrote to the checkout voids the round, like exit `3`.
4. **Fix only what breaks the change for a real user**, loses money, or leaks data. Record every other
   finding in the merge message (`-m "Not fixed: …"`) and move on. No second round, unless the fix was
   large.
5. **Land it:** `ship-feature land [-m <message>]...` from inside the worktree. It merges the branch
   (`--no-ff`) onto a freshly fetched default branch, checks that merge out, and pushes it, so the
   pre-push hook tests the exact tree that lands. If the push is refused, nothing landed: fix what the
   hook reported, or run `land` again if the default branch moved. The agent lands its own work here.
6. **Ship it** when the change needs a release or a deploy. **A change is done when it is live**, not
   when it is merged: report the version or the deployed commit.

### The careful lane — when to use it

Payments and subscriptions; ad consent and ad-revenue paths; authentication and account deletion;
database migrations and data deletion; security fixes; store-policy changes (permissions, SDKs that
collect data). Also any change the human asks to run in the careful lane.

### When a PR is still needed

A PR is the product for upstream and fork work, it is required where branch protection demands it,
and it is the human's inbox for code written by an unattended agent. In those repos, run the careful
lane's steps 4–7 with the same round caps.

---

## The careful lane — the gated pipeline

This is a **gated pipeline**: two points require an explicit human decision, and the agent must stop and
wait at each. The agent never merges its own work in this lane.

### The two human gates

A **human gate** means: *explicit human approval, recorded in the active conversation, before the agent
proceeds.* The agent's native plan/ask mode is only a convenience that helps enforce this — it is not the
gate itself. Before Gate 1, the agent may write the **plan** and workflow metadata, but must not write to
the **source repository**.

- **Gate 1 — approve the plan** (before any source change).
- **Gate 2 — merge** (only the human merges).

---

### The steps

### 1. Plan
Write a short, concrete plan: the problem, the approach, the files you expect to touch, and how success is
verified.

**Keep it in `~/.config/ship-feature/plans/<repo>-<slug>.md`** — creating that directory if it is not
there, which on an install updated by `git pull` alone it will not be — and **not in the repository**,
and **not in an agent's session scratchpad.** The scratchpad is `/tmp` on most setups and `/tmp` is tmpfs on many of
them, so a plan kept there is held in RAM: a reboot destroys it, silently and completely.

That matters more than it looks, because the plan is not a session artifact. It has to live as long as
the pull request does — §4 passes it to **every** relay round, and a review loop routinely spans days.
And what a lost plan costs is not the typing: it is the agreement. A plan that has been through §2 and
§3 carries review rounds and a human approval, and none of that can be reconstructed from memory. A
reviewer who corrected a sequence in §2 will not correct it again in a file you rewrote afterwards.

`~/.config/ship-feature/plans/` survives reboots, worktree removal and session ends, and sits beside
the config the workflow already reads.

### 2. Plan review
Have a second agent — or a panel — review the plan before writing code. Use the `plan-review` command,
which fans the plan out to your reviewer panel read-only and prints each review:

```
ship-feature plan-review ~/.config/ship-feature/plans/<repo>-<slug>.md
# to override the panel on purpose, append: --reviewers codex,glm
# or pipe it: cat ~/.config/ship-feature/plans/<repo>-<slug>.md | ship-feature plan-review
```

**Do not type the panel.** With no `--reviewers` it uses `SHIP_FEATURE_PLAN_REVIEWERS`, then
`SHIP_FEATURE_REVIEWERS` (your quorum). Either is taken from the **environment** first, then
`~/.config/ship-feature/config`, and otherwise `PLAN_REVIEWERS` / `REVIEWERS` in
`~/.config/pr-review-relay/config` — **set them in ONE place.** An **exported** value beats both files — see the Quorum note in §5 — so check the environment first when a round comes back the wrong size. The shared file is the usual home, because it is where seats are
added and swapped for both tools; a value in ship-feature's own config wins over it silently, which
is the same stale-copy problem one level up. A list typed into a command is a copy of that file that stops
being true the day it changes, and nothing announces the difference: the round simply comes back
smaller and reads as complete. Pass the flag to override deliberately, not to restate the config.

**Read the startup lines and say which reviewers actually ran.** Omitting the flag fixes a stale
list; it cannot tell you a seat dropped out. Here, bare `opencode` is a relay-only name — if your
panel falls back to `SHIP_FEATURE_REVIEWERS` and contains it, it is skipped with a warning and the
round still exits `0`. Each seat's dispatch line also shows the model and effort it resolved to.

With no file and no stdin it reads
`./plan.md` when nothing is named — convenient, and NOT where a plan should live: see §1. Reviewers run **read-only** and nothing is written or posted — supported: `claude`
(`--permission-mode plan --safe-mode`), `codex` (`--sandbox read-only`), `cursor` (ask mode, pinned to
`$CURSOR_REVIEW_MODEL` — default `composer-2.5`, Cursor's own model — so Cursor's `Auto` cannot
quietly route the review to a Claude model and have Claude grade a plan Claude wrote, and so the
seat stays out of `grok`'s family too), `glm`
(the opencode runner, model pinned to `$GLM_REVIEW_MODEL` — default `opencode-go/glm-5.3`, the
bundled OpenCode Go tier, overridable to a pay-as-you-go model — pinned read-only by
`OPENCODE_CONFIG_CONTENT` — the highest-precedence config
layer — denying `edit`+`bash`, with inherited `OPENCODE_CONFIG*` unset, plus `--pure`
and `--agent plan`; on OpenCode v2 `GLM_REVIEW_CONFIG_DIR`, `GLM_REVIEW_AGENT` and
`GLM_REVIEW_PROMPT_EXTRA` give it your own agent, MCP servers and prompt text, see the README), `grok` (model and effort from `MODEL_grok` / `EFFORT_grok` in the shared panel
file — the same keys the relay's grok seat reads — or `$GROK_REVIEW_MODEL` / `$GROK_REVIEW_EFFORT`;
defaults `grok-4.6` / `medium` — via `grok --prompt-file`, running in your
checkout with a read-only tool allowlist `--tools read_file,list_dir,grep`, the MCP bridge removed
(`--disallowed-tools search_tool,use_tool`), `--permission-mode plan`, `--sandbox read-only`), `pi_glm` and
`pi_grok` (the `pi` runner, one model each: `MODEL_pi_glm` / `EFFORT_pi_glm` and `MODEL_pi_grok` /
`EFFORT_pi_grok` in the shared panel file — the same keys the relay's pi seats read — or
`$PI_GLM_REVIEW_MODEL` / `$PI_GLM_REVIEW_EFFORT` / `$PI_GROK_REVIEW_MODEL` / `$PI_GROK_REVIEW_EFFORT`;
defaults `zai/glm-5.3` / `low` and `xai/grok-4.7` / `low` — running in your checkout with a read-only tool
allowlist `--tools read,grep,find,ls`, so there is no shell and no write tool, and with extensions, MCP,
skills, prompt templates, themes, context files, the trust-gated project files (`--no-approve`), the saved
session and the startup network calls all off. The effort must be one of `off minimal low medium high
xhigh max`, and any other value stops the command: pi does not refuse a level it does not know, it runs
at the level in your own pi settings. The seat needs `node` to read pi's json stream), and `antigravity` (aliases `agy`, `gemini`) via the
`gemini` CLI. The gemini run is fail-closed: an isolated `GEMINI_CLI_HOME` **and** working dir with a
locked `.gemini/settings.json` that **allowlists only the read-only tools** via `tools.core`, names
today's write tools in `tools.exclude` as defence-in-depth, disables hooks, and declares no MCP — so
neither the user's real `~/.gemini` nor a reviewed checkout's `.gemini/` contributes any `mcpServers`,
hooks, or `tools.allowed` (the gemini analog of claude's `--safe-mode`; default non-interactive mode
plus `-e none` on top). Because `tools.core` does **not** filter every tool gemini registers, the seat
also refuses to run against a gemini-cli whose tool registry has not been audited: only the exact
versions in `SHIP_FEATURE_GEMINI_TESTED_VERSIONS` (default `0.26.0`) are accepted, and anything else fails
the seat rather than trusting an unknown registry. Exact, not major.minor — a patch release can add a
tool as easily as a minor one. The version is probed inside the same isolation the review runs in. Model pinned to `gemini-3.1-pro-preview`; override
with `SHIP_FEATURE_GEMINI_MODEL` or `MODEL_gemini` in the shared panel file. **Tradeoff:** because the
run is fully isolated, gemini reviews the plan text only — it has no access to the checkout's files
(deep codebase fact-checking is the PR cross-review's job). The `antigravity` name maps to the `gemini`
CLI **here** but to `agy` in `relay` — only `gemini` has a read-only mode. Bare `opencode` is
relay-only and skipped with a warning. `grok45high` is the old name of the `grok` seat: it still runs
`grok`, with a warning, and its old pins (`MODEL_grok45high`, `GROK45HIGH_REVIEW_MODEL`) are ignored.

`claude` and `codex` take their pins from the same place: `MODEL_claude` / `EFFORT_claude` and
`MODEL_codex` / `EFFORT_codex` in the shared panel file, or `$CLAUDE_REVIEW_MODEL`,
`$CLAUDE_REVIEW_EFFORT`, `$CODEX_REVIEW_MODEL`, `$CODEX_REVIEW_EFFORT` in the environment (which
wins). Unpinned, they get no extra argument and run whatever their CLI is configured for. These ten
pins — claude's, codex's and grok's, and the four pi pins (`PI_GLM_REVIEW_MODEL`, `PI_GLM_REVIEW_EFFORT`,
`PI_GROK_REVIEW_MODEL`, `PI_GROK_REVIEW_EFFORT`) — are read from the shared file and the environment
only — set in ship-feature's own config they are ignored, with a warning.

Reviewers that run in the checkout — `claude`, `codex`, `cursor`, `glm`, `grok`, `pi_glm`, `pi_grok` — can read the
tree, so they check the plan against the code (a stale line number, a test the change would turn red).
`glm` has three states, in this order: it runs in the checkout; it falls back to an isolated empty
directory when the checkout carries its own opencode config (`opencode.json`, `opencode.jsonc`,
`.opencode`), because that config could otherwise reconfigure the reviewer, and it says so above its
output; and it is **skipped entirely** if that isolated directory cannot be created, rather than
running against a tree it cannot vouch for. `grok` needs a working OS sandbox to read the tree:
where one cannot be applied (Linux without bubblewrap) it degrades to an isolated, text-only review and
says so above its output.

What "read-only" means here, precisely: each reviewer is pinned to its CLI's read-only mode and none of
them is given a way to write your checkout or post anywhere. It is not a sandbox escape proof. Except for
`claude --safe-mode` and the pi seats, an in-checkout reviewer loads that checkout's own agent config (`CLAUDE.md`,
`AGENTS.md`, `.cursor`, `.grok`) and whatever hooks or plugins it declares — the same trust you already
extend by opening the repo in that agent. `glm` is in that group too — it reads the checkout. The pi
seats load none of it: `--no-context-files` skips `AGENTS.md` and `CLAUDE.md`, `--no-approve` ignores the
trust-gated `.pi/` files, and no extension runs. Their `read` tool can still open those files as text,
like any other file. Their tools are not confined to the checkout, though: `read`, `grep`, `find` and
`ls` reach any file your user can read, and what they read goes to the model provider (z.ai or xAI), as
a file the codex seat reads goes to OpenAI — `--sandbox read-only` restricts writes, not reads. The review
is printed to your terminal only; nothing posts it. The one seat that never reads the checkout is
`antigravity`/`gemini`, which is fully isolated and sees the plan text only, so review a plan for a
repository you do not trust with that seat, or not at all.
Exit `0` = every reviewer returned a review, `3` = a reviewer failed/timed out/returned empty/answered
without a verdict (re-run — see the two-consecutive-failure rule below), `1` = usage error. The
single-reviewer default still works too:
`cat ~/.config/ship-feature/plans/<repo>-<slug>.md | codex exec --sandbox read-only`.

Read the feedback and revise — but only within the cap below, not without limit. The reviewers catch
wrong assumptions and stale facts before they become code.

**Loop-termination rule.** A plan under review that keeps drawing new objections to each revision can
spin as long as an unreviewed PR can — one real round ran **13 rounds** before the panel agreed, burning
roughly an hour and a quarter on convergence instead of on the plan. Plan-review gets the same discipline
as step 5's cross-review, in its own terms: this is a **plan** under read-only review before any code
exists, not a **PR** under cross-review, so "plan-qualifying" below is a distinct term from step 5's
"qualifying Should-fix" (correctness / safety / deployability / verification) — do not conflate the two.

- **A round** is one `plan-review` invocation where every dispatched reviewer returned a review (exit
  `0`). Exit `3` (a reviewer failed, timed out, returned empty, or answered without a verdict) does
  **not** count as a round — re-run it. If the **same** reviewer hits exit `3` on **two consecutive
  attempts** at the same round, stop retrying that reviewer, drop that reviewer for the round, and
  proceed with the remaining panel — but **tell the human about the reduced panel** before Gate 1,
  the same way a benched reviewer in step 5's initial or closing round is the human's call, not a
  silent substitution. **If dropping the reviewer leaves zero reviewers, that is not a completed
  round at all** — stop and take the failure itself to Gate 1 (a plan nobody reviewed is not "the
  agreed plan").
- **Cap: 1 round.** One round with the full configured panel (`SHIP_FEATURE_PLAN_REVIEWERS`, or a
  `--reviewers` override). Fix each Blocker and each plan-qualifying Should-fix in the plan, then go to
  Gate 1 with the revised plan and a short list of what changed and why. Do not run a second round on
  your own: the human reads the revision at Gate 1, and may ask for one more round there.
- **Plan-qualifying** means: a **Blocker**, or a **Should-fix** saying the plan is wrong about the
  existing tree, unsafe to execute as written, or **materially incomplete** — a missing edge case, an
  unhandled failure mode, or missing verification that would let a broken change ship. A **Nit**, or a
  Should-fix that only expresses a stylistic or approach preference without any of the above, does not
  reopen a round. **Change the plan only for a Blocker or a plan-qualifying Should-fix:** the human reads
  each change at Gate 1 without a second review, so keep them few; a Nit or a non-qualifying Should-fix
  is recorded at Gate 1, not applied.

### 3. 🚦 Gate 1 — human approves the plan
Summarize the plan and **stop**. Bring the plan as revised after its one review round, with a short
list of each finding, how you classified it, and what you changed. Where you disagree with a reviewer,
say so with both positions. The human approves it, asks for one more round, or drops the change. Do not
touch the source repository until the human says go.

### 4. Implement in a worktree, open a PR
- Work in a **git worktree**, never the main working tree. Default root `.claude/worktrees/`, override
  with `SHIP_FEATURE_WORKTREE_ROOT`. Add the worktree marker dir to the repository's `info/exclude` (in a
  linked worktree that's the **common** git dir's exclude, which `ship-feature preflight` checks) so it
  never shows up in anyone's status.
- Branch off the repository's **default branch** (`origin/HEAD`), not a hardcoded name.
- **Stage explicit paths** — never `git add -A`/`git add .` (tools drop stray files).
- **The repository has a pre-push hook that runs the tests, a linter and a formatter check.** It is a
  committed `.githooks/pre-push` with mode `100755`, and `core.hooksPath` is `.githooks` (once per
  clone: `git config core.hooksPath .githooks`). `ship-feature preflight` refuses a worktree whose hook is
  missing, not committed, not executable, changed on disk, or not the file git runs on push. A repo
  without one adds it in its own PR first: commit the hook, then run `preflight`. Read
  `.githooks/pre-push` and the script it calls (for example `bin/ci`), and name in the PR's
  implementation notes the tests, the linter and the formatter check it runs; a hook that lacks one is
  fixed in its own PR first. `preflight` cannot check what the hook runs: that is your reading job.
  Never bypass the hook.
- One coherent change per PR. Ship tests at the level you touched.
- Open the PR.

Run `ship-feature preflight` to assert the working copy is set up correctly before you start.

### 5. Cross-review + tests
Hand the PR to the **other** agents for review, and run the full test suite / CI against the exact PR
head.

```
# Do NOT name the reviewers: `relay` injects your configured quorum. See below.
# ALWAYS pass the plan: reviewers that cannot see the intent can only find bugs.
ship-feature relay --author <self> \
  --context-file ~/.config/ship-feature/plans/<repo>-<slug>.md
```

**Do not pass `--reviewers` here either.** `relay` injects `SHIP_FEATURE_REVIEWERS` when you omit
it — `SHIP_FEATURE_REVIEWERS` and nothing else: from the environment if exported there, else
`~/.config/ship-feature/config`, else your `REVIEWERS` line in `~/.config/pr-review-relay/config` —
so the config is the panel and there is nothing to keep in sync. An **exported** value beats both files — see the Quorum note in §5 — so check the environment first when a round comes back the wrong size. The failure this prevents is quiet: an agent carrying
last month's list runs a smaller panel than the one you configured, every round exits `0`, and the
reviews read as complete. Pass the flag only to override on purpose. And read the startup lines every round: a benched
(out-of-quota) seat is dropped and the run still exits `0`.

**Always pass the plan with `--context-file`.** The plan already exists — §2 wrote it for the plan
review — and the flag prepends it as a document every reviewer must verify the PR *against*.

This is also why §1 insists the plan lives in `~/.config/ship-feature/plans/`: this flag is needed on
every round, so the file has to outlive the session that wrote it. A relay that cannot find its context
file refuses to start, and rewriting the plan at that point is worse than running without one — a plan
authored *after* the code, to check the code against, only ever agrees with it. Without
it a reviewer can find bugs but cannot find **"this is not what we agreed to build"**: the plan
conformance check, the stale count, the rule the implementation quietly skipped. Measured on
`pr-review-relay` #23: same number of findings, different kind, and the first review to open with
"the PR matches the plan" and a conformance checklist.

**The plan file is the source, and it is immutable once approved.** Write and revise it freely before
Gate 1 — that is what step 1 and step 2 are for — and not after. The PR body is generated from it
(`gh pr edit --body-file <the plan>`), never hand-edited, so the two cannot drift. When later rounds
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
- `4` — the round cap was hit. Take the open findings to Gate 2.

**Prove the round wrote nothing: `ship-feature seat-audit`.** A reviewer seat is meant to be
read-only, but for some seats that is only an instruction in the prompt, not a sandbox, and an agent
host that runs seats in-process can give a seat its own write access. Take a snapshot before the
round and check it after:

```
snap="$(mktemp)"                       # outside the work tree, out of the seats' reach
ship-feature seat-audit snapshot --out "$snap"
ship-feature review --author <self> --base origin/<default>    # or relay, or plan-review
ship-feature seat-audit check "$snap"
```

The snapshot records HEAD, every ref, the stash, the worktrees, `git status`, a hash of every tracked
and untracked file, size and mtime of every ignored file, and the git config and hooks. A non-zero
`check` means **the round does not count**, the same as exit `3`: `3` prints what changed, grouped as
local tree, refs, git config and hooks, and PR; `1` means the snapshot was unreadable or a fact could
not be read. Find what wrote, undo it, and re-run the round. Refs are shared by every worktree, so a
commit or fetch in another worktree during the round fails the check too; run it when nothing else
works in the repository. Add `--pr <n> --repo <owner/name>` to record the PR's head, comment count and
review count as well, for a round that posts nothing (`review`, `plan-review`): `relay` posts its own
reviews, so on a relay round the PR always changes.

**Quorum:** set it once — `SHIP_FEATURE_REVIEWERS` in `~/.config/ship-feature/config`, or
`REVIEWERS` in `~/.config/pr-review-relay/config`, not both — and then **do not pass a list on the
command line**.

**The environment wins over both files**, because `load_config` and `load_shared_panel_config` fill
these names only when they are not already defined. So a `SHIP_FEATURE_REVIEWERS` exported in a
shell profile months ago silently decides today's panel, and it is the first place to look when a
round comes back the wrong size. Note the two commands read different names: `relay` uses
`SHIP_FEATURE_REVIEWERS` only, while `plan-review` prefers `SHIP_FEATURE_PLAN_REVIEWERS` and falls
back to it. `relay` injects the configured quorum when you omit `--reviewers`, which is a hard
failure on a missing agent in exactly the way a typed list is, and cannot go stale the way a typed
list does. A partial pass must not read as consensus, so also read each round's startup lines: a
benched (out-of-quota) seat is dropped and the round still exits `0`.

**Loop-termination rule.** Iterating on *every* Should-fix produced eight full-quorum rounds on one
PR where the last five found no Blocker, and a later cap of six rounds still let one change run for
days. The loop is now **two rounds at most** (`--max-rounds 2`):

| round | panel | purpose |
|---|---|---|
| **Initial** — round 1 | full quorum | find everything |
| **Closing** — round 2 | full quorum, on the SHA that will merge | confirm the fixes and the merge candidate |

**A clean initial round IS the closing round.** If round 1 completes with no Blocker and no qualifying
Should-fix, you are done — there is nothing to fix, so the SHA the panel reviewed is already the SHA
that will merge. Do not run a second full quorum to "close" a round that never opened. The closing
round exists only because *fixing* something creates a SHA nobody reviewed in full.

**If the closing round still raises a qualifying finding, do not start another cycle.** Take it to
Gate 2 as an open item; the human merges with it recorded, or sends it to a follow-up change.

- **A round only counts if it completed** — every reviewer **the round was supposed to dispatch**
  produced and posted a review: every configured reviewer except the author. Exit `0` is *not* that
  statement: a **benched** reviewer (out of quota) is
  dropped deliberately and still exits `0`. A benched seat in an **initial or closing** round is a
  decision for the human **before the round**, taken when the relay announces the bench at startup:
  wait for the quota to reset, or authorise the reduced panel explicitly, recorded in the PR thread
  and repeated at Gate 2.
- **Iterate only for a Blocker, or a qualifying Should-fix** — one that is a material problem of
  **correctness, safety, deployability, or verification**. That covers documentation that
  misinstructs, release and deploy configuration, packaging, migrations, portability and API
  contracts; it does not cover wording, structure, or coverage of paths the PR does not touch.
- **The author classifies in writing**, naming the finding and the reason.
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

The round cap (exit `4`) means: stop and take the open findings to Gate 2. It is never permission to
merge, and never grounds for `--reset` or a higher `--max-rounds`.

**Exact-SHA rule:** capture the PR `headRefOid`; require local `HEAD` to equal it before testing; run the
tests; then re-check that the PR head has not moved. CI must check out the PR **head** SHA
(`github.event.pull_request.head.sha`), not the synthetic merge commit, so "green" maps to the reviewed
code.

### 6. 🚦 Gate 2 — human merges
Summarize the state and **stop**. The **human** merges. The agent never self-merges — merge authority
stays with the human.

The summary must state: green on the PR head; each Blocker and qualifying Should-fix either fixed or,
when the round cap stopped the loop, **listed as an open item**; every remaining finding recorded with
its classification; **every disputed classification listed with both positions**; and any reduced
panel that was authorised. The human rules on the open items and the disputes as part of deciding to
merge — merge with them recorded, ask for one more round on a fix, or send them to a follow-up change.

This is still **two** gates, not three: a dispute does not create a new stopping point, it changes
what Gate 2 receives.

### 7. Verify on the merge commit
After the merge, re-run the tests on the merge commit. Red = stop and fix.

### (8. Release — out of scope here)
Releasing to a store / registry is a separate tool's job and is not part of this workflow.

---

## Scope

Single repository, `origin/HEAD` as the base. Multi-repo changes are out of scope — split them into one
PR per repo, each run through this workflow independently.
