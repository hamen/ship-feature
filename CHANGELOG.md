# Changelog

All notable changes to **ship-feature** are documented here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`review-local --context-file <path>`, so `ship-feature review --context-file <plan>` works.** The
  relay has the flag; `review-local`, which `ship-feature review` runs, rejected it as
  an unknown argument, so a plan never reached a panel that reviews a branch with no PR. The flag
  prepends the document to every seat's prompt, once, with the relay's own `## Provided context`
  preamble: at the head of the prompt for claude, codex, qwen, cursor and antigravity, and as the
  context argument of the opencode, grok and pi helpers. A missing or unreadable file is exit 1
  before any seat starts. `review-local` still gives claude, codex and qwen the prompt as one argv string (and
  antigravity the prompt and the diff), so those four now have the relay's argv guard: a prompt over
  122880 bytes refuses the seat with a named reason on stderr, and the round exits 3, where exec
  used to fail with a bare exit 126. Fizzy #1429.

### Changed

- **ship-feature reads the shared panel config with the relay's own parser.** `bin/ship-feature`
  sources `relay/lib-panel.sh` and `relay/lib-pi.sh` from its own checkout, through the
  `~/.local/bin` link, and drops its second parser of `~/.config/pr-review-relay/config` and its copy
  of the pi json reader: about 125 fewer lines. One parser gives one meaning: an inline `# ...` in
  that file is now part of the value in ship-feature too, as it always was in the relay. A copy of
  `bin/ship-feature` with no `relay/` next to it stops with a message. Fizzy #1412.
- **`bin/ci` lints and formats `relay/` too.** The relay never ran shellcheck or shfmt. One commit
  holds the shfmt output only (listed in `.git-blame-ignore-revs`); a second one fixes what
  shellcheck reported. Most fixes change no behaviour: shell and source directives, `''` for empty
  values, three disables that say why, and removed variables that nothing read
  (`PANEL_CONFIG_PATH`, `cfg_key`, `dl`). One does:
  `pr-review-consensus` no longer runs a `gh repo view` whose answer it never used. Fizzy #1412.

### Removed

- **`pr-review-relay --verdict-file`**: the machine-readable round record, written only for
  autonomous mode's merge gate. Autonomous mode is gone and nothing else reads it. The review
  prompts no longer ask for a `VERDICT:` line; a review that still ends with `VERDICT: clean` counts
  as an approval, as before. `relay/test/test-verdict.sh` and its golden prompt capture go with it;
  a last run of that capture against this change matched byte for byte, so a round without the flag
  sends the same prompts as before. Its two exit-handler checks (a signal still kills the relay, the
  trap is armed before the attachments directory) move to `test-fail-closed.sh`.

### Fixed

- **OpenCode v2 (`@opencode/cli` 2.x) failed both opencode seats.** v2 has no `--pure`, so the
  relay's `opencode` seat and plan-review's `glm` seat stopped on every round. Dropping the flag was
  not enough: v2's `run` goes to a shared background server that ignores the seat's env, policy
  included, and the user's plugins still load. Both seats now read `opencode --help`: `--pure`
  means v1 and runs as before; `--standalone` means v2 and runs `run --standalone` with
  `OPENCODE_CONFIG_DIR` pointed at an empty private dir, which keeps plugins out. A CLI with
  neither flag fails with "has neither --pure (v1) nor --standalone (v2) … Upgrade OpenCode". On
  v2 the relay seat needs `PR_RELAY_OPENCODE_MODEL` (or `MODEL_opencode`): the empty dir hides
  your default model and custom providers. The upgrade hint now names 1.3.4, the first v1 release
  with `--pure`.
