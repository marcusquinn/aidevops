# Design System: Playful Vibrant

## 1. Visual Theme & Atmosphere

This design system celebrates energy, joy, and creative expression. It serves products where delight is a feature — children's education apps, gaming platforms, social communities, creative tools, and consumer products that embrace fun as a core value. The interface should make users smile before they even interact with it.

The palette is bold and saturated, anchored by a rich indigo primary that conveys creativity and imagination, paired with a warm rose accent that adds energy and urgency to key moments. Colours are used generously — not just for interactive elements but as environmental features: tinted backgrounds, gradient highlights, and colourful illustrations. This is not a system that whispers; it speaks with enthusiasm.

Every shape is rounded. Large border-radii (16–20px) soften all hard edges, creating a toy-like quality that feels safe, inviting, and tactile. Typography uses a rounded sans-serif that reinforces the friendly character. Micro-interactions are bouncy and responsive — elements spring, grow, and celebrate user actions with visible joy. The overall density is medium, balancing abundant content with enough whitespace to avoid visual chaos.

**Key characteristics:**
- **Mood:** Energetic, playful, joyful, expressive
- **Primary colour:** Indigo `#6366f1`
- **Accent colour:** Rose `#f43f5e`
- **Background:** Near-white `#FAFAFA` with colourful section tinting
- **Border treatment:** Minimal borders; colour and shadow define boundaries
- **Animation:** Bouncy — spring easing, scale transforms, celebratory micro-interactions
- **Imagery style:** Illustrations, bold icons, character art, bright photography
- **Overall density:** Medium — content-rich but well-organised

## 2. Colour Palette & Roles

### Primary

| Role | Hex | Usage |
|------|-----|-------|
| Primary | `#6366f1` | Primary buttons, active links, key UI elements |
| Primary Light | `#818cf8` | Hover states, secondary indicators |
| Primary Dark | `#4f46e5` | Active/pressed states |
| Primary Subtle | `#eef2ff` | Tinted backgrounds, selected states |
| Primary Gradient | `linear-gradient(135deg, #6366f1, #8b5cf6)` | Hero CTAs, feature highlights |

### Accent

| Role | Hex | Usage |
|------|-----|-------|
| Accent | `#f43f5e` | Notifications, badges, urgent CTAs, hearts/likes |
| Accent Light | `#fb7185` | Hover on accent elements |
| Accent Dark | `#e11d48` | Active/pressed accent |
| Accent Subtle | `#fff1f2` | Accent-tinted backgrounds |

### Extended Palette

| Role | Hex | Usage |
|------|-----|-------|
| Amber | `#f59e0b` | Warnings, stars, ratings, achievements |
| Emerald | `#10b981` | Success, online status, completions |
| Cyan | `#06b6d4` | Info, tips, secondary features |
| Purple | `#8b5cf6` | Premium, special content, gradients |

### Text

| Role | Hex | Usage |
|------|-----|-------|
| Heading | `#1e1b4b` | All headings (deep indigo-black) |
| Body | `#374151` | Paragraph text |
| Secondary | `#6b7280` | Captions, metadata |
| Tertiary | `#9ca3af` | Placeholders, disabled |
| Inverse | `#FFFFFF` | Text on dark/coloured backgrounds |

### Surface

| Role | Hex | Usage |
|------|-----|-------|
| Background | `#FAFAFA` | Page background |
| Surface | `#FFFFFF` | Cards, elevated elements |
| Surface Indigo | `#eef2ff` | Feature sections, hero backgrounds |
| Surface Rose | `#fff1f2` | Promotional sections |
| Surface Amber | `#fffbeb` | Achievement/reward sections |
| Border | `#E5E7EB` | Subtle borders (used sparingly) |

## 3. Typography Rules

**Font families:**
- **All text:** `Nunito, "Nunito Sans", system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif`
- **Monospace:** `"Fira Code", "JetBrains Mono", "SFMono-Regular", Consolas, monospace`

### Hierarchy

