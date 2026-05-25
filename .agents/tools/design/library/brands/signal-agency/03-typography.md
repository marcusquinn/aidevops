<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Signal Agency — Typography

## Font roles

| Role | Font | Use |
|------|------|-----|
| Display | Bricolage Grotesque | Cover titles, section titles, KPI numerals, card titles |
| Body | Instrument Sans | Narrative text, table cells, explanatory paragraphs |
| Mono | JetBrains Mono | Metadata, source IDs, labels, evidence tags, serials, code |

Fallbacks: `ui-sans-serif, system-ui, sans-serif` for display/body and `ui-monospace, "SF Mono", Menlo, monospace` for mono.

## Type scale

| Token | Size | Weight | Line | Tracking | Notes |
|-------|------|--------|------|----------|-------|
| Display 1 | `clamp(72px, 11vw, 168px)` | 700 | 0.92 | -0.045em | Cover only; italic signal word allowed |
| Display 2 | `clamp(48px, 6.4vw, 88px)` | 700 | 0.98 | -0.04em | Report title / applied audit title |
| H1 | `clamp(36px, 4.2vw, 56px)` | 600 | 1.0 | -0.035em | Section headings |
| H2 | `clamp(26px, 2.4vw, 34px)` | 600 | 1.1 | -0.02em | Subsections |
| H3 | `20px` | 600 | 1.3 | normal | Component titles |
| Body | `16px` | 400 | 1.55 | normal | Default body copy |
| Small | `14px` | 400/600 | 1.45 | normal | Notes, table detail |
| Micro | `10.5-12px` | 500/600 | 1.2 | 0.06-0.12em | Uppercase mono labels |

## Typographic rules

- Use tabular numerals for KPIs, deltas, confidence values, and source IDs.
- Uppercase mono labels should be small and widely tracked.
- Keep narrative measure near 56ch and ledes near 60ch.
- Italic display is reserved for one highlighted word in the cover/title area.
- Do not mix additional typefaces into the system; vary weight, optical size, width, and mono labels instead.
