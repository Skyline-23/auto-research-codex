#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

command_name="${1:-}"
if [[ -z "$command_name" ]]; then
  echo "usage: autoresearch_loop.sh <setup|status|stop|resume|resume-native|manual-fallback|reset> [args]" >&2
  exit 1
fi
shift

ensure_hooks() {
  /bin/bash "$SCRIPT_DIR/install.sh" "$@" >/dev/null
}

remove_hooks() {
  /bin/bash "$SCRIPT_DIR/uninstall.sh" "$@" >/dev/null
}

resolve_state_path() {
  python3 - "$PWD" <<'PY'
import json
import pathlib
import subprocess
import sys

cwd = pathlib.Path(sys.argv[1]).resolve()
result = subprocess.run(
    ["git", "rev-parse", "--show-toplevel"],
    cwd=cwd,
    text=True,
    capture_output=True,
    check=False,
)
if result.returncode != 0:
    raise SystemExit("not inside a git repo")
root = pathlib.Path(result.stdout.strip())
state_path = root / ".codex-autoresearch" / "state.json"
if state_path.exists():
    print(state_path)
    raise SystemExit(0)
pointer_path = root / ".codex-autoresearch" / "session.json"
if pointer_path.exists():
    print(json.loads(pointer_path.read_text())["state_path"])
    raise SystemExit(0)
raise SystemExit(f"no autoresearch state for {root}")
PY
}

tracked_repo_roots() {
  python3 - "$(resolve_state_path)" <<'PY'
import json
import pathlib
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text())
for repo in state.get("repos", []):
    root = repo.get("root")
    if isinstance(root, str) and root:
        print(root)
PY
}