| Role | Size | Weight | Line-Height | Letter-Spacing | Colour | Notes |
|------|------|--------|-------------|----------------|--------|-------|
| Display | 56px / 3.5rem | 800 | 1.1 | -0.02em | `#1e1b4b` | Hero headlines, celebrations |
| H1 | 40px / 2.5rem | 700 | 1.15 | -0.015em | `#1e1b4b` | Page titles |
| H2 | 32px / 2rem | 700 | 1.2 | -0.01em | `#1e1b4b` | Section headers |
| H3 | 24px / 1.5rem | 700 | 1.25 | -0.005em | `#1e1b4b` | Subsections |
| H4 | 18px / 1.125rem | 700 | 1.3 | 0 | `#1e1b4b` | Card titles |
| Body Large | 18px / 1.125rem | 400 | 1.6 | 0 | `#374151` | Lead text |
| Body | 16px / 1rem | 400 | 1.6 | 0 | `#374151` | Default text |
| Body Small | 14px / 0.875rem | 400 | 1.5 | 0.005em | `#374151` | Compact text |
| Caption | 12px / 0.75rem | 600 | 1.4 | 0.02em | `#6b7280` | Labels, badges |
| Button | 15px / 0.9375rem | 700 | 1.2 | 0.01em | — | Button text |

**Principles:**
- Weight 700 (bold) for all headings — confidence and energy
- Weight 800 (extra-bold) for display text only — maximum impact
- Nunito's rounded terminals complement the rounded UI shapes
- Avoid thin weights (300, 400) for headings — they lack the required energy
- Maximum content width: 800px for body text (wider than editorial — content is scanned, not deeply read)

## 4. Component Stylings

### Buttons

**Primary Button:**
```
background: linear-gradient(135deg, #6366f1, #8b5cf6)
color: #FFFFFF
padding: 14px 32px
border: none
border-radius: 16px
font-size: 15px
font-weight: 700
cursor: pointer
box-shadow: 0 4px 14px rgba(99, 102, 241, 0.35)
transition: all 200ms cubic-bezier(0.34, 1.56, 0.64, 1)

:hover    → transform: translateY(-2px); box-shadow: 0 6px 20px rgba(99, 102, 241, 0.4)
:active   → transform: translateY(0px); box-shadow: 0 2px 8px rgba(99, 102, 241, 0.3)
:focus    → outline: 3px solid rgba(99, 102, 241, 0.4); outline-offset: 2px
:disabled → background: #E5E7EB; color: #9ca3af; box-shadow: none; cursor: not-allowed
```

**Secondary Button:**
```
background: #FFFFFF
color: #6366f1
padding: 14px 32px
border: 2px solid #6366f1
border-radius: 16px
font-size: 15px
font-weight: 700
transition: all 200ms cubic-bezier(0.34, 1.56, 0.64, 1)

:hover    → background: #eef2ff; transform: translateY(-2px)
:active   → background: #e0e7ff; transform: translateY(0px)
:disabled → border-color: #E5E7EB; color: #9ca3af
```

**Ghost Button:**
```
background: transparent
color: #6366f1
padding: 14px 32px
border: none
border-radius: 16px
font-size: 15px
font-weight: 700

:hover    → background: #eef2ff
:active   → background: #e0e7ff
```

**Accent Button (urgent/fun CTA):**
```
background: linear-gradient(135deg, #f43f5e, #e11d48)
color: #FFFFFF
padding: 14px 32px
border-radius: 16px
font-size: 15px
font-weight: 700
box-shadow: 0 4px 14px rgba(244, 63, 94, 0.35)

:hover    → transform: translateY(-2px); box-shadow: 0 6px 20px rgba(244, 63, 94, 0.4)
:active   → transform: translateY(0px)
```

### Inputs

```
background: #FFFFFF
border: 2px solid #E5E7EB
border-radius: 16px
padding: 14px 18px
font-size: 16px
font-weight: 400
color: #1e1b4b
transition: all 200ms ease

:hover       → border-color: #c7d2fe
:focus       → border-color: #6366f1; box-shadow: 0 0 0 4px rgba(99, 102, 241, 0.15)
:error       → border-color: #f43f5e; box-shadow: 0 0 0 4px rgba(244, 63, 94, 0.1)
:success     → border-color: #10b981; box-shadow: 0 0 0 4px rgba(16, 185, 129, 0.1)
::placeholder → color: #9ca3af
:disabled    → background: #F9FAFB; color: #9ca3af
```

