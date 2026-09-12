<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Focused creative production

Tracking: GH#31822, owned by the primary interactive session. Release not requested.

## Objective and authority

Implement the approved 3D Modelling, Video, and Audio/Music primary-agent design
in aidevops. Content and Build+ use the same focused app specialists. The primary
interactive session owns implementation, verification, PR review and merge.
Publication, paid generation, cloud rendering, application installation, and
unguarded desktop/MCP connections require their separate applicable authority.

Resolve is optional, not an installed prerequisite. Archicad and Unreal are
reference/interchange targets, not applications to purchase or install.

## Delivery units

| Unit | Owner / effort | Files and scope | Dependencies | Acceptance |
| --- | --- | --- | --- | --- |
| C1 | Primary / thinking | New root creative agents; shared production workflow; domain/index/command routing | None | Canonical primaries delivered without loading every app guide |
| C2 | Primary / thinking | MCP registry, per-agent tools, creative launcher and focused execution contracts | C1 | Disabled startup; deny unrelated tools; preserve model pins; fail closed before external execution |
| C3 | Primary / standard | Blender/FreeCAD/Resolve/Ableton guides; capture, desktop, rendering and asset contracts | C1 | Version/provenance, isolation, telemetry, truthful readiness and authority documented |
| C4 | Primary / thinking | Creative demo scripts/templates and configurable lamp/kitchen recipes | C1 | Rebuildable source; named parts; dimensions; rendered/exported evidence; no automatic fabrication certification |
| C5 | Primary / standard | Existing applicable tests/lint plus focused regressions and runtime evidence | C1-C4 | Registration, authority and artifact checks; independent visual/security review where applicable |
| C6 | Primary / standard | Signed PR, terminal checks/reviews, guarded merge and cleanup | C5 | Managed full-loop complete; release not requested |
| C4-V | Advisory critic / standard | Supplied render and responsive-viewer screenshots only; no edits or acceptance authority | C4 artifacts | Concrete visual findings with screenshot citations; primary verifies disposition |

Advisory research is capped at two children with no further delegation. Unit
ownership is disjoint: runtime-profile discovery and upstream-adapter discovery
may be delegated read-only; implementation stays with the primary. Reuse their
returned evidence rather than repeating discovery.

## Production contract

- Four requested modes: draft idea, presentation, dimensionally accurate, and
  fabrication/construction package. Achieved verification is separate from mode.
- Brief assessment may proceed, state reversible assumptions, create a draft,
  or request material missing information. Generated targets never override
  measured constraints. Render fidelity is independent of dimensional accuracy.
- Preserve relevant framework safety and project instructions. Fresh Task
  history is not a stripped system prompt. App specialists receive a bounded
  brief, selected references, current artifact state, and only their tools.
- Keep one writer per native project. Hybrid MCP/API and UI actions require
  state readback. Headless execution, independent desktop input and OS security
  isolation are distinct properties; do not certify one from another.
- LiDAR/depth capture is opt-in source data, not assumed embedded in ordinary
  video. Preserve originals, calibration and uncertainty. Scans, images and
  acoustic hypotheses do not establish fabrication measurements by themselves.
- Quote billable cost ranges and ceilings before external jobs. Subscription
  estimates name the allowance/reset window and evidence quality; never derive
  exact percentages from raw token counts or API-equivalent currency estimates.
- Keep code, parameters, stable part IDs, decisions and verification in Git.
  Native binaries/large media need locking or asset storage. Reconcile manual
  edits with the rebuild recipe. Retain scoped, evidence-backed session learning.

## Demonstrations

1. Banker's lamp: green glass shade, brass assembly, bulb/light, adjustable
   dimensions/tilt/finish, named parts, source recipe, beauty render and export.
2. Modern kitchen: fictional explicit room dimensions; cabinets, panels, doors,
   drawers/worktop/appliances; stable assembly/part IDs; exploded view and parts
   list; consistent parameter updates and relevant dimension checks.

Both are original demonstrations. They are not certified electrical products,
as-built surveys, installation specifications, or ready-to-run fabrication files.

## Evidence and adoption choices

