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

## Findings table

Editorial table with no filled header row. Mono uppercase headers, bottom rules only, tabular numeric cells, evidence badges in cells, engine/source metadata as secondary mono line.

## Source ledger

Grid row: source ID, source name, note, confidence. Confidence is a mono label plus 56px horizontal bar. Mobile collapses to two columns and wraps note/confidence full-width.

## Priority callout

Left-bar component with wash background, state-coloured bar, compact tag, Bricolage title, optional evidence badge, and mono metadata row. Variants: P0 critical, P1 high, P2 medium, P3 backlog, done/resolved.

## Preserve/Fix split

Two columns divided by a rule. Each side has a mono label with square marker, Bricolage title, and dotted list rows. Use for “working vs costing citations” summaries.

## Action line

Two-rule sandwich. Columns: mono decision tag, large Bricolage action text, mono owner/date metadata. Use one decision per line.

## Implementation brief

Inverted ink panel set in mono. Rows begin with fixed-width field labels: Task, Files, Acceptance, Verify. Include only worker-actionable information.

## Dossier card

Square card with 1px ink border, optional hard 4px ink offset shadow, ink/state header strip, LED, class label, title row, serial code/stamp, body, and provenance footer.

## Dossier chrome

LEDs, stamps, serial codes, and tabs add instrumentation. Use sparingly: LEDs in headers, stamps for confidential/resolved, tabs above card groups, serials for traceable source or spec IDs.
