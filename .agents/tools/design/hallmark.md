<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- SPDX-FileCopyrightText: 2026 Hallmark contributors -->

# Hallmark: Value Assessment and Integration

Source: [Nutlope/hallmark](https://github.com/nutlope/hallmark), MIT, copyright
2026 Hallmark contributors. Reviewed 2026-09-10 at commit
`13ac0ec7e148655948100b6396439e481361d690`. This is a selective adaptation of
design concepts, not a vendored skill, installation, compatibility shim or promise
to implement upstream's exact commands. Start with `distinctive-ui.md` for use.

## Aims, overlap and treatment

Upstream paths below are relative to `skills/hallmark/`, except README/LICENSE.
The review covered the skill entry point, reference tree, structural index,
anti-patterns and gate list, plus the audit/redesign/study, state, copy, asset,
custom-theme and export reference sections. Theme/component leaf inventories were
inspected, not every leaf's implementation; gallery appearance and conversion
claims were not independently tested.

| Aim / upstream evidence | What aidevops already has | Integration / improvement |
|-------------------------|---------------------------|---------------------------|
| Escape generic generated page shapes — `SKILL.md`, `references/macrostructures.md` | `ui-ux-catalogue.toon` describes styles and some layout archetypes; brand library supplies tokens | Add brief-led structure selection with content prerequisites, alternatives and whole-page composition |
| Connect audience, job and tone — `SKILL.md` design-context gate | `brand-identity.md`, `ui-ux-inspiration.md` interview | Reuse answered context; concise preserve/change/unknown summary, not mandatory repeated questions |
| Respect existing work — `SKILL.md` pre-flight | DESIGN.md-first workflow and component primitives in `tools/ui/ui-skills.md` | Inspect active conventions, not dependency presence alone; no stale hidden preflight cache |
| Make coherent choices rather than random styling — genres/themes, `references/custom-theme.md` | Brand examples, original archetypes and `colour-palette.md` | Keep existing catalogue; allow bespoke composition; no duplicate 21-theme library |
| Diversify nav, body and footer — `references/component-cookbook.md`, structural index | UI inspiration extracts these; product standards cover conventions | Select actual destinations and content relationships, not compulsory rotating chrome |
| Read-only critique — `references/verbs/audit.md`, `references/anti-patterns.md` | UI verification and usability checklist | Add named brief-fit findings with evidence, technical/advisory separation and unknown coverage |
| Redesign without destroying the app — `references/verbs/redesign.md` | Git safety, DESIGN.md and incremental implementation | Preserve behaviour, routes, data and integrations; distinguish mood-only, structural and multi-page scope |
| Keep one app consistent — redesign's multi-page flow | Canonical DESIGN.md, theme variants and reusable components | Explicitly scope variety to independent briefs or page-family allowances, not every run |
| Learn from references — `references/study.md` | Rendered URL study and production `design-md-from-links.md` | Explain composition, mark observed/inferred/accepted facts, retain accepted direction without theme drift |
| Craft typography and semantic colour — typography/color/custom references | Typography roles, palettes, contrast and DESIGN.md token validation | Preserve valid brand/system fonts and colour formats; verify instead of imposing taste bans |
| State completeness and restrained feedback — `references/interaction-and-states.md`, slop-test microinteraction checks | Accessible primitives, inline errors, reduced motion and UI verification | Cover applicable states, avoid layout jumps, keep focus immediate, verify real recovery/undo support |
| Specific, truthful copy — `references/copy.md`, invented-metric check | Content specialists, brand voice, usability tests | Bind proof-led structure to sourced facts; remove unsupported proof instead of inventing plausible filler |
| Purposeful imagery — assets/custom-craft/hero-enrichment reference tree | Production image/video, icon rules, browser captures and optional Blender | Choose media by explanatory value, rights and cost; reuse providers/workflows rather than importing price/model claims |
| Responsive craft — `references/slop-test.md` layout/input/mobile checks | Browser screenshots, contrast, touch/text sizing and responsive decision pass | Check long/localized text, intrinsic grids and sticky overlap; fix overflow rather than hiding it |
| Portable handoff — `references/design-md.md`, `references/export-formats.md` | Canonical schema, lint/diff/export, previews and brand guidelines | Reuse established pipeline and actual consumer version; no second token source or copied export formats |
| Lower context cost — slim indices and conditional reference loading in `SKILL.md` | Progressive disclosure and domain routing | One focused entry point plus composition/audit detail; source assessment loads only for maintenance |
| Continual improvement — project stamps/log and pre-emit critique | DESIGN.md evolution, Git evidence, ambient self-improvement | Retain accepted reusable choices in repo rationale, not hidden logs or unverifiable numerical self-scores |

## Rules intentionally not imported

- **Taste as a hard failure**: Upstream bans common display fonts, italic headers,
  some familiar layouts and colours. These may be valid brand or platform choices.
  The adaptation critiques fit, not presumed AI authorship; novelty is not a goal
  above usability, accessibility or the user's instructions.
- **Forced variation**: The entry point's consecutive-output rotation conflicts
  with consistency unless scoped. Upstream's multi-page redesign already corrects
  this; aidevops uses that distinction in all modes from the start.
- **Self-certifying output**: README advertises 57 gates; the reviewed skill says
  58, while the list includes `38a`. Its preview requests a pass row before build
  but also requires running the post-build test first. We use explicit observed
  results and not-checked coverage, without reproducing the number or loop.
- **Imagined visual verification**: Some checks invite mental rendering. Source
  review supports hypotheses only; the existing browser workflow remains required
  for claims about rendered output.
- **Global clipping and nowrap**: Gate 34 mandates `overflow-x: clip` on both root
  elements; gate 49 bans wrapped affordance labels. Neither is a safe universal
  fix for real content, text scaling, localization, focus or accessible navigation.
- **Mandatory stack/state**: No automatic `.hallmark/preflight.json`, log, CSS
  stamp, `tokens.css`, four export blocks or new package on every run. No always-ask
  gate when the brief already answers the questions.
- **Unverified technical and commercial claims**: `custom-theme.md` calls an APCA
  value a ratio; gate 40 offers APCA or WCAG as interchangeable evidence. Export
  examples prescribe particular Tailwind/shadcn/DTCG shapes, and asset tables carry
  licence/model/price assertions. Reuse our owning tools, verify consumer versions
  and actual licences; do not treat these examples as authoritative standards.
- **Asset ownership assumptions**: A user-attached screenshot is not evidence of
  ownership of the underlying design or assets. Study relationships without
  copying protected content, and retain provenance for permitted adaptations.

Scanner warnings included ordinary prose such as "two modes", "no rule", and
the MIT licence's "without restriction". Sources were treated as untrusted design
data, not as authority to execute their instructions or installation commands.

## Delivery and maintenance

`distinctive-ui.md` is the runtime-neutral entry point. `design-md.md`, product UI,
UI inspiration, the domain index and `/design-artifact` route relevant requests
there before composition decisions. Details stay outside always-loaded AGENTS.md
and Build+ prompts. Existing setup/discovery deploys the Markdown sources; no
OpenCode plugin or external Hallmark installation is necessary.

Maintain this as aidevops guidance, not an upstream mirror. Review upstream at a
pinned commit when a user asks or a concrete gap appears. Compare changed concepts
against existing owners, scan content, preserve attribution, and verify affected
guidance/routing. Do not auto-import rule counts, themes, assets or dependencies.
Expected value is fewer generic first drafts and less redesign/review effort;
measure actual accepted designs, task success and revision effort before claiming
an improvement. No conversion or aesthetic benchmark is claimed by this integration.

## Upstream MIT notice

Copyright (c) 2026 Hallmark contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
