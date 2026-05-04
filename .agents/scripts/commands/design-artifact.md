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

1. If the project lacks `DESIGN.md`, create/lint it first via `tools/design/design-md.md`.
2. If the task is implementation in an existing codebase, use aidevops UI agents directly.
3. If the task is artifact-first preview/export (deck, poster, carousel, mobile mock, email, one-off HTML), consider `/open-design route "$ARGUMENTS"`.
4. If Open Design is used, keep generated files in its `.od/` workspace until selected outputs are reviewed.
5. Run verification: `workflows/ui-verification.md`, `email-design-test-helper.sh`, or media/deck export checks.

## Recommended Outputs

| Artifact | Primary route | Verification |
|----------|---------------|--------------|
| Landing page prototype | aidevops or Open Design `web-prototype` | Playwright screenshots + contrast |
| SaaS/pricing page | Open Design candidate, then aidevops implementation | CRO review + UI verification |
| HTML deck/PPT | Open Design deck skill | PDF/PPTX export + fidelity audit |
| Email creative | Open Design candidate + aidevops email workflow | local render + Email on Acid when needed |
| Mobile app mock | Open Design mobile skill | mobile/tablet screenshots + accessibility |
| Social carousel/poster | Open Design candidate | dimensions, brand, export QA |
| Production UI code | aidevops native | tests, lint, browser verification |

## Related

- `tools/design/open-design.md`
- `tools/design/design-md.md`
- `product/ui-design.md`
- `workflows/ui-verification.md`