**Labels:** 14px, weight 600, colour `#374151`, margin-bottom 8px.
**Helper text:** 13px, weight 400, colour `#6b7280`, margin-top 6px.
**Character counter:** 12px, colour `#9ca3af`, right-aligned.

### Links

```
color: #6366f1
text-decoration: none
font-weight: 600
transition: color 200ms ease

:hover  → color: #4f46e5; text-decoration: underline; text-decoration-style: wavy; text-underline-offset: 4px
:active → color: #4338ca
```

### Cards

```
background: #FFFFFF
border: none
border-radius: 20px
padding: 28px
box-shadow: 0 2px 12px rgba(0, 0, 0, 0.06)
transition: all 200ms cubic-bezier(0.34, 1.56, 0.64, 1)

Interactive cards:
:hover → transform: translateY(-4px) scale(1.01); box-shadow: 0 12px 32px rgba(0, 0, 0, 0.1)
```

**Feature cards** with colour accent: Add a 4px top border in one of the extended palette colours.
**Achievement cards:** Gold (`#f59e0b`) top border with `#fffbeb` background tint.

### Navigation

```
Top bar:
  background: #FFFFFF
  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.04)
  height: 68px
  padding: 0 24px
  border-radius: 0 (full width)

Nav links:
  color: #6b7280
  font-size: 15px
  font-weight: 600
  border-radius: 12px
  padding: 8px 16px
  transition: all 200ms ease
  :hover  → color: #6366f1; background: #eef2ff
  :active → color: #4f46e5; background: #e0e7ff

Active indicator:
  background: #eef2ff
  color: #6366f1
  (or bottom border 3px in #6366f1)

Mobile nav:
  Bottom tab bar with icons + labels
  Active tab: #6366f1 icon + text
  Inactive: #9ca3af
```

### Badges & Tags

```
Notification badge:
  background: #f43f5e
  color: #FFFFFF
  font-size: 11px
  font-weight: 700
  min-width: 20px
  height: 20px
  border-radius: 9999px
  padding: 0 6px

Tag:
  background: #eef2ff
  color: #6366f1
  font-size: 12px
  font-weight: 600
  padding: 4px 12px
  border-radius: 9999px
```

## 5. Layout Principles

### Spacing Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--space-1` | 4px | Inline icon gaps |
| `--space-2` | 8px | Badge padding, compact spacing |
| `--space-3` | 12px | Tag padding, tight groups |
| `--space-4` | 16px | Standard gap, list item spacing |
| `--space-5` | 24px | Card gap, form field spacing |
| `--space-6` | 32px | Card padding, section internal |
| `--space-7` | 48px | Section breaks |
| `--space-8` | 64px | Major section separation |
| `--space-9` | 80px | Hero padding |
| `--space-10` | 120px | Page-level separation |

### Grid

- 12-column grid, 24px gutter
- Common layouts: 2-column (50/50), 3-column (33/33/33), 4-column (25×4)
- Card grids use CSS Grid with `auto-fill` and `minmax(280px, 1fr)` for responsive columns
- Content alignment: centred for marketing, left-aligned for app interfaces

### Container Widths

| Breakpoint | Container | Padding |
|-----------|-----------|---------|
| ≥1440px | 1280px | auto (centred) |
| 1024–1439px | 100% | 48px per side |
| 768–1023px | 100% | 32px per side |
| <768px | 100% | 16px per side |

### Whitespace Philosophy

Whitespace prevents visual overload in a colourful system. Without it, bold colours and rounded shapes become chaotic. Sections need 48–64px breathing room. Cards need 24px internal padding. The colourful palette earns trust through organisation — every element has a clear place and enough space around it to be understood independently.

### Border-Radius Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--radius-sm` | 8px | Small interactive elements |
| `--radius-md` | 12px | Nav items, compact cards |
| `--radius-lg` | 16px | Buttons, inputs |
| `--radius-xl` | 20px | Cards, containers, modals |
| `--radius-2xl` | 28px | Hero sections, feature areas |
| `--radius-full` | 9999px | Avatars, pills, badges, toggles |

## 6. Depth & Elevation

