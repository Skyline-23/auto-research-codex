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


def git_output(args, cwd):
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "git command failed")
    return result.stdout.rstrip("\n")


def git_ok(args, cwd):
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        text=True,
        capture_output=True,
        check=False,
    )
    return result.returncode == 0, result.stdout, result.stderr


def load_state(root):
    path = root / ".codex-autoresearch" / "state.json"
    if not path.exists():
        return None, path
    return json.loads(path.read_text()), path


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
    for line in message.splitlines():
        if line.strip() == marker:
            return True
    return False


def summarize_state(state):
    max_text = "unlimited" if state.get("max_experiments") is None else str(state["max_experiments"])
    constraints = "; ".join(state["constraints"]) if state["constraints"] else "none"
    out_of_scope = ", ".join(state["out_of_scope"]) if state["out_of_scope"] else "none"
    return (
        f'Autoresearch is active. Goal: {state["goal"]}. '
        f'Baseline: {state["baseline_value"]}. '
        f'Best: {state["best_value"]} at {state["best_commit"][:12]}. '
        f'Experiments run: {state["experiments_run"]}/{max_text}. '
        f'In scope: {", ".join(state["in_scope"])}. '
        f'Out of scope: {out_of_scope}. '
        f'Constraints: {constraints}. '
        "Protocol: make one focused change, commit it as "
        '"experiment: ...", then let the Stop hook measure it. '
        "Non-improvements are reverted automatically. "
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


def append_result(root, state, commit_hash, metric_value, status, description):
    results_path = root / state["results_path"]
    metric_text = "" if metric_value is None else str(metric_value)
    with results_path.open("a", encoding="utf-8") as handle:
        handle.write(
            f'{state["next_experiment"]}\t{commit_hash}\t{metric_text}\t{status}\t{description}\n'
        )
    state["experiments_run"] += 1
    state["next_experiment"] += 1


def run_metric(root, state):
    log_path = root / state["log_path"]
    command = f'{state["metric_command"]} > {shlex.quote(str(log_path))} 2>&1'
    result = subprocess.run(
        command,
        cwd=root,
        shell=True,
        text=True,
        capture_output=True,
        check=False,
    )
    metric_text = log_path.read_text() if log_path.exists() else ""
    return result, metric_text


def tail_run_log(root, state, lines=20):
    log_path = root / state["log_path"]
    if not log_path.exists():
        return ""
    text = log_path.read_text().splitlines()
    return "\n".join(text[-lines:])


def maybe_finish(root, state, state_path):
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


def current_head_files(root):
    ok, stdout, _ = git_ok(["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"], root)
    if not ok:
        return []
    return [line.strip() for line in stdout.splitlines() if line.strip()]


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

try:
    dirty_output = git_output(["status", "--porcelain"], root)
    head_commit = git_output(["rev-parse", "HEAD"], root)
    head_subject = git_output(["log", "-1", "--pretty=%s", "HEAD"], root)
except RuntimeError:
    raise SystemExit(0)

dirty_paths = [line[3:].strip() for line in dirty_output.splitlines() if line.strip()]
if dirty_paths:
    out_of_scope_dirty = [path for path in dirty_paths if not path_allowed(path, state["in_scope"], state["out_of_scope"])]
    if out_of_scope_dirty:
        reason = (
            "Autoresearch found uncommitted out-of-scope changes: "
            + ", ".join(out_of_scope_dirty[:8])
            + ". Revert those files before the loop continues."
        )
        print(json.dumps({"decision": "block", "reason": reason}))
        raise SystemExit(0)
    reason = (
        "Autoresearch requires every experiment to be committed before evaluation. "
        'Commit the current change as `experiment: ...`, then let the Stop hook run again.'
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    raise SystemExit(0)

if head_commit == state.get("last_evaluated_commit"):
    reason = (
        f'Autoresearch is active for goal "{state["goal"]}". '
        f'Best metric: {state["best_value"]}. '
        "No new experiment commit was found since the last evaluation. "
        "Make one new experiment commit and stop again."
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    raise SystemExit(0)

head_files = current_head_files(root)
off_limits = [path for path in head_files if not path_allowed(path, state["in_scope"], state["out_of_scope"])]
if off_limits:
    append_result(root, state, head_commit, None, "discard", f"reverted out-of-scope change: {', '.join(off_limits[:4])}")
    subprocess.run(["git", "reset", "--hard", "HEAD~1"], cwd=root, text=True, capture_output=True, check=False)
    state["last_transition"] = "discarded-out-of-scope"
    state["last_metric"] = None
    state["last_status"] = "discard"
    state["last_evaluated_commit"] = git_output(["rev-parse", "HEAD"], root)
    state["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    write_state(state_path, state)
    if maybe_finish(root, state, state_path):
        raise SystemExit(0)
    reason = (
        "The last experiment touched out-of-scope files and was reverted automatically. "
        "Try another experiment that stays inside the approved paths."
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    raise SystemExit(0)

metric_run, metric_text = run_metric(root, state)
metric_value = parse_metric(metric_text, state["metric_regex"])

if metric_run.returncode != 0 or metric_value is None:
    append_result(root, state, head_commit, None, "crash", head_subject)
    subprocess.run(["git", "reset", "--hard", "HEAD~1"], cwd=root, text=True, capture_output=True, check=False)
    state["last_transition"] = "crash-reverted"
    state["last_metric"] = None
    state["last_status"] = "crash"
    state["last_evaluated_commit"] = git_output(["rev-parse", "HEAD"], root)
    state["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    write_state(state_path, state)
    if maybe_finish(root, state, state_path):
        raise SystemExit(0)
    log_tail = tail_run_log(root, state, lines=12).strip()
    reason = (
        "The last experiment crashed or did not yield a parseable metric and was reverted automatically. "
        "Read run.log, fix the likely issue, and try another focused experiment."
    )
    if log_tail:
        reason += "\nRecent run.log tail:\n" + log_tail
    print(json.dumps({"decision": "block", "reason": reason}))
    raise SystemExit(0)

best_value = state["best_value"]
improved = (
    metric_value < best_value if state["direction"] == "lower" else metric_value > best_value
)

if improved:
    append_result(root, state, head_commit, metric_value, "keep", head_subject)
    state["best_value"] = metric_value
    state["best_commit"] = head_commit
    state["best_description"] = head_subject
    state["last_transition"] = "keep"
    state["last_metric"] = metric_value
    state["last_status"] = "keep"
    state["last_evaluated_commit"] = head_commit
    state["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    write_state(state_path, state)
    if maybe_finish(root, state, state_path):
        raise SystemExit(0)
    reason = (
        f'Autoresearch kept experiment {state["next_experiment"] - 1}. '
        f"Metric improved from {best_value} to {metric_value}. "
        "Use the new best state as the baseline for the next experiment."
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    raise SystemExit(0)

append_result(root, state, head_commit, metric_value, "discard", head_subject)
subprocess.run(["git", "reset", "--hard", "HEAD~1"], cwd=root, text=True, capture_output=True, check=False)
state["last_transition"] = "discard-reverted"
state["last_metric"] = metric_value
state["last_status"] = "discard"
state["last_evaluated_commit"] = git_output(["rev-parse", "HEAD"], root)
state["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
write_state(state_path, state)
if maybe_finish(root, state, state_path):
    raise SystemExit(0)

reason = (
    f'Autoresearch discarded experiment {state["next_experiment"] - 1}. '
    f"Metric {metric_value} did not beat best {best_value}. "
    "The branch was reset to the last known good commit. Try a different idea."
)
print(json.dumps({"decision": "block", "reason": reason}))
PY
