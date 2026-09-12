---
description: Three.js configurable product viewers, stable parts, view modes and export contracts
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Three.js product viewers

Use Build+ for application implementation and 3D Modelling for authoritative
assets. A Three.js MCP is not required: use the installed library, source code and
the existing browser verification workflow. Verify package version/exports before
API changes; do not load every engine guide or invent supported export formats.

- Share the parameter schema, valid combinations, units and stable part IDs with
  the CAD/mesh recipe. A viewer change must not silently diverge from drawings/BOM.
- Separate configuration state, geometry generation, material options, selection,
  camera/view modes and export jobs. Keep business/pricing data outside geometry.
- Provide assembled/exploded, wireframe/clay/material, orthographic elevations and
  clipping/section views where meaningful. Label approximate visual cuts; they are
  not automatically CAD drawings or watertight manufacturing sections.
- Use instances for repeated components, suitable LODs and measured texture/GPU
  budgets. Dispose replaced resources. Validate picking/IDs after optimisation.
- Record supported imports/exports and losses: GLB materials may differ from Cycles;
  baking, compression or axis conversion may change appearance/identity.
- Provide accessible form/list alternatives to canvas-only controls, keyboard
  selection, visible focus, touch targets, loading/error states and reduced motion.
- Keep the object visible and properly framed on desktop/mobile. Verify nonblank
  rendered pixels, interactions, parameter updates, export contents and console
  errors using `workflows/ui-verification.md`; HTTP 200 is not proof of a scene.

Record durable UI decisions in the project `DESIGN.md`. Do not copy source-available
noncommercial demos into a commercial app; use licensed dependencies and original
implementation. For deterministic video, reuse `tools/video/remotion-3d.md`.
