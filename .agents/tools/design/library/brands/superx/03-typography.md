<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# superx: Typography

## Observed source font evidence

- `Instrument Serif`
- `Instrument Serif Fallback`
- `Inter`
- `Inter Fallback`
- `Inter,Inter Fallback`
- `Inter,sans-serif`
- `inherit`
- `ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,Liberation Mono,Courier New,monospace`

## Substitute policy

Use exact source fonts only when they are system/open-source and appropriate for redistribution. Where the source uses commercial or hosted proprietary fonts, map the style to open-source/system alternatives in DESIGN.md tokens. Document the source font in this chapter and the substitute in `DESIGN.md`.

## Report typography requirements

- Screen body text: 16px or larger with 1.45-1.7 line height.
- PDF body text: 10.5-12pt equivalent.
- Headings: preserve the source's broad serif/sans/mono character and weight contrast.
- Code/data: use a readable monospace stack and wrap long lines in PDF.
