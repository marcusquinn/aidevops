<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# exsqueezeme: Typography

## Observed source font evidence

- `Space Grotesk`
- `Space Mono`
- `var(--default-font-family,ui-sans-serif,system-ui,sans-serif,`
- `var(--default-mono-font-family,ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,`
- `var(--font-body)`
- `var(--font-heading)`
- `var(--font-mono)`
- `var(--font-sans)`

## Substitute policy

Use exact source fonts only when they are system/open-source and appropriate for redistribution. Where the source uses commercial or hosted proprietary fonts, map the style to open-source/system alternatives in DESIGN.md tokens. Document the source font in this chapter and the substitute in `DESIGN.md`.

## Report typography requirements

- Screen body text: 16px or larger with 1.45-1.7 line height.
- PDF body text: 10.5-12pt equivalent.
- Headings: preserve the source's broad serif/sans/mono character and weight contrast.
- Code/data: use a readable monospace stack and wrap long lines in PDF.
