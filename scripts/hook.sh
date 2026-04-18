#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

event="${1:-}"
if [[ -z "$event" ]]; then
  echo "usage: hook.sh <session-start|user-prompt|stop>" >&2
  exit 1
fi

HOOK_PAYLOAD=$(cat)
export HOOK_PAYLOAD
export HOOK_SCRIPT_DIR="$SCRIPT_DIR"

python3 - "$event" <<'PY'
import datetime as dt
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys

event = sys.argv[1]
payload = json.loads(os.environ["HOOK_PAYLOAD"])


def repo_root_from(payload_cwd):
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=payload_cwd,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    return pathlib.Path(result.stdout.strip())


def git_run(repo, args, check=True):
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        text=True,
        capture_output=True,
        check=False,
    )
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result


def load_state(root):
    state_path = root / ".codex-autoresearch" / "state.json"
    if state_path.exists():
        return json.loads(state_path.read_text()), state_path
    pointer_path = root / ".codex-autoresearch" / "session.json"
    if pointer_path.exists():
        pointer = json.loads(pointer_path.read_text())
        state_path = pathlib.Path(pointer["state_path"])
        if state_path.exists():
            return json.loads(state_path.read_text()), state_path
    return None, state_path


def write_state(path, state):
    path.write_text(json.dumps(state, indent=2) + "\n")


def cleanup_hooks():
    script = pathlib.Path(os.environ["HOOK_SCRIPT_DIR"]) / "uninstall.sh"
    subprocess.run(
        ["/bin/bash", str(script)],
        text=True,
        capture_output=True,
        check=False,
    )


def path_matches_scope(path, scope):
    normalized = path.strip("/")
    scope = scope.strip().strip("/")
    if scope in ("", ".", "./"):
        return True
    return normalized == scope or normalized.startswith(scope + "/")


def path_allowed(path, in_scope, out_of_scope):
    if not any(path_matches_scope(path, scope) for scope in in_scope):
        return False
    if any(path_matches_scope(path, scope) for scope in out_of_scope):
        return False
    return True


def has_done_marker(message, marker):
    return any(line.strip() == marker for line in message.splitlines())


def summarize_state(state):
    max_text = "unlimited" if state.get("max_experiments") is None else str(state["max_experiments"])
    constraints = "; ".join(state["constraints"]) if state["constraints"] else "none"
    repo_names = ", ".join(repo["name"] for repo in state["repos"])
    topology = "single-repo" if len(state["repos"]) == 1 else f"multi-repo ({repo_names})"
    if state.get("execution_mode") == "manual":
        return (
            f'Autoresearch is active in manual fallback mode. Goal: {state["goal"]}. '
            f'Topology: {topology}. '
            f'Reason: {state.get("manual_reason") or "manual fallback"}. '
            f'Best metric so far: {state["best_value"]}. '
            f'Experiments run: {state["experiments_run"]}/{max_text}. '
            f'Constraints: {constraints}. '
            "Native keep/discard automation is paused, but the loop stays active. "
            "Keep enforcing one hypothesis, one measured experiment, one explicit keep/discard decision manually. "
            f'Emit {state["done_marker"]} or run scripts/autoresearch_loop.sh stop to finish.'
        )
    return (
        f'Autoresearch is active. Goal: {state["goal"]}. '
        f'Topology: {topology}. '
        f'Baseline: {state["baseline_value"]}. '
        f'Best: {state["best_value"]}. '
        f'Experiments run: {state["experiments_run"]}/{max_text}. '
        f'Constraints: {constraints}. '
        "Protocol: one focused change set, commit all touched tracked repos, then let the Stop hook measure and keep/discard the whole experiment atomically. "
        f'Emit {state["done_marker"]} or run scripts/autoresearch_loop.sh stop to finish.'
    )


def parse_metric(text, pattern):
    match = re.search(pattern, text, re.MULTILINE)
    if not match:
        return None
    token = match.group(1) if match.groups() else match.group(0)
    try:
        return float(token)
    except ValueError:
        return None


def append_result(state, commits_map, metric_value, status, description):
    results_path = pathlib.Path(state["results_path"])
    metric_text = "" if metric_value is None else str(metric_value)
    commit_text = ",".join(f"{pathlib.Path(root).name}={commit}" for root, commit in commits_map.items())
    with results_path.open("a", encoding="utf-8") as handle:
        handle.write(
            f'{state["next_experiment"]}\t{metric_text}\t{status}\t{commit_text}\t{description}\n'
        )
    state["experiments_run"] += 1
    state["next_experiment"] += 1


