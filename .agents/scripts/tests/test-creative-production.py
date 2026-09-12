# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1]


def load_script(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


launcher = load_script("creative_mcp_launcher", "creative-mcp-launcher.py")


class CreativeLauncherTests(unittest.TestCase):
    def test_refuses_without_consent_before_command_lookup(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, "operator approval"):
                launcher.validate("freecad")

    def test_refuses_headless_execution(self):
        with mock.patch.dict(os.environ, {"FULL_LOOP_HEADLESS": "1"}, clear=True):
            with self.assertRaisesRegex(ValueError, "headless worker"):
                launcher.validate("davinci-resolve")

    def test_ableton_requires_telemetry_opt_out(self):
        environment = {
            "AIDEVOPS_CREATIVE_EXTERNAL_EXECUTION_APPROVED": "1",
            "AIDEVOPS_CREATIVE_ISOLATION_CONFIRMED": "1",
        }
        with mock.patch.dict(os.environ, environment, clear=True):
            with self.assertRaisesRegex(ValueError, "telemetry"):
                launcher.validate("ableton-live")

    def test_accepts_absolute_reviewed_executable_without_running_it(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "adapter"
            executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            executable.chmod(executable.stat().st_mode | stat.S_IXUSR)
            environment = {
                "AIDEVOPS_CREATIVE_EXTERNAL_EXECUTION_APPROVED": "1",
                "AIDEVOPS_CREATIVE_ISOLATION_CONFIRMED": "1",
                "FREECAD_MCP_COMMAND_JSON": json.dumps([str(executable), "--stdio"]),
            }
            with mock.patch.dict(os.environ, environment, clear=True):
                self.assertEqual(launcher.validate("freecad"), [str(executable), "--stdio"])

    def test_execution_environment_drops_credentials_and_consent_flags(self):
        environment = {"HOME": "/safe/home", "PATH": "/safe/bin", "API_TOKEN": "secret", "AIDEVOPS_CREATIVE_EXTERNAL_EXECUTION_APPROVED": "1"}
        with mock.patch.dict(os.environ, environment, clear=True):
            self.assertEqual(launcher.execution_environment(), {"HOME": "/safe/home", "PATH": "/safe/bin"})


class CreativeDemoTests(unittest.TestCase):
    def run_demo(self, *arguments: str) -> Path:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        output = Path(directory.name) / "package"
        result = subprocess.run(
            [sys.executable, str(SCRIPTS / "creative-demo.py"), *arguments, "--output", str(output)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return output

    def test_bankers_lamp_package_is_rebuildable_and_named(self):
        output = self.run_demo("bankers-lamp", "--shade-tilt", "22")
        recipe = json.loads((output / "recipe.json").read_text(encoding="utf-8"))
        self.assertEqual(recipe["parameters"]["shade_tilt_deg"], 22.0)
        self.assertIn("lamp.shade.001", {part["id"] for part in recipe["parts"]})
        self.assertTrue((output / "beauty-render.svg").is_file())

    def test_kitchen_updates_consistent_dimension_check_and_parts(self):
        output = self.run_demo("modern-kitchen", "--room-width", "3600", "--cabinet-width", "600")
        recipe = json.loads((output / "recipe.json").read_text(encoding="utf-8"))
        base_parts = [part for part in recipe["parts"] if part["name"] == "base_cabinet"]
        self.assertEqual(len(base_parts), 6)
        self.assertEqual(len([part for part in recipe["parts"] if part["name"] == "cabinet_door"]), 6)
        self.assertEqual(len([part for part in recipe["parts"] if part["name"] == "cabinet_drawer"]), 6)
        self.assertEqual(recipe["checks"]["cabinet_run_width"], 3600.0)
        self.assertTrue(recipe["checks"]["fits_room_width"])
        evidence = json.loads((output / "evidence.json").read_text(encoding="utf-8"))
        self.assertIn("stable_part_ids_unique", evidence["verification_achieved"])
        self.assertTrue((output / "exploded-view.svg").is_file())


if __name__ == "__main__":
    unittest.main()
