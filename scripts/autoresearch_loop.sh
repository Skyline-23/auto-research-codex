#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

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

results_file() {
  printf '%s/results.tsv\n' "$(repo_root)"
}

run_log_file() {
  printf '%s/run.log\n' "$(repo_root)"
}

ensure_hooks() {
  /bin/bash "$SCRIPT_DIR/install.sh" >/dev/null
}

remove_hooks() {
  /bin/bash "$SCRIPT_DIR/uninstall.sh" >/dev/null
}

exclude_runtime_files() {
  local root info exclude
  root=$(repo_root)
  info="$root/.git/info"
  exclude="$info/exclude"
  mkdir -p "$info"
  touch "$exclude"
  for entry in ".codex-autoresearch/" "results.tsv" "run.log"; do
    if ! grep -Fxq "$entry" "$exclude"; then
      printf '\n%s\n' "$entry" >>"$exclude"
    fi
  done
}

ensure_branch() {
  local branch
  branch="autoresearch/$(date +%Y%m%d)"
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git checkout "$branch" >/dev/null
  else
    git checkout -b "$branch" >/dev/null
  fi
  printf '%s\n' "$branch"
}

parse_metric_from_log() {
  python3 - "$1" "$2" <<'PY'
import pathlib
import re
import sys

log_path = pathlib.Path(sys.argv[1])
pattern = sys.argv[2]
text = log_path.read_text() if log_path.exists() else ""
match = re.search(pattern, text, re.MULTILINE)
if not match:
    raise SystemExit(1)
token = match.group(1) if match.groups() else match.group(0)
print(float(token))
PY
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
  local goal="" metric_command="" metric_regex="" direction="" max_experiments="unlimited"
  local simplicity_policy="All else equal, simpler is better."
  local in_scope=()
  local out_of_scope=()
  local constraints=()

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
      --in-scope)
        in_scope+=("$2")
        shift 2
        ;;
      --out-of-scope)
        out_of_scope+=("$2")
        shift 2
        ;;
      --constraint)
        constraints+=("$2")
        shift 2
        ;;
      --max-experiments)
        max_experiments="$2"
        shift 2
        ;;
      --simplicity-policy)
        simplicity_policy="$2"
        shift 2
        ;;
      *)
        echo "unknown setup flag: $1" >&2
        exit 1
        ;;
    esac
  done

  if [[ -z "$goal" || -z "$metric_command" || -z "$metric_regex" || -z "$direction" || ${#in_scope[@]} -eq 0 ]]; then
    echo "setup requires --goal, --metric-command, --metric-regex, --direction, and at least one --in-scope" >&2
    exit 1
  fi
  if [[ "$direction" != "higher" && "$direction" != "lower" ]]; then
    echo "--direction must be higher or lower" >&2
    exit 1
  fi
  if [[ "$max_experiments" != "unlimited" && ! "$max_experiments" =~ ^[0-9]+$ ]]; then
    echo "--max-experiments must be a number or unlimited" >&2
    exit 1
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "setup requires a clean git worktree" >&2
    exit 1
  fi

  local root branch results_path log_path baseline_value baseline_commit state
  ensure_hooks
  root=$(repo_root)
  branch=$(ensure_branch)
  exclude_runtime_files
  results_path=$(results_file)
  log_path=$(run_log_file)

  if [[ ! -f "$results_path" ]]; then
    printf 'experiment\tcommit\tmetric\tstatus\tdescription\n' >"$results_path"
  fi

  if ! bash -lc "$metric_command" >"$log_path" 2>&1; then
    echo "baseline metric command failed; inspect $log_path" >&2
    exit 1
  fi
  if ! baseline_value=$(parse_metric_from_log "$log_path" "$metric_regex"); then
    echo "baseline metric could not be parsed from $log_path" >&2
    exit 1
  fi
  baseline_commit=$(git rev-parse HEAD)
  printf '0\t%s\t%s\tbaseline\tunmodified code\n' "$baseline_commit" "$baseline_value" >>"$results_path"

  state=$(python3 - "$root" "$goal" "$metric_command" "$metric_regex" "$direction" "$branch" "$baseline_value" "$baseline_commit" "$results_path" "$log_path" "$max_experiments" "$simplicity_policy" "${in_scope[@]}" -- "${out_of_scope[@]-}" -- "${constraints[@]-}" <<'PY'
import datetime as dt
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
goal = sys.argv[2]
metric_command = sys.argv[3]
metric_regex = sys.argv[4]
direction = sys.argv[5]
branch = sys.argv[6]
baseline_value = float(sys.argv[7])
baseline_commit = sys.argv[8]
results_path = pathlib.Path(sys.argv[9]).name
log_path = pathlib.Path(sys.argv[10]).name
max_experiments_raw = sys.argv[11]
simplicity_policy = sys.argv[12]

parts = sys.argv[13:]
separator_1 = parts.index("--")
separator_2 = parts.index("--", separator_1 + 1)
in_scope = [item for item in parts[:separator_1] if item]
out_of_scope = [item for item in parts[separator_1 + 1:separator_2] if item]
constraints = [item for item in parts[separator_2 + 1:] if item]

state = {
    "version": 2,
    "active": True,
    "last_transition": "baseline",
    "goal": goal,
    "metric_command": metric_command,
    "metric_regex": metric_regex,
    "direction": direction,
    "branch": branch,
    "baseline_value": baseline_value,
    "baseline_commit": baseline_commit,
    "best_value": baseline_value,
    "best_commit": baseline_commit,
    "best_description": "unmodified code",
    "last_metric": baseline_value,
    "last_status": "baseline",
    "last_evaluated_commit": baseline_commit,
    "experiments_run": 0,
    "next_experiment": 1,
    "max_experiments": None if max_experiments_raw == "unlimited" else int(max_experiments_raw),
    "done_marker": "AUTORESEARCH_DONE",
    "in_scope": in_scope,
    "out_of_scope": out_of_scope,
    "constraints": constraints,
    "simplicity_policy": simplicity_policy,
    "repo_root": str(root),
    "results_path": results_path,
    "log_path": log_path,
    "updated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    "stopped_at": None,
}
print(json.dumps(state))
PY
)

  mkdir -p "$(state_dir)"
  touch "$(state_dir)/run.log"
  write_state "$(state_file)" "$state" >/dev/null
  load_state
}

toggle_active() {
  local value="$1"
  python3 - "$(state_file)" "$value" <<'PY'
import datetime as dt
import json
import pathlib
import sys

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
    remove_hooks
    ;;
  resume)
    ensure_hooks
    toggle_active true
    ;;
  reset)
    reset_loop
    remove_hooks
    ;;
  *)
    echo "unknown command: $command_name" >&2
    exit 1
    ;;
esac