- **The pi seats run on a Node that meets pi's floor, not on the reviewed repo's pinned Node.** pi's
  launcher starts through `env node`, and both the relay and `plan-review` run pi inside the checkout,
  where mise puts that repo's pinned Node first. A repo pinned to Node 20 crashed both pi seats at
  startup (`does not provide an export named 'enableCompileCache'`), and the round did not count.
  `pi_resolve_node` (`relay/lib-pi.sh`) keeps the PATH node when it meets `PI_NODE_MIN` (22.19.0,
  pi 1.2.0's `engines.node`), else takes the newest mise-installed node that does, never one inside
  the checkout under review; pi and its json reader both run on it. Each candidate is asked for its
  version and its real executable, and the seat runs that executable: a mise shim answers for the cwd
  it runs in, and pi runs from another one. With none, the seat fails before the model call and names
  every version it found.

- **`pr-review-relay --context-file` with an unreadable file posted a clean round.** A file that
  exists but cannot be read passed the `-f` check; `cat` failed inside the preamble's command
  substitution, so every seat reviewed the preamble with an empty plan, and the round could post
  and exit `0` ("clean: 2/2 posted" in the test). The read is now its own step: "context file not
  readable", exit 1, logged, before any seat starts. The same fix went into `review-local` in
  #1429. Also: the preamble lost its trailing blank line to `$(...)`, so every prompt ran on as
  `---You are reviewing …`; the blank line is back.
- **An OpenCode CLI without `--pure` failed the `opencode` seat with no reason.** On such a CLI
  (seen with 1.2.27), `opencode --pure run …` prints the top-level help and exits `0`, so the
  non-review gate rejected every round and nothing named the CLI. The seat of `pr-review-relay` and
  `review-local` now checks that `opencode --help` lists `--pure` before it runs, with the same
  isolation as the run, and fails with "opencode 1.2.27 has no --pure flag … Upgrade OpenCode".
  A `--help` that fails or hangs gets its own message (its exit code and error, or a timeout),
  never the upgrade advice. The probe finds `--pure` in other help layouts too (`-p, --pure`,
  colour). The review run never starts when the probe fails. Issue #38.
- **A plan-review seat that did not review could still count as a review.** `plan-review` failed a
  seat only on an empty answer, so "Reading the plan before reviewing." made a clean round. It now
  runs the relay's gate (`review_looks_like_a_review` in `relay/lib-panel.sh`), as `pr-review-relay`
  and `review-local` do: an answer must name a severity (Blocker / Should-fix / Nit) or say that it
  looks good, and its last sentence must not announce more reading. A rejected answer is shown with
  a label, never under the review banner, and the round exits `3`. Fizzy #1412.
- **A clean "No issues found" did not count as a review.** The gate knew "no findings", "none
  found" and "looks good", but not "no issues": on 2026-10-16 pi_grok answered exactly
  "No issues found" twice, the gate called it "not a review", and the round ran with two of three
  seats. `no issues` and `no issue` are now approval phrases, in all three callers. A "No issues
  found so far. Let me read the rest." is still a stall. Fizzy #1421.

## [0.7.0] — 2026-10-16

### Added

- **pr-review-relay is part of ship-feature now**, in `relay/`, imported as one commit from
  pr-review-relay 9fc675d; the older history stays in
  [hamen/pr-review-relay](https://github.com/hamen/pr-review-relay). `install.sh` links
  `review-local`, `pr-review-relay`, `pr-review-fetch`, `pr-review-distill`,
  `pr-review-collapse-comments`, `pr-review-consensus` and `wrap-collapsed-pr-comment.mjs` from
  `relay/` into `~/.local/bin`, so one clone and one install give the whole workflow. `ship-feature
  review` is the light lane's review step, a pass-through to `review-local` with the exact exit
  code. `bin/ci` runs `relay/bin/ci` as a new last stage; `relay/` is syntax-checked but stays out
  of shellcheck and shfmt until a commit of pure tool output brings it in. The relay's own pre-push
  hook and its test suite go: ship-feature's hook guards the repository. The commands, flags, exit
  codes and `~/.config/pr-review-relay/config` do not change. [`relay/CHANGELOG.md`](relay/CHANGELOG.md) is the closed
  history of the old repo, with its last unreleased changes; relay changes are recorded here.

- **Two lanes; the light lane is the default.** A change that is not risky skips the plan, the plan
  review, the PR and the human merge: one review round by the configured panel on the branch diff
  (`review-local`), then `ship-feature land`. The careful lane (payments, consent, auth, migrations,
  security, store policy) keeps the gated pipeline with low caps: one plan-review round, at most two
  cross-review rounds, no narrow rounds, and the open findings go to Gate 2 instead of another cycle.
  The adapters now summarise the lanes and point at `WORKFLOW.md` for the details, and the suite checks
  those details in `WORKFLOW.md` only. Why: with caps of six rounds the loop did not converge, and one
  fix could take days.

- **`ship-feature land [-m <message>]...`.** The light lane's merge, with no PR: from inside the
  feature worktree it merges the branch (`--no-ff`) onto a freshly fetched default branch, checks that
  merge out and pushes it, so the pre-push hook tests the exact tree that lands. Every failure (a
  conflict, a refused hook, a moved default branch) leaves the remote as it was and returns to the
  branch.

- **Plan-review seats `pi_glm` and `pi_grok`, on the `pi` runner.** One `pi` binary, one model each:
  `zai/glm-5.3` and `xai/grok-4.7`, both at `low` effort by default. They are pinned by the relay's own
  keys, `MODEL_pi_glm` / `EFFORT_pi_glm` and `MODEL_pi_grok` / `EFFORT_pi_grok` in
  `~/.config/pr-review-relay/config` or `PI_GLM_REVIEW_*` / `PI_GROK_REVIEW_*` in the environment (never
  ship-feature's own config, where they are reported and ignored). They run in the checkout, read-only by
  the tool allowlist `--tools read,grep,find,ls`, with no extensions, MCP, skills, prompt templates,
  themes, context files, trust-gated `.pi/` files, saved session or startup network calls. An effort
  outside `off minimal low medium high xhigh max` stops the command, because pi runs an unknown level at
  the user's own setting instead of refusing it. The seat needs `node` to read pi's json stream (a copy
  of pr-review-relay's lib-pi.sh reader). Residual risk, in `WORKFLOW.md` §2: the tools can read any file
  the user can, and what they read goes to the model provider. To switch the plan panel:
  `PLAN_REVIEWERS=codex,pi_glm,pi_grok` in the shared file. Fizzy #1401.

- **ship-feature has its own pre-push hook and `bin/ci`.** `.githooks/pre-push` (the app-tools
  portfolio template, plus a refusal of tracked files marked assume-unchanged or skip-worktree, which
  `git diff` cannot see) runs `bin/ci` on every push: `bash -n`, `shellcheck -S warning`, `shfmt -i 2 -ci
  -d` on every tracked shell file, the leak scan, then the suite. `shellcheck` 0.11.0 and `shfmt` 3.14.1
  are pinned in `mise.toml`, and `bin/ci` refuses any other version. CI runs the same `bin/ci` on ubuntu
  and macOS. The existing code got its 19 shellcheck warnings fixed and one reformat commit (tool output
  only, listed in `.git-blame-ignore-revs`). Once per clone: `git config core.hooksPath .githooks`.
  Fizzy #1370.

### Changed

- **The Codex block and the Cursor rule are pointers to the skill.** Both were full copies of the
  lanes, so every rule change had to be made in four files, and the copy that is always loaded could
  drift from the skill. Now they name `~/.agents/skills/ship-feature/SKILL.md` and `WORKFLOW.md`, say
  to stop when neither exists, and keep one rule: careful-lane changes (payments, consent, auth,
  migrations, security, store policy) are merged by a human, never by the agent. The Cursor rule is
  `alwaysApply: true`, since a pointer costs nothing to load. The lane rules are checked in the skill
  and `WORKFLOW.md`; new checks keep each pointer a pointer (it names both files, keeps the human
  merge, and does not restate the lane steps).

- **Every repo needs a committed `.githooks/pre-push`, and the tool checks it.** `preflight` refuses a
  worktree whose `.githooks/pre-push` is missing, not committed with mode `100755`, not executable,
  changed on disk or in the index, or not the file git runs on push (`core.hooksPath` must resolve to
  it; the fix is `git config core.hooksPath .githooks`). No flag or variable skips it. WORKFLOW step 4:
  the hook runs the tests, a linter and a formatter check; the agent reads it and names those checks in
  the PR's implementation notes. Fizzy #1370.

### Removed

- **Autonomous mode** (`plan-consensus`, `relay --autonomous`, `merge-gate`), added earlier in this
  cycle and never in a release. The light lane replaces it: one review round, then `ship-feature land`
  for the agent's own work, and the careful lane keeps a human at the merge. The three commands now stop
  with a message that names the change. Leftover state in `~/.local/state/ship-feature/autonomous` is
  no longer read and can be deleted.

### Fixed

- **Codex never loaded the ship-feature skill.** `install.sh` made `~/.agents/skills/ship-feature` a
  real directory holding only a `SKILL.md` symlink, and Codex skips a `SKILL.md` that is a symlink to a
  file (measured with `codex exec`; every other harness that reads `~/.agents/skills` loaded it). The
  skill directory is now the link. The installer removes the old layout without a backup, because a
  backup in the skills directory loads as a second `ship-feature`. Cursor, Antigravity and Junie read
  only their own skills directory, so they now get a link there: Cursor always, as it always gets the
  Cursor rule; Antigravity (`~/.gemini/config/skills`, its global root, measured with `agy -p`) and
  Junie only when the tool is installed.

- **A reviewer that did not review could still count as a review.** `pr-review-relay` and
  `review-local` failed closed only on an EMPTY answer, so any text at all was that seat's verdict
  and the round exited `0`. Measured on 2026-09-01: four answers of 156–246 bytes ("Reading the rest
  of the diff before reviewing.", a leaked tool-call fragment), all exit `0`, all posted, none a
  review. With one reviewer in the light lane, such an answer means the change landed unreviewed.
  An answer must now name a severity (Blocker / Should-fix / Nit) or say it looks good, and its
  closing sentence must not announce work still to come. A rejected answer is not posted, is printed
  in full on stderr, and fails the round with `3`. `relay/README.md` ("What counts as a review") has
  the rules and the known limits. Ported from the open pr-review-relay PR #38, which went through
  eight review rounds; `VERDICT: clean` also counts as an approval, and an echo of the
  `--verdict-file` rules does not count as a verdict.

- **A `.git` directory that is not a repository could become "the repository being reviewed", and
  the relay then refused to start.** `relay_worktree_root` accepted any existing `.git` and kept the
  outermost match, so a directory that holds only `info/exclude` (Claude Code creates one at the top
  of a projects directory, to keep `.claude/` out of every project's status) made a whole tree of
  unrelated repositories look like one. Every `PATH` entry symlinked into that tree, such as a skill
  `bin` under `~/.claude/skills/`, was then "inside the repository", and the `PATH` guard refused the
  run. A `.git` directory must now contain a `HEAD` file. A `.git` that is not a directory (a linked
  worktree, a submodule) is accepted as before, and a `.git` directory that cannot be searched still
  counts as a repository, so the guard never turns itself off. The fix is in `lib-opencode.sh`, so
  `review-local` and `pr-review-distill` get it too. Ported from the open pr-review-relay PR #39
  (three review rounds, no Blockers at the end).

## [0.6.0] — 2026-09-25

### Changed

- **plan-review honours model and effort pins for `claude`, `codex` and `grok` — and `grok45high` is
  now `grok`.** `~/.config/pr-review-relay/config` is meant to be the one place a seat's model and
  effort are pinned, but plan-review ignored it for three seats: `claude -p` and `codex exec` ran
  bare (codex on whatever `~/.codex/config.toml` said), and `grok45high` had `--reasoning-effort
  high` hardcoded, so no key could set it. Now:

  | seat | shared keys | environment (wins) | unpinned |
  |---|---|---|---|
  | `claude` | `MODEL_claude`, `EFFORT_claude` → `--model`, `--effort` | `CLAUDE_REVIEW_MODEL`, `CLAUDE_REVIEW_EFFORT` | no extra argument (as before) |
  | `codex` | `MODEL_codex`, `EFFORT_codex` → `-m`, `-c model_reasoning_effort="…"` | `CODEX_REVIEW_MODEL`, `CODEX_REVIEW_EFFORT` | no extra argument (as before) |
  | `grok` | `MODEL_grok`, `EFFORT_grok` → `-m`, `--reasoning-effort` | `GROK_REVIEW_MODEL`, `GROK_REVIEW_EFFORT` | `grok-4.6`, **`medium`** (was a hardcoded `high`) |

  These are the relay's own keys and environment names, so one line pins the seat for the plan
  review and the PR review alike. They are read from the shared file and the environment only — set
  in `~/.config/ship-feature/config` they are ignored with a warning — and they are not exported,
  so `ship-feature relay` behaves exactly as before. A model starting with `-`, or an effort that is
  not a bare word, stops the run before any reviewer starts. Each seat's dispatch line now prints
  the model and effort it resolved to (`→ grok reviewing… (model=grok-4.7, effort=medium)`).

  **The seat rename.** A seat called `grok45high` running at medium effort would lie twice — the
  `kimi3` problem again. Plan-review's grok seat is now bare `grok`, the same seat the relay runs:

  | old | new | what happens now |
  |---|---|---|
  | `grok45high` in any reviewer list | `grok` | runs `grok`, with one warning per run |
  | `GROK45HIGH_REVIEW_MODEL` (environment or `~/.config/ship-feature/config`) | `GROK_REVIEW_MODEL` / `MODEL_grok` | warned, ignored — and a stale export no longer blocks `MODEL_grok` |
  | `MODEL_grok45high` (`~/.config/pr-review-relay/config`) | `MODEL_grok` | warned, ignored |

  **Behaviour change on pull:** bare `grok` is no longer relay-only in plan-review. A plan panel that
  falls back to `REVIEWERS` containing `grok` now **runs** it — and, by the quorum rule, now
  **fails the round (exit 3) if the `grok` CLI is not installed**, where it used to be skipped with
  a warning. Update `PLAN_REVIEWERS` (`grok45high` → `grok`) and delete `MODEL_grok45high`.

- **BREAKING — the plan-review seat `kimi3` is now `glm`.** The old name was a lie and had been one
  since 2026-08-11: the seat is the **opencode runner pinned read-only**, and which model sits on it
  is one config line. It ran GLM 5.2 for a week, then Kimi K3, then GLM 5.3, while the panel header
  kept naming a model that had not reviewed anything.

  What forced the rename into code rather than config: renaming the key in a config file alone
  **silently downgraded the seat**. `MODEL_glm` matched no case arm in `load_shared_panel_config`,
  was dropped without a word, and the seat fell back to its built-in default — exit 0, no warning,
  a plan reviewed by a different model than the config named.

  Every old spelling is now loud. None is silently honoured:

  | old | new | what happens now |
  |---|---|---|
  | `kimi3` in **any** reviewer list — `--reviewers`, `SHIP_FEATURE_PLAN_REVIEWERS`, `SHIP_FEATURE_REVIEWERS`, or `PLAN_REVIEWERS` / `REVIEWERS` in `~/.config/pr-review-relay/config` | `glm` | unknown reviewer — the round **fails** rather than passing on a thinned panel |
  | `KIMI3_REVIEW_MODEL` (environment) | `GLM_REVIEW_MODEL` | warned, ignored |
  | `KIMI3_REVIEW_MODEL` (`~/.config/ship-feature/config`) | `GLM_REVIEW_MODEL` | warned, ignored |
  | `MODEL_kimi3` (`~/.config/pr-review-relay/config`) | `MODEL_glm` | warned, ignored |

  The warnings are printed by `plan-review` only — never by `relay` or `preflight`, which also load
  config and have no business reporting a plan-review seat.

- **BREAKING — this seat's default model is now `opencode-go/glm-5.3`** (was `opencode-go/kimi-k3`).
  Same bundled OpenCode Go tier, so nothing new needs paying for. This affects users who have **no**
  stale spelling to be warned about: if you never pinned this seat, it changes model. Pin
  `GLM_REVIEW_MODEL` to keep Kimi K3. A seat named `glm` that defaulted to a Moonshot model would
  have rebuilt the exact defect the rename removes.

- Corrected four long-standing false statements about this seat in `README.md` and `WORKFLOW.md`.
  They said it runs isolated, outside the checkout; it has read the checkout since v0.5.0, and the
  test suite has asserted so for as long. The docs now describe its three real states: it runs in
  the checkout; it falls back to an isolated empty directory when the checkout carries its own
  opencode config; and it is skipped entirely, fail-closed, if that directory cannot be created.

  Note for anyone who followed the old advice to "review a plan for a repository you do not trust
  with `kimi3`": that was wrong. The fully isolated seat is `antigravity`/`gemini`.

- **Transitional noise, now gone:** `pr-review-relay` listed `kimi3` but not `glm` among its own
  `PANEL_SEATS`, so a `MODEL_glm` key printed one `warning: no reviewer seat named 'glm'` line per
  run. It was cosmetic — the relay never read this key — and **pr-review-relay v1.7.0** lists `glm`
  (and `gemini`). Upgrade both together.

- **Every adapter and WORKFLOW.md now say to run `relay` and `plan-review` WITHOUT `--reviewers`.**
  They used to say the opposite — "name the reviewers you have — the quorum — so a missing one
  fails rather than thinning the panel" — and that advice makes the cross-review quietly weaker.
  `relay` already injects `SHIP_FEATURE_REVIEWERS`, and `plan-review` already falls back to
  `SHIP_FEATURE_PLAN_REVIEWERS` then `SHIP_FEATURE_REVIEWERS`, all filled from
  `~/.config/pr-review-relay/config`. A list typed into a command is a copy of that file that stops
  being true the day a seat is added, and nothing announces the difference: the round comes back
  smaller and reads as complete. That happened on three PRs in one day before this change.
  `--reviewers` is unchanged and stays the way to override — including for the narrow rounds 2+,
  where a deliberate subset is the point.
- The docs now also say to **read each round's startup lines** and state which reviewers actually
  ran. Omitting the flag fixes a stale list; it cannot tell you a seat dropped out. `relay` drops a
  benched (out-of-quota) seat and still exits `0`, and `plan-review` skips the relay-only names
  (bare `opencode`, and — until the rename above made it a plan seat — bare `grok`) with a warning
  and still exits `0`.

Touches `adapters/{skill,cursor,codex}`, `WORKFLOW.md`, `README.md`, `config.example` and the
adapter-consistency clauses in `test/`. Documentation only — no change to `bin/ship-feature`. **Re-run `./install.sh`**: the Codex adapter
is copied into `~/.codex/AGENTS.md`, not symlinked like the Cursor and skill adapters, so a `git
pull` alone leaves Codex reading the old advice.

## [0.5.0] — 2026-08-27

### Added

- **`antigravity` (aliases `agy`, `gemini`) is now a read-only reviewer in `ship-feature plan-review`.**
  It runs the `gemini` CLI **fail-closed**: an isolated `GEMINI_CLI_HOME` **and** working dir with a
  locked `.gemini/settings.json` that **allowlists only the read-only tools** via `tools.core`
  (`read_file`, `read_many_files`, `glob`, `search_file_content`, `list_directory`), with
  `tools.exclude` naming today's known write tools as extra defence-in-depth. It also disables hooks
  (`hooksConfig.enabled:false`, so no `SessionStart` shell) and declares no MCP. All four gemini
  settings scopes are redirected to controlled files (user via `GEMINI_CLI_HOME`, workspace via the
  CWD, system + system-defaults via `GEMINI_CLI_SYSTEM_SETTINGS_PATH` /
  `GEMINI_CLI_SYSTEM_DEFAULTS_PATH`), so **neither the user's real `~/.gemini`, nor a reviewed
  checkout's `.gemini/`, nor `/etc/gemini-cli` contributes any `mcpServers`, hooks, or
  `tools.allowed`** — closing the shallow-merge hole where a `mcpServers:{}` override would still leave
  global MCP servers loaded. `GEMINI_CLI_HOME` and the workspace are **separate sibling dirs**, so the
  copied OAuth creds live outside the workspace and the allowlisted `read_file` can't disclose them.
  `XDG_CONFIG_HOME` is unset for the run, and a controlled empty `.gemini/.env` halts gemini's ancestor
  `.env` walk (so a hostile `/tmp/.env` can't inject a `CODE_ASSIST_ENDPOINT` / base-URL override).
  Auth: an explicit environment method — `GEMINI_API_KEY`, or Vertex, which needs **both**
  `GOOGLE_GENAI_USE_VERTEXAI=true` and its own credentials — is preferred; only when none is set does it
  fall back to the user's OAuth creds (copied in, with `GOOGLE_GENAI_USE_GCA=true`) so a stale
  `~/.gemini` can't override a valid API key. Note that `GOOGLE_API_KEY` **alone** selects no auth
  method in gemini-cli v0.26.0, so it is not treated as one. Default non-interactive mode and `-e none`
  (extensions off) are layered on top. `--approval-mode plan` is **not** used: in gemini-cli v0.26.0 it
  throws unless `experimental.plan` is enabled. **Tradeoff:** the isolated run sees only the plan text,
  not the checkout's files (deep codebase fact-checking is the PR cross-review's job).
- **A fail-closed version gate for that seat, via `SHIP_FEATURE_GEMINI_TESTED_VERSIONS`** (default
  `0.26.0`). `tools.core` is an allowlist, but **not a universal one**: gemini-cli registers some tools
  outside the core-tool filter — `delegate_to_agent` in v0.26.0 — and for those the `tools.exclude`
  blocklist is the only control. A future release that registered another write-capable tool the same
  way would pass both controls while the seat went on advertising a guarantee it no longer had. There
  is no CLI call that dumps the active tool registry, so the seat now runs only against a gemini-cli
  whose registry has actually been audited, and **fails the seat otherwise** rather than assuming.
  The match is on the **exact** version, not major.minor: a patch release can add a tool as easily as
  a minor one. The version is probed **inside the same isolation** the review runs in — `gemini
  --version` is still gemini starting up, and probing it on the caller's environment would run the
  very configuration this seat exists to neutralise, before the gate meant to guard it was evaluated.
  Widening the gate is deliberate: audit the new release's tools, then add its exact version.
- **`SHIP_FEATURE_GEMINI_MODEL`** (environment or `~/.config/ship-feature/config`), and **`MODEL_gemini`**
  in the shared `~/.config/pr-review-relay/config`, pin the model for that reviewer. Default
  `gemini-3.1-pro-preview`, because the CLI's own built-in default is a retired model that 404s. The
  key is `MODEL_gemini`, not `MODEL_antigravity`: the relay already maps `MODEL_antigravity` onto its
  own `agy` seat, and the two seats are different binaries that accept different model ids — the same
  reason `MODEL_grok` and `MODEL_grok45high` stay apart.

### Changed

- **`agy` is no longer relay-only in `plan-review`.** It (and `gemini`) now alias the read-only
  `antigravity` reviewer above. Only bare `opencode` and bare `grok` remain relay-only.
  **Behavior change:** a panel that lists `antigravity` now **requires** the `gemini` CLI at the plan
  gate — where it used to be skipped with a warning, a missing `gemini` binary now **fails the quorum**
  (exit `3`), so a review can't silently pass on a thinned panel.


- **The per-reviewer timeout comes from the same file as the rest of the panel, and defaults to
  500s.** `AGENT_TIMEOUT` in `~/.config/pr-review-relay/config` was the one panel key ship-feature
  did not read: the resolver consulted the environment and stopped, so that file configured
  `pr-review-relay` and left every plan review on the old default. Setting it produced no error and
  no effect. A timed-out reviewer exits `3` and prints a diagnostic, but the round returns **no
  findings**, which on the page is indistinguishable from a clean plan. One session lost three
  consecutive `grok45high` attempts to a 300s clock on a plan whose only fault was being thorough.

  Resolution is now a five-rung ladder, highest first: `SHIP_FEATURE_PLAN_TIMEOUT` in the
  environment, then in `~/.config/ship-feature/config` (new — it was environment-only, alone among
  the `SHIP_FEATURE_*` keys, which is why writing it there did nothing), then
  `PR_RELAY_AGENT_TIMEOUT` in the environment, then `AGENT_TIMEOUT` in pr-review-relay's config,
  then `500`. Rung 3 is not decorative: without it a machine exporting `PR_RELAY_AGENT_TIMEOUT`
  gets that value in the relay and the shared file's value here — the same inputs, two timeouts.

  `load_shared_model_pins` is renamed `load_shared_panel_config`. It stopped being only about model
  pins when `REVIEWERS` and `PLAN_REVIEWERS` moved into it, and a name that lies is how the next key
  ends up in a fourth place.

- **The whole panel can live in one file.** On top of the model pins, `REVIEWERS` and
  `PLAN_REVIEWERS` from `~/.config/pr-review-relay/config` are read as the fallback for
  `SHIP_FEATURE_REVIEWERS` and `SHIP_FEATURE_PLAN_REVIEWERS`. They were duplicated across the two
  configs — identical until the day they are not, with nothing to notice, because both files are
  valid. A panel that differs between the plan gate and the PR gate is something you find out from
  a verdict.
- **ship-feature reads pr-review-relay's config as the shared source for model pins.** Its
  seat-named keys (`MODEL_kimi3`, `MODEL_cursor`, `MODEL_grok45high`) are the last fallback, below
  the environment and below ship-feature's own config. Both tools drive the same seats on the same
  accounts, so which model a seat runs belongs to the machine rather than to whichever tool is
  invoking it — and a pin kept in two files drifts silently, because both are valid config.
  `MODEL_opencode` is deliberately not mapped: that seat is the relay's own.
- **The config file now carries the model pins**, not just the seats. `KIMI3_REVIEW_MODEL`,
  `CURSOR_REVIEW_MODEL`, `GROK45HIGH_REVIEW_MODEL` and `PR_RELAY_OPENCODE_MODEL` are read from
  `~/.config/ship-feature/config` with the usual precedence — the environment still wins, the file
  fills in. They keep their vendor-shaped names because `pr-review-relay` reads two of them as well,
  and they are **exported** when read, so that child process actually sees them.

  Previously the panel was split across two files: who sits on it in the config, what each seat
  actually ran in the shell profile. A seat and its model could drift apart, and a run with no
  profile loaded (cron, a fresh machine, a container) silently fell back to the bundled default
  while the panel looked unchanged.

### Fixed

- **The macOS CI job has been failing since 2026-08-15, for a reason that had nothing to do with the
  code it was reporting on.** Four `sf_clause` adapter-consistency patterns used `.{0,300}` and
  `.{0,400}`. BSD grep — which is what macOS runs — refuses an interval above 255 outright:
  `grep: maximum repetition exceeds 255`, after which `grep -q` exits non-zero exactly as it would
  for a genuine miss. So the suite reported those clauses as *missing from every adapter*, on macOS
  only, while GNU grep on Linux matched them happily.

  That is the worst shape a failure can take. It names the wrong cause — it sends the reader looking
  for documentation drift that never happened — and it is invisible on the machine the tests get
  written on. Eleven days of merges to `main` went in over a red macOS job.

  The intervals are now concatenated (`.{0,200}.{0,200}`) rather than lowered, so the distance each
  clause allows between its anchors is unchanged; these clauses exist to catch a rule going missing
  from prose that is free to reflow, and narrowing the span would quietly weaken them.

  A check enforces the cap on this file itself, so the rule cannot drift from the clauses it governs.
  It skips comment lines, because the paragraph explaining the rule names the bad interval as its
  example, and a guard that fails on its own description teaches people to delete the description.

- **The `kimi3` plan-review seat reads the checkout it reviews.** It ran in an empty directory
  outside any checkout, so it had nothing to read: the model spent its turn hunting for the repo,
  hit an auto-rejected `external_directory` request, and returned an empty review. It now runs in
  the checkout like the other reviewers, and falls back to the isolated directory — announcing it —
  only when the checkout carries its own opencode config, so the tree being reviewed can never
  reconfigure the reviewer reading it. `external_directory`, `task`, `webfetch`, `websearch` and
  `lsp` are denied, and `OPENCODE_CONFIG_DIR` is unset alongside `OPENCODE_CONFIG`.

### Notes

- The `antigravity` name maps to two different binaries by command: the `gemini` CLI in `plan-review`
  (the only Gemini binary with a read-only mode) and `agy` in `relay` (unchanged). The `plan-review`
  isolation is stronger than a pure `--safe-mode`: it neutralizes both the reviewed *checkout's* config
  and the user's own global `~/.gemini` (via `GEMINI_CLI_HOME`), at the cost of the reviewer not seeing
  the checkout's files.
- Because `tools.core` is an allowlist, a future gemini-cli release that adds a new read-only tool will
  have it disabled until it is added to `GEMINI_LOCKED_SETTINGS` in `bin/ship-feature` — the safe
  direction (a new *write* tool is disabled automatically; only new *read* conveniences need a manual
  opt-in).

## [0.4.0] — 2026-08-13

### Added

- **`GROK45HIGH_REVIEW_MODEL`** overrides the `grok45high` plan-review reviewer's model (default bumped
  to `grok-4.6`, xAI released it 2026-08-12) — same env-only override pattern as `CURSOR_REVIEW_MODEL`
  and `KIMI3_REVIEW_MODEL`, so `grok45high` can be pinned to a different Grok version without a code
  change when the next one ships.
- **`KIMI3_REVIEW_MODEL`** overrides the `kimi3` plan-review reviewer's model (default
  `opencode-go/kimi-k3`, the bundled OpenCode Go tier) — same env-only override pattern as
  `CURSOR_REVIEW_MODEL`, so `kimi3` can be pointed at a pay-as-you-go model (e.g. an OpenRouter id)
  without a code change.

### Fixed

- **`ship-feature help` no longer truncates itself when the header grows.** It printed a hardcoded
  line range (`sed -n '2,15p'`), so documenting a new flag in the file header cut the output off
  mid-sentence and dropped the last command from the list. It now prints the header comment block up
  to the first non-comment line. There were no tests for `help` at all; there are now.

### Changed

- **`plan-review` now runs the panel in parallel by default**, with `--sequential` as the opt-out
  (`--parallel` is kept, and now only re-asserts the default, so existing callers keep working; if
  both flags are passed the last one wins). The reviewers are independent, so
  sequencing them bought nothing and multiplied the per-reviewer timeout by the panel size: a four-seat
  panel at the standard 300s cap could sit for twenty minutes before printing a verdict, and a real
  session lost two of those seats to timeouts before the third had even started. Parallel was already
  implemented and already correct — reviews and diagnostics are buffered per reviewer and emitted in
  panel order after the barrier, so nothing interleaves — it just had to be asked for by name, which
  meant remembering it. `--sequential` remains useful when you want to watch one reviewer work, or to
  keep concurrent agent load down.
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

[0.7.0]: https://github.com/hamen/ship-feature/releases/tag/v0.7.0
[0.6.0]: https://github.com/hamen/ship-feature/releases/tag/v0.6.0
[0.5.0]: https://github.com/hamen/ship-feature/releases/tag/v0.5.0
[0.4.0]: https://github.com/hamen/ship-feature/releases/tag/v0.4.0
[0.3.0]: https://github.com/hamen/ship-feature/releases/tag/v0.3.0
[0.2.0]: https://github.com/hamen/ship-feature/releases/tag/v0.2.0
[0.1.0]: https://github.com/hamen/ship-feature/releases/tag/v0.1.0
