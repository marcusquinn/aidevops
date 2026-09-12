---
description: Guarded FreeCAD modelling and optional MCP execution
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# FreeCAD

Use FreeCAD for parametric and dimension-led models. The inspected MCP candidate
is `neka-nat/freecad-mcp` at revision
`5dbfe2c80b53c3102bff0723951676e16edf2d84`; configure only an executable from a
separately reviewed checkout at that exact revision. No dependency is vendored or
installed by aidevops. Re-verify upstream revision, license, entry point, tool
exports, and supported FreeCAD version before changing the pin.

Headless FreeCAD execution and GUI automation differ. Neither proves an isolated
desktop. Work on a copy, preserve units and placement, use stable object names,
and validate constraints/recompute status plus exported dimensions. For explicit
MCP activation, set the profile executable and both launcher attestations only
after operator approval and isolation; use the `freecad` focused agent, connect
`freecad`, inspect tools, perform bounded work, read state back, and disconnect.
The launcher refuses missing consent, missing executables, relative paths, and
headless worker sessions before executing external code.

Exports to STEP/IGES/STL/DXF do not certify tolerances, manufacturability, code
compliance, or an as-built condition. Archicad and Unreal are interchange targets,
not installation instructions.
