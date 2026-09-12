# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Create and build original, local-only creative demonstration projects."""

import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import subprocess
import struct
import sys
from pathlib import Path

from _creative_demo_model import DEFAULTS, model

SCRIPTS = Path(__file__).resolve().parent
TEMPLATES = SCRIPTS.parent / "templates"


def within_workspace(value):
    path = Path(os.path.abspath(value))
    if path.resolve() != path or not path.is_relative_to(Path.cwd().resolve()):
        raise ValueError("Project/output must be a non-symlink path inside the current workspace")
    return path


def write_json(path, data):
    with path.open("x", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, allow_nan=False)
        handle.write("\n")


def init_project(demo, destination):
    root = within_workspace(destination)
    if root.exists() or not root.parent.is_dir():
        raise ValueError("Use a new project directory with an existing parent; nothing is overwritten")
    root.mkdir()
    write_json(root / "project.json", {"demo": demo, "parameters": DEFAULTS[demo]})
    write_json(root / "package.json", {"name": "creative-demo", "private": True, "type": "module",
                                      "dependencies": {"three": "0.186.0"}})
    (root / "index.html").write_text((TEMPLATES / "creative-viewer.html").read_text(encoding="utf-8"), encoding="utf-8")
    (root / ".gitignore").write_text("node_modules/\nruns/\n", encoding="utf-8")
    print(json.dumps({"project": str(root), "next": "Edit project.json, then build a fresh named run. Viewer dependencies are not installed automatically."}))


def executable(override, name, mac_path):
    found = override or shutil.which(name)
    if not found and sys.platform == "darwin" and Path(mac_path).is_file():
        found = mac_path
    if not found or not Path(found).is_file() or not os.access(found, os.X_OK):
        raise ValueError(f"{name} is unavailable; provide its installed executable explicitly")
    return str(Path(os.path.abspath(found)))


def write_parts(out, scene):
    with (out / "parts.csv").open("x", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["part_id", "assembly", "kind", "material", "x_m", "y_m", "z_m", "quantity"])
        for item in scene["parts"]:
            writer.writerow([item["id"], item["assembly"], item["kind"], item["material"], *item["size"], 1])


def run_app(command, out, name, timeout):
    env = {key: value for key, value in os.environ.items() if key in
           ("PATH", "HOME", "USER", "LANG", "LC_ALL", "SYSTEMROOT", "WINDIR", "DISPLAY", "XDG_RUNTIME_DIR")}
    env["TMPDIR"] = str(out)
    print(f"Running {name} with a {timeout}s limit; progress is retained in {name}.log", flush=True)
    with (out / f"{name}.log").open("x", encoding="utf-8") as log:
        result = subprocess.run(command, env=env, stdin=subprocess.DEVNULL, stdout=log,
                                stderr=subprocess.STDOUT, timeout=timeout, check=False)
    if result.returncode:
        raise ValueError(f"{name} failed with exit {result.returncode}; inspect its retained run log")


def verify_glb(path, scene):
    with path.open("rb") as handle:
        header = handle.read(20)
        magic, version, length, json_length, chunk = struct.unpack("<4sIIII", header)
        if magic != b"glTF" or version != 2 or chunk != 0x4E4F534A or length != path.stat().st_size:
            raise ValueError("Invalid GLB header")
        if json_length > 16*1024*1024:
            raise ValueError("Unexpectedly large GLB metadata")
        gltf = json.loads(handle.read(json_length))
    exported = [node["extras"]["part_id"] for node in gltf.get("nodes", [])
                if node.get("extras", {}).get("part_id") and "mesh" in node]
    expected = [item["id"] for item in scene["parts"]]
    if len(exported) != len(set(exported)) or set(exported) != set(expected):
        raise ValueError("GLB part IDs do not match the recipe; inspect conversion/export losses")
    return len(exported)


def build(args):
    root = within_workspace(args.project)
    config_path = root / "project.json"
    if not config_path.is_file() or config_path.is_symlink() or config_path.stat().st_size > 65536:
        raise ValueError("project.json must be a bounded regular JSON file")
    config = json.loads(config_path.read_text(encoding="utf-8"))
    if not isinstance(config, dict):
        raise ValueError("project.json must contain an object")
    scene = model(config.get("demo"), config.get("parameters"))
    if args.cad and scene["demo"] != "kitchen":
        raise ValueError("The CAD demo currently supports kitchen components only")
    scene["recipe_hash"] = hashlib.sha256(b"".join((SCRIPTS / filename).read_bytes() for filename in
        ("_creative_demo_model.py", "creative-demo-blender.py", "creative-demo-freecad.py"))).hexdigest()
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}", args.run):
        raise ValueError("Run name must be a short alphanumeric slug")
    runs = within_workspace(root / "runs")
    runs.mkdir(exist_ok=True)
    out = runs / args.run
    out.mkdir()  # Refuse repeat writes to the same native project/export directory.
    write_json(out / "scene.json", scene)
    write_parts(out, scene)
    blender = executable(args.blender, "blender", "/Applications/Blender.app/Contents/MacOS/Blender")
    command = [blender, "--factory-startup", "--disable-autoexec", "--background", "--threads", "4",
               "--python-exit-code", "1", "--python", str(SCRIPTS / "creative-demo-blender.py"),
               "--", str(out / "scene.json"), "--samples", str(args.samples)]
    if args.render:
        command.append("--render")
    run_app(command, out, "blender", args.timeout)
    if args.cad:
        freecad = executable(args.freecad, "freecadcmd", "/Applications/FreeCAD.app/Contents/Resources/bin/freecadcmd")
        run_app([freecad, "--safe-mode", "-u", str(out / "freecad-user.cfg"), "-s", str(out / "freecad-system.cfg"),
                 str(SCRIPTS / "creative-demo-freecad.py"), "--pass", str(out / "scene.json")], out, "freecad", args.timeout)
    required = ["scene.blend", "scene.glb", "verification.json"]
    if args.render:
        required.append("render.png")
    if args.cad:
        required.extend(["kitchen.FCStd", "kitchen.step", "cad-verification.json"])
    if any(not (out / name).is_file() or not (out / name).stat().st_size for name in required):
        raise ValueError("App exited without all requested artifacts; inspect the run logs")
    verify_glb(out / "scene.glb", scene)
    write_json(out / "run.json", {"source_hash": scene["source_hash"], "recipe_hash": scene["recipe_hash"],
                                  "artifacts": [*required, "scene.json", "parts.csv"], "state": "generated",
                                  "visual_review": "required", "production_certification": False})
    print(json.dumps({"run": str(out), "parts": len(scene["parts"]), "source_hash": scene["source_hash"],
                      "artifacts": required, "visual_review": "required", "production_certification": False}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init")
    init.add_argument("demo", choices=DEFAULTS)
    init.add_argument("project")
    render = commands.add_parser("build")
    render.add_argument("project")
    render.add_argument("--run", required=True)
    render.add_argument("--render", action="store_true")
    render.add_argument("--cad", action="store_true")
    render.add_argument("--blender")
    render.add_argument("--freecad")
    render.add_argument("--samples", type=int, choices=(16, 32, 64, 128), default=32)
    render.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    try:
        if args.command == "init":
            init_project(args.demo, args.project)
        elif not 1 <= args.timeout <= 900:
            raise ValueError("Timeout must be between 1 and 900 seconds")
        else:
            build(args)
        return 0
    except (OSError, ValueError, TypeError, struct.error, subprocess.SubprocessError) as exc:
        print(f"Creative demo: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