def run_metric(state):
    metric_repo = pathlib.Path(state["metric_repo"])
    log_path = pathlib.Path(state["log_path"])
    command = f'{state["metric_command"]} > {shlex.quote(str(log_path))} 2>&1'
    result = subprocess.run(
        command,
        cwd=metric_repo,
        shell=True,
        text=True,
        capture_output=True,
        check=False,
    )
    metric_text = log_path.read_text() if log_path.exists() else ""
    return result, metric_text


def tail_run_log(state, lines=20):
    log_path = pathlib.Path(state["log_path"])
    if not log_path.exists():
        return ""
    text = log_path.read_text().splitlines()
    return "\n".join(text[-lines:])


def maybe_finish(state, state_path):
    max_experiments = state.get("max_experiments")
    if max_experiments is not None and state["experiments_run"] >= max_experiments:
        state["active"] = False
        state["last_transition"] = "budget-reached"
        state["stopped_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
        state["updated_at"] = state["stopped_at"]
        write_state(state_path, state)
        cleanup_hooks()
        return True
    return False


def current_head_files(repo):
    result = git_run(repo, ["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"], check=False)
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def revert_changed_repos(changed, repo_map):
    for root, previous_commit in changed.items():
        repo = repo_map[root]
        current = git_run(repo, ["rev-parse", "HEAD"]).stdout.strip()
        if current != previous_commit:
            git_run(repo, ["reset", "--hard", previous_commit], check=False)


root = repo_root_from(payload["cwd"])
if root is None:
    raise SystemExit(0)

state, state_path = load_state(root)
if not state or not state.get("active"):
    cleanup_hooks()
    raise SystemExit(0)

if event in {"session-start", "user-prompt"}:
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "SessionStart" if event == "session-start" else "UserPromptSubmit",
                    "additionalContext": summarize_state(state),
                }
            }
        )
    )
    raise SystemExit(0)

if payload.get("stop_hook_active"):
    raise SystemExit(0)

