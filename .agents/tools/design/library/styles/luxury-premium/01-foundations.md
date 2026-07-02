<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Luxury Premium Foundations

## 1. Overview

Exclusivity, craftsmanship, quiet confidence. Serves luxury automotive, high-end real estate, premium hospitality, fine jewellery, couture fashion. Restraint over embellishment throughout.

Near-black backgrounds create a cinematic stage for photography. Palette: black, near-black, white, single champagne gold accent. Ultra-light serif headings at large scale; body text small and secondary to imagery. Density extremely low — blackspace dominates. Transitions slow and cinematic (400-600ms).

**Key characteristics:**
- **Mood:** Exclusive, cinematic, restrained, aspirational
- **Background:** Black `#000000` or near-black `#0a0a0a`
- **Accent colour:** Champagne gold `#c9a96e`
- **Text colour:** White `#FFFFFF` with `rgba(255,255,255,0.75)` for body and `rgba(255,255,255,0.5)` for secondary
- **Border treatment:** 1px `rgba(255,255,255,0.1)` — barely visible
- **Animation:** Slow, cinematic — 400-600ms ease, fade-ins, parallax
- **Imagery style:** Full-bleed, art-directed, high-contrast, minimal post-processing
- **Overall density:** Very low — massive negative space, few elements per viewport

## 2. Colors

### Core Dark

| Role | Hex | Usage |
|------|-----|-------|
| Background | `#000000` | Primary page background |
| Surface | `#0a0a0a` | Card backgrounds, elevated sections |
| Surface Raised | `#111111` | Interactive cards, input backgrounds |
| Surface Accent | `#1a1a1a` | Navigation overlay, footer |
| Border | `rgba(255, 255, 255, 0.08)` | Subtle dividers |
| Border Strong | `rgba(255, 255, 255, 0.15)` | Active borders, hover states |

### Text

| Role | Value | Usage |
|------|-------|-------|
| Primary | `#FFFFFF` | Headings, primary labels |
| Body | `rgba(255, 255, 255, 0.75)` | Paragraph text |
| Secondary | `rgba(255, 255, 255, 0.5)` | Captions, metadata, navigation |
| Tertiary | `rgba(255, 255, 255, 0.3)` | Disabled, deemphasised |

### Accent

| Role | Hex | Usage |
|------|-----|-------|
| Gold | `#c9a96e` | CTAs, highlights, key interactive elements |
| Gold Light | `#d4b87a` | Hover states |
| Gold Dark | `#b08d50` | Active/pressed states |
| Gold Subtle | `rgba(201, 169, 110, 0.1)` | Tinted backgrounds, selected states |

### Light Mode (optional alternate)

| Role | Hex | Usage |
|------|-----|-------|
| Background | `#FFFFFF` | Alternate light pages |
| Surface | `#F7F5F0` | Light mode surface |
| Text | `#0a0a0a` | Light mode headings |
| Body | `#333333` | Light mode body |
| Border | `#E8E4DF` | Light mode borders |

### Semantic

| Role | Dark Mode | Usage |
|------|-----------|-------|
| Success | `#4ade80` | Confirmations (muted, not vibrant) |
| Warning | `#fbbf24` | Caution indicators |
| Error | `#f87171` | Errors, destructive actions |
| Info | `#c9a96e` | Informational — uses gold accent |

## 3. Typography

**Font families:**
- **Headings:** `"Cormorant Garamond", Garamond, "Times New Roman", "Noto Serif", serif`
- **Body:** `system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif`
- **Monospace:** `"SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace`

### Hierarchy

| Role | Font | Size | Weight | Line-Height | Letter-Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display | Serif | 80px / 5rem | 300 | 1.05 | 0.02em | Hero headlines, dramatic impact |
| H1 | Serif | 56px / 3.5rem | 300 | 1.1 | 0.015em | Page titles |
| H2 | Serif | 40px / 2.5rem | 300 | 1.15 | 0.01em | Section headers |
| H3 | Serif | 30px / 1.875rem | 400 | 1.2 | 0.01em | Subsection headers |
| H4 | Sans-serif | 14px / 0.875rem | 400 | 1.3 | 0.15em | Labels, categories (uppercase) |
| Body | Sans-serif | 15px / 0.9375rem | 300 | 1.7 | 0.02em | Primary text |
| Body Small | Sans-serif | 13px / 0.8125rem | 300 | 1.6 | 0.03em | Secondary text |
| Caption | Sans-serif | 11px / 0.6875rem | 400 | 1.4 | 0.1em | Metadata (uppercase) |
| Pull Quote | Serif | 36px / 2.25rem | 300 | 1.3 | 0.01em | Featured quotes, italicised |

**Principles:**
- Weight 300 (light) is the dominant weight — it defines the luxury aesthetic
- Headings are large in size but light in weight — imposing yet delicate
- Uppercase is used for small labels and navigation, with generous letter-spacing (0.1em+)
- Body text is intentionally smaller than web defaults (15px) — content is secondary to imagery
- Avoid weight 700+ unless for rare emphasis — heaviness contradicts the luxury feel
