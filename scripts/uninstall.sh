#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

if [[ $# -eq 0 ]]; then
  set -- "$(git rev-parse --show-toplevel)"
fi

python3 - "$SKILL_ROOT" "$@" <<'PY'
import json
import pathlib
import subprocess
import sys

skill_root = pathlib.Path(sys.argv[1])
repo_specs = sys.argv[2:]

commands = {
    f'/bin/bash "{skill_root}/scripts/hook.sh" session-start',
    f'/bin/bash "{skill_root}/scripts/hook.sh" user-prompt',
    f'/bin/bash "{skill_root}/scripts/hook.sh" stop',
}


def canonical_repo(spec: str) -> pathlib.Path:
    candidate = pathlib.Path(spec)
    if not candidate.is_absolute():
        candidate = (pathlib.Path.cwd() / candidate).resolve()
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=candidate,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(result.stderr.strip() or f"not inside a git repo: {candidate}")
    return pathlib.Path(result.stdout.strip()).resolve()

results = []
for repo in [canonical_repo(spec) for spec in repo_specs]:
    hooks_path = repo / ".codex" / "hooks.json"
    if not hooks_path.exists():
        results.append({"repo": str(repo), "hooks_path": str(hooks_path), "removed": 0, "ok": True})
        continue

    text = hooks_path.read_text()
    decoder = json.JSONDecoder()
    try:
        data, _ = decoder.raw_decode(text.lstrip())
    except json.JSONDecodeError:
        data = {"hooks": {}}
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
    results.append({"repo": str(repo), "hooks_path": str(hooks_path), "removed": removed, "ok": True})

print(json.dumps({"results": results, "ok": True}, indent=2))
PY
