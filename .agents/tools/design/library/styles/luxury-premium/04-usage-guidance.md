<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Luxury Premium Usage Guidance

## 8. Do's and Don'ts

### Do's

1. **Do** use massive negative space — content should occupy less than half the viewport on desktop
2. **Do** keep headings at weight 300 (light) for the refined, luxury feel
3. **Do** use full-bleed, high-quality photography as the primary storytelling device
4. **Do** animate slowly and smoothly — 400-600ms transitions, ease timing
5. **Do** use uppercase sparingly and with generous letter-spacing (0.1em+) for labels and nav
6. **Do** maintain sharp corners (0px radius) on all rectangular elements
7. **Do** use the gold accent only for primary interactive elements — never decoratively
8. **Do** test all text against dark backgrounds for WCAG contrast compliance

### Don'ts

1. **Don't** use rounded corners — they undermine the precision aesthetic
2. **Don't** use bright, saturated colours — the palette is muted and restrained
3. **Don't** add multiple accent colours — champagne gold is the sole accent
4. **Don't** use fast animations (<200ms) — they feel cheap and nervous
5. **Don't** use heavy font weights (600+) for headings — weight 300 defines this system
6. **Don't** clutter the viewport — remove any element that does not serve a clear purpose
7. **Don't** use stock photography, clip art, or illustrations — only art-directed imagery
8. **Don't** use visible focus outlines thicker than 1px — subtlety extends to accessibility indicators
9. **Don't** place body text below 13px — legibility on dark backgrounds requires adequate size
10. **Don't** use emoji, playful icons, or informal language — tone is always elevated

---

<!-- Sections 9-10 below are aidevops-specific extensions. The Google Labs DESIGN.md spec preserves -->
<!-- unknown sections per its "Consumer Behavior for Unknown Content" rule. -->

## 9. Responsive Behaviour

### Breakpoints

| Name | Range | Columns | Gutter | Container Padding |
|------|-------|---------|--------|-------------------|
| Mobile | 0-767px | 4 | 16px | 24px |
| Tablet | 768-1023px | 8 | 24px | 48px |
| Desktop | 1024-1439px | 12 | 32px | 64px |
| Wide | >=1440px | 12 | 32px | auto (centred 1400px) |

### Touch Targets

- Minimum tap target: 48x48px
- Navigation links: generous vertical padding (16px minimum)
- Buttons: full-width on mobile with 16px vertical padding

### Mobile-Specific Rules

- Navigation: full-screen overlay with centred vertical link stack, large text (20px)
- Hero images: full viewport height maintained; text overlay adjusts
- Typography: Display -> 40px, H1 -> 32px, H2 -> 28px, Body remains 15px
- Grid: single column on mobile; asymmetric layouts collapse to stacked
- Spacing reduces proportionally: 160px -> 80px, 80px -> 48px, 48px -> 32px
- Gallery: single-column vertical scroll, full-width images
- Video backgrounds: replaced with static key-frame image on mobile
- Navigation overlay: `background: rgba(0, 0, 0, 0.95)` with centred vertical text menu
- Horizontal scrolling: only for curated image galleries with snap scrolling
- Gold accent elements remain visible — do not hide or mute on mobile

## 10. Agent Prompt Guide

### Quick Colour Reference

| CSS Variable | Hex / Value | Role |
|-------------|-------------|------|
| `--color-bg` | `#000000` | Black background |
| `--color-surface` | `#0a0a0a` | Near-black surface |
| `--color-surface-raised` | `#111111` | Interactive surfaces |
| `--color-surface-accent` | `#1a1a1a` | Nav overlay, footer |
| `--color-text` | `#FFFFFF` | Primary text (headings) |
| `--color-text-body` | `rgba(255,255,255,0.75)` | Body text |
| `--color-text-secondary` | `rgba(255,255,255,0.5)` | Captions, nav links |
| `--color-text-tertiary` | `rgba(255,255,255,0.3)` | Disabled, deemphasised |
| `--color-accent` | `#c9a96e` | Champagne gold — CTAs, highlights |
| `--color-accent-light` | `#d4b87a` | Gold hover |
| `--color-accent-dark` | `#b08d50` | Gold active |
| `--color-border` | `rgba(255,255,255,0.08)` | Subtle borders |
| `--color-border-strong` | `rgba(255,255,255,0.15)` | Active borders |

### Ready-to-Use Prompts

**Prompt 1 — Luxury brand landing page:**
> Build a landing page following DESIGN.md. Full-screen hero with a background image (100vh), transparent navigation (80px) with Cormorant Garamond logo (28px/300) and uppercase nav links (12px, letter-spacing 0.15em, rgba(255,255,255,0.5)). Hero headline in Cormorant Garamond 80px/300 white, centred. Below: full-bleed image section. Then a split layout (5/7 grid) with text on left (40px/300 serif heading, 15px/300/1.7 body in rgba(255,255,255,0.75)) and image on right. CTA button: gold (#c9a96e) background, black text, 0px radius, uppercase 12px with 0.15em letter-spacing. All backgrounds #000000. Section spacing: 120px+.

**Prompt 2 — Property/product showcase:**
> Create a showcase page following DESIGN.md. Full-bleed hero image (80vh) with a thin 1px rgba(255,255,255,0.08) border framing the content area. Title in Cormorant Garamond 56px/300 white. Specs section: 3-column grid on #0a0a0a with 1px border separators. Each spec: 11px uppercase label (rgba(255,255,255,0.5), 0.1em spacing) above 30px/400 serif value. Image gallery: two-column masonry grid with 4px gaps, images expand on click to a lightbox with 0 8px 32px rgba(0,0,0,0.4) shadow. Contact button: gold border, 0px radius, uppercase. Footer: #1a1a1a background.

**Prompt 3 — Booking/enquiry form:**
> Build an enquiry form following DESIGN.md. Centred at 480px max-width on #000000 background with 160px top padding. Heading in Cormorant Garamond 40px/300 white. Subtext in 15px/300 rgba(255,255,255,0.75). Inputs: #111111 background, 1px border rgba(255,255,255,0.1), 0px radius, 14px/300 white text. Labels: 11px uppercase, 0.1em letter-spacing, rgba(255,255,255,0.5). Focus state: border changes to #c9a96e, no shadow. Submit button: full-width, gold (#c9a96e) background, black text, 0px radius, uppercase. Privacy text below in 11px rgba(255,255,255,0.3). All transitions 400ms ease.

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md spec: https://github.com/google-labs-code/design.md
-->