| Level | Name | CSS Box-Shadow | Usage |
|-------|------|---------------|-------|
| 0 | Flat | `none` | Inline elements, badges |
| 1 | Soft | `0 2px 8px rgba(0, 0, 0, 0.04), 0 1px 3px rgba(0, 0, 0, 0.03)` | Cards at rest, nav bar |
| 2 | Raised | `0 4px 16px rgba(0, 0, 0, 0.06), 0 2px 6px rgba(0, 0, 0, 0.04)` | Hover cards, active dropdowns |
| 3 | Elevated | `0 12px 32px rgba(0, 0, 0, 0.1), 0 4px 12px rgba(0, 0, 0, 0.05)` | Popovers, floating menus |
| 4 | Overlay | `0 24px 48px rgba(0, 0, 0, 0.14), 0 8px 24px rgba(0, 0, 0, 0.06)` | Modals, full overlays |

**Coloured shadows (for primary buttons and feature cards):**

| Element | Shadow |
|---------|--------|
| Primary button | `0 4px 14px rgba(99, 102, 241, 0.35)` |
| Accent button | `0 4px 14px rgba(244, 63, 94, 0.35)` |
| Feature card hover | `0 12px 32px rgba(99, 102, 241, 0.12)` |

**Elevation principles:**
- Coloured shadows match the element's primary colour — never neutral-only
- Cards always have at least a soft shadow (level 1) — no flat cards with borders
- Hover states increase shadow AND add slight `translateY` for physical feel
- Spring easing on hover: `cubic-bezier(0.34, 1.56, 0.64, 1)`
- Modal backdrop: `rgba(30, 27, 75, 0.3)` — slightly indigo-tinted

## 7. Do's and Don'ts

### Do's

1. **Do** use large border-radii consistently — 16px for interactive elements, 20px for cards
2. **Do** use the gradient primary (`#6366f1` → `#8b5cf6`) for hero CTAs and feature highlights
3. **Do** add micro-interactions: scale on hover, spring easing, success celebrations (confetti, checkmarks)
4. **Do** use coloured surface tints (`#eef2ff`, `#fff1f2`) to create visual sections without harsh borders
5. **Do** keep headings bold (700+) — the playful aesthetic needs confident typography
6. **Do** use the extended palette (amber, emerald, cyan, purple) for categories, tags, and status indicators
7. **Do** ensure every interactive element has visible, generous focus states (3px+ outline)
8. **Do** use illustration and iconography as first-class design elements

### Don'ts

1. **Don't** use sharp corners (0–4px radius) — they break the soft, approachable feel
2. **Don't** combine more than three palette colours in a single component
3. **Don't** use thin font weights (<400) for any visible text — the system needs visual weight
4. **Don't** use flat, borderless cards — always provide shadow or colour differentiation
5. **Don't** animate too many elements simultaneously — limit to one animation focal point per viewport
6. **Don't** use dark backgrounds as the default — this is a light-mode-first system
7. **Don't** skip success/celebration feedback — completing a task should feel rewarding
8. **Don't** use indigo (#6366f1) for body text on white — insufficient contrast (use #1e1b4b instead)
9. **Don't** place rose (#f43f5e) text on coloured backgrounds without verifying contrast
10. **Don't** overuse gradients — reserve them for primary CTAs and hero elements only

## 8. Responsive Behaviour

### Breakpoints

| Name | Range | Columns | Gutter | Container Padding |
|------|-------|---------|--------|-------------------|
| Mobile | 0–767px | 4 | 16px | 16px |
| Tablet | 768–1023px | 8 | 24px | 32px |
| Desktop | 1024–1439px | 12 | 24px | 48px |
| Wide | ≥1440px | 12 | 24px | auto (centred 1280px) |

### Touch Targets

- Minimum tap target: 48×48px (generous for the target audience)
- Minimum gap between targets: 12px
- Mobile buttons: full-width below 480px, minimum 52px height
- Game/interactive elements: minimum 56×56px

### Mobile-Specific Rules

