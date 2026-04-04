<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# IBM Design: Visual Theme & Atmosphere

IBM's website is the digital embodiment of enterprise authority built on the Carbon Design System — a design language so methodically structured it reads like an engineering specification rendered as a webpage. The page operates on a stark duality: a bright white (`#ffffff`) canvas with near-black (`#161616`) text, punctuated by a single, unwavering accent — IBM Blue 60 (`#0f62fe`). This isn't playful tech-startup minimalism; it's corporate precision distilled into pixels. Every element exists within Carbon's rigid 2x grid, every color maps to a semantic token, every spacing value snaps to the 8px base unit.

The IBM Plex type family is the system's backbone. IBM Plex Sans at light weight (300) for display headlines creates an unexpectedly airy, almost delicate quality at large sizes — a deliberate counterpoint to IBM's corporate gravity. At body sizes, regular weight (400) with 0.16px letter-spacing on 14px captions introduces the meticulous micro-tracking that makes Carbon text feel engineered rather than designed. IBM Plex Mono serves code, data, and technical labels, completing the family trinity alongside the rarely-surfaced IBM Plex Serif.

What defines IBM's visual identity beyond monochrome-plus-blue is the reliance on Carbon's component token system. Every interactive state maps to a CSS custom property prefixed with `--cds-` (Carbon Design System). Buttons don't have hardcoded colors; they reference `--cds-button-primary`, `--cds-button-primary-hover`, `--cds-button-primary-active`. This tokenized architecture means the entire visual layer is a thin skin over a deeply systematic foundation — the design equivalent of a well-typed API.

**Key Characteristics:**
- IBM Plex Sans at weight 300 (Light) for display — corporate gravitas through typographic restraint
- IBM Plex Mono for code and technical content with consistent 0.16px letter-spacing at small sizes
- Single accent color: IBM Blue 60 (`#0f62fe`) — every interactive element, every CTA, every link
- Carbon token system (`--cds-*`) driving all semantic colors, enabling theme-switching at the variable level
- 8px spacing grid with strict adherence — no arbitrary values, everything aligns
- Flat, borderless cards on `#f4f4f4` Gray 10 surface — depth through background-color layering, not shadows
- Bottom-border inputs (not boxed) — the signature Carbon form pattern
- 0px border-radius on primary buttons — unapologetically rectangular, no softening
