# ship-feature

A gated, multi-agent workflow for shipping any repository change:
**plan → plan-review → implement → cross-review → merge → verify.**
Designed to be driven by Claude, Codex, or Cursor from one canonical `WORKFLOW.md`.

> Bootstrapping. The full contents land via the initial pull request.

Depends on [pr-review-relay](https://github.com/hamen/pr-review-relay) for the cross-review step.
