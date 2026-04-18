---
name: auto-research-codex
description: Run an autonomous experimentation loop for Codex based on github/awesome-copilot autoresearch, adapted to native hooks for persistence. Use when a repo needs repeated measurable experiments with baseline capture, one commit per experiment, automatic discard of regressions, strict scope control, and uninterrupted iteration until stopped.
---

# Auto Research Codex

Use `$auto-research-codex` for metric-driven autonomous experimentation, not for open-ended coding.

This skill is based on the public `awesome-copilot/autoresearch` workflow, but uses Codex native hooks to keep the loop alive between turns.

## Phase 1: Setup

Before the loop starts, collect and confirm every item below. Do not skip any.

1. Goal
   - Ask what the user wants to improve or optimize.
2. Metric
   - Ask for the exact command to run.
   - Ask how to extract one numeric value from the output.
   - Ask whether lower is better or higher is better.
3. Scope
   - Ask which files or directories are in scope.
   - Ask which files or directories are off limits.
4. Constraints
   - Ask for constraints such as test requirements, API stability, no new dependencies, time budget, or memory limits.
5. Experiment budget
   - Ask for a number of experiments or `unlimited`.
6. Simplicity policy
   - Default policy: all else equal, simpler is better.

Summarize the full setup back to the user and wait for confirmation before starting.

## Phase 2: Start the loop

From the skill directory, run:

```bash
bash scripts/autoresearch_loop.sh setup \
  --goal "<goal>" \
  --metric-command "<command>" \
  --metric-regex "<regex>" \
  --direction higher|lower \
  --in-scope <path> \
  --out-of-scope <path> \
  --constraint "<constraint>" \
  --max-experiments <number|unlimited> \
  --simplicity-policy "<policy>"
```

What setup does:

- re-installs this skill's native hook entries automatically
- creates or switches to `autoresearch/YYYYMMDD`
- initializes root-level `results.tsv` and `run.log`
- adds `results.tsv`, `run.log`, and `.codex-autoresearch/` to `.git/info/exclude`
- runs the baseline measurement and records experiment `0`

## Phase 3: Experiment loop

Once active, keep iterating without asking whether to continue.

For each experiment:

1. Think
   - Analyze the current best result and propose one focused hypothesis.
2. Edit
   - Modify only in-scope files.
3. Commit
   - Commit every experiment before the turn ends.
   - Use `experiment: <short description>`.
4. Stop
   - Let the native `Stop` hook measure the result.

The hook enforces the autoresearch protocol:

- baseline is preserved
- every experiment must be committed before evaluation
- out-of-scope changes are rejected
- crashes and parse failures are logged and reverted
- same-or-worse results are discarded with `git reset --hard HEAD~1`
- improvements are kept and become the new best result
- every evaluated experiment is appended to `results.tsv`

## Phase 4: End the loop

End cleanly by either:

- running `bash scripts/autoresearch_loop.sh stop`
- or emitting a line that is exactly `AUTORESEARCH_DONE` only after the result is actually verified

Both paths remove this skill's hook entries automatically.

## Outputs

Repo root:

- `results.tsv`
- `run.log`

Repo-local state:

- `.codex-autoresearch/state.json`

## Key rules

- No experiment without a measurement.
- Commit every experiment before it is evaluated.
- Regressions are not kept unless the user explicitly changes the policy.
- Do not modify off-limits files.
- Do not install new dependencies unless the user approved it.
- Stay autonomous once the loop starts.
