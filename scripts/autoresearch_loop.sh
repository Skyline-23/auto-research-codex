#!/usr/bin/env bash
set -euo pipefail

command_name="${1:-}"
if [[ -z "$command_name" ]]; then
  echo "usage: autoresearch_loop.sh <setup|status|stop|resume|reset> [args]" >&2
  exit 1
fi
shift

repo_root() {
  git rev-parse --show-toplevel
}

state_dir() {
  printf '%s/.codex-autoresearch\n' "$(repo_root)"
}

state_file() {
  printf '%s/state.json\n' "$(state_dir)"
}

exclude_state_dir() {
  local root info exclude
  root=$(repo_root)
  info="$root/.git/info"
  exclude="$info/exclude"
  mkdir -p "$info"
  touch "$exclude"
  if ! grep -Fxq '.codex-autoresearch/' "$exclude"; then
    printf '\n.codex-autoresearch/\n' >>"$exclude"
  fi
}

ensure_branch() {
  local branch
  branch="feat/autoresearch-$(date +%Y%m%d)"
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git checkout "$branch" >/dev/null
  else
    git checkout -b "$branch" >/dev/null
  fi
  printf '%s\n' "$branch"
}

write_state() {
  python3 - "$@" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(sys.argv[2])
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, indent=2) + "\n")
print(json.dumps(payload, indent=2))
PY
}

load_state() {
  local path
  path=$(state_file)
  if [[ ! -f "$path" ]]; then
    echo "no autoresearch state at $path" >&2
    exit 1
  fi
  cat "$path"
}

setup_loop() {
  local goal="" metric_command="" metric_regex="" direction="" budget="12"
  local scopes=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --goal)
        goal="$2"
        shift 2
        ;;
      --metric-command)
        metric_command="$2"
        shift 2
        ;;
      --metric-regex)
        metric_regex="$2"
        shift 2
        ;;
      --direction)
        direction="$2"
        shift 2
        ;;
      --scope)
        scopes+=("$2")
        shift 2
        ;;
      --budget)
        budget="$2"
        shift 2
        ;;
      *)
        echo "unknown setup flag: $1" >&2
        exit 1
        ;;
    esac
  done

  if [[ -z "$goal" || -z "$metric_command" || -z "$metric_regex" || -z "$direction" || ${#scopes[@]} -eq 0 ]]; then
    echo "setup requires --goal, --metric-command, --metric-regex, --direction, and at least one --scope" >&2
    exit 1
  fi
  if [[ "$direction" != "higher" && "$direction" != "lower" ]]; then
    echo "--direction must be higher or lower" >&2
    exit 1
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "setup requires a clean git worktree" >&2
    exit 1
  fi

  local root state branch
  root=$(repo_root)
  branch=$(ensure_branch)
  exclude_state_dir
  state=$(python3 - "$root" "$goal" "$metric_command" "$metric_regex" "$direction" "$budget" "$branch" "${scopes[@]}" <<'PY'
import json
import pathlib
import sys
import datetime as dt

root = pathlib.Path(sys.argv[1])
goal = sys.argv[2]
metric_command = sys.argv[3]
metric_regex = sys.argv[4]
direction = sys.argv[5]
budget = int(sys.argv[6])
branch = sys.argv[7]
scopes = sys.argv[8:]

state = {
    "version": 1,
    "active": True,
    "last_transition": "setup",
    "goal": goal,
    "metric_command": metric_command,
    "metric_regex": metric_regex,
    "direction": direction,
    "budget": budget,
    "iterations": 0,
    "best_value": None,
    "best_label": None,
    "last_value": None,
    "last_label": None,
    "last_fingerprint": None,
    "branch": branch,
    "done_marker": "AUTORESEARCH_DONE",
    "scopes": scopes,
    "repo_root": str(root),
    "results_path": ".codex-autoresearch/results.tsv",
    "log_path": ".codex-autoresearch/run.log",
    "updated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    "stopped_at": None,
}
print(json.dumps(state))
PY
)

  mkdir -p "$(state_dir)"
  if [[ ! -f "$(state_dir)/results.tsv" ]]; then
    printf 'timestamp\titeration\tvalue\tresult\tlabel\n' >"$(state_dir)/results.tsv"
  fi
  touch "$(state_dir)/run.log"
  write_state "$(state_file)" "$state" >/dev/null
  load_state
}

toggle_active() {
  local value="$1"
  python3 - "$(state_file)" "$value" <<'PY'
import json
import pathlib
import sys
import datetime as dt

path = pathlib.Path(sys.argv[1])
value = sys.argv[2] == "true"
state = json.loads(path.read_text())
state["active"] = value
state["last_transition"] = "resume" if value else "manual-stop"
state["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
state["stopped_at"] = None if value else state["updated_at"]
path.write_text(json.dumps(state, indent=2) + "\n")
print(json.dumps(state, indent=2))
PY
}

reset_loop() {
  rm -rf "$(state_dir)"
}

case "$command_name" in
  setup)
    setup_loop "$@"
    ;;
  status)
    load_state
    ;;
  stop)
    toggle_active false
    ;;
  resume)
    toggle_active true
    ;;
  reset)
    reset_loop
    ;;
  *)
    echo "unknown command: $command_name" >&2
    exit 1
    ;;
esac
