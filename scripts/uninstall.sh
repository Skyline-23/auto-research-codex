#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
HOOKS_PATH="$CODEX_HOME/hooks.json"

mkdir -p "$CODEX_HOME"

python3 - "$HOOKS_PATH" "$SKILL_ROOT" <<'PY'
import json
import pathlib
import sys

hooks_path = pathlib.Path(sys.argv[1])
skill_root = pathlib.Path(sys.argv[2])

commands = {
    f'/bin/bash "{skill_root}/scripts/hook.sh" session-start',
    f'/bin/bash "{skill_root}/scripts/hook.sh" user-prompt',
    f'/bin/bash "{skill_root}/scripts/hook.sh" stop',
}

if not hooks_path.exists():
    print(json.dumps({"hooks_path": str(hooks_path), "removed": 0, "ok": True}, indent=2))
    raise SystemExit(0)

data = json.loads(hooks_path.read_text())
if not isinstance(data, dict):
    raise SystemExit("hooks.json must contain an object")

hooks = data.get("hooks", {})
if not isinstance(hooks, dict):
    raise SystemExit("hooks.json field 'hooks' must contain an object")

removed = 0
for event_name in list(hooks.keys()):
    event_groups = hooks.get(event_name, [])
    if not isinstance(event_groups, list):
        continue
    filtered_groups = []
    for group in event_groups:
        group_hooks = group.get("hooks", []) if isinstance(group, dict) else []
        if not isinstance(group_hooks, list):
            filtered_groups.append(group)
            continue
        next_hooks = []
        for hook in group_hooks:
            if isinstance(hook, dict) and hook.get("command") in commands:
                removed += 1
                continue
            next_hooks.append(hook)
        if next_hooks:
            new_group = dict(group)
            new_group["hooks"] = next_hooks
            filtered_groups.append(new_group)
    if filtered_groups:
        hooks[event_name] = filtered_groups
    else:
        hooks.pop(event_name, None)

data["hooks"] = hooks
hooks_path.write_text(json.dumps(data, indent=2) + "\n")
print(json.dumps({"hooks_path": str(hooks_path), "removed": removed, "ok": True}, indent=2))
PY
