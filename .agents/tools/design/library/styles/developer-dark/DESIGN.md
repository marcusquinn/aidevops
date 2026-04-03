# Design System: Developer Dark

## 1. Visual Theme & Atmosphere

A terminal-native dark interface built for developers who live in their editor. The design takes its cues from modern IDE themes and terminal emulators -- deep grey backgrounds (`#111827`) that are easier on the eyes than pure black, with a carefully chosen palette of terminal-green (`#4ade80`), amber warnings (`#fbbf24`), and error red (`#ef4444`) that map directly to the semantic colours developers already associate with success, caution, and failure.

Typography is monospace-first. JetBrains Mono serves as the primary font for all headings and code, reinforcing the terminal aesthetic, while Inter handles body text where readability at smaller sizes matters more than character alignment. The system is information-dense by design -- small base spacing (4px), compact padding, and minimal border-radius (4px) create a utilitarian interface where screen real-estate is maximised for content. Every pixel serves a purpose.

The depth model is deliberately flat. Shadows are minimal and cool-toned, borders do the heavy lifting for structural separation. Interactive elements use colour changes rather than elevation shifts -- a philosophy borrowed from terminal interfaces where the cursor is the primary focus indicator. The overall impression is of a system designed by engineers, for engineers: precise, dense, and efficient.

**Key Characteristics:**
- Deep grey background (`#111827`) -- never pure black, prevents OLED flicker
- Terminal-green accent (`#4ade80`) for success states and primary interactive elements
- Amber (`#fbbf24`) for warnings and secondary highlights
- JetBrains Mono as primary display/heading font with ligatures enabled
- Inter as body font for readability at 14-16px
- 4px base spacing unit for dense, compact layouts
- Minimal border-radius (4px) -- sharp but not brutal
- Border-driven structure (`#1f2937`) rather than shadow-driven depth
- Semantic colour mapping: green=success, amber=warning, red=error, blue=info
- Focus rings use visible outline (`2px solid #4ade80`) -- no subtle indicators

## 2. Colour Palette & Roles

### Background Surfaces
- **Base Dark** (`#111827`): Primary page background, the foundation of all surfaces
- **Surface** (`#1f2937`): Cards, panels, sidebar backgrounds -- one step up from base
- **Elevated** (`#374151`): Dropdown menus, tooltips, hover states on surfaces
- **Inset** (`#0d1117`): Code blocks, terminal output, sunken areas

### Text Colours
- **Primary Text** (`#f9fafb`): Main text on dark backgrounds -- near-white, not pure white
- **Secondary Text** (`#9ca3af`): Descriptions, labels, metadata, muted content
- **Tertiary Text** (`#6b7280`): Placeholders, disabled states, timestamps
- **Code Text** (`#e5e7eb`): Code content in monospace contexts

### Accent & Interactive
- **Terminal Green** (`#4ade80`): Primary accent -- CTAs, active states, success indicators
- **Green Hover** (`#22c55e`): Hover state for green interactive elements
- **Amber** (`#fbbf24`): Secondary accent -- warnings, highlights, secondary actions
- **Blue** (`#3b82f6`): Info states, links, tertiary interactive elements

### Semantic
- **Success** (`#4ade80`): Same as accent -- confirms terminal-green convention
- **Warning** (`#fbbf24`): Amber -- caution states, approaching limits
- **Error** (`#ef4444`): Red -- failures, destructive actions, validation errors
- **Info** (`#3b82f6`): Blue -- informational notices, help text

### Borders & Dividers
- **Border Primary** (`#1f2937`): Main structural borders, card outlines
- **Border Secondary** (`#374151`): Lighter borders for inner divisions
- **Border Focus** (`#4ade80`): Focus ring colour for keyboard navigation

### Shadows
- **Ambient** (`rgba(0, 0, 0, 0.3) 0px 1px 2px`): Minimal ambient shadow
- **Elevated** (`rgba(0, 0, 0, 0.4) 0px 4px 6px -1px`): Dropdowns, popovers
- **Overlay** (`rgba(0, 0, 0, 0.6) 0px 10px 15px -3px`): Modals, command palettes

## 3. Typography Rules

### Font Families
- **Display/Heading**: `'JetBrains Mono', 'Fira Code', 'SF Mono', ui-monospace, monospace` -- monospace headings reinforce the developer aesthetic
- **Body**: `'Inter', -apple-system, system-ui, 'Segoe UI', sans-serif` -- clean sans-serif for readable body text
- **Code**: `'JetBrains Mono', 'Fira Code', 'SF Mono', ui-monospace, monospace` -- same as heading, with ligatures enabled (`"liga", "calt"`)

