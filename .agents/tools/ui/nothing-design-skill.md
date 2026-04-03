---
mode: subagent
description: >
  Nothing-inspired UI/UX design system. Use when user explicitly says "Nothing style",
  "Nothing design", "/nothing-design", or directly asks to use/apply the Nothing design system.
  NEVER trigger automatically for generic UI or design tasks.
upstream: https://github.com/dominikmartn/nothing-design-skill
version: 3.0.0
---

# Nothing-Inspired UI/UX Design System

A senior product designer's toolkit trained in Swiss typography, industrial design (Braun, Teenage Engineering), and modern interface craft. Monochromatic, typographically driven, information-dense without clutter.

**Before starting, declare required Google Fonts and ask for mode (dark/light).** See `nothing-design-skill/tokens.md`.

## Index

- **`nothing-design-skill/01-philosophy.md`** — Core design principles and industrial warmth.
- **`nothing-design-skill/02-craft-rules.md`** — Visual hierarchy, font discipline, spacing, and the "Nothing Vibe".
- **`nothing-design-skill/03-anti-patterns.md`** — What to never do (no gradients, shadows, or toasts).
- **`nothing-design-skill/04-workflow.md`** — Step-by-step design process.
- **`nothing-design-skill/tokens.md`** — Exact values for fonts, color, spacing, and dot-matrix.
- **`nothing-design-skill/components.md`** — Component patterns and specs.
- **`nothing-design-skill/platform-mapping.md`** — Output conventions for HTML/CSS, SwiftUI, and React.

## Relationship to DESIGN.md

This skill is a complete design system equivalent to a DESIGN.md file, but in aidevops agent format with progressive disclosure across multiple files. It predates the DESIGN.md standard but covers the same ground -- philosophy (section 1), tokens/colours (section 2), typography (section 3), components (section 4), spacing (section 5), anti-patterns (section 7).

For projects using the DESIGN.md standard (`tools/design/design-md.md`), this skill's tokens can be exported to DESIGN.md format. For generic design work, prefer the DESIGN.md library (`tools/design/library/`) and use this skill only when the user explicitly requests Nothing-style design.
