<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Signal Agency — Agent Prompt Guide

## Quick prompt

> Build an AI-search audit report following Signal Agency DESIGN.md. Use warm paper `#ECEEEB`, ink `#0B0D0A`, terracotta signal `#B93A19`, Bricolage Grotesque display headings, Instrument Sans body, and JetBrains Mono metadata. Use square components, light paper code blocks, hairline rules, evidence badges, source IDs, priority callouts, stat/KPI cards, and a source ledger. Avoid rounded SaaS cards, dark terminal blocks in light-mode reports, gradients, and decorative colour.

## Report preview prompt

> Render the canonical report Markdown with a Signal Agency style: sticky editorial masthead, huge cover title, 4-up stat strip, table with evidence tags, source ledger, P0/P1/P2/P3 callouts, preserve/fix split, action line, implementation brief, and dossier cards with ink header strips and provenance footers. Ensure A4, US Letter, and 16:9 PDF profiles remain readable.

## Component prompt

> Create a dossier card grid for audit findings. Each card has a 1px ink border, ink/state header strip, LED, mono class label, title row, serial code, body copy, and footer with owner/source/due metadata. Use state header colours only for critical/warning/info/resolved variants.

## Verification checklist

- `npx @google/design.md lint DESIGN.md` has zero errors.
- Body copy is at least 16px with line-height >= 1.45.
- Normal text contrast passes WCAG AA on paper, white, and state washes.
- Evidence badges and priority markers have text labels, not colour-only meaning.
- Tables retain headers and source IDs in print/PDF.
- Code blocks render as light paper panels with square corners in light-mode reports.
- Preview includes the same component taxonomy as the style-guide specimen.