last_message = payload.get("last_assistant_message") or ""
if has_done_marker(last_message, state["done_marker"]):
    state["active"] = False
    state["last_transition"] = "done-marker"
    state["stopped_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    state["updated_at"] = state["stopped_at"]
    write_state(state_path, state)
    cleanup_hooks()
    raise SystemExit(0)

if state.get("execution_mode") == "manual":
    reason = (
        f'Autoresearch manual fallback is active for goal "{state["goal"]}". '
        f'Reason: {state.get("manual_reason") or "manual fallback"}. '
        "Keep running the autoresearch protocol manually and do not stop the loop. "
        "Return to native mode with scripts/autoresearch_loop.sh resume-native when native tracking is safe again."
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    raise SystemExit(0)

repo_map = {repo["root"]: pathlib.Path(repo["root"]) for repo in state["repos"]}
repo_states = {repo["root"]: repo for repo in state["repos"]}

changed_commits = {}
head_subjects = []

for root_str, repo in repo_map.items():
    repo_state = repo_states[root_str]
    dirty_output = git_run(repo, ["status", "--porcelain"]).stdout
    dirty_paths = [line[3:].strip() for line in dirty_output.splitlines() if line.strip()]
    if dirty_paths:
        out_of_scope_dirty = [
            path for path in dirty_paths
            if not path_allowed(path, repo_state["in_scope"], repo_state["out_of_scope"])
        ]
        if out_of_scope_dirty:
            reason = (
                f'Autoresearch found uncommitted out-of-scope changes in {repo.name}: '
                + ", ".join(out_of_scope_dirty[:8])
                + ". Revert those files before the loop continues."
            )
            print(json.dumps({"decision": "block", "reason": reason}))
            raise SystemExit(0)
        reason = (
            f'Autoresearch requires every touched tracked repo to be committed before evaluation. '
            f'{repo.name} still has uncommitted changes.'
        )
        print(json.dumps({"decision": "block", "reason": reason}))
        raise SystemExit(0)

    head_commit = git_run(repo, ["rev-parse", "HEAD"]).stdout.strip()
    if head_commit != repo_state["last_evaluated_commit"]:
        changed_commits[root_str] = head_commit
        head_subjects.append(f'{repo.name}: {git_run(repo, ["log", "-1", "--pretty=%s", "HEAD"]).stdout.strip()}')

if not changed_commits:
    reason = (
        f'Autoresearch is active for goal "{state["goal"]}". '
        "No new experiment commit was found in any tracked repo since the last evaluation. "
        "Make one new experiment commit set and stop again."
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    raise SystemExit(0)

for root_str, head_commit in changed_commits.items():
    repo = repo_map[root_str]
    repo_state = repo_states[root_str]
    head_files = current_head_files(repo)
    off_limits = [
        path for path in head_files
        if not path_allowed(path, repo_state["in_scope"], repo_state["out_scope"] if "out_scope" in repo_state else repo_state["out_of_scope"])
    ]
    if off_limits:
        previous_commits = {root: repo_states[root]["last_evaluated_commit"] for root in changed_commits}
        append_result(
            state,
            changed_commits,
            None,
            "discard",
            f"reverted out-of-scope change in {repo.name}: {', '.join(off_limits[:4])}",
        )
        revert_changed_repos(previous_commits, repo_map)
        state["last_transition"] = "discarded-out-of-scope"
        state["last_metric"] = None
        state["last_status"] = "discard"
        state["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
        write_state(state_path, state)
        if maybe_finish(state, state_path):
            raise SystemExit(0)
        reason = (
            f"The last experiment touched out-of-scope files in {repo.name} and was reverted automatically. "
            "Try another experiment that stays inside the approved paths."
        )
        print(json.dumps({"decision": "block", "reason": reason}))
        raise SystemExit(0)

metric_run, metric_text = run_metric(state)
metric_value = parse_metric(metric_text, state["metric_regex"])
description = " | ".join(head_subjects)[:400] if head_subjects else "experiment"

if metric_run.returncode != 0 or metric_value is None:
    previous_commits = {root: repo_states[root]["last_evaluated_commit"] for root in changed_commits}
    append_result(state, changed_commits, None, "crash", description)
    revert_changed_repos(previous_commits, repo_map)
    state["last_transition"] = "crash-reverted"
    state["last_metric"] = None
    state["last_status"] = "crash"
    state["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    write_state(state_path, state)
    if maybe_finish(state, state_path):
        raise SystemExit(0)
    log_tail = tail_run_log(state, lines=12).strip()
    reason = (
        "The last experiment crashed or did not yield a parseable metric and was reverted automatically across tracked repos. "
        "Read run.log, fix the likely issue, and try another focused experiment."
    )
    if log_tail:
        reason += "\nRecent run.log tail:\n" + log_tail
    print(json.dumps({"decision": "block", "reason": reason}))
    raise SystemExit(0)

best_value = state["best_value"]
improved = metric_value < best_value if state["direction"] == "lower" else metric_value > best_value

if improved:
    append_result(state, changed_commits, metric_value, "keep", description)
    state["best_value"] = metric_value
    state["best_description"] = description
    for root_str, head_commit in changed_commits.items():
        repo_states[root_str]["last_evaluated_commit"] = head_commit
        state["best_commits"][root_str] = head_commit
    state["last_transition"] = "keep"
    state["last_metric"] = metric_value
    state["last_status"] = "keep"
    state["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    write_state(state_path, state)
    if maybe_finish(state, state_path):
        raise SystemExit(0)
    reason = (
        f"Autoresearch kept experiment {state['next_experiment'] - 1}. "
        f"Metric improved from {best_value} to {metric_value}. "
        "Use the new best state as the baseline for the next experiment."
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    raise SystemExit(0)

previous_commits = {root: repo_states[root]["last_evaluated_commit"] for root in changed_commits}
append_result(state, changed_commits, metric_value, "discard", description)
revert_changed_repos(previous_commits, repo_map)
state["last_transition"] = "discard-reverted"
state["last_metric"] = metric_value
state["last_status"] = "discard"
state["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
write_state(state_path, state)
if maybe_finish(state, state_path):
    raise SystemExit(0)

reason = (
    f"Autoresearch discarded experiment {state['next_experiment'] - 1}. "
    f"Metric {metric_value} did not beat best {best_value}. "
    "All tracked repos were reset to the last known good experiment."
)
print(json.dumps({"decision": "block", "reason": reason}))
PY
