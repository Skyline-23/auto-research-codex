# Auto Research Codex

Autonomous experiment-loop skill for OpenAI Codex.

This repository publishes a single skill, `auto-research-codex`, for metric-driven iteration with baseline capture, one commit per experiment, automatic regression discard, and repo-local native-hook persistence.

## Install

Official `skills.sh` flow:

```bash
npx skills add https://github.com/Skyline-23/auto-research-codex -a codex -g -y
```

Fallback if `npx skills` does not resolve correctly in your npm environment:

```bash
npm exec --package=skills@latest -- skills add https://github.com/Skyline-23/auto-research-codex -a codex -g -y
```

## Use

Start the loop from the target repository with a goal, metric command, metric extraction regex, direction, and scope:

```bash
bash scripts/autoresearch_loop.sh setup \
  --goal "Improve build throughput" \
  --metric-command "npm run bench" \
  --metric-regex "score: ([0-9.]+)" \
  --direction higher \
  --in-scope /absolute/path/to/repo/src \
  --out-of-scope /absolute/path/to/repo/dist
```

Inspect or stop:

```bash
bash scripts/autoresearch_loop.sh status
bash scripts/autoresearch_loop.sh stop
bash scripts/autoresearch_loop.sh resume
```

## Notes

- The skill definition lives in [`SKILL.md`](./SKILL.md).
- Native hooks are experimental and intended for macOS/Linux-style environments.
- Results are recorded in `results.tsv`, `run.log`, and `.codex-autoresearch/` in the tracked repository.
