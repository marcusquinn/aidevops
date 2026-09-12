# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline process checks for creative launch guards; no third-party app runs."""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

LAUNCHER = Path(__file__).resolve().parents[1] / "creative-mcp-launcher.py"
SPEC = importlib.util.spec_from_file_location("creative_launcher", LAUNCHER)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CreativeLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="creative-launcher-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / "source"
        self.source.mkdir()
        self.app = self.root / "app"
        self.app.touch()
        self.python = self.root / "python"
        self.python.symlink_to(sys.executable)
        git = self.root / "git"
        git.write_text(f"#!{sys.executable}\n" + """
import os, sys
from pathlib import Path
root = Path(os.environ['HOME'])
(root / 'git-called').touch()
if 'rev-parse' in sys.argv:
    print((root / 'revision').read_text())
elif (root / 'dirty').exists():
    print(' M modified.py')
""", encoding="utf-8")
        git.chmod(0o700)

    def environment(self, app):
        spec = MODULE.APPS[app]
        prefix = spec["prefix"]
        (self.root / "revision").write_text(spec["revision"], encoding="utf-8")
        entry = self.source / spec["entry"]
        entry.parent.mkdir(parents=True, exist_ok=True)
        entry.write_text("""
import json, os, sys
def main():
    print(json.dumps({'payload': sys.stdin.read(), 'env': dict(os.environ), 'args': sys.argv[1:]}))
if __name__ == '__main__':
    main()
""", encoding="utf-8")
        return {
            "HOME": str(self.root), "PATH": str(self.root),
            f"AIDEVOPS_{prefix}_ISOLATED": "1",
            f"AIDEVOPS_{prefix}_CODE_EXECUTION": "approved",
            f"AIDEVOPS_{prefix}_MCP_SOURCE": str(self.source),
            f"AIDEVOPS_{prefix}_MCP_PYTHON": str(self.python),
            f"AIDEVOPS_{prefix}_APP": str(self.app),
        }

    def invoke(self, app, env, action="check", payload=""):
        return subprocess.run([sys.executable, "-I", str(LAUNCHER), app, action],
                              env=env, input=payload, capture_output=True, text=True,
                              timeout=10, check=False)

    def test_missing_consent_never_probes(self):
        for app, spec in MODULE.APPS.items():
            env = self.environment(app)
            del env[f"AIDEVOPS_{spec['prefix']}_CODE_EXECUTION"]
            result = self.invoke(app, env)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertIn("Operator approval", result.stderr)
            self.assertFalse((self.root / "git-called").exists())

    def test_interpreter_symlink_preserves_virtual_environment_path(self):
        actual = MODULE.required_path({"PY": str(self.python)}, "PY", executable=True)
        self.assertEqual(actual, self.python)
        self.assertNotEqual(actual, self.python.resolve())

    def test_missing_app_revision_drift_and_dirty_source_fail(self):
        env = self.environment("ableton")
        self.app.unlink()
        self.assertIn("installed app", self.invoke("ableton", env).stderr)
        self.app.touch()
        (self.root / "revision").write_text("different", encoding="utf-8")
        self.assertIn("revision differs", self.invoke("ableton", env).stderr)
        (self.root / "revision").write_text(MODULE.APPS["ableton"]["revision"], encoding="utf-8")
        (self.root / "dirty").touch()
        self.assertIn("must be clean", self.invoke("ableton", env).stderr)

    def test_ableton_refuses_non_loopback_and_invalid_port(self):
        for change in ({"ABLETON_HOST": "localhost"}, {"ABLETON_HOST": "0.0.0.0"},
                       {"ABLETON_PORT": "0"}, {"ABLETON_PORT": "65536"}):
            env = {**self.environment("ableton"), **change}
            self.assertNotEqual(self.invoke("ableton", env).returncode, 0)
            self.assertFalse((self.root / "git-called").exists())

    def test_check_reports_limits_without_running_server(self):
        env = self.environment("ableton")
        result = self.invoke("ableton", env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("live app operations remain unverified", result.stdout)
        self.assertNotIn("payload", result.stdout)

    def test_run_preserves_stdio_disables_collection_and_drops_unrelated_environment(self):
        env = self.environment("ableton")
        env.update(OPENAI_API_KEY="test-placeholder", PYTHONPATH="untrusted",
                   ABLETON_MCP_DISABLE_TELEMETRY="false", ABLETON_MCP_DISABLE_DATASET="0")
        result = self.invoke("ableton", env, "run", '{"jsonrpc":"2.0","id":1}')
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertIn('"id":1', data["payload"])
        self.assertEqual(data["env"]["ABLETON_MCP_DISABLE_TELEMETRY"], "true")
        self.assertEqual(data["env"]["ABLETON_MCP_DISABLE_DATASET"], "1")
        self.assertNotIn("OPENAI_API_KEY", data["env"])
        self.assertNotIn("PYTHONPATH", data["env"])

    def test_resolve_uses_compact_script_without_granular_or_advanced_arguments(self):
        env = self.environment("davinci-resolve")
        result = self.invoke("davinci-resolve", env, "run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["args"], [])


if __name__ == "__main__":
    unittest.main()
