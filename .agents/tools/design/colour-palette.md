---
name: colour-palette
description: >
  Colour palette generation, spinning, and narrowing for DESIGN.md files.
  Use when creating a new colour scheme, exploring palette variants, or
  refining colours for a project's design system.
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  webfetch: true
model: sonnet
---

# Colour Palette Generation & Spinning

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Generate, spin, and narrow colour palettes for DESIGN.md files
- **Trigger**: New project palette, "try different colours", "spin the palette", palette exploration
- **Output**: Colour section for `DESIGN.md` (Section 2: Colour Palette & Roles)
- **CLI helper**: `scripts/colormind-helper.sh` (generate, spin, contrast, models)
- **Preview helper**: `scripts/design-preview-helper.sh` (screenshot preview.html in light+dark)
- **Tools**: Colormind API, HSL manipulation, contrast checking
- **Related**: `tools/design/design-md.md`, `tools/design/brand-identity.md`, `tools/design/library/`

<!-- AI-CONTEXT-END -->

## External Tools

### Colormind (AI Palette Generation)

Website: http://colormind.io/

Colormind uses deep learning trained on photographs, films, and art to generate cohesive colour palettes. It can generate from scratch or lock specific colours and generate the rest.

**API usage** (no auth required):

```bash
# Generate random palette
curl -s -X POST http://colormind.io/api/ \
  --data '{"model":"default"}' | jq '.result'

# Generate with locked colours (lock primary, generate rest)
# "N" = generate, [R,G,B] = locked colour
curl -s -X POST http://colormind.io/api/ \
  --data '{"input":[[44,43,196],"N","N","N","N"],"model":"default"}' | jq '.result'

# Response: {"result":[[R,G,B],[R,G,B],[R,G,B],[R,G,B],[R,G,B]]}
# 5 colours: darkest to lightest (typically: dark bg, dark accent, mid, light accent, light bg)
```

**Models**: `default` (general), `ui` (UI-optimised when available). Check `http://colormind.io/api/` for current models.

### Other Palette & Typography Resources

| Tool | URL | Use |
|------|-----|-----|
| Colormind | http://colormind.io/ | AI palette generation (deep learning trained on photos, film, art) |
| Colormind Bootstrap | http://colormind.io/bootstrap/ | Live Bootstrap theme preview with AI palettes |
| Colormind Dashboard | http://colormind.io/template/paper-dashboard/ | Live dashboard template preview with AI palettes |
| Huemint | https://huemint.com/ | AI colour for brand identity, logos, and web mockups |
| Fontjoy | https://fontjoy.com/ | AI font pairing generator (heading + body + accent) |
| Poolors | https://poolors.com/ | Discover colour combinations that stand out |
| Coolors | https://coolors.co/ | Interactive palette generator with lock/shuffle |
| Realtime Colors | https://realtimecolors.com/ | See palette applied to a live UI mockup instantly |
| Adobe Color | https://color.adobe.com/ | Colour wheel, harmony rules, accessibility tools |
| Colour Hunt | https://colorhunt.co/ | Curated palette collections by community |
| Happy Hues | https://www.happyhues.co/ | Palettes shown in realistic UI context |
| Brandmark | https://brandmark.io/ | AI logo maker -- generates logo, typography, and colour schemes |
| Looka | https://looka.com/ | AI logo and brand kit generator with mockups |

## Palette Generation Workflow

### Step 1: Determine Constraints

Before generating, establish what's fixed:

- **Brand colour**: Does the user have a primary brand colour already? Lock it.
- **Mode**: Light-first, dark-first, or both?
- **Mood**: Warm/cool, saturated/muted, energetic/calm?
- **Industry**: Developer tools (cool/dark), healthcare (warm/light), finance (blue/trustworthy)?
- **Style archetype**: Check `tools/design/library/styles/` for matching archetype.

### Step 2: Generate Base Palette

**Option A: From Colormind API**

```bash
# Lock user's primary colour (e.g. #6366f1 = indigo)
curl -s -X POST http://colormind.io/api/ \
  --data '{"input":[[99,102,241],"N","N","N","N"],"model":"default"}'
```

**Option B: From HSL Harmony Rules**

Start with the primary colour's HSL values, then derive:

| Role | HSL Rule | Example |
|------|----------|---------|
| Primary | Base | hsl(239, 84%, 67%) |
| Accent | Complementary (+180 hue) | hsl(59, 84%, 67%) |
| Secondary | Analogous (+30 hue) | hsl(269, 84%, 67%) |
| Success | Fixed green range | hsl(142, 71%, 45%) |
| Warning | Fixed amber range | hsl(38, 92%, 50%) |
| Error | Fixed red range | hsl(0, 84%, 60%) |

**Option C: From Library Example**

Pick a brand or style from `tools/design/library/`, extract Section 2, and use as starting point.

### Step 3: Derive Full Role Set

Every DESIGN.md needs these colour roles populated:

```
Primary Brand:     primary, secondary
Accent:            accent, accent-hover
Text:              text-primary, text-secondary, text-tertiary
Surface:           bg-primary, bg-secondary, bg-surface
Semantic:          success, warning, error, info
Border:            border-primary, border-secondary
Interactive:       btn-primary-bg, btn-primary-text, btn-secondary-bg, btn-secondary-text
Shadow:            shadow tint colours (usually dark with low opacity)
```

