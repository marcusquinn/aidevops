# Design System: Developer Dark — Typography Rules

## Font Families

- **Display/Heading**: `'JetBrains Mono', 'Fira Code', 'SF Mono', ui-monospace, monospace` -- monospace headings reinforce the developer aesthetic
- **Body**: `'Inter', -apple-system, system-ui, 'Segoe UI', sans-serif` -- clean sans-serif for readable body text
- **Code**: `'JetBrains Mono', 'Fira Code', 'SF Mono', ui-monospace, monospace` -- same as heading, with ligatures enabled (`"liga", "calt"`)

## Hierarchy

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display | JetBrains Mono | 36px (2.25rem) | 700 | 1.15 | -0.5px | Hero headings, page titles |
| Heading 1 | JetBrains Mono | 28px (1.75rem) | 700 | 1.2 | -0.3px | Section headers |
| Heading 2 | JetBrains Mono | 22px (1.375rem) | 600 | 1.25 | -0.2px | Subsection headers |
| Heading 3 | JetBrains Mono | 18px (1.125rem) | 600 | 1.3 | normal | Card titles, panel headers |
| Body | Inter | 15px (0.9375rem) | 400 | 1.6 | normal | Standard body text |
| Body Small | Inter | 13px (0.8125rem) | 400 | 1.5 | normal | Dense content, sidebar text |
| Caption | Inter | 11px (0.6875rem) | 500 | 1.4 | 0.3px | Labels, metadata, timestamps |
| Button | JetBrains Mono | 13px (0.8125rem) | 600 | 1.0 | 0.5px | `text-transform: uppercase` |
| Code | JetBrains Mono | 14px (0.875rem) | 400 | 1.6 | normal | Inline code, code blocks |
| Terminal | JetBrains Mono | 14px (0.875rem) | 400 | 1.5 | normal | Terminal/CLI output |

## Principles

- **Monospace-first hierarchy**: Headings and buttons use JetBrains Mono, creating a cohesive terminal feel throughout navigation and structure.
- **Compact sizing**: Body at 15px (not 16px) and small at 13px reflect the density preference of developer tools.
- **Tight headings**: Line heights 1.15-1.3 for headings keep the interface compact.
- **Uppercase buttons**: All button text is uppercase with 0.5px letter-spacing, mimicking CLI command aesthetics.
