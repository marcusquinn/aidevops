<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# docuseal: Typography

## Observed source font evidence

- `Inter`
- `ui-sans-serif/system stacks`
- `ui-monospace/SFMono-Regular/Menlo/Consolas`

## Report substitutions

- Heading: `Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif`
- Body: `Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif`
- Code/data: `ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace`

Use exact source fonts only when available and redistributable. Otherwise, use the documented system/open-source fallbacks while preserving the source's typographic feel.

## Report typography requirements

- Screen body text: 16px or larger with 1.58-1.75 line height.
- PDF body text: 10.5-12pt equivalent.
- Headings should echo the brand but stay within report-readable size limits.
- Code/data must wrap long lines in HTML and PDF.
