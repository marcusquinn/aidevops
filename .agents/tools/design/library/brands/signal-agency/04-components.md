<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Signal Agency — Components

## Evidence tag

Inline mono badge with dot, uppercase label, 1px radius, wash background. Values: `Verified`, `Partial`, `Inferred`, `Missing`. Keep tags inline with claims; never use as standalone decoration.

## Priority marker

Mono label with 14px square marker. P0 uses signal/negative, P1 warning, P2 info, P3 hollow neutral. Use in callouts, roadmap lists, and action panels.

## Stat strip and KPI card

- Stat strip: 2-up mobile / 4-up desktop, 1px ink border, internal soft dividers, huge tabular Bricolage numerals.
- KPI card: ink header with live LED, body figure, footer with source and trend delta.
- Each stat carries index metadata (`01 / 04`) and a short note.

## Manifest card and inline TOC

- Manifest card: dossier metadata block with ink header, LED, class label, serial/version, two-column `dt/dd` fields, and provenance footer. Use for prepared-for, scope, period, auditor, source count, and next audit date.
- Inline TOC: in-body navigation between summary and findings. Rows use section number, Bricolage title, and mono metadata such as “5 engines · 5 rows”. Keep the sticky renderer TOC separate; this block is part of the report content.

## Findings table

Editorial table with no filled header row. Mono uppercase headers, bottom rules only, tabular numeric cells, evidence badges in cells, engine/source metadata as secondary mono line.

## Source ledger

Grid row: source ID, source name, note, confidence. Confidence is a mono label plus 56px horizontal bar. Mobile collapses to two columns and wraps note/confidence full-width.

## Privacy note

Square warning card for export rules. Use paper-alt background, 1px ink border, mono rule label, and concise body copy. It appears before evidence excerpts or source-ledger detail when raw evidence is private.

## Visibility bars

Horizontal mono rows for engine citation share, mention share, or score distributions. Use muted hairline tracks, state-coloured fills, right-aligned values, and a caption naming the prompt batch/window/threshold.

## Priority callout

Left-bar component with wash background, state-coloured bar, compact tag, Bricolage title, optional evidence badge, and mono metadata row. Variants: P0 critical, P1 high, P2 medium, P3 backlog, done/resolved.

## Preserve/Fix split

Two columns divided by a rule. Each side has a mono label with square marker, Bricolage title, and dotted list rows. Use for “working vs costing citations” summaries.

## Action line

Two-rule sandwich. Columns: mono decision tag, large Bricolage action text, mono owner/date metadata. Use one decision per line.

## Implementation brief

Inverted ink panel set in mono. Rows begin with fixed-width field labels: Task, Files, Acceptance, Verify. Include only worker-actionable information.

## Code and source blocks

Use light paper code panels by default: `#F5F6F4` background, `#0B0D0A` code ink, `#B93A19` uppercase label/accent, and `#0B0D0A` 1px border. Code blocks, Mermaid fallbacks, LaTeX fallbacks, copy buttons, and code headers all have square `0px` corners. Reserve dark terminal blocks only for explicitly dark-mode artifacts or screenshots of a dark terminal.

## Dossier card

Square card with 1px ink border, optional hard 4px ink offset shadow, ink/state header strip, LED, class label, title row, serial code/stamp, body, and provenance footer. No rounded corners.

## Dossier chrome

LEDs, stamps, serial codes, and tabs add instrumentation. Use sparingly: LEDs in headers, stamps for confidential/resolved, tabs above card groups, serials for traceable source or spec IDs.

## Style-guide specimen blocks

When presenting brand systems, reuse the same grammar: swatch rows with token name/value/use, type rows with specimen text and font metadata, component specimen cards with class ID and constraints, and do/don't cards. Brand reports should show enough tokens and component rules for an agent to reproduce the style without seeing the original HTML specimen.
