#!/usr/bin/env python3
"""Build deterministic, inspectable 3D creative demonstration packages."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
import sys


def positive(value: str) -> float:
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("value must be a finite positive number")
    return number


def lamp(args: argparse.Namespace) -> dict:
    return {
        "demo": "bankers-lamp",
        "mode": args.mode,
        "units": "mm",
        "parameters": {
            "base_diameter": args.base_diameter,
            "height": args.height,
            "shade_width": args.shade_width,
            "shade_tilt_deg": args.shade_tilt,
            "finish": args.finish,
        },
        "parts": [
            {"id": "lamp.base.001", "name": "weighted_base", "material": args.finish, "quantity": 1},
            {"id": "lamp.stem.001", "name": "brass_stem", "material": args.finish, "quantity": 1},
            {"id": "lamp.hinge.001", "name": "tilt_hinge", "material": args.finish, "quantity": 1},
            {"id": "lamp.shade.001", "name": "green_glass_shade", "material": "green_glass", "quantity": 1},
            {"id": "lamp.light.001", "name": "illustrative_bulb", "material": "glass", "quantity": 1},
        ],
        "disclaimer": "Original visual demonstration; not an electrically certified or fabrication-ready product.",
    }


def kitchen(args: argparse.Namespace) -> dict:
    cabinet_count = max(1, int(args.room_width // args.cabinet_width))
    parts = []
    for index in range(cabinet_count):
        suffix = index + 1
        parts.extend([
            {"id": f"kitchen.base.{suffix:03d}", "name": "base_cabinet", "material": args.finish, "quantity": 1},
            {"id": f"kitchen.panel.{suffix:03d}", "name": "cabinet_panel", "material": args.finish, "quantity": 2},
            {"id": f"kitchen.door.{suffix:03d}", "name": "cabinet_door", "material": args.finish, "quantity": 1},
            {"id": f"kitchen.drawer.{suffix:03d}", "name": "cabinet_drawer", "material": args.finish, "quantity": 1},
        ])
    parts.extend([
        {"id": "kitchen.worktop.001", "name": "worktop", "material": "quartz", "quantity": 1},
        {"id": "kitchen.appliance.001", "name": "oven_placeholder", "material": "steel", "quantity": 1},
        {"id": "kitchen.appliance.002", "name": "fridge_placeholder", "material": "steel", "quantity": 1},
    ])
    return {
        "demo": "modern-kitchen",
        "mode": args.mode,
        "units": "mm",
        "parameters": {
            "room_width": args.room_width,
            "room_depth": args.room_depth,
            "room_height": args.room_height,
            "cabinet_width": args.cabinet_width,
            "finish": args.finish,
        },
        "parts": parts,
        "checks": {
            "cabinet_run_width": cabinet_count * args.cabinet_width,
            "fits_room_width": cabinet_count * args.cabinet_width <= args.room_width,
        },
        "disclaimer": "Fictional original room; not an as-built survey, installation specification, or fabrication package.",
    }


def svg_for(recipe: dict, view: str) -> str:
    title = recipe["demo"].replace("-", " ").title()
    parts = len(recipe["parts"])
    subtitle = "Exploded assembly view" if view == "exploded" else "Beauty preview"
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="960" height="540" viewBox="0 0 960 540">
<rect width="960" height="540" fill="#17191d"/><path d="M120 410 L480 205 L840 410 L480 515 Z" fill="#30343b" stroke="#d6b56c" stroke-width="4"/>
<rect x="280" y="105" width="400" height="235" rx="24" fill="#203f35" stroke="#d6b56c" stroke-width="5"/>
<text x="480" y="180" fill="#f5f1e8" font-family="sans-serif" font-size="42" text-anchor="middle">{title}</text>
<text x="480" y="225" fill="#d6b56c" font-family="monospace" font-size="24" text-anchor="middle">{parts} named parts · rebuildable recipe</text>
<text x="480" y="265" fill="#f5f1e8" font-family="sans-serif" font-size="22" text-anchor="middle">{subtitle}</text>
<text x="480" y="305" fill="#c7ccd4" font-family="sans-serif" font-size="20" text-anchor="middle">Illustrative preview — inspect recipe.json for dimensions</text>
</svg>'''


def write_package(recipe: dict, output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    (output / "recipe.json").write_text(json.dumps(recipe, indent=2) + "\n", encoding="utf-8")
    with (output / "parts.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=("id", "name", "material", "quantity"))
        writer.writeheader()
        writer.writerows(recipe["parts"])
    render_name = "beauty-render.svg" if recipe["demo"] == "bankers-lamp" else "exploded-view.svg"
    render_view = "beauty" if recipe["demo"] == "bankers-lamp" else "exploded"
    (output / render_name).write_text(svg_for(recipe, render_view) + "\n", encoding="utf-8")
    evidence = {
        "schema": 1,
        "demo": recipe["demo"],
        "mode_requested": recipe["mode"],
        "verification_achieved": ["recipe_serialized", "stable_part_ids_unique", "parts_list_exported", "preview_rendered"],
        "artifacts": ["recipe.json", "parts.csv", render_name],
        "limitations": recipe["disclaimer"],
    }
    ids = [part["id"] for part in recipe["parts"]]
    if len(ids) != len(set(ids)):
        raise ValueError("part IDs must be unique")
    (output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    sub = root.add_subparsers(dest="demo", required=True)
    shared = argparse.ArgumentParser(add_help=False)
    shared.add_argument("--output", type=Path, required=True)
    shared.add_argument("--mode", choices=("draft", "presentation", "dimensionally-accurate", "fabrication-package"), default="presentation")
    shared.add_argument("--finish", default="brushed-brass")
    lamp_parser = sub.add_parser("bankers-lamp", parents=[shared])
    lamp_parser.add_argument("--base-diameter", type=positive, default=180.0)
    lamp_parser.add_argument("--height", type=positive, default=420.0)
    lamp_parser.add_argument("--shade-width", type=positive, default=260.0)
    lamp_parser.add_argument("--shade-tilt", type=float, default=15.0)
    kitchen_parser = sub.add_parser("modern-kitchen", parents=[shared])
    kitchen_parser.add_argument("--room-width", type=positive, default=4200.0)
    kitchen_parser.add_argument("--room-depth", type=positive, default=3200.0)
    kitchen_parser.add_argument("--room-height", type=positive, default=2500.0)
    kitchen_parser.add_argument("--cabinet-width", type=positive, default=600.0)
    return root


def main() -> int:
    args = parser().parse_args()
    recipe = lamp(args) if args.demo == "bankers-lamp" else kitchen(args)
    try:
        write_package(recipe, args.output)
    except (OSError, ValueError) as error:
        print(f"creative-demo: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"demo": recipe["demo"], "output": str(args.output), "parts": len(recipe["parts"])}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