### Hierarchy

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display | JetBrains Mono | 36px (2.25rem) | 700 | 1.15 | -0.5px | Hero headings, page titles |
| Heading 1 | JetBrains Mono | 28px (1.75rem) | 700 | 1.2 | -0.3px | Section headers |
| Heading 2 | JetBrains Mono | 22px (1.375rem) | 600 | 1.25 | -0.2px | Subsection headers |
| Heading 3 | JetBrains Mono | 18px (1.125rem) | 600 | 1.3 | normal | Card titles, panel headers |
| Body | Inter | 15px (0.9375rem) | 400 | 1.6 | normal | Standard body text |
| Body Small | Inter | 13px (0.8125rem) | 400 | 1.5 | normal | Dense content, sidebar text |
| Caption | Inter | 11px (0.6875rem) | 500 | 1.4 | 0.3px | Labels, metadata, timestamps |
| Button | JetBrains Mono | 13px (0.8125rem) | 600 | 1.0 | 0.5px | `text-transform: uppercase` |
| Code | JetBrains Mono | 14px (0.875rem) | 400 | 1.6 | normal | Inline code, code blocks |
| Terminal | JetBrains Mono | 14px (0.875rem) | 400 | 1.5 | normal | Terminal/CLI output |

### Principles
- **Monospace-first hierarchy**: Headings and buttons use JetBrains Mono, creating a cohesive terminal feel throughout navigation and structure.
- **Compact sizing**: Body at 15px (not 16px) and small at 13px reflect the density preference of developer tools.
- **Tight headings**: Line heights 1.15-1.3 for headings keep the interface compact.
- **Uppercase buttons**: All button text is uppercase with 0.5px letter-spacing, mimicking CLI command aesthetics.

## 4. Component Stylings

### Buttons

**Primary (Green)**
- Background: `#4ade80`
- Text: `#111827` (dark on green for contrast)
- Border: none
- Radius: 4px
- Padding: 8px 16px
- Font: JetBrains Mono, 13px, weight 600, uppercase, letter-spacing 0.5px
- Hover: background `#22c55e`
- Focus: outline `2px solid #4ade80`, outline-offset `2px`
- Active: background `#16a34a`
- Disabled: opacity 0.4, cursor not-allowed

**Secondary (Ghost)**
- Background: transparent
- Text: `#f9fafb`
- Border: `1px solid #374151`
- Radius: 4px
- Padding: 8px 16px
- Hover: background `#1f2937`, border-color `#4b5563`
- Focus: outline `2px solid #4ade80`, outline-offset `2px`

**Danger**
- Background: `#ef4444`
- Text: `#ffffff`
- Border: none
- Radius: 4px
- Hover: background `#dc2626`

### Inputs

**Text Input**
- Background: `#0d1117`
- Text: `#f9fafb`
- Border: `1px solid #374151`
- Radius: 4px
- Padding: 8px 12px
- Font: JetBrains Mono, 14px, weight 400
- Placeholder: `#6b7280`
- Focus: border-color `#4ade80`, box-shadow `0 0 0 2px rgba(74, 222, 128, 0.2)`
- Error: border-color `#ef4444`, box-shadow `0 0 0 2px rgba(239, 68, 68, 0.2)`

### Links
- Default: `#3b82f6`, no underline
- Hover: `#60a5fa`, underline
- Active: `#2563eb`
- Code links: `#4ade80`, hover `#22c55e`

### Cards & Containers
- Background: `#1f2937`
- Border: `1px solid #374151`
- Radius: 4px
- Padding: 16px
- Shadow: none (border-driven depth)
- Hover: border-color `#4b5563`

### Navigation
- Sticky top bar, background `#111827` with border-bottom `1px solid #1f2937`
- Nav links: JetBrains Mono 13px, weight 500, `#9ca3af`
- Active link: `#4ade80`
- Hover: `#f9fafb`
- Logo/brand: JetBrains Mono 15px, weight 700, `#f9fafb`

## 5. Layout Principles

### Spacing Scale
- Base unit: 4px
- Scale: 2, 4, 6, 8, 12, 16, 20, 24, 32, 40, 48, 64

### Grid & Container
- Max content width: 1200px
- Sidebar width: 240px (collapsible)
- Content area: fluid within container
- Gutter: 16px
- Section spacing: 32-48px vertical

### Breakpoints

| Name | Width | Key Changes |
|------|-------|-------------|
| Mobile | < 640px | Single column, sidebar hidden, hamburger menu |
| Tablet | 640-1024px | Sidebar overlay, reduced padding |
| Desktop | 1024-1440px | Full layout, sidebar visible |
| Wide | > 1440px | Max-width contained, centred |

### Whitespace Philosophy
- **Dense by default**: Small gaps, compact padding, tight line-heights. Developers prefer information density.
- **Section breathing room**: 32-48px between major sections prevents wall-of-text feel.
- **Code blocks generous**: Code content gets extra padding (16px) and line-height (1.6) for readability.

### Border Radius Scale
| Size | Value | Use |
|------|-------|-----|
| Default | 4px | Everything -- buttons, cards, inputs, badges |
| Code | 6px | Code blocks, terminal containers |
| Pill | 9999px | Status badges, tags |

