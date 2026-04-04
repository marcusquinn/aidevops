# Design System: Developer Dark — Agent Prompt Guide

## Quick Colour Reference

| Token | Value | Use |
|-------|-------|-----|
| --bg-base | #111827 | Page background |
| --bg-surface | #1f2937 | Cards, panels |
| --bg-elevated | #374151 | Dropdowns, hover |
| --bg-inset | #0d1117 | Code blocks, inputs |
| --text-primary | #f9fafb | Main text |
| --text-secondary | #9ca3af | Muted text |
| --text-tertiary | #6b7280 | Placeholders |
| --accent | #4ade80 | Primary accent (green) |
| --accent-secondary | #fbbf24 | Secondary accent (amber) |
| --success | #4ade80 | Success states (alias for --accent) |
| --warning | #fbbf24 | Warning/caution states (alias for --accent-secondary) |
| --error | #ef4444 | Error states |
| --info | #3b82f6 | Links, info |
| --border | #1f2937 | Primary borders |
| --border-light | #374151 | Secondary borders |

## Ready-to-Use Prompts

- "Build a dashboard layout": Use `--bg-base` background, `--bg-surface` sidebar and cards, `--accent` for active nav items. JetBrains Mono headings, Inter body text. Dense 4px spacing grid. Sticky top nav with border-bottom.
- "Build a CLI documentation page": Inset `--bg-inset` code blocks with JetBrains Mono 14px. Body text in Inter 15px on `--bg-base`. Max-width 780px for reading. Green accent for inline code references.
- "Build a settings panel": `--bg-surface` cards with `--border` outlines. Toggle switches using `--accent` green for on state, `--bg-elevated` for off. Compact 8px padding on form groups. JetBrains Mono labels.
- "Build an API reference": Sidebar navigation on `--bg-surface` with `--accent` active indicator. Main content on `--bg-base`. Code blocks on `--bg-inset` with syntax highlighting. Endpoint badges as pills with semantic colours.
