#!/usr/bin/env python3
import json
import os
import pathlib
import sys


CODEX_HOME = pathlib.Path(os.environ.get("CODEX_HOME", pathlib.Path.home() / ".codex"))
REGISTRY_PATH = CODEX_HOME / "auto-research-codex-registry.json"


def load_registry():
    if not REGISTRY_PATH.exists():
        return {"roots": []}
    try:
        data = json.loads(REGISTRY_PATH.read_text())
    except json.JSONDecodeError:
        return {"roots": []}
    if not isinstance(data, dict):
        return {"roots": []}
    roots = data.get("roots", [])
    if not isinstance(roots, list):
        roots = []
    normalized = []
    for item in roots:
        if isinstance(item, str) and item:
            normalized.append(str(pathlib.Path(item).resolve()))
    return {"roots": sorted(set(normalized))}


def save_registry(data):
    CODEX_HOME.mkdir(parents=True, exist_ok=True)
    REGISTRY_PATH.write_text(json.dumps(data, indent=2) + "\n")


def state_path_for_root(root_str):
    return pathlib.Path(root_str) / ".codex-autoresearch" / "state.json"


def is_active_root(root_str):
    path = state_path_for_root(root_str)
    if not path.exists():
        return False
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError:
        return False
    return bool(isinstance(data, dict) and data.get("active") is True)


def prune_registry():
    data = load_registry()
    data["roots"] = [root for root in data["roots"] if is_active_root(root)]
    save_registry(data)
    return data


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command not in {"add", "remove", "list-active", "has-active"}:
        raise SystemExit("usage: registry.py <add|remove|list-active|has-active> [repo_root]")

    if command == "add":
        if len(sys.argv) < 3:
            raise SystemExit("add requires repo_root")
        root = str(pathlib.Path(sys.argv[2]).resolve())
        data = prune_registry()
        data["roots"] = sorted(set(data["roots"] + [root]))
        save_registry(data)
        print(json.dumps({"roots": data["roots"], "ok": True}, indent=2))
        return

    if command == "remove":
        if len(sys.argv) < 3:
            raise SystemExit("remove requires repo_root")
        root = str(pathlib.Path(sys.argv[2]).resolve())
        data = load_registry()
        data["roots"] = [item for item in data["roots"] if item != root]
        data = prune_registry()
        print(json.dumps({"roots": data["roots"], "ok": True}, indent=2))
        return

    data = prune_registry()
    if command == "list-active":
        print(json.dumps({"roots": data["roots"], "count": len(data["roots"])}, indent=2))
        return

    print(json.dumps({"active": bool(data["roots"]), "count": len(data["roots"])}, indent=2))


if __name__ == "__main__":
    main()