## 6. Depth & Elevation

| Level | Treatment | Use |
|-------|-----------|-----|
| Sunken (-1) | Background `#0d1117`, inset feel | Code blocks, terminal areas, input fields |
| Flat (0) | No shadow, border `#1f2937` | Default cards, panels, sidebar |
| Raised (1) | `rgba(0,0,0,0.3) 0px 1px 2px` | Hover states, dropdown triggers |
| Elevated (2) | `rgba(0,0,0,0.4) 0px 4px 6px -1px` | Dropdown menus, popovers, tooltips |
| Overlay (3) | `rgba(0,0,0,0.6) 0px 10px 15px -3px` | Modals, command palette, full-screen overlays |

**Shadow Philosophy**: Shadows are minimal and cool-toned. Structure comes from borders, not elevation. This mirrors terminal interfaces where everything exists on a single plane with colour and borders providing visual separation.

## 7. Do's and Don'ts

**Do:**
- Use monospace font for headings, buttons, labels, and code -- it's the design language
- Use semantic colours consistently: green=success/go, amber=warning/caution, red=error/stop
- Keep border-radius at 4px for all standard elements -- consistency over variety
- Use the inset (`#0d1117`) background for code blocks and terminal output
- Provide clear keyboard focus indicators (2px green outline)
- Use uppercase for button text and navigation labels
- Keep padding compact (8px, 12px, 16px) -- density is a feature
- Use border-driven depth rather than shadow-driven depth
- Include a command palette (Cmd+K) pattern for power users

**Don't:**
- Never use gradients -- flat colours only, like a terminal
- Never use rounded corners beyond 6px (except pills for badges)
- Never use decorative elements, illustrations, or ornamental dividers
- Never use more than 3 font weights (400, 600, 700)
- Never make interactive elements smaller than 32x32px even in dense layouts
- Never use colour as the only indicator -- always pair with text/icon
- Never animate beyond 150ms for interface feedback -- developers expect instant response
- Never use light mode as the default -- dark is the primary and expected theme
- Never use serif fonts anywhere in the system

## 8. Responsive Behaviour

### Breakpoints

| Name | Width | Key Changes |
|------|-------|-------------|
| Mobile | < 640px | Sidebar hidden, hamburger, stacked layout, 12px padding |
| Tablet | 640-1024px | Sidebar as overlay, 16px padding |
| Desktop | 1024-1440px | Full layout, sidebar pinned |
| Wide | > 1440px | Content max-width 1200px, centred |

### Touch Targets
- Minimum: 32x32px (denser than standard 44px, acceptable for developer audience)
- Preferred: 40x40px for primary actions
- Mobile override: 44x44px minimum on touch devices

### Mobile Rules
- Sidebar collapses to hamburger overlay
- Code blocks gain horizontal scroll, not wrapping
- Navigation simplifies to icon-only with labels on hover/tap
- Tables switch to card view below 640px

## 9. Agent Prompt Guide

### Quick Colour Reference

| Token | Value | Use |
|-------|-------|-----|
| --bg-base | #111827 | Page background |
| --bg-surface | #1f2937 | Cards, panels |
| --bg-elevated | #374151 | Dropdowns, hover |
| --bg-inset | #0d1117 | Code blocks, inputs |
| --text-primary | #f9fafb | Main text |
| --text-secondary | #9ca3af | Muted text |
| --text-tertiary | #6b7280 | Placeholders |
| --accent | #4ade80 | Primary accent (green) |
| --accent-secondary | #fbbf24 | Secondary accent (amber) |
| --error | #ef4444 | Error states |
| --info | #3b82f6 | Links, info |
| --border | #1f2937 | Primary borders |
| --border-light | #374151 | Secondary borders |

### Ready-to-Use Prompts
- "Build a dashboard layout": Use `--bg-base` background, `--bg-surface` sidebar and cards, `--accent` for active nav items. JetBrains Mono headings, Inter body text. Dense 4px spacing grid. Sticky top nav with border-bottom.
- "Build a CLI documentation page": Inset `--bg-inset` code blocks with JetBrains Mono 14px. Body text in Inter 15px on `--bg-base`. Max-width 780px for reading. Green accent for inline code references.
- "Build a settings panel": `--bg-surface` cards with `--border` outlines. Toggle switches using `--accent` green for on state, `--bg-elevated` for off. Compact 8px padding on form groups. JetBrains Mono labels.
- "Build an API reference": Sidebar navigation on `--bg-surface` with `--accent` active indicator. Main content on `--bg-base`. Code blocks on `--bg-inset` with syntax highlighting. Endpoint badges as pills with semantic colours.

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md format: https://stitch.withgoogle.com/docs/design-md/overview
Not based on any specific brand. Use as a starting point for your project.
-->
