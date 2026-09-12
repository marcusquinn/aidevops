# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Editable Blender geometry and materials for the shared creative recipe."""

import math

import bpy


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
