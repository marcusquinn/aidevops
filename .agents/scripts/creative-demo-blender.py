# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Render the original creative demo in a factory-startup headless Blender."""

import argparse
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _creative_demo_blender_geometry import geometry, materials  # noqa: E402

def light(name, position, target, **settings):
    data = bpy.data.lights.new(name, "AREA")
    data.energy, data.shape, data.size = settings["energy"], "DISK", settings["size"]
    data.color = settings.get("color", (1, 1, 1))
    obj = bpy.data.objects.new(name, data)
    bpy.context.collection.objects.link(obj)
    obj.location = position
    obj.rotation_euler = (Vector(target)-obj.location).to_track_quat("-Z", "Y").to_euler()


def studio(demo, mats, parameters):
    lamp = demo == "lamp"
    scale = parameters["height"]/.44 if lamp else 1
    target = (0, 0, .24*scale) if lamp else (0, 0, 1.05)
    bpy.ops.mesh.primitive_plane_add(size=200 if lamp else 20, location=(0, 0, -.001))
    floor = bpy.context.object
    floor.name = "Studio floor (not a part)"
    floor.data.materials.append(mats["oak"] if lamp else mats["stone"])
    if lamp:
        light("Large softbox", (-.65, -.5, 1.1), target, energy=18, size=.7)
        light("Rim softbox", (.6, .4, .85), target, energy=23, size=.55, color=(.78, .88, 1))
        light("Front fill", (.3, -.8, .6), target, energy=4, size=.6)
        light("Bulb downward", (0, -.005*scale, .361*scale), (0, 0, 0), energy=.8*scale*scale,
              size=.11*scale, color=(1, .74, .4))
        camera_location = (.63, -.9, .57)
    else:
        bpy.ops.mesh.primitive_cube_add(size=1, location=(0, .42, 3))
        wall = bpy.context.object
        wall.dimensions = (20, .10, 6)
        wall.data.materials.append(mats["stone"])
        light("Window", (-3, -2, 4), target, energy=450, size=3)
        light("Fill", (3, -1, 3.5), target, energy=180, size=3)
        camera_location = (3.7, -5.7, 3.2)
    bpy.ops.object.camera_add(location=camera_location)
    camera = bpy.context.object
    camera.rotation_euler = (Vector(target)-camera.location).to_track_quat("-Z", "Y").to_euler()
    camera.data.lens = 52 if lamp else 45
    bpy.context.scene.camera = camera
    return Vector(target)


def frame_camera(objects, target):
    """Keep supported parameter changes inside the actual render projection."""
    from bpy_extras.object_utils import world_to_camera_view

    scene = bpy.context.scene
    points = [obj.matrix_world @ Vector(corner) for obj in objects for corner in obj.bound_box]
    for _ in range(12):
        bpy.context.view_layer.update()
        projected = [world_to_camera_view(scene, scene.camera, point) for point in points]
        if all(.025 <= point.x <= .975 and .025 <= point.y <= .975 and point.z > 0 for point in projected):
            return [min(p.x for p in projected), min(p.y for p in projected),
                    max(p.x for p in projected), max(p.y for p in projected)]
        scene.camera.location = target + (scene.camera.location-target)*1.12
    raise ValueError("Could not frame all configured parts within the bounded camera adjustment")


def export_meshes(objects, out):
    """Export evaluated geometry without destroying editable native curves/modifiers."""
    bpy.ops.object.select_all(action="DESELECT")
    graph = bpy.context.evaluated_depsgraph_get()
    copies = []
    try:
        for original in objects:
            mesh = bpy.data.meshes.new_from_object(original.evaluated_get(graph))
            obj = bpy.data.objects.new(original.name+".export", mesh)
            bpy.context.collection.objects.link(obj)
            obj.matrix_world = original.matrix_world.copy()
            for key, value in original.items():
                obj[key] = value
            obj.select_set(True)
            copies.append(obj)
        bpy.ops.export_scene.gltf(filepath=str(out / "scene.glb"), export_format="GLB",
                                  use_selection=True, export_extras=True, export_apply=True)
    finally:
        for obj in copies:
            mesh = obj.data
            bpy.data.objects.remove(obj, do_unlink=True)
            bpy.data.meshes.remove(mesh)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("scene")
    parser.add_argument("--samples", type=int, default=32)
    parser.add_argument("--render", action="store_true")
    args = parser.parse_args(sys.argv[sys.argv.index("--")+1:])
    path = Path(args.scene).resolve()
    data = json.loads(path.read_text(encoding="utf-8"))
    out = path.parent
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    mats = materials(data["materials"])
    objects = [geometry(item, mats) for item in data["parts"]]
    if data["demo"] == "lamp":
        pivot = Vector((0, 0, .366*data["parameters"]["height"]/.44))
        angle = math.radians(data["parameters"]["shade_tilt"])
        from mathutils import Matrix
        rotation = Matrix.Rotation(angle, 4, "X")
        for obj in objects:
            if obj["assembly"] == "shade":
                obj.location = pivot + rotation.to_3x3() @ (obj.location-pivot)
                obj.rotation_euler.x += angle
    bpy.context.view_layer.update()
    verification = {"source_hash": data["source_hash"], "recipe_hash": data.get("recipe_hash"), "blender": bpy.app.version_string,
                    "part_count": len(objects), "part_ids": [obj["part_id"] for obj in objects],
                    "units": "m", "visual_review": "required", "production_certification": False}
    export_meshes(objects, out)
    target = studio(data["demo"], mats, data["parameters"])
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.render.engine = "CYCLES"
    scene.cycles.samples = args.samples
    scene.cycles.use_denoising = True
    scene.render.resolution_x, scene.render.resolution_y = 1000, 800
    scene.render.resolution_percentage = 100
    verification["projected_part_bounds"] = frame_camera(objects, target)
    scene.world.use_nodes = True
    scene.world.node_tree.nodes["Background"].inputs["Color"].default_value = (.25, .28, .32, 1)
    scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = .3
    scene.render.filepath = str(out / "render.png")
    bpy.ops.wm.save_as_mainfile(filepath=str(out / "scene.blend"))
    if args.render:
        bpy.ops.render.render(write_still=True)
    (out / "verification.json").write_text(json.dumps(verification, indent=2)+"\n", encoding="utf-8")
    print(json.dumps(verification))


if __name__ == "__main__":
    main()
