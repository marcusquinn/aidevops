# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Original provider-neutral demonstration geometry in metres, with stable IDs."""

import hashlib
import json
import math

DEFAULTS = {
    "lamp": {"height": 0.44, "shade_width": 0.29, "shade_tilt": 0, "finish": "brass"},
    "kitchen": {"modules": 5, "module_width": 0.6, "depth": 0.58,
                "cabinet_height": 0.76, "panel_thickness": 0.018},
}
BOUNDS = {
    "height": (0.25, 0.7), "shade_width": (0.2, 0.5), "shade_tilt": (-25, 25),
    "modules": (3, 8), "module_width": (0.45, 0.9), "depth": (0.45, 0.8),
    "cabinet_height": (0.6, 1.0), "panel_thickness": (0.012, 0.03),
}
MATERIALS = {
    "brass": {"color": [0.53, 0.32, 0.10, 1], "metallic": 0.95, "roughness": 0.29},
    "nickel": {"color": [0.6, 0.64, 0.67, 1], "metallic": 0.95, "roughness": 0.24},
    "glass": {"color": [0.004, 0.09, 0.022, 1], "roughness": 0.22, "transmission": 0.18},
    "opal": {"color": [0.88, 0.93, 0.82, 1], "roughness": 0.25, "transmission": 0.2},
    "bulb": {"color": [1, 0.79, 0.48, 1], "emission": 4, "roughness": 0.25},
    "black": {"color": [0.018, 0.021, 0.021, 1], "roughness": 0.4},
    "cabinet": {"color": [0.075, 0.16, 0.135, 1], "roughness": 0.33},
    "oak": {"color": [0.48, 0.30, 0.15, 1], "roughness": 0.4},
    "stone": {"color": [0.76, 0.75, 0.69, 1], "roughness": 0.27},
    "steel": {"color": [0.47, 0.52, 0.54, 1], "metallic": 0.85, "roughness": 0.28},
}


def configuration(demo, supplied=None):
    if demo not in DEFAULTS or (supplied is not None and not isinstance(supplied, dict)):
        raise ValueError("Choose lamp or kitchen with a parameter object")
    if set(supplied or {}) - set(DEFAULTS[demo]):
        raise ValueError("Unknown demo parameter")
    result = {**DEFAULTS[demo], **(supplied or {})}
    for key, value in result.items():
        if key == "finish":
            if value not in ("brass", "nickel"):
                raise ValueError("finish must be brass or nickel")
            continue
        low, high = BOUNDS[key]
        if type(value) not in (int, float) or not math.isfinite(value) or not low <= value <= high:
            raise ValueError(f"{key} must be finite and between {low} and {high}")
        if key == "modules" and int(value) != value:
            raise ValueError("modules must be an integer")
    return result


def part(identifier, kind, size, position, **extra):
    return {"id": identifier, "kind": kind, "size": list(size),
            "position": list(position), "material": extra.pop("material"), "assembly": extra.pop("assembly"),
            "rotation": [0, 0, 0], "explode": [0, 0, 0], **extra}


def lamp_parts(cfg):
    s, w, metal = cfg["height"] / 0.44, cfg["shade_width"], cfg["finish"]
    parts = [
        part("lamp.base", "base", (.20*s, .16*s, .034*s), (0, 0, .005*s), material=metal, assembly="base"),
        part("lamp.felt", "cylinder", (.18*s, .14*s, .006*s), (0, 0, .003*s), material="black", assembly="base"),
        part("lamp.stem", "cylinder", (.020*s, .020*s, .292*s), (0, .027*s, .19*s), material=metal, assembly="support"),
        part("lamp.collar", "cylinder", (.036*s, .036*s, .026*s), (0, .027*s, .035*s), material=metal, assembly="support"),
        part("lamp.crossbar", "cylinder", (.014*s, .014*s, w+.022*s), (0, .027*s, .33*s), material=metal, assembly="support",
             rotation=[0, math.pi/2, 0]),
        part("lamp.shade", "dome", (w, .16*s, .072*s), (0, 0, .366*s), material="glass", assembly="shade",
             explode=[0, 0, .15*s]),
        part("lamp.rim", "ring", (w, .16*s, .004*s), (0, 0, .366*s), material=metal, assembly="shade",
             explode=[0, 0, .15*s]),
        part("lamp.bulb", "ellipsoid", (w*.70, .027*s, .027*s), (0, 0, .375*s), material="bulb", assembly="shade",
             explode=[0, -.07*s, 0]),
        part("lamp.cord", "curve", (.25*s, .2*s, .03*s), (0, 0, 0), material="black", assembly="base",
             points=[[0, .06*s, .013*s], [.04*s, .16*s, .004*s], [.16*s, .18*s, .004*s],
                     [.22*s, .11*s, .004*s], [.28*s, .14*s, .004*s]]),
    ]
    for side in (-1, 1):
        label = "left" if side < 0 else "right"
        parts.append(part(f"lamp.arm.{label}", "cylinder", (.014*s, .014*s, .047*s),
                          (side*(w/2+.007*s), .015*s, .348*s), material=metal, assembly="support"))
        parts.append(part(f"lamp.pivot.{label}", "cylinder", (.027*s, .027*s, .021*s),
                          (side*(w/2+.007*s), 0, .371*s), material=metal, assembly="support", rotation=[0, math.pi/2, 0]))
    for index in range(15):
        parts.append(part(f"lamp.chain.{index:02}", "ellipsoid", (.004*s, .004*s, .004*s),
                          (w*.30, -.035*s, (.36-index*.005)*s), material=metal, assembly="chain"))
    return parts


