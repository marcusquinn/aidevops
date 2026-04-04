# Design System: Resend — Typography Rules

## Font Families

- **Display Serif**: `domaine` (Domaine Display by Klim Type Foundry) — hero headlines
- **Display Sans**: `aBCFavorit` (ABC Favorit by Dinamo), fallbacks: `ui-sans-serif, system-ui` — section headings
- **Body / UI**: `inter`, fallbacks: `ui-sans-serif, system-ui` — body text, buttons, navigation
- **Monospace**: `commitMono`, fallbacks: `ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas`
- **Secondary**: `Helvetica` — fallback for specific UI contexts
- **System**: `-apple-system, system-ui, Segoe UI, Roboto` — embedded content

## Hierarchy

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display Hero | domaine | 96px (6.00rem) | 400 | 1.00 (tight) | -0.96px | `"ss01", "ss04", "ss11"` |
| Display Hero Mobile | domaine | 76.8px (4.80rem) | 400 | 1.00 (tight) | -0.768px | Scaled for mobile |
| Section Heading | aBCFavorit | 56px (3.50rem) | 400 | 1.20 (tight) | -2.8px | `"ss01", "ss04", "ss11"` |
| Sub-heading | aBCFavorit | 20px (1.25rem) | 400 | 1.30 (tight) | normal | `"ss01", "ss04", "ss11"` |
| Sub-heading Compact | aBCFavorit | 16px (1.00rem) | 400 | 1.50 | -0.8px | `"ss01", "ss04", "ss11"` |
| Feature Title | inter | 24px (1.50rem) | 500 | 1.50 | normal | Section sub-headings |
| Body Large | inter | 18px (1.13rem) | 400 | 1.50 | normal | Introductions |
| Body | inter | 16px (1.00rem) | 400 | 1.50 | normal | Standard body text |
| Body Semibold | inter | 16px (1.00rem) | 600 | 1.50 | normal | Emphasis, active states |
| Nav Link | aBCFavorit | 14px (0.88rem) | 500 | 1.43 | 0.35px | `"ss01", "ss03", "ss04"` — positive tracking |
| Button / Link | inter | 14px (0.88rem) | 500–600 | 1.43 | normal | Buttons, nav, CTAs |
| Caption | inter | 14px (0.88rem) | 400 | 1.60 (relaxed) | normal | Descriptions |
| Helvetica Caption | Helvetica | 14px (0.88rem) | 400–600 | 1.00–1.71 | normal | UI elements |
| Small | inter | 12px (0.75rem) | 400–500 | 1.33 | normal | Tags, meta, fine print |
| Small Uppercase | inter | 12px (0.75rem) | 500 | 1.33 | normal | `text-transform: uppercase` |
| Small Capitalize | inter | 12px (0.75rem) | 500 | 1.33 | normal | `text-transform: capitalize` |
| Code Body | commitMono | 16px (1.00rem) | 400 | 1.50 | normal | Code blocks |
| Code Small | commitMono | 14px (0.88rem) | 400 | 1.43 | normal | Inline code |
| Code Tiny | commitMono | 12px (0.75rem) | 400 | 1.33 | normal | Small code labels |
| Heading (Helvetica) | Helvetica | 24px (1.50rem) | 400 | 1.40 | normal | Alternate heading context |

## Principles

- **Three-font editorial hierarchy**: Domaine Display (serif, hero), ABC Favorit (geometric sans, sections), Inter (readable body). Each font has a strict role — they never cross lanes.
- **Aggressive negative tracking on display**: Domaine at -0.96px, ABC Favorit at -2.8px. The display type feels compressed, urgent, and designed — like a magazine masthead.
- **Positive tracking on nav**: ABC Favorit nav links use +0.35px letter-spacing — the only positive tracking in the system. This creates airy, spaced-out navigation text that contrasts with the compressed headings.
- **OpenType as identity**: The `"ss01"`, `"ss03"`, `"ss04"`, `"ss11"` stylistic sets are enabled on all ABC Favorit and Domaine text, activating alternate glyphs that give Resend's typography its unique character.
- **Commit Mono as design element**: The monospace font isn't hidden in code blocks — it's used prominently for code examples and technical content, treated as a first-class visual element.
