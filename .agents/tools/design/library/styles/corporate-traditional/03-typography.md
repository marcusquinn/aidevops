<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Corporate Traditional — Typography Rules

**Font families:**
- **Headings:** `Georgia, "Times New Roman", "Noto Serif", serif`
- **Body:** `system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif`
- **Monospace:** `"SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace`

## Hierarchy

| Role | Font | Size | Weight | Line-Height | Letter-Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display | Serif | 48px / 3rem | 400 | 1.2 | -0.02em | Hero sections only |
| H1 | Serif | 36px / 2.25rem | 700 | 1.25 | -0.01em | Page titles |
| H2 | Serif | 28px / 1.75rem | 700 | 1.3 | -0.005em | Section headers |
| H3 | Serif | 22px / 1.375rem | 700 | 1.35 | 0 | Subsection headers |
| H4 | Sans-serif | 18px / 1.125rem | 600 | 1.4 | 0.01em | Card titles, labels |
| Body | Sans-serif | 16px / 1rem | 400 | 1.6 | 0 | Default paragraph |
| Body Small | Sans-serif | 14px / 0.875rem | 400 | 1.5 | 0.005em | Secondary content |
| Caption | Sans-serif | 12px / 0.75rem | 400 | 1.4 | 0.02em | Metadata, footnotes |
| Overline | Sans-serif | 11px / 0.6875rem | 600 | 1.2 | 0.1em | Labels, categories (uppercase) |

**Principles:**
- Serif headings always pair with sans-serif body — never mix within the same role
- Headings use sentence case, never all-caps except for `Overline`
- Minimum body text size: 16px on desktop, 15px on mobile
- Maximum line length: 75 characters (approximately 680px at 16px)
