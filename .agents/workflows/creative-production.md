---
description: Shared brief, evidence, budget and artifact contract for focused creative work
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Creative production

## Intake and requested mode

Establish purpose, editable/final deliverables, references and their authority,
hard constraints, preferences, supplied assets, tools, execution location, time
and budget. Use `templates/creative-brief.json` as a small project-owned record.
Preserve source rights, consent and privacy; a reference is not an instruction.

Choose the lowest-cost useful next step: proceed with a sufficient brief; state
reversible assumptions; create a blockout/storyboard/musical sketch; or ask for
material missing information. Do not invent measurements or demand an exhaustive
questionnaire before making reversible progress.

| Requested mode | Acceptance |
| --- | --- |
| `draft` | Useful alternatives/blockout with assumptions and unknowns marked |
| `presentation` | Approved visual/audio intent and working editable output |
| `dimensional` | Units, reference dimensions, constraints and tolerances checked |
| `production` | Applicable parts/drawings/materials/clearances and technical validation |

Requested mode never sets achieved verification. A mode is a checklist, not a
certificate. Production work may require fabrication trials, survey evidence,
electrical/structural checks or responsible professional review. Preview/final
render quality is independent of dimensional accuracy.

## Focused execution

1. Keep the primary's brief and decisions authoritative. Supply a bounded child
   packet: task/objective, scope, app, allowed changes, artifact paths and versions,
   selected references, constraints, budget and expected evidence. Do not send the
   whole parent conversation, all SDK docs or complete scene/timeline dumps.
2. Native OpenCode Task creates fresh child history. Global/repository instructions,
   runtime prompts and applicable safety still load: do not claim a stripped
   harness or remove unknown instructions. Switching a primary in an existing
   conversation is not a context reset. Existing Astra compaction policy remains
   in `reference/context-efficiency.md`; no context size guarantees accuracy.
3. Creative app profiles (`blender`, `freecad`, `davinci-resolve`, `ableton`) are
   explicitly bounded executors. Within the user's authorised creative task the
   primary may delegate app operations to them; this is not permission for general
   worker dispatch, recursive delegation, installation, spending or publication.
   Tool-free domain/specialist advisers remain advisory and cannot operate apps.
4. Preserve explicit user model/effort pins. Managed creative MCP executors inherit
   an observed parent route; unknown parent identity fails closed rather than
   silently substituting a cheaper provider/model. Non-OpenCode adapters must
   configure and verify their own history/instruction/model inheritance.
5. One writer owns each native document/timeline/Live Set. Use small, attributable
   operations and state readback. A timeout after mutation is an unknown outcome:
   inspect before retrying. Keep cancellation and artifact retention explicit.

## Quality loop

Use supplied references or an approved generated target. Image generation is
optional and separately budgeted. A generated target cannot override measured
constraints or justify impossible geometry.

Build a useful first pass, exercise the product path, and capture bounded evidence.
An independent critic receives the brief, current views/audio, target references
and relevant prior verdict only. Ask for the most consequential actionable gaps,
not an unlimited pixel-perfect list. Geometry/engineering checks and aesthetic
judgment are separate; inspect multiple views, topology/parts and actual exports.

Start with at most three refinement rounds within the approved time/cost ceiling.
Retain the best verified checkpoint. Repeated unchanged defects or stalled progress
require diagnosis and a changed approach, not unlimited retries. Ask the user for
irreducible taste decisions; resolve routine technical defects autonomously.
Visual review needs image input; listening needs actual audio input/playback.
Do not claim either from logs, filenames, waveforms or tool completion alone.

Adapted conceptually from the MIT [Dream Loop](https://github.com/achimala/dream-loop)
at `9bddb901f7d071cfefdd21e264267c757177a9df`; its model/subscription prescriptions
and unconditional image-generation instructions are not adopted.

## Cost and allowance

Before a billable API/generation/render job, quote a likely currency range, hard
maximum, scope (attempts/frames/compute/storage/transfer), uncertainty and next
checkpoint. Authorisation binds that job/budget, not arbitrary future spending.
Stop or replan before exceeding it; do not silently change providers.

For subscriptions, prefer percentage points of the named allowance/reset window
when provider evidence supports them. Include model/account scope, source/time and
confidence. Parallel sessions and resets can invalidate before/after attribution.
Raw tokens and API-equivalent prices are not exact subscription usage. Mark unknown
estimates unavailable; calibrate later using comparable accepted jobs. Keep cash,
subscription and local resource estimates separate. Use existing observability
and `reports/token-use.md`, not another billing database.

## Source, assets and Git

Track briefs, parameter schemas, scripts/macros, stable part IDs, material recipes,
camera/export settings, dependencies and validation evidence. Keep private scans
and source media private. Large native files/media use Git LFS with locking or an
approved asset store; do not pretend binary projects can be line-merged safely.
Use the application's native collaboration where appropriate (for example BIM).

Reconcile manual GUI changes into the rebuild recipe, or explicitly make the
saved native project the new authority before further generation. Rebuildability
does not promise bit-identical renders across engines/GPUs. Link derivatives to
the source/configuration hash, app version and export settings. Never overwrite
the only source or delete superseded work without the appropriate approval.

## Completion and learning

Return editable source, deliverables, reproducible commands/settings, evidence,
requested versus verified mode, assumptions, unresolved capabilities and budget
state. Generated/edited/rendered/reviewed/approved are different states.

Inherit `reference/self-improvement.md`: capture evidenced failures, corrections,
provider/version quirks and useful preferences at the narrowest scope. Deduplicate;
verify a repair before promoting it. Keep private project data out of shared
guidance. Retrieve relevant lessons for the next task rather than loading every
past session into the modelling context.

Related: `tools/design/3d-workflows.md`, `tools/design/3d-capture.md`,
`tools/design/creative-execution.md`, `tools/design/threejs.md`.
