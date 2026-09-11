---
description: Route artifact-first design requests across aidevops and optional Open Design
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design Artifact Routing

Request: $ARGUMENTS

## Decision Tree

For design audit or reference study, use `tools/design/distinctive-ui.md` in its
read-only mode and stop after the report unless implementation/export is requested.
For new UI composition, redesign or "less generic" requests, load that guide before
choosing a structure; keep the existing DESIGN.md authoritative. The following
creation/export steps apply only to the authorized artifact scope.

For brand directions/boards, use `tools/design/brand-concepts.md`. For optional
visual concepts, image-to-code or a coherent mobile journey, use
`tools/design/visual-concepts.md` before the creation steps. Concept-only work
keeps proposals in the authorized brief/artifact area; do not populate canonical
brand/design files until adoption is authorized. Generation and Open Design are
optional; lack of a provider is not a blocker to a useful non-generated concept.

1. For authorized implementation or design-system export, if the project lacks `DESIGN.md`, create/lint it via `tools/design/design-md.md` using accepted choices.
2. For brand guideline handoff, run `aidevops design guidelines . --pdf` and review `_reports/brand-guidelines/`.
3. For cross-repo rollout, run `aidevops design survey --json` then `aidevops design issues --apply` to file worker-ready GUI repo tasks.
4. If the task is implementation in an existing codebase, use aidevops UI agents directly.
5. If the task is artifact-first preview/export (deck, poster, carousel, mobile mock, email, one-off HTML), consider `/open-design route "$ARGUMENTS"`.
6. If Open Design is used, keep generated files in its `.od/` workspace until selected outputs are reviewed.
7. Run verification: `workflows/ui-verification.md`, `email-design-test-helper.sh`, or media/deck export checks.

## Recommended Outputs

| Artifact | Primary route | Verification |
|----------|---------------|--------------|
| Brand concept board | aidevops `brand-concepts.md` | rationale, readable labels, rights/contrast; production kit checks remain separate |
| Visual concept / image-to-code | aidevops `visual-concepts.md` | direction selection, provenance, rendered comparison after implementation |
| Landing page prototype | aidevops or Open Design `web-prototype` | Playwright screenshots + contrast |
| SaaS/pricing page | Open Design candidate, then aidevops implementation | CRO review + UI verification |
| HTML deck/PPT | Open Design deck skill | PDF/PPTX export + fidelity audit |
| Email creative | Open Design candidate + aidevops email workflow | local render + Email on Acid when needed |
| Mobile app mock | aidevops visual-concepts journey; optional Open Design | shared system, transitions/state, platform screenshots + accessibility |
| Social carousel/poster | Open Design candidate | dimensions, brand, export QA |
| Production UI code | aidevops native | tests, lint, browser verification |

## Related

- `tools/design/open-design.md`
- `tools/design/design-md.md`
- `product/ui-design.md`
- `workflows/ui-verification.md`
