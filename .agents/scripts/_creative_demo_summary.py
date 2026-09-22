# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Compact scene and verified run evidence; full native reports stay on disk."""

import json
import math
from collections import Counter


def scene_summary(scene):
    return {"schema_version": 1, "demo": scene["demo"], "units": scene["units"],
            "parameters": scene["parameters"], "source_hash": scene["source_hash"],
            "recipe_hash": scene["recipe_hash"], "part_count": len(scene["parts"]),
            "assemblies": dict(sorted(Counter(item["assembly"] for item in scene["parts"]).items())),
            "details": {"recipe": "scene.json", "parts": "parts.csv"}}


def _report(out, name):
    path = out / name
    if path.is_symlink() or path.stat().st_size > 2*1024*1024:
        raise ValueError(f"Invalid {name}; inspect the retained app log")
    return json.loads(path.read_text(encoding="utf-8"))


def _expect(condition, label):
    if not condition:
        raise ValueError(f"{label} verification disagrees with the recipe or exported geometry")


def _provenance(report, scene, units, label):
    _expect(isinstance(report, dict), label)
    for key, value in (("source_hash", scene["source_hash"]), ("recipe_hash", scene["recipe_hash"]),
                       ("units", units)):
        _expect(report.get(key) == value, label)


def _visual_summary(out, scene, exported):
    visual = _report(out, "verification.json")
    _provenance(visual, scene, scene["units"], "Blender")
    _expect(visual.get("part_count") == exported, "Blender")
    _expect(visual.get("part_ids") == [item["id"] for item in scene["parts"]], "Blender")
    _expect(isinstance(visual.get("blender"), str), "Blender")
    return {"exported_meshes": exported, "blender_version": visual["blender"],
            "mesh_part_ids_matched": True}


def _valid_solid(part):
    if not isinstance(part, dict):
        return False
    volume = part.get("volume_mm3")
    if part.get("valid") is not True:
        return False
    if type(volume) not in (int, float):
        return False
    return math.isfinite(volume) and volume > 0


def _cad_summary(out, scene):
    cad = _report(out, "cad-verification.json")
    _provenance(cad, scene, "mm", "CAD")
    solids = cad.get("parts")
    _expect(isinstance(solids, list), "CAD")
    _expect(all(_valid_solid(part) for part in solids), "CAD")
    supported = ("box", "cylinder", "ring")
    solid_ids = [item["id"] for item in scene["parts"] if item["kind"] in supported]
    excluded_ids = [item["id"] for item in scene["parts"] if item["kind"] not in supported]
    _expect([part["part_id"] for part in solids] == solid_ids, "CAD")
    _expect(cad.get("excluded_reference_geometry") == excluded_ids, "CAD")
    _expect(cad.get("step_reimported_solids") == len(solids), "CAD")
    _expect(cad.get("native_reopened") is True, "CAD")
    width = cad.get("worktop_width_mm")
    _expect(type(width) in (int, float), "CAD")
    expected_width = (scene["parameters"]["modules"]*scene["parameters"]["module_width"]+.05)*1000
    _expect(math.isclose(width, expected_width, abs_tol=.001), "CAD")
    _expect(isinstance(cad.get("freecad"), list), "CAD")
    return {"valid_solids": len(solids), "step_reimported_solids": len(solids),
            "worktop_width_mm": width, "freecad_version": cad["freecad"],
            "excluded_reference_count": len(excluded_ids)}


def verified_summary(out, scene, exported, cad):
    result = _visual_summary(out, scene, exported)
    if cad:
        result["cad"] = _cad_summary(out, scene)
    return result