**Derivation rules:**

- `bg-secondary`: Shift lightness +-5% from `bg-primary`
- `bg-surface`: Shift lightness +-3% from `bg-secondary`
- `text-secondary`: Reduce opacity/saturation of `text-primary`
- `border-primary`: Low-opacity version of `text-primary` (10-15% opacity)
- `accent-hover`: Shift lightness +-10% from `accent`
- `btn-primary-text`: Must pass WCAG AA contrast against `btn-primary-bg`

### Step 4: Contrast Validation

Every text/background pair must pass WCAG 2.1 AA:

| Pair | Minimum Ratio |
|------|---------------|
| Body text on background | 4.5:1 |
| Large text (18px+ or 14px bold) on background | 3:1 |
| UI component borders | 3:1 against adjacent colours |
| Focus indicators | 3:1 against background |

**Quick contrast check formula** (approximate):

```
luminance(colour) = 0.2126 * R/255 + 0.7152 * G/255 + 0.0722 * B/255
contrast = (lighter_luminance + 0.05) / (darker_luminance + 0.05)
```

Flag any pair below 4.5:1 and suggest adjustment.

## Palette Spinning

"Spinning" = generating multiple palette variants quickly so the user can compare and narrow down.

### Spin Methods

**Hue rotation**: Rotate the primary hue in 30-degree increments, regenerate derived colours.

```
Spin 1: Original (hsl 239)
Spin 2: +30 degrees (hsl 269) -- purple shift
Spin 3: +60 degrees (hsl 299) -- magenta shift
Spin 4: -30 degrees (hsl 209) -- blue shift
Spin 5: -60 degrees (hsl 179) -- teal shift
Spin 6: Complementary (hsl 59) -- radical change
```

**Saturation sweep**: Keep hue fixed, vary saturation from muted (30%) to vivid (90%).

**Lightness sweep**: Keep hue/saturation, generate light-mode-optimised and dark-mode-optimised variants.

**Temperature shift**: Warm the palette (shift towards orange/red) or cool it (shift towards blue/cyan).

### Spin Presentation

Present each spin as a compact table:

```markdown
### Spin 1: Indigo Original
| Role | Hex | Preview |
|------|-----|---------|
| Primary | #6366f1 | [swatch] |
| Accent | #f59e0b | [swatch] |
| Background | #ffffff | [swatch] |
| Text | #18181b | [swatch] |
| Surface | #f4f4f5 | [swatch] |

### Spin 2: Purple Shift (+30)
| Role | Hex | Preview |
...
```

Ask user: "Which spin feels closest? I can refine from there."

### Narrowing

Once user picks a spin direction:

1. Generate 3 micro-variants (+-5 degrees hue, +-10% saturation)
2. Present side by side
3. User picks final
4. Derive full role set
5. Write to DESIGN.md Section 2

## Integration with DESIGN.md

### Writing the Palette

After finalising, write the complete Section 2 of the target DESIGN.md:

```markdown
## 2. Colour Palette & Roles

### Primary Brand
- **Primary** (`#6366f1`): Brand colour, primary buttons, active navigation
- **Secondary** (`#8b5cf6`): Supporting accent, secondary buttons

### Accent Colours
- **Accent** (`#f59e0b`): CTAs, highlights, attention-grabbing elements
- **Accent Hover** (`#d97706`): Hover state for accent elements

### Text Colours
- **Text Primary** (`#18181b`): Main body text, headings
- **Text Secondary** (`#71717a`): Descriptions, labels, metadata
- **Text Tertiary** (`#a1a1aa`): Placeholders, disabled text

### Surface & Background
- **Background** (`#ffffff`): Page background
- **Surface** (`#f4f4f5`): Cards, panels, elevated areas
- **Surface Elevated** (`#e4e4e7`): Dropdowns, tooltips

### Semantic
- **Success** (`#22c55e`): Positive states, completion
- **Warning** (`#f59e0b`): Caution states
- **Error** (`#ef4444`): Error states, destructive actions
- **Info** (`#3b82f6`): Informational notices

### Borders
- **Border** (`#e4e4e7`): Primary borders, dividers
- **Border Focus** (`#6366f1`): Focus ring colour

### Shadows
- **Shadow Colour**: `rgba(0, 0, 0, 0.1)` for light mode, `rgba(0, 0, 0, 0.3)` for dark mode
```

### Updating Existing Palette

When user wants to change colours in an existing DESIGN.md:

1. Read current Section 2
2. Identify which colours to change (primary only? full respray?)
3. Regenerate derived colours from new primary
4. Validate contrast ratios
5. Update Section 2 in place
6. Update Section 9 (Agent Prompt Guide) quick reference table
7. Regenerate preview.html if it exists

## Related

- `tools/design/design-md.md` -- DESIGN.md format specification
- `tools/design/brand-identity.md` -- Strategic brand profile (upstream)
- `tools/design/ui-ux-inspiration.md` -- URL study extraction
- `tools/design/library/` -- Example palettes from brands and styles
- `tools/design/ui-ux-catalogue.toon` -- Style patterns with colour data
- `product/ui-design.md` -- Accessibility requirements for colour
