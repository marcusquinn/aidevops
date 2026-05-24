<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# exsqueezeme: Responsive and Mode Behaviour

## Responsive HTML

- Keep one canonical `report.html` preview.
- Collapse side navigation/table of contents above narrow widths.
- Preserve square button borders and readable heading wrapping on small screens.
- Ensure tables wrap or scroll in HTML and use PDF-safe fixed layout for print.

## PDF profiles

- A4 portrait is the default PDF profile.
- Letter portrait is optional for recipients that require it.
- 16:9 landscape is for PDF presentation export only; do not create separate slides HTML variants.

## Light/dark handling

Dark is canonical for this preset. If light output is generated for review, label it as a derived review variant and validate WCAG contrast before publication.
