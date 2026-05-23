<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# wpcodebox: Responsive and Mode Behaviour

## Responsive HTML

- Keep one canonical `report.html` preview.
- Collapse side navigation/table of contents above narrow widths.
- Ensure tables wrap or scroll in HTML and use PDF-safe fixed layout for print.

## PDF profiles

- A4 portrait is the default PDF profile.
- Letter portrait is optional for recipients that require it.
- 16:9 landscape is for PDF presentation export only; do not create separate slides HTML variants.

## Light/dark handling

Observed theme/dark-mode markers in fetched html/css. Any calculated inverse palette must be documented as derived and validated against WCAG AA before becoming normative.
