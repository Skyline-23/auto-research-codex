#!/usr/bin/env python3
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parent


def run(args, *, cwd=None):
    return subprocess.run(
        args,
        cwd=cwd,
        text=True,
        input="",
        capture_output=True,
        check=False,
    )


def init_git_repo(path: pathlib.Path) -> None:
    run(["git", "init", "-q"], cwd=path)
    run(["git", "config", "user.name", "Codex Test"], cwd=path)
    run(["git", "config", "user.email", "codex@example.com"], cwd=path)
    (path / "README.md").write_text("test\n")
    run(["git", "add", "README.md"], cwd=path)
    run(["git", "commit", "-qm", "init"], cwd=path)


def expected_commands():
    return {
        f'/bin/bash "{REPO_ROOT}/scripts/hook.sh" session-start',
        f'/bin/bash "{REPO_ROOT}/scripts/hook.sh" user-prompt',
        f'/bin/bash "{REPO_ROOT}/scripts/hook.sh" stop',
    }


def commands_in_hooks(hooks_path: pathlib.Path):
    if not hooks_path.exists():
        return set()
    data = json.loads(hooks_path.read_text())
    hooks = data.get("hooks", {})
    commands = set()
    for groups in hooks.values():
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict):
                continue
            for hook in group.get("hooks", []):
                if isinstance(hook, dict) and "command" in hook:
                    commands.add(hook["command"])
    return commands


class AutoresearchRepoLocalHookTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = pathlib.Path(tempfile.mkdtemp(prefix="autoresearch-repo-local-"))

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_setup_and_stop_manage_hooks_in_each_tracked_repo(self):
        primary = self.tmpdir / "primary"
        secondary = self.tmpdir / "secondary"
        primary.mkdir()
        secondary.mkdir()
        init_git_repo(primary)
        init_git_repo(secondary)
        primary = primary.resolve()
        secondary = secondary.resolve()

        setup = run(
            [
                "/bin/bash",
                str(REPO_ROOT / "scripts" / "autoresearch_loop.sh"),
                "setup",
                "--repo",
                str(primary),
                "--repo",
                str(secondary),
                "--goal",
                "Keep hooks repo-local",
                "--metric-command",
                "printf 'score: 1\\n'",
                "--metric-regex",
                r"score: ([0-9.]+)",
                "--direction",
                "higher",
                "--in-scope",
                str(primary / "."),
                "--in-scope",
                str(secondary / "."),
                "--max-experiments",
                "1",
            ],
            cwd=primary,
        )
        self.assertEqual(setup.returncode, 0, msg=setup.stderr or setup.stdout)

        primary_hooks = primary / ".codex" / "hooks.json"
        secondary_hooks = secondary / ".codex" / "hooks.json"
        primary_config = primary / ".codex" / "config.toml"
        secondary_config = secondary / ".codex" / "config.toml"
        self.assertTrue(primary_hooks.exists())
        self.assertTrue(secondary_hooks.exists())
        self.assertTrue(primary_config.exists())
        self.assertTrue(secondary_config.exists())
        self.assertIn("codex_hooks = true", primary_config.read_text())
        self.assertIn("codex_hooks = true", secondary_config.read_text())
        expected = expected_commands()
        self.assertTrue(expected.issubset(commands_in_hooks(primary_hooks)))
        self.assertTrue(expected.issubset(commands_in_hooks(secondary_hooks)))

        stop = run(
            [
                "/bin/bash",
                str(REPO_ROOT / "scripts" / "autoresearch_loop.sh"),
                "stop",
            ],
            cwd=primary,
        )
        self.assertEqual(stop.returncode, 0, msg=stop.stderr or stop.stdout)
        self.assertTrue(commands_in_hooks(primary_hooks).isdisjoint(expected))
        self.assertTrue(commands_in_hooks(secondary_hooks).isdisjoint(expected))


if __name__ == "__main__":
    unittest.main()
