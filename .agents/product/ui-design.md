---
description: Product UI/UX design standards - aesthetics, animations, icons, branding, accessibility for any app type
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Product UI Design - Beautiful by Default

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Principle**: Aesthetics drive downloads; usability drives retention
- **Standards**: Apple HIG, Material Design 3, WCAG 2.1 AA accessibility
- **Tools**: Vision AI for asset generation, Remotion for animated previews, Gemini for SVG design
- **Applies to**: Mobile apps, browser extensions, desktop apps, web apps

**Design pillars**: Simple (remove non-essentials) · Clean (whitespace, hierarchy, spacing) · Stylish (typography, colour, animation) · Beautiful (pixel detail, micro-interactions) · Accessible (WCAG 2.1 AA)

<!-- AI-CONTEXT-END -->

## Design System Foundation

### Colour

| Role | Purpose | Example |
|------|---------|---------|
| Primary | Brand, CTAs, active states | Blue, purple, coral |
| Secondary | Supporting actions, accents | Complementary to primary |
| Background | Screen/page backgrounds | White/near-white · black/near-black |
| Surface | Cards, sheets, elevated elements | Slightly tinted background |
| Text | Primary content | Near-black (light) · near-white (dark) |
| Text secondary | Labels, captions, metadata | Grey |
| Success/Warning/Error | State feedback | Green · Amber · Red |
| Border | Dividers, input borders | Light grey |

**Dark mode is mandatory.** Design both themes from the start. Use semantic colour tokens, not hardcoded values.

### Typography

- **System fonts preferred**: SF Pro (iOS), Roboto (Android), system-ui (web)
- **Custom fonts** only when brand identity requires it
- **Type scale**: 5 sizes max — Title, Headline, Body, Caption, Footnote
- **Line height**: 1.4–1.6× body, 1.2× headings. Use weight (not size) for hierarchy.

### Spacing and Layout

- **8px grid**: All spacing in multiples of 8 (8, 16, 24, 32, 48)
- **Touch/click targets**: 44×44pt (iOS) / 48×48dp (Android) / 44×44px (web) minimum
- **Content width**: Max 600px for readability. Card padding: 16px minimum.
- **Safe areas**: Respect notch, home indicator, status bar on mobile.

### Icons

**Product icon**: Distinctive at all sizes, no text, simple silhouette, matches palette. Test against competitor icons in search results.

**In-product icons**: SF Symbols (iOS) · Material Icons (Android) · Lucide/Heroicons (web/extensions). Consistent weight/size; filled = active, outlined = inactive.

### Animations and Micro-Interactions

| Type | Duration | Notes |
|------|----------|-------|
| Page transitions | 250–350ms | |
| Button feedback | 100–150ms | |
| Loading states | — | Skeleton screens, not spinners |
| Success/Error feedback | 200–400ms | + haptics on mobile |
| List item enter/exit | Staggered 50ms/item | |
| Pull to refresh | — | Spring physics |

**Haptic feedback** (mobile): Light impact (taps, toggles) · Medium (selections) · Success (task complete) · Warning (limits) · Error (failures).

## Asset Generation

- **Product icons**: `tools/vision/image-generation.md` · Gemini Pro for SVG · model contests for best results
- **Screenshots/previews**: `tools/browser/remotion-best-practices-skill.md` · `tools/vision/` for marketing · Playwright for device screenshots

## DESIGN.md (AI-Readable Design System)

For any project with UI, create a `DESIGN.md` in the project root. This gives coding agents exact hex values, font specs, component styles, and layout rules to produce consistent, on-brand UI. See `tools/design/design-md.md` for the format specification and creation workflows.

- **Library**: `tools/design/library/` -- 54 brand examples + 12 style archetypes
- **Palette**: `tools/design/colour-palette.md` -- generate and spin colour palettes
- **Template**: `templates/DESIGN.md.template` -- skeleton seeded by `aidevops init`
- **Preview**: `tools/design/library/_template/preview.html.template` -- visual catalogue generator

## Design Inspiration

Full catalogue (60+ resources): `tools/design/design-inspiration.md`. Design intelligence (UI styles, palettes, font pairings): `tools/design/ui-ux-catalogue.toon`. Brand/style interviews: `tools/design/brand-identity.md`, `tools/design/ui-ux-inspiration.md`.

| Resource | URL | Best For |
|----------|-----|----------|
| Mobbin | https://mobbin.com | Real-world mobile UI patterns and flows |
| Screenlane | https://screenlane.com | Mobile UI screenshots by component (free) |
| Page Flows | https://pageflows.com | Recorded user flows with annotations |
| PaywallPro | https://paywallpro.app | 46,000+ iOS paywall screenshots |
| Dribbble | https://dribbble.com | UI inspiration across all platforms |
| Apple HIG | https://developer.apple.com/design/ | iOS/macOS standards |
| Material Design | https://m3.material.io/ | Android/web standards |

**Illustration style**: Choose one and maintain it — Flat · 3D · Hand-drawn · Geometric · Photographic.

## Platform Guidelines

| Platform | Key rules |
|----------|-----------|
| **iOS** | Native nav patterns (tab bar, nav stack); system gestures; Dynamic Type; SF Symbols |
| **Android** | Material You dynamic colour; bottom nav; FAB for primary actions; predictive back |
| **Browser Extensions** | Compact popup (max 400×600px); match browser light/dark; options page = standard web |
| **Desktop** | Platform conventions (menu bar macOS, title bar Windows); keyboard shortcuts; resizable windows |
| **Web** | Mobile-first responsive; progressive enhancement; skeleton screens; accessible nav |

## Accessibility Checklist

- [ ] Colour contrast ≥ 4.5:1 (text), ≥ 3:1 (large text)
- [ ] All interactive elements have accessibility labels
- [ ] Screen reader navigation order is logical
- [ ] Touch/click targets ≥ 44×44pt
- [ ] Animations respect "Reduce Motion" system setting
- [ ] Text scales with system font size
- [ ] No information conveyed by colour alone
- [ ] Focus indicators visible for keyboard/switch navigation

See `tools/accessibility/accessibility-audit.md` for comprehensive auditing.

## Related

- `tools/design/design-md.md` — DESIGN.md format and generation workflows
- `tools/design/library/` — Design example library (brands + style archetypes)
- `tools/design/colour-palette.md` — Palette generation and spinning
- `tools/design/brand-identity.md` — Strategic brand identity profile
- `product/onboarding.md` — Onboarding flow design
- `product/validation.md` — Competitor UI research
- `tools/vision/overview.md` — Image generation tools
- `tools/browser/remotion-best-practices-skill.md` — Animated previews
- `tools/ui/tailwind-css.md` — Tailwind CSS
- `tools/ui/shadcn.md` — shadcn/ui component library

