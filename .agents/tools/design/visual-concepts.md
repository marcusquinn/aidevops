---
description: Optional visual concept approval, image-to-code handoff and coherent mobile journey design
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: false
  grep: true
  webfetch: true
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- SPDX-FileCopyrightText: 2026 Leonxlnx -->

# Visual Concepts to Implementation

<!-- AI-CONTEXT-START -->

- **Optional path**: Brief → bounded concept → selected direction → canonical
  `DESIGN.md` → implementation → rendered comparison. Direct code remains valid.
- **Use when**: A board, reference or mock would resolve consequential design
  uncertainty; skip when direction is settled or the work is a small repair.
- **Authority**: An image is evidence of appearance, not exact tokens, functioning
  UI, accessibility, asset rights or permission to build/publish.
- **Reuse**: `brand-concepts.md`, `design-md.md`, `distinctive-ui.md`,
  `content/production-image.md`, `tools/vision/image-generation.md`,
  `product/ui-design.md` and `workflows/ui-verification.md`.
- **Source**: [Taste assessment and licence](taste-skill.md); adapted guidance,
  not an installed generator, new storage convention or competing design system.

<!-- AI-CONTEXT-END -->

## 1. Bound the concept work

Resolve whether the user wants study, concepts, implementation or export. Read
existing brand/design files and the real content/task constraints. A study is
read-only; concept creation writes only the authorized brief/artifact area, not
unaccepted canonical preferences. Existing brand constraints still apply.

State the surface, question to resolve, deliverable and stopping point. A few
concepts or one revision may suffice; use a user-approved budget when generation
has billing consequences. Check an available authorized provider and reference
rights through existing image tooling before generation. Do not upload private
screens/copy to an external provider without data-sharing authority, buy credits,
install tools, switch to paid API billing or retry indefinitely by implication.

If generation is unavailable, unnecessary or not authorized, use a textual layout
brief, supplied references, existing components or an authorized low-fidelity
wireframe. Report that no image was generated. Do not fabricate provider output.
No mandatory imagery per section, forced visual style or motion library.

## 2. Compare and select

Keep the same factual copy, viewport and task across alternatives so the comparison
isolates direction. Describe differences in hierarchy, composition, density,
imagery and interaction intent. Use a coherent idea, not random styling or merely
palette swaps. Provide readable text alongside image boards and label placeholders.

Record selection and rejected trade-offs in the existing brief. Honour a requested
approval checkpoint before coding; if the user already authorized choosing and
implementing a direction, document the choice without another approval ritual.
Selection is not permission for unrelated behaviour changes or publication.

## 3. Translate the selected direction

Record a compact handoff, not a pixel-perfect claim based on guessed image values:

| Evidence | Handoff decision |
|----------|------------------|
| Accepted composition | Information order, hierarchy, proportions, alignment and responsive intent |
| Observed/approximate appearance | Proposed font candidates, spacing and colours to validate, not extracted exact facts |
| Existing brand and implementation | Reuse canonical tokens, primitives, licensed fonts and real assets |
| Factual content | Preserve approved copy, claims, prices and data; never transcribe generated hallucinations |
| Interactions absent from the image | Specify keyboard, focus, navigation, states, validation and recovery |
| Constraints | Explain accessibility/platform adaptations and unresolved approval/rights questions |

Promote accepted cross-cutting decisions through `brand-identity.md` and
`design-md.md`. Implement in the real codebase through Distinctive UI build/redesign
and existing framework owners. Do not substitute a nearby catalogue theme or
flatten interactive UI into an image to imitate the concept.

## 4. Keep mobile journeys coherent

Before drawing independent screens, identify the main task and map a small
meaningful journey: entry → action → result, with back/cancel and recovery. Reuse
`tools/mobile/app-dev.md`, `product/onboarding.md` and platform guidance.

For each screen/transition record the user action, destination, visible state,
persisted input/selection and back behaviour. Cover relevant loading, empty, error,
permission-denied and interrupted/resumed states. Do not invent persistence,
checkout or undo support that the backend does not provide.

Share navigation, semantic tokens, type, icon style, controls and motion across
the journey. Page-family variation must be intentional, not a new theme for each
screen. Include realistic long/localized text, text scaling, keyboard/insets,
safe areas, touch targets, focus order and assistive labels. Respect native HIG/
Material conventions where applicable; an aesthetic reference is not an official
platform design system.

## 5. Verify implementation, not just resemblance

Use `workflows/ui-verification.md` for web and `tools/mobile/app-dev-testing.md`
for native/mobile. Compare the rendered affected surface with the selected concept
at matching bounded viewports/states (max 1568px longest side for AI screenshots).
Explain material deviations instead of silently redesigning during implementation.

Check actual layout, loaded fonts/assets, real copy, interactions, responsive
behaviour and standard runtime diagnostics. Verify contrast, keyboard/focus,
semantics, text scaling and reduced motion relevant to the changed surface.
Visual fidelity never overrides accessibility or functional correctness; resolve
conflicts with the smallest explicit adaptation and record it in `DESIGN.md`.

Report concept selection, changed paths, observed checks, deviations and untested
coverage separately. An approved screenshot cannot earn a functional or WCAG pass;
before implementation, these checks remain planned, not completed.
