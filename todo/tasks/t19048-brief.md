## What

Add a remote 3D rendering playbook so agents can choose, cost and run off-Mac Blender (Cycles/Eevee) renders, and extend the cloud GPU guide with rendering-capable GPUs and missing providers.

## Why

aidevops covers Runpod for AI media generation (`content/video-runpod.md`) and generic GPU rental (`tools/infrastructure/cloud-gpu.md`), but `tools/design/creative-execution.md` "Rendering" only states requirements for remote rendering. There is no provider/render-farm comparison, no Cycles GPU guidance (RT cores/OptiX, VRAM), no headless Blender job recipe and no worked cost method. Upcoming 3D modelling work needs this.

## How

- NEW: `.agents/tools/design/3d-render-backends.md` — decision table (local Metal, rented GPU DIY, managed farm, community farm, dedicated monthly), provider comparison with dated prices and sources, Cycles GPU selection, job contract (pack, bake, version pin, test frame, budget, cancel, hashes), headless Blender commands, cost method via `media-gen-cost-helper.sh compare`, user-experience notes.
- EDIT: `.agents/tools/infrastructure/cloud-gpu.md` — add SaladCloud, TensorDock, DigitalOcean, Hetzner GEX, AWS rows; add 3D rendering row to GPU selection; see-also pointer.
- EDIT: `.agents/tools/design/creative-execution.md` "Rendering" — pointer to the playbook.
- EDIT: `.agents/3d-modelling.md`, `.agents/subagent-index.toon` — discoverability.

## Acceptance

- Playbook exists, prices carry an as-of date and source, unverified items are marked.
- `markdownlint` / `linters-local.sh` pass for changed files; `verify-agent-discoverability.sh` or subagent index tests pass.

## Files Scope

- .agents/tools/design/3d-render-backends.md
- .agents/tools/infrastructure/cloud-gpu.md
- .agents/tools/design/creative-execution.md
- .agents/3d-modelling.md
- .agents/subagent-index.toon
