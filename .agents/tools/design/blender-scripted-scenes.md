---
description: Script-built Blender scenes - Python build contract, seamless loops, Blender 5.x API notes, preview loop and delegating modelling to another model
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Script-built Blender scenes

<!-- AI-CONTEXT-START -->

Use when an agent authors a Blender scene in Python (headless, no GUI) for local
preview and a remote render, or briefs another model to do so. The build script is
the editable source; the `.blend` and frames are derived outputs. Remote job
mechanics: `tools/design/3d-render-backends.md`.

- One script builds the whole scene from an empty file; render settings are saved in it.
- Motion uses keyframes or F-curve modifiers only, so the file renders with `-Y`.
- Probe uncertain Blender 5.x API names with small runs; never guess.
- Review several rendered frames across the range before any paid render.

<!-- AI-CONTEXT-END -->

## Build contract

- Build from empty: `Blender -b --factory-startup -P build_scene.py -- out.blend`.
  In the script, call `bpy.ops.wm.read_factory_settings(use_empty=True)` and read
  arguments after `--` from `sys.argv`.
- No external files: procedural node textures, or images packed into the `.blend`.
- No Python drivers, and no unbaked physics, particles or Geometry Nodes
  simulations. Remote renders run with `-Y` (auto-run off), which disables drivers.
- Save render settings in the file: engine, resolution, samples, denoiser, output
  `//frames/frame_####`, frame range, fps and scene camera.
- `scene.cycles.device = "GPU"` is saved, but the backend (OPTIX, METAL, CUDA) is a
  user preference. Set Metal only in a preview-only script; the render helper's
  `enable_gpu.py` selects OptiX remotely. Never put Metal in the build script.
- Keep consumer-GPU scenes under about 2 million triangles and 8 GB of VRAM.

## Seamless loops

For a period of P frames, frame P+1 must equal frame 1. Two methods passed on
2026-11-17 (P = 120):

- **Harmonics.** Each channel is a sum of whole-number harmonics of P, keyed on
  every frame 1..P+1 with LINEAR interpolation. Measured loop error was 0.0.
- **Cyclic keys.** Equal keys at frame 1 and P+1 plus a `CYCLES` F-curve modifier.

Deformation patterns that worked:

- An armature for plant sway: a chain of stem bones (amplitude growing towards the
  top, with a small phase lag up the chain), a head bone and one bone per leaf.
- Two shape keys keyed 90 degrees apart give many small parts (petals) their own
  flutter phase without one bone per part.
- A small camera drift or orbit with a Track To constraint adds parallax.

## Blender 5.x API notes (5.3.0)

- Actions are layered. `action.fcurves` can be missing or empty, so create a slot
  and channelbag and add F-curves there:

  ```python
  act = bpy.data.actions.new(name)
  slot = act.slots.new(id_type=idb.id_type, name=name)
  cb = act.layers.new("Layer").strips.new(type="KEYFRAME").channelbag(slot, ensure=True)
  ad = idb.animation_data_create()
  ad.action, ad.action_slot = act, slot
  fc = cb.fcurves.new("rotation_euler", index=0)
  ```

  `keyframe_insert()` also works and creates the layered action for you.
- `Material.use_nodes` and `World.use_nodes` print deprecation warnings (removal
  planned for 6.0). They are harmless in 5.3.
- Socket names change between versions (Principled `Subsurface Weight`,
  `Coat Weight`; Mix node data types). List them with a short probe run:
  `Blender -b --factory-startup --python-expr "<print node inputs>"`.
- Check a built file the way a remote worker opens it:
  `Blender -b -Y scene.blend --python-expr "<print engine, resolution, samples, output, range, camera, len(bpy.data.images), len(bpy.data.libraries)>"`.

## Preview and review loop

- Local Metal previews at 50% resolution and 64 samples. Check the first frame,
  quarter points and the last frame, not one frame. The first Metal render on a
  machine compiles kernels and can take minutes.
- Measure warm seconds per frame at full quality: render 3 frames in one Blender
  run and time the later ones. A single cold frame includes scene sync, BVH build
  and denoiser start-up. On 2026-11-17 a cold 20-31 s Mac frame became 8.1 s/frame
  on an A40 once warm. Warm time, not the triangle count, drives the remote estimate.
- The renderer's self-review is not acceptance. Show the user a still before a
  paid range render.

## Delegating the modelling to another model

Use when the user asks for a specific model (for example Claude Fable) to do the
creative work while the primary owns the pipeline, budget and render.

1. **Brief file.** Separate hard pipeline requirements (this guide's build
   contract) from creative freedom. Set a scratch working directory, no network,
   installs, git or secrets, a time budget, and deliverables: build script,
   `.blend`, one full-quality frame, `NOTES.md` with warm seconds per frame,
   triangle count and known issues.
2. **Run** under `aidevops_bounded_operation` with a budget:

   ```bash
   env OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX=64000 opencode run \
     "Read the attached BRIEF.md and carry it out. Write large files in sections of under 120 lines." \
     -m <provider/model> --dir <scratch-dir> --title "<title>" --auto -f <scratch-dir>/BRIEF.md
   ```

   Put the message before `-f`, which takes an array. `--auto` approves every
   permission that is not denied; aidevops command policy still applies, but the
   brief's boundaries are instructions, not a sandbox.
3. **Output clamp.** OpenCode clamps each response to 32,000 output tokens by
   default, and thinking counts. Writing a whole build script in one tool call ends
   with finish reason `length` and `Tool execution aborted`, and nothing is saved.
   Raise the clamp and ask for sectioned writes (Write, then Edit appends) or
   helper modules.
4. **Resume** with `--session <id>` from `opencode session list --format json` run
   in the scratch directory. Bare `--continue` is blocked because it can attach to
   another live session.
5. **Diagnose a silent exit** with `opencode export <id> | rg '"finish"'`. Piped
   export output can be truncated, so read the last `finish` values.
6. **Verify independently:** load the file with `-Y`, check settings and view frames.

Observed on 2026-11-17: `claude-fable-5-2` built a 636-line sunflower scene in
about 17 minutes once the clamp was raised (1,300 florets, translucent petals,
subdivision, depth of field, about 110k triangles). Its brief asked for one cold
full-quality frame, which over-stated the cost about 3x; ask delegates for warm
timing instead. Delegate token cost was not measured.

## Related

- `tools/design/3d-render-backends.md`: remote routes, job contract, helper, measurements
- `tools/design/blender.md`: Blender Lab MCP and interactive scene inspection
- `workflows/creative-production.md`: brief, quality mode and acceptance
