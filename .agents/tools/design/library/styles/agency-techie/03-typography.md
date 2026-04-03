# Agency Techie — Typography Rules

## Font Families

| Role | Stack |
|------|-------|
| Mono | `'JetBrains Mono', 'Fira Code', 'Cascadia Code', 'SF Mono', 'Consolas', monospace` |
| Sans | `'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif` |

## Type Scale

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display | Sans | 48px | 700 | 1.1 | -0.03em | Landing pages, hero sections |
| H1 | Sans | 36px | 700 | 1.2 | -0.025em | Page titles |
| H2 | Sans | 28px | 600 | 1.25 | -0.02em | Section headings |
| H3 | Sans | 22px | 600 | 1.3 | -0.015em | Subsection headings |
| H4 | Sans | 18px | 600 | 1.35 | -0.01em | Card titles, group labels |
| Body | Sans | 15px | 400 | 1.6 | -0.006em | Primary reading text |
| Body Small | Sans | 13px | 400 | 1.5 | 0 | Secondary descriptions, captions |
| Label | Sans | 12px | 500 | 1.4 | 0.04em | Form labels, column headers (uppercase optional) |
| Code Block | Mono | 14px | 400 | 1.65 | 0 | Code snippets, terminal output |
| Code Inline | Mono | 13px | 400 | inherit | 0 | Inline code within body text |
| Data | Mono | 14px | 500 | 1.4 | 0 | Metrics, stats, API values, IDs |

## Typography Principles

- Use monospace for anything that represents code, data, identifiers, or machine-readable values
- Sans-serif for all human-readable prose, navigation, and UI labels
- Never go below 12px — even for tertiary information
- Heading weight should always be 600+ to maintain hierarchy against dense layouts
- Line-height for body text stays at 1.6 for readability in dark mode (looser than light-mode norms)