- Existing Blender pattern: `.agents/tools/design/blender.md`,
  `.agents/scripts/blender-lab-mcp-launcher.py`, and
  `.agents/plugins/opencode-aidevops/tests/test-blender-mcp-registry.mjs`.
- FreeCAD candidate: `neka-nat/freecad-mcp`, inspected revision
  `5dbfe2c80b53c3102bff0723951676e16edf2d84`; headless and GUI execution differ.
- Resolve candidate: `samuelgursky/davinci-resolve-mcp`; compact API surface;
  optional offline DB/XML mutation is excluded from initial activation.
- Ableton candidate: `ahujasid/ableton-mcp`; disable documented default-on
  telemetry before connecting and verify actual exports/installed app support.
- Adapt the MIT Dream Loop visual-target/independent-critic pattern, not its
  unconditional image generation or pixel-perfect target instructions.
- Stadium reference is PolyForm Noncommercial: do not vendor its code.
- Higgsfield's official posts claim Blender/Cycles execution on Supercomputer;
  arbitrary-job API, editable exports and pricing remain unverified.

## Verification and continuation

Use changed-file lint, native plugin tests, Python syntax/unit checks and the
normal demo CLI. Exercise installed local tools without GUI takeover or paid
services. Prove optional integration refusals without inventing live handshakes.
Review actual artifacts, not successful process exit alone. Record exact
commands, outcomes, unresolved capabilities and PR identity here as work proceeds.

### Implementation checkpoint

- C1/C3 guidance written: three root primaries, shared brief/mode/budget/Git/learning
  contract, capture/representation/desktop/viewer guides, app-specific guides.
- C2 code written: disabled MCP registration, scoped tools, parent-route inheritance
  and source/approval-gated launcher. Preserve venv interpreter symlinks.
- Markdown lint passes on the new/changed guides. Python/Node syntax checks pass.
- Foundation committed as `f5db5dc44`. Launcher checks: 8 passed. Combined creative,
  MCP activation, Blender registry, research boundary and effort-routing checks:
  71 passed, 0 failed. Fixed wildcard frontmatter parsing and venv symlink handling.
- C4 recipe/CLI, Blender/FreeCAD exporters and local Three.js viewer are written.
  The lamp rebuild exports 28 actual GLB meshes; native source and Cycles PNG exist.
  Evaluated export copies retain editable curves/modifiers in the native project.
- Fixed FreeCADCmd's imported-script entry point. Kitchen exports 131 GLB meshes;
  130 valid CAD solids survived native reopening and STEP import. The worktop is
  3050 mm; the curved tap remains explicitly excluded reference geometry.
- Browser QA uses the existing installed Playwright Core 1.57.0 via the helper's
  documented module override and an existing separate browser. Both models load
  on desktop/mobile. Initial smoke found only a missing favicon; source repaired.
  Structural accessibility reported no issues. The helper's contrast subcheck was
  unavailable; a bounded check of actual rendered CSS confirmed ratios 6.58–20.24.
- Final v3 viewer verification passed part/view/wireframe/explode/section/fit/PNG
  interactions, 6 lamp and 9 kitchen downloads, keyboard focus, 44px controls,
  mobile overflow checks and retention of a verified model after a failed load.
  No unexpected browser errors. Independent C4-V review accepted the refined
  lighting, material legibility and framing; only optional exploded-view tone polish.
- Runtime evidence is under ignored `.agents/loop-state/creative-{lamp,kitchen}-v3/`.
  Viewer uses pinned Three.js 0.186.0 (upstream r186); dependency install ran with
  lifecycle scripts disabled. No live third-party MCP, app install or paid job ran.
- Native demonstrations have been archived outside the worktree before cleanup.
  Offline demo tests: 10 passed; changed-file lint passes with no new regressions.
- C5 adds explicit creative workflow/app readiness records; catalogue presence is
  not installation, consent, bridge reachability or verified usability. Git source
  validation also rejects nested directories inheriting a parent repository pin.
- Next: finish capability-registry validation and independent security closeout,
  commit, PR and guarded merge. Release remains not requested; no PR exists yet.
