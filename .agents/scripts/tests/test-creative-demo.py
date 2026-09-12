# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline recipe, export-contract and CLI tests; native apps are checked separately."""

import contextlib
import importlib.util
import io
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from _creative_demo_model import configuration, model  # noqa: E402

SPEC = importlib.util.spec_from_file_location("demo_helper", SCRIPTS / "creative-demo-helper.py")
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)


class RecipeTests(unittest.TestCase):
    def test_bad_parameters_fail_closed(self):
        for supplied in (False, [], "", {"height": True}, {"height": float("nan")},
                         {"height": .1}, {"unknown": 1}, {"finish": "plastic"}):
            with self.subTest(supplied=supplied), self.assertRaises(ValueError):
                configuration("lamp", supplied)
        with self.assertRaises(ValueError):
            configuration("kitchen", {"modules": 3.5})

    def test_hashes_and_ids_are_deterministic(self):
        for demo in ("lamp", "kitchen"):
            first, second = model(demo), model(demo)
            self.assertEqual(first, second)
            ids = [item["id"] for item in first["parts"]]
            self.assertEqual(len(ids), len(set(ids)))
            self.assertIsNone(first["verified_mode"])
            self.assertTrue(all(value > 0 for item in first["parts"] for value in item["size"]))

    def test_configuration_changes_geometry_and_hash_not_stable_ids(self):
        original, changed = model("kitchen"), model("kitchen", {"module_width": .7})
        self.assertNotEqual(original["source_hash"], changed["source_hash"])
        self.assertEqual([p["id"] for p in original["parts"]], [p["id"] for p in changed["parts"]])
        top = next(p for p in changed["parts"] if p["id"] == "kitchen.worktop")
        self.assertAlmostEqual(top["size"][0], 3.55)
        self.assertEqual(len(top["cuts"]), 1)

    def test_lamp_support_contacts_base_and_stem(self):
        parts = {p["id"]: p for p in model("lamp")["parts"]}
        base, collar, stem = (parts["lamp."+key] for key in ("base", "collar", "stem"))
        self.assertAlmostEqual(base["position"][2]+base["size"][2]/2,
                               collar["position"][2]-collar["size"][2]/2)
        self.assertGreaterEqual(collar["position"][2]+collar["size"][2]/2,
                                stem["position"][2]-stem["size"][2]/2)


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="creative-demo-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def glb(self, nodes):
        payload = json.dumps({"nodes": nodes}).encode()
        payload += b" "*((-len(payload)) % 4)
        target = self.root / "scene.glb"
        target.write_bytes(struct.pack("<4sIIII", b"glTF", 2, 20+len(payload), len(payload), 0x4E4F534A)+payload)
        return target

    def test_glb_requires_real_meshes_not_empty_nodes_or_duplicate_ids(self):
        source = {"parts": [{"id": "part.one"}]}
        good = {"mesh": 0, "extras": {"part_id": "part.one"}}
        self.assertEqual(HELPER.verify_glb(self.glb([good]), source), 1)
        for nodes in ([{"extras": good["extras"]}], [good, good], []):
            with self.assertRaises(ValueError):
                HELPER.verify_glb(self.glb(nodes), source)

    def test_glb_rejects_truncation(self):
        path = self.root / "bad.glb"
        path.write_bytes(b"glTF")
        with self.assertRaises(struct.error):
            HELPER.verify_glb(path, {"parts": []})

    def test_cli_refuses_outside_workspace_and_symlink(self):
        with mock.patch.object(Path, "cwd", return_value=self.root):
            with self.assertRaises(ValueError):
                HELPER.within_workspace(self.root.parent / "outside")
            link = self.root / "link"
            link.symlink_to(self.root.parent)
            with self.assertRaises(ValueError):
                HELPER.within_workspace(link / "outside")

    def test_init_is_non_overwriting_and_does_not_install(self):
        target = self.root / "lamp"
        with mock.patch.object(Path, "cwd", return_value=self.root), contextlib.redirect_stdout(io.StringIO()):
            HELPER.init_project("lamp", str(target))
            self.assertTrue((target / "index.html").is_file())
            self.assertFalse((target / "node_modules").exists())
            with self.assertRaises(ValueError):
                HELPER.init_project("lamp", str(target))

    def test_app_logs_survive_timeout_without_forwarding_secrets(self):
        with mock.patch.dict(os.environ, {"EXAMPLE_API_KEY": "synthetic", "PYTHONPATH": "untrusted"}), \
             mock.patch.object(subprocess, "run", side_effect=subprocess.TimeoutExpired("blender", 1)) as run, \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(subprocess.TimeoutExpired):
                HELPER.run_app(["blender"], self.root, "blender", 1)
        self.assertNotIn("EXAMPLE_API_KEY", run.call_args.kwargs["env"])
        self.assertNotIn("PYTHONPATH", run.call_args.kwargs["env"])
        self.assertTrue((self.root / "blender.log").is_file())

    @unittest.skipUnless(shutil.which("node"), "Node is required to check the viewer module")
    def test_viewer_module_syntax(self):
        html = (SCRIPTS.parent / "templates" / "creative-viewer.html").read_text(encoding="utf-8")
        script = html.split('<script type="module">', 1)[1].split("</script>", 1)[0]
        result = subprocess.run(["node", "--check", "--input-type=module"], input=script,
                                capture_output=True, text=True, timeout=10, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
