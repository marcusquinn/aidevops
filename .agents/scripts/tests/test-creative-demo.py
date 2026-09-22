# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline recipe, export-contract and CLI tests; native apps are checked separately."""

import argparse
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

    def test_live_stage_receipts_are_bounded_and_not_app_logs(self):
        code = ("import pathlib,sys,time; "
                "p=pathlib.Path(sys.argv[1]); p.write_text('rendering'); "
                "print('unrelated native output'); time.sleep(.6); p.write_text('saved')")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            HELPER.run_app([sys.executable, "-c", code, str(self.root / "blender.stage")],
                           self.root, "blender", 3)
        self.assertIn("AIDEVOPS_PROGRESS: blender:rendering", output.getvalue())
        self.assertIn("AIDEVOPS_PROGRESS: blender:saved", output.getvalue())
        self.assertIn("AIDEVOPS_PROGRESS: blender:completed", output.getvalue())
        self.assertNotIn("unrelated native output", output.getvalue())
        self.assertIn("unrelated native output", (self.root / "blender.log").read_text())

    def test_live_timeout_retains_log_without_success_receipt(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaises(subprocess.TimeoutExpired):
            HELPER.run_app([sys.executable, "-c", "import time; time.sleep(5)"],
                           self.root, "blender", 1)
        self.assertTrue((self.root / "blender.log").is_file())
        self.assertNotIn("blender:completed", output.getvalue())

    def test_manifest_requires_matching_native_evidence(self):
        scene = model("lamp")
        scene["recipe_hash"] = "recipe"
        summary = HELPER.scene_summary(scene)
        self.assertEqual(summary["part_count"], 28)
        self.assertNotIn("parts", summary)
        self.assertEqual(sum(summary["assemblies"].values()), 28)
        report = {"source_hash": scene["source_hash"], "recipe_hash": "recipe", "units": "m",
                  "part_count": 28, "part_ids": [item["id"] for item in scene["parts"]],
                  "blender": "5.2.1"}
        (self.root / "verification.json").write_text(json.dumps(report))
        self.assertEqual(HELPER.verified_summary(self.root, scene, 28, False)["exported_meshes"], 28)
        report["recipe_hash"] = "different"
        (self.root / "verification.json").write_text(json.dumps(report))
        with self.assertRaisesRegex(ValueError, "Blender verification disagrees"):
            HELPER.verified_summary(self.root, scene, 28, False)

    def test_cad_summary_checks_part_identity_and_roundtrip(self):
        scene = model("kitchen")
        scene["recipe_hash"] = "recipe"
        ids = [item["id"] for item in scene["parts"]]
        visual = {"source_hash": scene["source_hash"], "recipe_hash": "recipe", "units": "m",
                  "part_count": len(ids), "part_ids": ids, "blender": "5.2.1"}
        (self.root / "verification.json").write_text(json.dumps(visual))
        solids = [item["id"] for item in scene["parts"] if item["kind"] != "curve"]
        cad = {"source_hash": scene["source_hash"], "recipe_hash": "recipe", "units": "mm",
               "parts": [{"part_id": key, "volume_mm3": 1, "valid": True} for key in solids],
               "excluded_reference_geometry": [item["id"] for item in scene["parts"] if item["kind"] == "curve"],
               "step_reimported_solids": len(solids), "native_reopened": True,
               "worktop_width_mm": 3050, "freecad": [1, 0, 0]}
        path = self.root / "cad-verification.json"
        path.write_text(json.dumps(cad))
        self.assertEqual(HELPER.verified_summary(self.root, scene, len(ids), True)["cad"]["valid_solids"], len(solids))
        cad["parts"][0]["part_id"] = "other"
        path.write_text(json.dumps(cad))
        with self.assertRaisesRegex(ValueError, "CAD verification disagrees"):
            HELPER.verified_summary(self.root, scene, len(ids), True)

    def test_build_writes_compact_manifest_only_after_checks(self):
        with mock.patch.object(Path, "cwd", return_value=self.root), contextlib.redirect_stdout(io.StringIO()):
            HELPER.init_project("lamp", str(self.root / "lamp"))
        project = self.root / "lamp"
        args = argparse.Namespace(project=str(project), run="preview", cad=False, render=False,
                                  blender=None, freecad=None, samples=16, timeout=2)

        def fake_app(_command, out, _name, _timeout):
            scene = json.loads((out / "scene.json").read_text())
            self.assertTrue((out / "scene-summary.json").is_file())
            self.assertFalse((out / "run.json").exists())
            self.glb([{"mesh": index, "extras": {"part_id": part["id"]}}
                      for index, part in enumerate(scene["parts"])]).replace(out / "scene.glb")
            (out / "scene.blend").write_bytes(b"native")
            report = {"source_hash": scene["source_hash"], "recipe_hash": scene["recipe_hash"],
                      "units": "m", "part_count": len(scene["parts"]),
                      "part_ids": [item["id"] for item in scene["parts"]], "blender": "5.2.1"}
            (out / "verification.json").write_text(json.dumps(report))

        with mock.patch.object(HELPER, "executable", return_value="/installed/blender"), \
                mock.patch.object(HELPER, "run_app", side_effect=fake_app), \
                mock.patch.object(Path, "cwd", return_value=self.root), \
                contextlib.redirect_stdout(io.StringIO()):
            HELPER.build(args)
        out = project / "runs" / "preview"
        run = json.loads((out / "run.json").read_text())
        self.assertEqual(run["summary"]["checks"]["exported_meshes"], 28)
        self.assertEqual(run["summary"]["scene"], "scene-summary.json")
        self.assertEqual(run["visual_review"], "required")
        self.assertFalse(run["production_certification"])

        with mock.patch.object(Path, "cwd", return_value=self.root), contextlib.redirect_stdout(io.StringIO()):
            HELPER.init_project("lamp", str(self.root / "bad"))
        args.project, args.run = str(self.root / "bad"), "tampered"

        def tampered_app(command, out, name, timeout):
            fake_app(command, out, name, timeout)
            report_path = out / "verification.json"
            report = json.loads(report_path.read_text())
            report["source_hash"] = "wrong"
            report_path.write_text(json.dumps(report))

        with mock.patch.object(HELPER, "executable", return_value="/installed/blender"), \
                mock.patch.object(HELPER, "run_app", side_effect=tampered_app), \
                mock.patch.object(Path, "cwd", return_value=self.root), \
                contextlib.redirect_stdout(io.StringIO()), \
                self.assertRaisesRegex(ValueError, "Blender verification disagrees"):
            HELPER.build(args)
        self.assertFalse((self.root / "bad" / "runs" / "tampered" / "run.json").exists())

    @unittest.skipUnless(shutil.which("node"), "Node is required to check the viewer module")
    def test_viewer_module_syntax(self):
        html = (SCRIPTS.parent / "templates" / "creative-viewer.html").read_text(encoding="utf-8")
        script = html.split('<script type="module">', 1)[1].split("</script>", 1)[0]
        result = subprocess.run(["node", "--check", "--input-type=module"], input=script,
                                capture_output=True, text=True, timeout=10, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