def drawer_parts(group, x, cfg):
    w, d, h, t = (cfg[key] for key in ("module_width", "depth", "cabinet_height", "panel_thickness"))
    result = []
    for index in range(3):
        z, front_h = .10+(index+.5)*h/3, h/3-.004
        prefix, shift = f"{group}.drawer.{index+1}", [0, -.40-index*.18, 0]
        result.extend([
            part(prefix+".front", "box", (w-.008, t, front_h), (x, -d/2-t/2-.002, z), material="cabinet", assembly=group, explode=shift),
            part(prefix+".bottom", "box", (w-4*t, d-.08, t), (x, -.015, z-front_h*.32), material="oak", assembly=group, explode=shift),
            part(prefix+".back", "box", (w-4*t, t, front_h*.6), (x, d/2-.07, z), material="oak", assembly=group, explode=shift),
            part(prefix+".handle", "cylinder", (.008, .008, .18), (x, -d/2-t-.025, z+.035), material="brass", assembly=group,
                 rotation=[0, math.pi/2, 0], explode=shift),
        ])
        for side in (-1, 1):
            result.append(part(prefix+(".left" if side < 0 else ".right"), "box", (t, d-.08, front_h*.6),
                               (x+side*(w-3*t)/2, -.015, z), material="oak", assembly=group, explode=shift))
    return result


def cabinet_parts(index, cfg, start):
    w, d, h, t = (cfg[key] for key in ("module_width", "depth", "cabinet_height", "panel_thickness"))
    x, z, group = start + (index+.5)*w, .10+h/2, f"cabinet.{index+1:02}"
    parts = []
    for side in (-1, 1):
        label = "left" if side < 0 else "right"
        parts.append(part(f"{group}.side.{label}", "box", (t, d, h),
                          (x+side*(w-t)/2, 0, z), material="oak", assembly=group, explode=[side*.18, 0, 0]))
    parts.extend([
        part(f"{group}.bottom", "box", (w-2*t, d, t), (x, 0, .10+t/2), material="oak", assembly=group, explode=[0, 0, -.13]),
        part(f"{group}.back", "box", (w-2*t, t, h-t), (x, (d-t)/2, z+t/2), material="oak", assembly=group, explode=[0, .25, 0]),
        part(f"{group}.shelf", "box", (w-2*t, d-2*t, t), (x, 0, z), material="oak", assembly=group, explode=[0, -.25, .08]),
        part(f"{group}.rail.front", "box", (w-2*t, .055, t), (x, -d/2+.0275, .10+h-t/2), material="oak", assembly=group),
        part(f"{group}.rail.back", "box", (w-2*t, .055, t), (x, d/2-.0275, .10+h-t/2), material="oak", assembly=group),
    ])
    if index in (0, 1):
        parts = [item for item in parts if not item["id"].endswith(".shelf")]
    if index == 0:
        parts.extend(drawer_parts(group, x, cfg))
    for number, offset in enumerate(() if index == 0 else (-w/4, w/4)):
        parts.append(part(f"{group}.door.{number+1}", "box", (w/2-.004, t, h-.004),
                          (x+offset, -d/2-t/2-.002, z), material="cabinet", assembly=group, explode=[0, -.6, 0]))
        parts.append(part(f"{group}.handle.{number+1}", "cylinder", (.008, .008, .15),
                          (x+offset, -d/2-t-.028, .10+h-.12), material="brass", assembly=group,
                          rotation=[0, math.pi/2, 0], explode=[0, -.65, 0]))
    for number, (dx, dy) in enumerate(((-w*.36, -d*.34), (w*.36, -d*.34), (-w*.36, d*.34), (w*.36, d*.34))):
        parts.append(part(f"{group}.leg.{number+1}", "cylinder", (.045, .045, .1),
                          (x+dx, dy, .05), material="black", assembly=group, explode=[0, 0, -.12]))
    return parts