- Navigation becomes a bottom tab bar (4–5 items with icons + labels, active in `#6366f1`)
- Card grids collapse to single column with 16px gaps
- Cards maintain 20px border-radius on mobile
- Typography: Display → 36px, H1 → 32px, H2 → 26px; Body remains 16px
- Gradients on buttons simplify to solid `#6366f1` on low-power devices
- Micro-interactions maintain — bouncy hover becomes bouncy tap feedback
- Floating action button: 60px diameter, `#6366f1` gradient, 16px from bottom-right
- Section tinted backgrounds remain on mobile — they define content zones
- Horizontal scrolling: acceptable for category pills, sticker/emoji pickers, and image carousels
- Pull-to-refresh: custom animation with brand character/mascot (if applicable)
- Keyboard: suggest emoji/sticker toolbar for social features

## 9. Agent Prompt Guide

### Quick Colour Reference

| CSS Variable | Hex | Role |
|-------------|-----|------|
| `--color-primary` | `#6366f1` | Indigo — buttons, links, active states |
| `--color-primary-light` | `#818cf8` | Hover highlights |
| `--color-primary-dark` | `#4f46e5` | Active/pressed |
| `--color-primary-subtle` | `#eef2ff` | Tinted backgrounds |
| `--color-accent` | `#f43f5e` | Rose — notifications, hearts, urgent CTAs |
| `--color-accent-light` | `#fb7185` | Accent hover |
| `--color-accent-subtle` | `#fff1f2` | Accent backgrounds |
| `--color-amber` | `#f59e0b` | Stars, ratings, achievements |
| `--color-emerald` | `#10b981` | Success, online, completions |
| `--color-cyan` | `#06b6d4` | Info, tips |
| `--color-purple` | `#8b5cf6` | Premium, gradients |
| `--color-text` | `#1e1b4b` | Headings (deep indigo-black) |
| `--color-text-body` | `#374151` | Body text |
| `--color-text-secondary` | `#6b7280` | Captions, metadata |
| `--color-surface` | `#FAFAFA` | Page background |
| `--color-surface-white` | `#FFFFFF` | Cards |
| `--color-border` | `#E5E7EB` | Subtle borders (rarely used) |

### Ready-to-Use Prompts

**Prompt 1 — Children's education landing page:**
> Build a landing page following DESIGN.md. Background #FAFAFA with a white navbar (68px, soft shadow). Hero section on #eef2ff with a 56px/800 heading in #1e1b4b, 18px body in #374151, and a gradient primary button (linear-gradient 135deg #6366f1 to #8b5cf6, 16px radius, coloured shadow). Feature section with 3 cards (white, 20px radius, soft shadow), each with a coloured top border (indigo, rose, amber) and a 48px icon in a 64px rounded-full circle with the matching subtle background colour. Achievement section on #fffbeb with gold (#f59e0b) star icons. All corners rounded 16–20px, spring easing on hover.

**Prompt 2 — Social app profile page:**
> Create a profile page following DESIGN.md. Bottom tab navigation with 5 items (home, search, create, messages, profile) — active tab in #6366f1, inactive in #9ca3af. Profile header: circular avatar (80px, border: 3px solid #6366f1), display name in 24px/700 #1e1b4b, handle in 14px #6b7280. Stats row: followers/following/posts in 20px/700 with labels in 12px/600. Bio in 16px/400. Post grid: 3-column with 4px gaps, 12px border-radius on images. Edit profile button: secondary style (white bg, #6366f1 border, 16px radius). Follow button: gradient primary. Rose (#f43f5e) heart icon for likes.

**Prompt 3 — Gamified dashboard:**
> Build a gamified learning dashboard following DESIGN.md. Background #FAFAFA. Welcome card (white, 20px radius) with user avatar and streak counter (amber #f59e0b flame icon, 32px/700 number). Progress section: course cards with gradient progress bars (#6366f1 → #8b5cf6), percentage in 24px/700, subject name in 18px/700. Achievement badges: circular (64px) with coloured backgrounds from the extended palette and white icons. Leaderboard: numbered list with avatar, name, and XP points (emerald #10b981 for level-ups). Daily challenge card: rose (#f43f5e) accent border, animated pulse on the "Start" button. All cards 20px radius with soft shadows, spring easing on hover.

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md format: https://stitch.withgoogle.com/docs/design-md/overview
Not based on any specific brand. Use as a starting point for your project.
-->
