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


def materials(specs):
    result = {}
    for name, spec in specs.items():
        mat = bpy.data.materials.new(name)
        mat.use_nodes = True
        shader = mat.node_tree.nodes.get("Principled BSDF")
        shader.inputs["Base Color"].default_value = spec["color"]
        shader.inputs["Roughness"].default_value = spec.get("roughness", .35)
        shader.inputs["Metallic"].default_value = spec.get("metallic", 0)
        shader.inputs["Transmission Weight"].default_value = spec.get("transmission", 0)
        shader.inputs["IOR"].default_value = 1.46
        if spec.get("emission"):
            shader.inputs["Emission Color"].default_value = spec["color"]
            shader.inputs["Emission Strength"].default_value = spec["emission"]
        result[name] = mat
    return result


def dome(item):
    width, depth, height = item["size"]
    segments, rings = 96, 24
    vertices, faces = [], []
    for row in range(rings):
        latitude = row/rings*math.pi/2
        for column in range(segments):
            angle = column/segments*math.tau
            vertices.append((width/2*math.cos(angle)*math.cos(latitude),
                             depth/2*math.sin(angle)*math.cos(latitude), height*math.sin(latitude)))
    for row in range(rings-1):
        for column in range(segments):
            next_column = (column+1) % segments
            faces.append((row*segments+column, row*segments+next_column,
                          (row+1)*segments+next_column, (row+1)*segments+column))
    pole = len(vertices)
    vertices.append((0, 0, height))
    for column in range(segments):
        faces.append(((rings-1)*segments+column, (rings-1)*segments+(column+1) % segments, pole))
    mesh = bpy.data.meshes.new(item["id"])
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(item["id"], mesh)
    bpy.context.collection.objects.link(obj)
    return obj


def curve(item):
    data = bpy.data.curves.new(item["id"], "CURVE")
    data.dimensions = "3D"
    data.bevel_depth = item["size"][2]/2 if item["kind"] == "ring" else item.get("radius", .0022)
    data.bevel_resolution = 4
    spline = data.splines.new("BEZIER")
    if item["kind"] == "ring":
        points = [(item["size"][0]/2*math.cos(i*math.tau/32),
                   item["size"][1]/2*math.sin(i*math.tau/32), 0) for i in range(32)]
        spline.use_cyclic_u = True
    else:
        points = item["points"]
    spline.bezier_points.add(len(points)-1)
    for point, position in zip(spline.bezier_points, points):
        point.co = position
        point.handle_left_type = "AUTO"
        point.handle_right_type = "AUTO"
    obj = bpy.data.objects.new(item["id"], data)
    bpy.context.collection.objects.link(obj)
    return obj


def apply_cuts(obj, item):
    for cut in item.get("cuts", []):
        bpy.ops.mesh.primitive_cube_add(size=1, location=cut["offset"])
        cutter = bpy.context.object
        cutter.dimensions = cut["size"]
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        boolean = obj.modifiers.new("Opening", "BOOLEAN")
        boolean.operation, boolean.solver, boolean.object = "DIFFERENCE", "EXACT", cutter
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.modifier_apply(modifier=boolean.name)
        bpy.data.objects.remove(cutter, do_unlink=True)


def geometry(item, mats):
    kind = item["kind"]
    if kind == "dome":
        obj = dome(item)
    elif kind in ("curve", "ring"):
        obj = curve(item)
    else:
        if kind == "box":
            bpy.ops.mesh.primitive_cube_add(size=1)
        elif kind == "cylinder":
            bpy.ops.mesh.primitive_cylinder_add(vertices=64, radius=.5, depth=1)
        else:
            bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=24, radius=.5)
        obj = bpy.context.object
        obj.dimensions = item["size"]
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        apply_cuts(obj, item)
        if kind in ("box", "cylinder"):
            bevel = obj.modifiers.new("Manufactured edge", "BEVEL")
            bevel.width = min(item["size"])*.08
            bevel.segments = 3
    obj.name = item["id"]
    obj.location = item["position"]
    obj.rotation_euler = item["rotation"]
    obj.data.materials.append(mats[item["material"]])
    if kind == "dome":
        obj.data.materials.append(mats["opal"])
        shell = obj.modifiers.new("Cased glass thickness", "SOLIDIFY")
        shell.thickness = .0025
        shell.offset = -1
        shell.material_offset = 1
    if obj.type == "MESH" and kind != "box":
        for polygon in obj.data.polygons:
            polygon.use_smooth = True
    obj["part_id"], obj["assembly"] = item["id"], item["assembly"]
    obj["explode_offset"] = item["explode"]
    return obj


def light(name, position, energy, size, target, color=(1, 1, 1)):
    data = bpy.data.lights.new(name, "AREA")
    data.energy, data.shape, data.size, data.color = energy, "DISK", size, color
    obj = bpy.data.objects.new(name, data)
    bpy.context.collection.objects.link(obj)
    obj.location = position
    obj.rotation_euler = (Vector(target)-obj.location).to_track_quat("-Z", "Y").to_euler()


def studio(demo, mats):
    lamp = demo == "lamp"
    target = (0, 0, .24) if lamp else (0, 0, 1.05)
    bpy.ops.mesh.primitive_plane_add(size=200 if lamp else 20, location=(0, 0, -.001))
    floor = bpy.context.object
    floor.name = "Studio floor (not a part)"
    floor.data.materials.append(mats["oak"] if lamp else mats["stone"])
    if lamp:
        light("Large softbox", (-.65, -.5, 1.1), 18, .7, target)
        light("Rim softbox", (.6, .4, .85), 23, .55, target, (.78, .88, 1))
        light("Front fill", (.3, -.8, .6), 4, .6, target)
        light("Bulb downward", (0, -.005, .361), .8, .11, (0, 0, 0), (1, .74, .4))
        camera_location = (.63, -.9, .57)
    else:
        bpy.ops.mesh.primitive_cube_add(size=1, location=(0, .42, 3))
        wall = bpy.context.object
        wall.dimensions = (20, .10, 6)
        wall.data.materials.append(mats["stone"])
        light("Window", (-3, -2, 4), 450, 3, target)
        light("Fill", (3, -1, 3.5), 180, 3, target)
        camera_location = (3.7, -5.7, 3.2)
    bpy.ops.object.camera_add(location=camera_location)
    camera = bpy.context.object
    camera.rotation_euler = (Vector(target)-camera.location).to_track_quat("-Z", "Y").to_euler()
    camera.data.lens = 52 if lamp else 45
    bpy.context.scene.camera = camera


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
    studio(data["demo"], mats)
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.render.engine = "CYCLES"
    scene.cycles.samples = args.samples
    scene.cycles.use_denoising = True
    scene.render.resolution_x, scene.render.resolution_y = 1000, 800
    scene.render.resolution_percentage = 100
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