def upper_parts(index, x, w, d, t):
    group, height, depth, y, z = f"upper.{index+1:02}", .68, .31, d/2-.12, 1.83
    result = []
    for side in (-1, 1):
        result.append(part(group+(".left" if side < 0 else ".right"), "box", (t, depth, height),
                           (x+side*(w-t)/2, y, z), material="oak", assembly=group, explode=[side*.16, .12, .28]))
    for suffix, level in (("bottom", z-(height-t)/2), ("shelf", z), ("top", z+(height-t)/2)):
        result.append(part(group+"."+suffix, "box", (w-2*t, depth-t, t), (x, y, level), material="oak", assembly=group,
                           explode=[0, .1, .28+(level-z)*.3]))
    result.extend([
        part(group+".back", "box", (w-2*t, t, height), (x, y+(depth-t)/2, z), material="oak", assembly=group, explode=[0, .3, .28]),
        part(group+".front", "box", (w-.008, .018, height-.004), (x, y-depth/2-.009, z), material="cabinet", assembly=group,
             explode=[0, -.4, .28]),
    ])
    return result


def kitchen_parts(cfg):
    count, w, d, h = int(cfg["modules"]), cfg["module_width"], cfg["depth"], cfg["cabinet_height"]
    width, top = count*w, .10+h
    start = -width/2
    sink_x, sink_w, sink_d = start+1.5*w, w*.72, d*.62
    parts = [item for index in range(count) for item in cabinet_parts(index, cfg, start)]
    parts.extend([
        part("kitchen.worktop", "box", (width+.05, d+.065, .035), (0, -.016, top+.0175), material="stone", assembly="worktop",
             explode=[0, 0, .65], cuts=[{"size": [sink_w, sink_d, .12], "offset": [sink_x, 0, 0]}]),
        part("kitchen.sink", "box", (sink_w+.012, sink_d+.012, .14), (sink_x, -.016, top-.034), material="steel", assembly="appliances",
             explode=[0, 0, .70], cuts=[{"size": [sink_w, sink_d, .14], "offset": [0, 0, .007]}]),
        part("kitchen.tap", "curve", (.028, .20, .31), (0, 0, 0), material="steel", assembly="appliances", radius=.012,
             explode=[0, 0, .70], points=[[sink_x, d*.36, top+.035], [sink_x, d*.36, top+.24],
                                         [sink_x, d*.30, top+.32], [sink_x, .04, top+.30], [sink_x, -.015, top+.22]]),
        part("kitchen.plinth", "box", (width-.04, .018, .085), (0, -d/2+.07, .043), material="cabinet", assembly="base",
             explode=[0, -.35, 0]),
        part("kitchen.hob", "box", (w*.78, d*.76, .009), (start+2.5*w, -.03, top+.040), material="black", assembly="appliances",
             explode=[0, 0, .7]),
    ])
    for index, (dx, dy) in enumerate(((-w*.20, -d*.17), (w*.20, -d*.17), (-w*.20, d*.17), (w*.20, d*.17))):
        parts.append(part(f"kitchen.hob.ring.{index}", "ring", (w*.23, w*.23, .001),
                          (start+2.5*w+dx, -.03+dy, top+.045), material="steel", assembly="appliances", explode=[0, 0, .7]))
    for index in range(count):
        x = start+(index+.5)*w
        parts.extend(upper_parts(index, x, w, d, cfg["panel_thickness"]))
    return parts


def model(demo, supplied=None):
    cfg = configuration(demo, supplied)
    parts = lamp_parts(cfg) if demo == "lamp" else kitchen_parts(cfg)
    result = {"schema_version": 1, "demo": demo, "units": "m", "parameters": cfg,
              "requested_mode": "presentation", "verified_mode": None,
              "materials": MATERIALS, "parts": parts,
              "notice": "Original reference demo; not a manufacturing or installation specification"}
    payload = json.dumps(result, sort_keys=True, allow_nan=False).encode()
    result["source_hash"] = hashlib.sha256(payload).hexdigest()
    return result
