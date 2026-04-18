---
name: auto-research-codex
description: Run a standalone, native-hook-based experiment loop for Codex. Use when a repo needs repeated measurable experiments against one metric command, a bounded edit scope, and automatic continuation through Codex SessionStart, UserPromptSubmit, and Stop hooks without depending on conductor or tmux.
---

# Auto Research Codex

Use `$auto-research-codex` for metric-driven iteration, not for open-ended coding.

## Workflow

1. In the target repo, initialize the experiment:
   - from the skill directory, run `bash scripts/autoresearch_loop.sh setup --goal "<goal>" --metric-command "<command>" --metric-regex "<regex>" --direction higher|lower --scope <path>`
   - setup re-installs this skill's native hook entries automatically
3. Let Codex keep iterating. The hooks inject the current experiment contract on session start and prompt submit, then the `Stop` hook measures the metric and continues the run automatically.
4. Inspect or end the loop with:
   - `bash scripts/autoresearch_loop.sh status`
   - `bash scripts/autoresearch_loop.sh stop`
   - `bash scripts/autoresearch_loop.sh resume`

## Rules

- Require a real metric command and a regex that extracts exactly one numeric value.
- Keep edits inside the declared scopes. The stop hook checks dirty paths before continuing.
- Make one bounded experiment per turn. The hook appends one line per measured fingerprint to `.codex-autoresearch/results.tsv`.
- End cleanly by either running the stop command or emitting a line that is exactly `AUTORESEARCH_DONE` only after the result is actually verified. Both paths remove this skill's hook entries automatically.
- Treat hooks as experimental and unavailable on Windows.

## Outputs

The loop writes repo-local state under `.codex-autoresearch/`:

- `state.json`
- `results.tsv`
- `run.log`

The setup command also creates or switches to `feat/autoresearch-YYYYMMDD` and adds `.codex-autoresearch/` to `.git/info/exclude`.
