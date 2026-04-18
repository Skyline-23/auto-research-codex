#!/usr/bin/env bash
set -euo pipefail

event="${1:-}"
if [[ -z "$event" ]]; then
  echo "usage: hook.sh <session-start|user-prompt|stop>" >&2
  exit 1
fi

HOOK_PAYLOAD=$(cat)
export HOOK_PAYLOAD

python3 - "$event" <<'PY'
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys

event = sys.argv[1]
payload = json.loads(os.environ["HOOK_PAYLOAD"])


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


def load_state(root):
    path = root / ".codex-autoresearch" / "state.json"
    if not path.exists():
        return None, path
    return json.loads(path.read_text()), path


def write_state(path, state):
    path.write_text(json.dumps(state, indent=2) + "\n")


def normalize_scope(scope):
    scope = scope.strip()
    if scope in ("", ".", "./"):
        return ""
    return scope.strip("/")


def path_in_scope(path, scopes):
    normalized = path.strip("/")
    for scope in scopes:
        prefix = normalize_scope(scope)
        if prefix == "":
            return True
        if normalized == prefix or normalized.startswith(prefix + "/"):
            return True
    return False


def parse_metric(text, pattern):
    match = re.search(pattern, text, re.MULTILINE)
    if not match:
        return None
    token = match.group(1) if match.groups() else match.group(0)
    try:
        return float(token)
    except ValueError:
        return None


def summarize_state(state):
    best = "none yet"
    if state.get("best_value") is not None:
        best = f'{state["best_value"]} ({state.get("best_label") or "best"})'
    scopes = ", ".join(state["scopes"])
    return (
        f'Autoresearch is active. Goal: {state["goal"]}. '
        f'Metric command: {state["metric_command"]}. '
        f'Stay inside scope: {scopes}. '
        f'Best metric: {best}. '
        f'Budget: {state["iterations"]}/{state["budget"]}. '
        "If the user asks to stop or change goals, run scripts/autoresearch_loop.sh stop first. "
        f'Emit {state["done_marker"]} or run scripts/autoresearch_loop.sh stop when done.'
    )


def has_done_marker(message, marker):
    for line in message.splitlines():
        if line.strip() == marker:
            return True
    return False


root = repo_root_from(payload["cwd"])
if root is None:
    sys.exit(0)

state, state_path = load_state(root)
if not state or not state.get("active"):
    sys.exit(0)

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
    sys.exit(0)

if payload.get("stop_hook_active"):
    sys.exit(0)

last_message = payload.get("last_assistant_message") or ""
if has_done_marker(last_message, state["done_marker"]):
    state["active"] = False
    state["last_transition"] = "done-marker"
    state["stopped_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    state["updated_at"] = state["stopped_at"]
    write_state(state_path, state)
    sys.exit(0)

try:
    status_output = git_output(["status", "--porcelain"], root)
except RuntimeError:
    sys.exit(0)

dirty_paths = []
if status_output:
    for line in status_output.splitlines():
        dirty_paths.append(line[3:].strip())

out_of_scope = [path for path in dirty_paths if not path_in_scope(path, state["scopes"])]
if out_of_scope:
    reason = (
        "Autoresearch is active, but dirty files escaped the declared scope: "
        + ", ".join(out_of_scope[:8])
        + ". Clean those paths or narrow the experiment before continuing."
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(0)

metric_command = state["metric_command"]
metric_run = subprocess.run(
    metric_command,
    cwd=root,
    shell=True,
    text=True,
    capture_output=True,
    check=False,
)
metric_text = "\n".join(
    part for part in [metric_run.stdout.strip(), metric_run.stderr.strip()] if part
)
metric_value = parse_metric(metric_text, state["metric_regex"])

diff_text = subprocess.run(
    ["git", "diff", "--no-ext-diff", "--no-color"],
    cwd=root,
    text=True,
    capture_output=True,
    check=False,
).stdout
cached_diff_text = subprocess.run(
    ["git", "diff", "--cached", "--no-ext-diff", "--no-color"],
    cwd=root,
    text=True,
    capture_output=True,
    check=False,
).stdout
fingerprint = hashlib.sha256(
    ("\n".join([status_output, diff_text, cached_diff_text])).encode("utf-8")
).hexdigest()
previous_fingerprint = state.get("last_fingerprint")

label = "iteration"
if last_message:
    label = last_message.splitlines()[0].strip()[:120] or label

results_path = root / ".codex-autoresearch" / "results.tsv"
log_path = root / ".codex-autoresearch" / "run.log"

if metric_value is not None and fingerprint != previous_fingerprint:
    state["iterations"] += 1
    state["last_value"] = metric_value
    state["last_label"] = label
    state["last_fingerprint"] = fingerprint
    state["last_transition"] = "measured"
    state["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()

    is_better = False
    best_value = state.get("best_value")
    if best_value is None:
        is_better = True
    elif state["direction"] == "lower" and metric_value < best_value:
        is_better = True
    elif state["direction"] == "higher" and metric_value > best_value:
        is_better = True

    if is_better:
        state["best_value"] = metric_value
        state["best_label"] = label

    with results_path.open("a", encoding="utf-8") as handle:
        handle.write(
            f'{dt.datetime.now(dt.timezone.utc).isoformat()}\t'
            f'{state["iterations"]}\t{metric_value}\t'
            f'{"best" if is_better else "recorded"}\t{label}\n'
        )

with log_path.open("a", encoding="utf-8") as handle:
    handle.write(
        json.dumps(
            {
                "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
                "event": "stop",
                "label": label,
                "metric_exit_code": metric_run.returncode,
                "metric_value": metric_value,
                "fingerprint": fingerprint,
            }
        )
        + "\n"
    )

if metric_value is None:
    state["last_transition"] = "metric-parse-failed"
    state["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
elif fingerprint == previous_fingerprint:
    state["last_transition"] = "continuation-no-new-fingerprint"
    state["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()

write_state(state_path, state)

if state["iterations"] >= state["budget"]:
    state["active"] = False
    state["last_transition"] = "budget-reached"
    state["stopped_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    state["updated_at"] = state["stopped_at"]
    write_state(state_path, state)
    print(
        json.dumps(
            {
                "continue": False,
                "stopReason": "autoresearch budget reached",
                "systemMessage": (
                    "Autoresearch budget reached. "
                    f'Best metric: {state.get("best_value")} ({state.get("best_label") or "n/a"}).'
                ),
            }
        )
    )
    sys.exit(0)

if metric_value is None:
    reason = (
        "Autoresearch is active but the metric command did not yield a parseable value. "
        f'Command: {metric_command}. Regex: {state["metric_regex"]}. '
        "Fix the measurement or adjust the regex before the next stop. "
        "If the goal changed, stop the loop first."
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(0)

best_text = state.get("best_value")
if best_text is None:
    best_text = "none yet"
else:
    best_text = f'{best_text} ({state.get("best_label") or "best"})'

reason = (
    f'Autoresearch is active for goal "{state["goal"]}". '
    f"Current metric: {metric_value}. "
    f"Best metric: {best_text}. "
    f"Budget used: {state['iterations']}/{state['budget']}. "
    "Review the last change, keep edits inside scope, make one more bounded experiment, "
    "and stop again. If the user asks to stop or pivot, run scripts/autoresearch_loop.sh stop first. "
    f'Emit a line that is exactly {state["done_marker"]} or run scripts/autoresearch_loop.sh stop to finish.'
)
print(json.dumps({"decision": "block", "reason": reason}))
PY
