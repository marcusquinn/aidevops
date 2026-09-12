---
description: Representation, assembly and export choices for editable 3D products and scenes
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# 3D workflows

## Choose the authoritative representation

| Representation | Best fit | Do not infer |
| --- | --- | --- |
| Polygon/subdivision/procedural mesh | Organic objects, animation, visual products, real-time assets | Engineering constraints from appearance |
| Parametric CAD/B-rep solids | Defined dimensions, assemblies, sections, parts | Fabrication readiness without tolerances/validation |
| Reconstructed mesh | Existing objects/spaces with suitable capture | Reliable scale or hidden surfaces without evidence |
| Gaussian splats/radiance fields | Captured appearance and novel views | Editable solids, watertight parts or accurate sections |

Video is usually a capture input or rendered output, not a substitute for these
representations. CAD and visual masters may differ, but ownership and derivation
must be explicit. A rendered image is not an editable scene.

## Configurable products

Define units, coordinate conventions, parameter bounds, valid combinations,
constraints, assembly hierarchy and stable part IDs before generating derivatives.
Keep parametric input authoritative; never let the viewer invent a different
configuration from the drawing or parts list.

Generate relevant outputs from the same configuration:

- Native CAD and STEP for solids; Blender source for visual refinement.
- Plans, sections, elevations and dimensions in supported DXF/SVG/PDF workflows.
- Parts/BOM with IDs, material, quantity and applicable cut/finish information.
- GLB/glTF for interactive viewing; USD/USDZ when the target actually supports it.
- STL/3MF only after checking units, manifoldness and the manufacturing brief.
- Beauty/wireframe/clay/exploded renders with saved cameras and colour settings.

Export availability is app/version/scene dependent. A mesh converted into STEP is
not automatically a useful parametric solid. Check transforms, axis conversion,
units, material fidelity, external assets and stable identity after round-trip.

## Demonstration acceptance

The lamp tests shade thickness, glass/metal response, plausible light, component
naming, tilt/dimension parameters and reproducible rendering. It is not electrical
or thermal certification.

The kitchen uses explicit fictional room dimensions until measured sources are
provided. Cabinets should decompose into actual panels/doors/drawers/hardware,
not merely translated copies of a monolithic mesh. Check dimensions, part counts,
door/drawer motion envelopes and agreement between views, configuration and BOM.
Manufacturer appliance and hardware specifications replace assumptions before
production use. Installation/structural/service rules depend on jurisdiction.

## Adjacent tools and references

- FreeCAD: `tools/design/freecad.md`; Blender: `tools/design/blender.md`.
- Browser configurators: `tools/design/threejs.md`; capture: `3d-capture.md`.
- Archicad is a BIM/interchange candidate for building context and coordinated
  documentation, not an installed prerequisite. Use supported APIs/GDL/openBIM
  and native collaboration after separately verifying availability and authority.
- Unreal/Twinmotion and other engines are optional presentation targets; select
  them for a demonstrated need, not merely because an MCP exists.
- The [stadium reference](https://github.com/thebuggeddev/football-stadium) is
  PolyForm Noncommercial, not an MIT-compatible commercial template. Study the
  interaction requirements without copying its implementation into products.
