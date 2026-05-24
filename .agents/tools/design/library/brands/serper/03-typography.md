<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# serper: Typography

## Observed source font evidence

- `-apple-system,BlinkMacSystemFont,Segoe UI,Noto Sans,Helvetica,Arial,sans-serif,Apple Color Emoji,Segoe UI Emoji`
- `-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Oxygen,Ubuntu,Cantarell,Fira Sans,Droid Sans,Helvetica Neue,sans-serif`
- `Apple Color Emoji,Segoe UI Emoji,Segoe UI Symbol`
- `inherit`
- `monospace`
- `ui-monospace,SFMono-Regular,SF Mono,Menlo,Consolas,Liberation Mono,monospace`

## Substitute policy

Use exact source fonts only when they are system/open-source and appropriate for redistribution. Where the source uses commercial or hosted proprietary fonts, map the style to open-source/system alternatives in DESIGN.md tokens. Document the source font in this chapter and the substitute in `DESIGN.md`.

## Report typography requirements

- Screen body text: 16px or larger with 1.45-1.7 line height.
- PDF body text: 10.5-12pt equivalent.
- Headings: preserve the source's broad serif/sans/mono character and weight contrast.
- Code/data: use a readable monospace stack and wrap long lines in PDF.
