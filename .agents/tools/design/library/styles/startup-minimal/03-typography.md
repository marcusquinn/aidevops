<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Startup Minimal — Typography Rules

## Font Families

| Role | Stack |
|------|-------|
| Sans | `'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif` |
| Mono | `'Geist Mono', 'JetBrains Mono', 'SF Mono', 'Consolas', monospace` |

## Type Scale

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display | Sans | 48px | 700 | 1.1 | -0.03em | Landing page hero only |
| H1 | Sans | 36px | 600 | 1.15 | -0.025em | Page titles |
| H2 | Sans | 28px | 600 | 1.2 | -0.02em | Section headings |
| H3 | Sans | 22px | 600 | 1.25 | -0.015em | Subsection headings |
| H4 | Sans | 18px | 600 | 1.3 | -0.01em | Card titles, group labels |
| H5 | Sans | 15px | 600 | 1.4 | 0 | Small headings, sidebar titles |
| Body | Sans | 15px | 400 | 1.6 | -0.006em | Primary reading text |
| Body Small | Sans | 13px | 400 | 1.5 | 0 | Captions, help text |
| Label | Sans | 13px | 500 | 1.4 | 0 | Form labels, table headers |
| Tiny | Sans | 11px | 500 | 1.3 | 0.02em | Badges, status indicators |
| Code Block | Mono | 14px | 400 | 1.6 | 0 | Code snippets |
| Code Inline | Mono | 13px | 400 | inherit | 0 | Inline code in body |

## Typography Principles

- One typeface does everything — Inter (or system font fallback) across all roles
- Hierarchy is achieved through size and weight, never through font-family switching
- Headings use 600 weight (semi-bold), not 700/800 — authority without shouting
- Monospace is reserved strictly for code and machine-readable content
- 15px base (not 16px) for a slightly tighter, more tool-like feel
- Maximum content width for body text: 680px (for readability)