setup_loop() {
  local goal="" metric_command="" metric_regex="" direction="" max_experiments="unlimited"
  local simplicity_policy="All else equal, simpler is better."
  local metric_repo=""
  local repos=()
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
      --metric-repo)
        metric_repo="$2"
        shift 2
        ;;
      --repo)
        repos+=("$2")
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

  if [[ ${#repos[@]} -eq 0 ]]; then
    repos+=("$PWD")
  fi

  local setup_json
  setup_json=$(python3 - "$PWD" "$goal" "$metric_command" "$metric_regex" "$direction" "$max_experiments" "$simplicity_policy" "$metric_repo" "${repos[@]}" -- "${in_scope[@]}" -- "${out_of_scope[@]-}" -- "${constraints[@]-}" <<'PY'
import datetime as dt
import json
import pathlib
import re
import subprocess
import sys

cwd = pathlib.Path(sys.argv[1]).resolve()
goal = sys.argv[2]
metric_command = sys.argv[3]
metric_regex = sys.argv[4]
direction = sys.argv[5]
max_experiments_raw = sys.argv[6]
simplicity_policy = sys.argv[7]
metric_repo_arg = sys.argv[8]
parts = sys.argv[9:]

sep1 = parts.index("--")
sep2 = parts.index("--", sep1 + 1)
sep3 = parts.index("--", sep2 + 1)
repo_specs = [item for item in parts[:sep1] if item]
in_scope_specs = [item for item in parts[sep1 + 1:sep2] if item]
out_scope_specs = [item for item in parts[sep2 + 1:sep3] if item]
constraints = [item for item in parts[sep3 + 1:] if item]


def git_run(repo, args, check=True):
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        text=True,
        capture_output=True,
        check=False,
    )
    if check and result.returncode != 0:
        raise SystemExit(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result


def canonical_repo(path_like):
    path = pathlib.Path(path_like)
    if not path.is_absolute():
        path = (cwd / path).resolve()
    return pathlib.Path(git_run(path, ["rev-parse", "--show-toplevel"]).stdout.strip()).resolve()


repo_roots = []
for spec in repo_specs:
    root = canonical_repo(spec)
    if root not in repo_roots:
        repo_roots.append(root)

primary_repo = repo_roots[0]
metric_repo = canonical_repo(metric_repo_arg) if metric_repo_arg else primary_repo
if metric_repo not in repo_roots:
    raise SystemExit("--metric-repo must be one of the configured --repo roots")


def repo_for_absolute_scope(scope_path: pathlib.Path):
    scope_path = scope_path.resolve()
    matches = []
    for repo in repo_roots:
        try:
            scope_path.relative_to(repo)
            matches.append(repo)
        except ValueError:
            continue
    if not matches:
        raise SystemExit(f"scope path is outside every configured repo: {scope_path}")
    matches.sort(key=lambda repo: len(str(repo)), reverse=True)
    return matches[0]


def assign_scope_map(specs):
    mapping = {str(repo): [] for repo in repo_roots}
    for spec in specs:
        raw_spec = spec.strip()
        if not raw_spec:
            continue
        scope_path = pathlib.Path(raw_spec)
        if scope_path.is_absolute():
            repo = repo_for_absolute_scope(scope_path)
            rel = scope_path.relative_to(repo)
            mapping[str(repo)].append("." if str(rel) == "." else rel.as_posix())
            continue
        else:
            mapping[str(primary_repo)].append(raw_spec)
    return mapping


in_scope_map = assign_scope_map(in_scope_specs)
out_scope_map = assign_scope_map(out_scope_specs)

for repo in repo_roots:
    if not in_scope_map[str(repo)]:
        in_scope_map[str(repo)] = ["."]
    if git_run(repo, ["status", "--porcelain"]).stdout.strip():
        raise SystemExit(f"setup requires a clean git worktree: {repo}")

branch = f'autoresearch/{dt.datetime.now().strftime("%Y%m%d")}'
for repo in repo_roots:
    exists = git_run(repo, ["show-ref", "--verify", "--quiet", f"refs/heads/{branch}"], check=False).returncode == 0
    if exists:
        git_run(repo, ["checkout", branch])
    else:
        git_run(repo, ["checkout", "-b", branch])


def ensure_exclude(repo: pathlib.Path, entries):
    exclude = repo / ".git" / "info" / "exclude"
    exclude.parent.mkdir(parents=True, exist_ok=True)
    lines = exclude.read_text().splitlines() if exclude.exists() else []
    changed = False
    for entry in entries:
        if entry not in lines:
            lines.append(entry)
            changed = True
    if changed or not exclude.exists():
        exclude.write_text("\n".join(line for line in lines if line).rstrip() + "\n")


for repo in repo_roots:
    ensure_exclude(repo, [".codex-autoresearch/"])
ensure_exclude(primary_repo, ["results.tsv", "run.log"])

results_path = primary_repo / "results.tsv"
log_path = primary_repo / "run.log"
if not results_path.exists():
    results_path.write_text("experiment\tmetric\tstatus\tcommits\tdescription\n")

metric_run = subprocess.run(
    metric_command,
    cwd=metric_repo,
    shell=True,
    text=True,
    capture_output=True,
    check=False,
)
log_text = "\n".join(part for part in [metric_run.stdout.strip(), metric_run.stderr.strip()] if part)
log_path.write_text(log_text + ("\n" if log_text else ""))
if metric_run.returncode != 0:
    raise SystemExit(f"baseline metric command failed; inspect {log_path}")
match = re.search(metric_regex, log_text, re.MULTILINE)
if not match:
    raise SystemExit(f"baseline metric could not be parsed from {log_path}")
token = match.group(1) if match.groups() else match.group(0)
baseline_value = float(token)

repos_state = []
best_commits = {}
commit_labels = []
for repo in repo_roots:
    commit = git_run(repo, ["rev-parse", "HEAD"]).stdout.strip()
    repo_state = {
        "root": str(repo),
        "name": repo.name,
        "baseline_commit": commit,
        "last_evaluated_commit": commit,
        "in_scope": in_scope_map[str(repo)],
        "out_of_scope": out_scope_map[str(repo)],
    }
    repos_state.append(repo_state)
    best_commits[str(repo)] = commit
    commit_labels.append(f"{repo.name}={commit}")

with results_path.open("a", encoding="utf-8") as handle:
    handle.write(f'0\t{baseline_value}\tbaseline\t{",".join(commit_labels)}\tunmodified code\n')

state_dir = primary_repo / ".codex-autoresearch"
state_dir.mkdir(parents=True, exist_ok=True)
state_path = state_dir / "state.json"
pointer_payload = {
    "state_path": str(state_path),
    "primary_repo": str(primary_repo),
}
for repo in repo_roots:
    repo_state_dir = repo / ".codex-autoresearch"
    repo_state_dir.mkdir(parents=True, exist_ok=True)
    (repo_state_dir / "session.json").write_text(json.dumps(pointer_payload, indent=2) + "\n")

state = {
    "version": 4,
    "active": True,
    "execution_mode": "native",
    "manual_reason": None,
    "last_transition": "baseline",
    "goal": goal,
    "metric_command": metric_command,
    "metric_regex": metric_regex,
    "direction": direction,
    "branch": branch,
    "primary_repo": str(primary_repo),
    "metric_repo": str(metric_repo),
    "baseline_value": baseline_value,
    "best_value": baseline_value,
    "best_description": "unmodified code",
    "best_commits": best_commits,
    "last_metric": baseline_value,
    "last_status": "baseline",
    "experiments_run": 0,
    "next_experiment": 1,
    "max_experiments": None if max_experiments_raw == "unlimited" else int(max_experiments_raw),
    "done_marker": "AUTORESEARCH_DONE",
    "constraints": constraints,
    "simplicity_policy": simplicity_policy,
    "repos": repos_state,
    "results_path": str(results_path),
    "log_path": str(log_path),
    "updated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    "stopped_at": None,
}
state_path.write_text(json.dumps(state, indent=2) + "\n")
print(json.dumps(state, indent=2))
PY
)
  repos=()
  while IFS= read -r repo_root; do
    if [[ -n "$repo_root" ]]; then
      repos+=("$repo_root")
    fi
  done < <(python3 - <<'PY' "$setup_json"
import json
import sys
for repo in json.loads(sys.argv[1])["repos"]:
    print(repo["root"])
PY
)
  ensure_hooks "${repos[@]}"
  printf '%s\n' "$setup_json"
}

status_loop() {
  cat "$(resolve_state_path)"
}

toggle_active() {
  local value="$1"
  local state_json
  state_json=$(python3 - "$(resolve_state_path)" "$value" <<'PY'
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
)
  printf '%s\n' "$state_json"
}

set_execution_mode() {
  local mode="$1"
  local reason="${2:-}"
  local state_json
  state_json=$(python3 - "$(resolve_state_path)" "$mode" "$reason" <<'PY'
import datetime as dt
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
reason = sys.argv[3] or None
state = json.loads(path.read_text())
state["execution_mode"] = mode
state["manual_reason"] = reason if mode == "manual" else None
state["last_transition"] = "manual-fallback" if mode == "manual" else "resume-native"
state["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
path.write_text(json.dumps(state, indent=2) + "\n")
print(json.dumps(state, indent=2))
PY
)
  printf '%s\n' "$state_json"
}

manual_fallback_loop() {
  local reason=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reason)
        reason="$2"
        shift 2
        ;;
      *)
        echo "unknown manual-fallback flag: $1" >&2
        exit 1
        ;;
    esac
  done
  if [[ -z "$reason" ]]; then
    echo "manual-fallback requires --reason" >&2
    exit 1
  fi
  local repo_roots=()
  while IFS= read -r repo_root; do
    if [[ -n "$repo_root" ]]; then
      repo_roots+=("$repo_root")
    fi
  done < <(tracked_repo_roots)
  ensure_hooks "${repo_roots[@]}"
  set_execution_mode manual "$reason"
}

resume_native_loop() {
  local repo_roots=()
  while IFS= read -r repo_root; do
    if [[ -n "$repo_root" ]]; then
      repo_roots+=("$repo_root")
    fi
  done < <(tracked_repo_roots)
  ensure_hooks "${repo_roots[@]}"
  set_execution_mode native ""
}

reset_loop() {
  local state_path
  state_path=$(resolve_state_path)
  python3 - "$state_path" <<'PY'
import json
import pathlib
import shutil
import sys

state_path = pathlib.Path(sys.argv[1])
state = json.loads(state_path.read_text())
for repo in state["repos"]:
    session_dir = pathlib.Path(repo["root"]) / ".codex-autoresearch"
    session_file = session_dir / "session.json"
    if session_file.exists():
        session_file.unlink()
    if pathlib.Path(repo["root"]) != pathlib.Path(state["primary_repo"]):
        try:
            session_dir.rmdir()
        except OSError:
            pass
shutil.rmtree(state_path.parent, ignore_errors=True)
PY
}

case "$command_name" in
  setup)
    setup_loop "$@"
    ;;
  status)
    status_loop
    ;;
  stop)
    repo_roots=()
    while IFS= read -r repo_root; do
      if [[ -n "$repo_root" ]]; then
        repo_roots+=("$repo_root")
      fi
    done < <(tracked_repo_roots)
    toggle_active false
    remove_hooks "${repo_roots[@]}"
    ;;
  resume)
    repo_roots=()
    while IFS= read -r repo_root; do
      if [[ -n "$repo_root" ]]; then
        repo_roots+=("$repo_root")
      fi
    done < <(tracked_repo_roots)
    ensure_hooks "${repo_roots[@]}"
    toggle_active true
    ;;
  resume-native)
    resume_native_loop
    ;;
  manual-fallback)
    manual_fallback_loop "$@"
    ;;
  reset)
    repo_roots=()
    while IFS= read -r repo_root; do
      if [[ -n "$repo_root" ]]; then
        repo_roots+=("$repo_root")
      fi
    done < <(tracked_repo_roots)
    reset_loop
    remove_hooks "${repo_roots[@]}"
    ;;
  *)
    echo "unknown command: $command_name" >&2
    exit 1
    ;;
esac
