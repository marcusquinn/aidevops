# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Build kitchen component solids from the same metre-based render recipe."""

import json
import math
import sys
from pathlib import Path

import FreeCAD as App
import Part


def shape_for(item):
    size = [value*1000 for value in item["size"]]
    if item["kind"] == "box":
        shape = Part.makeBox(*size, App.Vector(-size[0]/2, -size[1]/2, -size[2]/2))
    elif item["kind"] == "cylinder":
        shape = Part.makeCylinder(size[0]/2, size[2], App.Vector(0, 0, -size[2]/2))
    elif item["kind"] == "ring":
        shape = Part.makeTorus(size[0]/2, size[2]/2)
    else:
        return None
    for cut in item.get("cuts", []):
        dimensions = [value*1000 for value in cut["size"]]
        corner = App.Vector(*[(cut["offset"][i]-cut["size"][i]/2)*1000 for i in range(3)])
        shape = shape.cut(Part.makeBox(*dimensions, corner))
    angles = [math.degrees(value) for value in item["rotation"]]
    shape.Placement = App.Placement(App.Vector(*[value*1000 for value in item["position"]]),
                                    App.Rotation(angles[2], angles[1], angles[0]))
    return shape


def main():
    source = next((Path(value) for value in reversed(sys.argv) if value.endswith("scene.json")), None)
    if source is None:
        raise ValueError("Pass the generated scene.json with --pass")
    data = json.loads(source.read_text(encoding="utf-8"))
    if data["demo"] != "kitchen" or data["units"] != "m":
        raise ValueError("Only the metre-based kitchen recipe is supported")
    doc = App.newDocument("Kitchen")
    objects, checked, excluded = [], [], []
    for index, item in enumerate(data["parts"]):
        shape = shape_for(item)
        if shape is None:
            excluded.append(item["id"])
            continue
        if shape.isNull() or not shape.isValid() or shape.Volume <= 0:
            raise ValueError("Invalid solid: " + item["id"])
        obj = doc.addObject("Part::Feature", f"Part{index:04}")
        obj.Label = item["id"]
        obj.addProperty("App::PropertyString", "PartId").PartId = item["id"]
        obj.addProperty("App::PropertyString", "AssemblyId").AssemblyId = item["assembly"]
        obj.Shape = shape
        objects.append(obj)
        checked.append({"part_id": item["id"], "volume_mm3": shape.Volume, "valid": True})
    doc.recompute()
    out = source.parent
    doc.saveAs(str(out / "kitchen.FCStd"))
    Part.export(objects, str(out / "kitchen.step"))
    worktop = next(obj for obj in objects if obj.PartId == "kitchen.worktop")
    expected_width = (data["parameters"]["modules"]*data["parameters"]["module_width"]+.05)*1000
    if not math.isclose(worktop.Shape.BoundBox.XLength, expected_width, abs_tol=.001):
        raise ValueError("Worktop width differs from configured dimensions")
    App.closeDocument(doc.Name)
    reopened = App.openDocument(str(out / "kitchen.FCStd"))
    if sorted(obj.PartId for obj in reopened.Objects) != sorted(item["part_id"] for item in checked):
        raise ValueError("Native project part IDs did not survive reopening")
    if any(not obj.Shape.isValid() for obj in reopened.Objects):
        raise ValueError("Native project contains an invalid reopened solid")
    App.closeDocument(reopened.Name)
    imported = Part.read(str(out / "kitchen.step"))
    if len(imported.Solids) != len(checked) or not imported.isValid():
        raise ValueError("STEP solids did not survive round-trip import")
    report = {"source_hash": data["source_hash"], "recipe_hash": data.get("recipe_hash"), "freecad": App.Version()[:3], "units": "mm",
              "parts": checked, "excluded_reference_geometry": excluded,
              "native_reopened": True, "step_reimported_solids": len(imported.Solids),
              "worktop_width_mm": expected_width,
              "production_certification": False}
    (out / "cad-verification.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    print(json.dumps({"valid_solids": len(checked), "excluded": excluded}))


# FreeCADCmd imports command-line .py files rather than running them as __main__.
# This is an app entry point, not an importable library.
main()
