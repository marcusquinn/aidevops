<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18057: feat(agents): add a reusable tiled image mosaic agent capability

## Pre-flight

- [x] Memory recall: `aidevops tiled mosaic agent issue todo brief` → 0 hits.
- [x] Discovery pass: `prework-discovery-helper.sh --keywords "tiled image mosaic photo mosaic collage wallpaper mozaic agent skill" --files "TODO.md todo/tasks" --repo marcusquinn/aidevops` → no related recent commits, merged PRs, or open PRs reported.
- [x] Existing issue search: `tiled mosaic`, `photo mosaic`, `mozaic`, and `collage wallpaper` in `marcusquinn/aidevops` → no matches found before filing this task.
- [x] Tier: `tier:standard` — this is a focused agent/skill addition, but it needs image-pipeline judgment, trigger wording, fixture examples, and verification guidance.

## Origin

- **Created:** 2026-07-02
- **Session:** OpenCode interactive framework follow-up
- **Created by:** AI DevOps (ai-interactive)
- **Source issue:** GH#26259
- **Blocked by:** none
- **Conversation context:** A working implementation produced recognisable tiled photo mosaics by switching from texture-like micro-tiles to larger square image tiles, generating real tile assets, assembling them with explicit dimensions, and checking the visual result against source images and generated tiles. Capture that implementation pattern as a reusable aidevops agent or skill without coupling it to any application-specific repository or domain.

## What

Add an aidevops agent or skill that can reproduce high-quality tiled image mosaics, photo mosaics, collage wallpapers, and image-grid backgrounds from real source imagery. The capability should teach the agent how to choose tile size, filter and crop source images, generate reusable tile assets, assemble a deterministic output, and verify that the result is visually recognisable rather than a noisy texture.

The discovery triggers should include at least:

- `tiled image mosaic`
- `photo mosaic`
- `image mosaic`
- `collage wallpaper`
- `image grid background`
- `mozaic` as a misspelling users commonly type

## Why

Generic image-generation prompts often produce collage-like suggestions but do not reliably implement a reproducible asset pipeline. A dedicated aidevops capability should preserve the operational lessons from a successful implementation:

- tiny 100px-style tiles can be acceptable for abstract texture but are usually too small for recognisable event or product photos;
- 200px square tiles are a proven starting baseline when the goal is for humans to recognise individual photos inside the mosaic;
- generated outputs should use actual processed source images, not placeholders or arbitrary stock imagery;
- explicit rendered dimensions prevent SVG/HTML composition bugs where embedded images collapse, blur, or reuse incorrectly;
- a proof image or visual verification artifact is required before claiming success.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** Unknown — depends on whether this lands as a skill, agent, reference doc, or helper script.
- [ ] **Every target file under 500 lines?** Unknown — agent/skill registries may require navigation.
- [ ] **Exact `oldString`/`newString` for every edit?** No — choose the best framework location and wording.
- [ ] **No judgment or design decisions?** No — select agent versus skill and define verification contract.
- [x] **No production safety gate changes?** Yes — docs/agent capability only unless a helper script is added.
- [ ] **Estimate 1h or less?** No — estimate ~4h including examples/tests.
- [ ] **4 or fewer acceptance criteria?** No — image-pipeline quality needs explicit criteria.

**Selected tier:** `tier:standard`

**Tier rationale:** The task is bounded, but implementation quality depends on image-processing decisions and framework integration choices. It should be worker-ready, not a one-line prompt tweak.

## PR Conventions

Leaf task: use `Resolves #26259` in the implementation PR body.

## Files Scope

### Candidate files to modify

- `EDIT: .agents/skills/<new-or-existing-image-mosaic-skill>/SKILL.md` — preferred if this should be invoked only when the user requests mosaic/collage image generation.
- `EDIT: .agents/agents/<new-or-existing-agent>.md` — use only if a dedicated agent is more appropriate than a skill.
- `EDIT: .agents/tools/build-agent/build-agent.md` or relevant skill documentation only if discoverability rules require a pointer.
- `ADD: .agents/skills/<skill>/fixtures/` or a small fixture/example file if the framework convention supports fixture-driven verification.

Keep the capability generic. Do not mention private projects, client names, local file paths, or application-specific domains.

## Implementation Guidance

1. Decide whether this belongs as a skill or a specialised agent:
   - Prefer a skill if it is a task-specific workflow invoked by phrases such as `photo mosaic`, `collage wallpaper`, or `mozaic`.
   - Prefer an agent only if autonomous multi-step image-asset generation and verification should be routed as a distinct worker role.
2. Document the pipeline the agent should follow:
   - collect or locate source images from approved local/project assets only;
   - exclude tiny images, logos, transparent placeholders, screenshots, and unrelated decorative files unless the user explicitly wants them;
   - normalize orientation and crop each selected source to a square cover tile;
   - generate real tile assets with deterministic names;
   - use 200px square tiles as the default recognisable-photo baseline;
   - allow smaller tiles only when the user wants abstract texture rather than recognisable photos;
   - assemble the output with explicit width/height attributes or CSS dimensions for every tile;
   - avoid SVG &lt;symbol&gt;/&lt;use&gt; indirection for raster-heavy mosaics unless the renderer is proven to preserve embedded image rendering;
   - generate at least one proof artifact that compares the final mosaic with representative source images and tile assets.
3. Include quality heuristics:
   - enough source-image variety to avoid obvious repetition;
   - balanced crop focus where possible;
   - visible individual-photo recognisability at the target display size;
   - no accidental use of private or secret images in public artifacts;
   - deterministic regeneration command or documented manual workflow.
4. Add examples that explain the difference between:
   - texture mosaic: many small tiles, recognisability not required;
   - recognisable photo mosaic: fewer larger tiles, 200px baseline, proof required;
   - collage wallpaper: responsive grid or SVG/HTML background with explicit dimensions.
5. Add tests or dry-run verification suitable for the chosen framework location. At minimum, include a checklist that a worker can run against a small fixture image set.

## Acceptance Criteria

- [ ] aidevops exposes a discoverable agent or skill for `tiled image mosaic`, `photo mosaic`, `image mosaic`, `collage wallpaper`, `image grid background`, and `mozaic`.
- [ ] The guidance includes a concrete image-processing pipeline: source filtering, square cover-crop, real tile asset generation, deterministic assembly, and proof verification.
- [ ] The guidance documents the 200px square tile baseline for recognisable-photo mosaics and explains when smaller texture tiles are acceptable.
- [ ] The guidance warns against placeholders, arbitrary unrelated images, private-image leakage, and renderer-fragile SVG reuse patterns.
- [ ] A fixture, dry-run example, or explicit verification checklist lets workers prove generated mosaics are recognisable before claiming completion.
- [ ] No application-specific project names, private repo names, local paths, or client identifiers are added to public aidevops content.

## Verification

Recommended verification after implementation:

```bash
# Confirm the new capability is discoverable by likely user phrasing.
rg -n "tiled image mosaic|photo mosaic|collage wallpaper|mozaic" .agents

# Run the framework's local quality checks.
.agents/scripts/linters-local.sh
```

If a helper script or fixture generator is added, include its focused test command in the PR body and run it before handoff.

## Notes for Worker

- Keep this generic and reusable across projects.
- Do not mention the project where the lesson was first observed.
- Prefer implementation details over brand/domain context: tile size, image filtering, crop strategy, output assembly, and visual proof are the transferable parts.
- Use public-safe placeholders such as `source-images/`, `generated-tiles/`, and `mosaic-proof.png` in examples.
