#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG_PATH="$CODEX_HOME/config.toml"
HOOKS_PATH="$CODEX_HOME/hooks.json"

mkdir -p "$CODEX_HOME"

python3 - "$CONFIG_PATH" "$HOOKS_PATH" "$SKILL_ROOT" <<'PY'
import json
import pathlib
import re
import sys

config_path = pathlib.Path(sys.argv[1])
hooks_path = pathlib.Path(sys.argv[2])
skill_root = pathlib.Path(sys.argv[3])

session_command = f'/bin/bash "{skill_root}/scripts/hook.sh" session-start'
prompt_command = f'/bin/bash "{skill_root}/scripts/hook.sh" user-prompt'
stop_command = f'/bin/bash "{skill_root}/scripts/hook.sh" stop'


def ensure_feature_flag(path: pathlib.Path) -> None:
    text = path.read_text() if path.exists() else ""
    lines = text.splitlines()
    if not lines:
        path.write_text("[features]\ncodex_hooks = true\n")
        return

    output = []
    in_features = False
    inserted = False
    replaced = False

    for line in lines:
        section_match = re.match(r"\s*\[(.+?)\]\s*$", line)
        if section_match:
            if in_features and not inserted and not replaced:
                output.append("codex_hooks = true")
                inserted = True
            in_features = section_match.group(1).strip() == "features"
            output.append(line)
            continue

        if in_features and re.match(r"\s*codex_hooks\s*=", line):
            output.append("codex_hooks = true")
            inserted = True
            replaced = True
            continue

        output.append(line)

    if in_features and not inserted and not replaced:
        output.append("codex_hooks = true")
        inserted = True

    if not inserted and not replaced:
        if output and output[-1] != "":
            output.append("")
        output.extend(["[features]", "codex_hooks = true"])

    path.write_text("\n".join(output).rstrip() + "\n")


def load_hooks(path: pathlib.Path) -> dict:
    if not path.exists():
        return {"hooks": {}}
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise SystemExit("hooks.json must contain an object")
    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise SystemExit("hooks.json field 'hooks' must contain an object")
    return data


def ensure_group(event_groups, command, status_message, matcher=None, timeout=None):
    for group in event_groups:
        for hook in group.get("hooks", []):
            if hook.get("command") == command:
                if status_message:
                    hook["statusMessage"] = status_message
                if timeout is not None:
                    hook["timeout"] = timeout
                if matcher is not None:
                    group["matcher"] = matcher
                elif "matcher" in group:
                    group.pop("matcher", None)
                return

    hook = {"type": "command", "command": command}
    if status_message:
        hook["statusMessage"] = status_message
    if timeout is not None:
        hook["timeout"] = timeout
    group = {"hooks": [hook]}
    if matcher is not None:
        group["matcher"] = matcher
    event_groups.append(group)


ensure_feature_flag(config_path)
data = load_hooks(hooks_path)
hooks = data["hooks"]

session_groups = hooks.setdefault("SessionStart", [])
prompt_groups = hooks.setdefault("UserPromptSubmit", [])
stop_groups = hooks.setdefault("Stop", [])

ensure_group(
    session_groups,
    session_command,
    "Autoresearch: loading experiment state",
    matcher="startup|resume",
    timeout=5,
)
ensure_group(
    prompt_groups,
    prompt_command,
    "Autoresearch: refreshing experiment state",
    timeout=5,
)
ensure_group(
    stop_groups,
    stop_command,
    "Autoresearch: evaluating experiment loop",
    timeout=30,
)

hooks_path.write_text(json.dumps(data, indent=2) + "\n")
print(
    json.dumps(
        {
            "config_path": str(config_path),
            "hooks_path": str(hooks_path),
            "commands": [session_command, prompt_command, stop_command],
            "ok": True,
        },
        indent=2,
    )
)
PY
