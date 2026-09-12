---
description: Original configurable lamp and kitchen examples with native projects, CAD and a local model viewer
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Rebuildable 3D demonstrations

These original examples exercise the normal local app/export path. They are
reference demonstrations, not electrical designs, site surveys, fabrication
specifications or certified installation packages. Requested presentation mode
does not automatically become achieved verification.

## Build

Use an existing project/worktree as the current directory. Python 3.10+, Blender
and optionally FreeCAD must already be installed. No MCP, GUI takeover or paid
service is involved; the helper never installs an app or a dependency.

```bash
python3 ~/.aidevops/agents/scripts/creative-demo-helper.py init lamp ./lamp
python3 ~/.aidevops/agents/scripts/creative-demo-helper.py build ./lamp --run preview --render

python3 ~/.aidevops/agents/scripts/creative-demo-helper.py init kitchen ./kitchen
python3 ~/.aidevops/agents/scripts/creative-demo-helper.py build ./kitchen --run preview --render --cad
```

The destination needs an existing parent inside the current workspace. Symlink
destinations, traversal outside the workspace and existing run names are refused.
Use `--blender /absolute/executable` or `--freecad /absolute/executable` when PATH
and the standard macOS app locations do not apply. `--timeout` is a per-app limit
(1–900 seconds). Blender uses four threads and defaults to 32 Cycles samples;
`--samples 16|32|64|128` changes that explicit quality/time trade-off.

Edit `project.json`, then build a **new** named run. The lamp has height, shade
width, shade tilt and brass/nickel finish parameters. The kitchen has module
count/width, cabinet height/depth and panel thickness. Bounds reject invalid or
non-finite geometry inputs. Stable IDs survive dimension/finish changes; changing
module count adds/removes assemblies intentionally.

## Artifacts and viewer

Each successful run includes recipe JSON, source/recipe hashes, a parts CSV,
editable `.blend`, a GLB with mesh-backed part IDs, geometry verification and
`run.json`. `--render` adds a Cycles PNG. Native curves and modifiers remain
editable while the GLB contains their evaluated geometry.

The kitchen includes separate carcass panels, drawer components, doors, hardware,
upper panels, cut worktop, sink, tap and hob references. `--cad` also creates
`kitchen.FCStd`, `kitchen.step` and CAD verification. It checks solid validity,
positive volume, configured worktop width, native reopening and STEP solid-count
round trip. The curved tap is explicitly excluded from CAD as reference geometry.
Millimetre CAD and metre render units are explicit. Bevels in the presentation
mesh are not manufacturing tolerances in the un-bevelled nominal CAD solids.

With approval for the pinned local viewer dependency, run inside the generated
project directory:

```bash
npm install --ignore-scripts --no-audit --no-fund
python3 -m http.server 3188 --bind 127.0.0.1
```

Use an available local port (see `services/hosting/local-hosting.md`). Open the
address printed by the server; select a generated run. The viewer provides
orthographic front/side/top views, orbit, wireframe, exploded parts, section
inspection, accessible part selection, fitting and viewport PNG export. Only
artifacts listed in a successful run manifest get download links. A section is
an inspection clipping plane, not a dimensioned construction drawing. Geometry
is configured in the source file, not silently mutated by viewer controls.

Keep `project.json`, the pinned dependency lockfile and authoritative source in
Git. Generated binaries/runs and `node_modules` are excluded by default; retain
required native projects/reviews in approved asset storage before cleanup. Apply
`workflows/creative-production.md` for locks, provenance and manual-edit recovery.
Failed app logs remain in their run directory; an exit code alone is not success.

## Verified reference environment

The local reference run used Blender 5.2.1 LTS, FreeCAD 1.0.0 and Three.js 0.186.0.
The lamp exported 28 GLB meshes. The five-module kitchen exported 131 GLB meshes;
130 CAD solids survived native reopening and STEP import, with a 3050 mm worktop.
Other app versions/platforms require their own run; this is not a compatibility
matrix or production certification. Offline checks live in
`scripts/tests/test-creative-demo.py`; native-app verification uses the CLI above.
