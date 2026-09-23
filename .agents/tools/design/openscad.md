---
description: Script-based parametric CAD with OpenSCAD and verified mesh exports
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# OpenSCAD

[OpenSCAD](https://github.com/openscad/openscad) describes solid geometry in
editable `.scad` source using constructive solid geometry and 2D extrusion. Use
it for dimensioned, repeatable parts, variants and print-oriented designs when
the script is the authoritative model. It complements FreeCAD's native CAD and
STEP workflow and Blender's visual/mesh workflow; do not call an STL an editable
B-rep or assume an OpenSCAD export preserves a feature tree.

## Working with a project

- Start with `3d-workflows.md` and `workflows/creative-production.md`. Record
  dimensions, units, origin, parameter bounds, tolerances, component identity
  and intended fabrication method; OpenSCAD geometry has no inherent unit.
- Keep `.scad` source, local library dependencies, parameter sets and decisions
  in the project. Inspect any external scripts/libraries before evaluating them;
  do not auto-install extensions, run arbitrary build commands, or overwrite
  existing project files. Use a separate output directory for generated files.
- Check that `openscad` is installed and inspect `openscad -v` and
  `openscad --help` on the target machine. No OpenSCAD installation, MCP server
  or GUI session is bundled or started by aidevops. Use the native CLI for
  reproducible exports when available; interactive preview is not final render.
- For example, from a project with `part.scad`, run
  `openscad -o output/part.stl part.scad` to generate a mesh, or
  `openscad -o output/part.stl -D 'width=42' part.scad` for a parameterised
  variant. The variable must exist in the source. Use `-o output/part.3mf`
  only after confirming the installed version supports that export. Consult
  the installed help for options rather than assuming current upstream flags
  exist locally. Avoid untrusted `-m` make commands and unreviewed imports.

## Verification and handoff

Inspect the CLI's diagnostics and the actual output; an exit code or preview
alone does not establish printable or dimensionally correct geometry. Check
bounding dimensions, orientation, manifoldness, minimum walls/clearances and
mesh integrity in an appropriate independent viewer/slicer, with a test print
or fabrication review where required. Record the input parameters, app version,
export format and validation evidence alongside the editable `.scad` source.
For STEP, constrained assemblies or engineering drawings, select FreeCAD or a
verified conversion workflow and recheck solids, dimensions and part IDs after
round-trip. Do not claim printability or manufacturing readiness from export.

Upstream reference: [OpenSCAD source and README](https://github.com/openscad/openscad)
and its `doc/openscad.1.in` command-line manual. Export formats and flags depend
on the installed build.
