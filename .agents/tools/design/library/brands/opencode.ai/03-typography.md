# Design System: OpenCode — Typography Rules

## Font Family

- **Universal**: `Berkeley Mono`, with fallbacks: `IBM Plex Mono, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, Liberation Mono, Courier New, monospace`

## Hierarchy

| Role | Size | Weight | Line Height | Notes |
|------|------|--------|-------------|-------|
| Heading 1 | 38px (2.38rem) | 700 | 1.50 | Hero headlines, page titles |
| Heading 2 | 16px (1.00rem) | 700 | 1.50 | Section titles, bold emphasis |
| Body | 16px (1.00rem) | 400 | 1.50 | Standard body text, paragraphs |
| Body Medium | 16px (1.00rem) | 500 | 1.50 | Links, button text, nav items |
| Body Tight | 16px (1.00rem) | 500 | 1.00 (tight) | Compact labels, tab items |
| Caption | 14px (0.88rem) | 400 | 2.00 (relaxed) | Footnotes, metadata, small labels |

## Principles

- **One font, one voice**: Berkeley Mono is used exclusively. There is no typographic variation between display, body, and code -- everything speaks in the same monospace register. Hierarchy is achieved through size and weight alone.
- **Weight as hierarchy**: 700 for headings, 500 for interactive/medium emphasis, 400 for body text. Three weight levels create the entire hierarchy.
- **Generous line-height**: 1.50 as the standard line-height gives text room to breathe within the monospace grid. The relaxed 2.00 line-height on captions creates clear visual separation.
- **Tight for interaction**: Interactive elements (tabs, compact labels) use 1.00 line-height for dense, clickable targets.
