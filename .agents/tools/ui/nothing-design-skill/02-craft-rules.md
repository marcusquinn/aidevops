<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Nothing Design System — Craft Rules

## 1. Visual Hierarchy: The Three-Layer Rule

Exactly **three layers of importance.**

| Layer | What | How |
|-------|------|-----|
| **Primary** | The ONE thing the user sees first. A number, a headline, a state. | Doto or Space Grotesk at display size. `--text-display`. 48-96px breathing room. |
| **Secondary** | Supporting context. Labels, descriptions, related data. | Space Grotesk at body/subheading. `--text-primary`. Grouped tight (8-16px) to the primary. |
| **Tertiary** | Metadata, navigation, system info. Visible but never competing. | Space Mono at caption/label. `--text-secondary` or `--text-disabled`. ALL CAPS. Pushed to edges or bottom. |

**The test:** Squint at the screen. Can you still tell what's most important? If two things compete, one needs to shrink, fade, or move.

**Common mistake:** Visual flatness from evenly-sized elements. Be brave — make the primary absurdly large and the tertiary absurdly small. Contrast IS the hierarchy.

## 2. Font Discipline

Per screen, use maximum:
- **2 font families** (Space Grotesk + Space Mono. Doto only for hero moments.)
- **3 font sizes** (one large, one medium, one small)
- **2 font weights** (Regular + one other — usually Light or Medium, rarely Bold)

Every additional size/weight costs visual coherence. If reaching for a new font-size, it's probably a spacing problem. Add distance instead.

| Decision | Size | Weight | Color |
|----------|:---:|:---:|:---:|
| Heading vs. body | Yes | No | No |
| Label vs. value | No | No | Yes |
| Active vs. inactive nav | No | No | Yes |
| Hero number vs. unit | Yes | No | No |
| Section title vs. content | Yes | Optional | No |

## 3. Spacing as Meaning

Spacing is the primary tool for communicating relationships.

```text
Tight (4-8px)   = "Belong together" (icon + label, number + unit)
Medium (16px)    = "Same group, different items" (list items, form fields)
Wide (32-48px)   = "New group starts here" (section breaks)
Vast (64-96px)   = "New context" (hero to content, major divisions)
```

**If a divider line is needed, spacing is probably wrong.** Dividers are symptoms of insufficient spacing contrast. Use only in data-dense lists where items are structurally identical.

## 4. Container Strategy (prefer top)

1. **Spacing alone** (proximity groups items)
2. A single divider line
3. A subtle border outline
4. A surface card with background change

Use the lightest tool that works. Never box the most important element — let it float.

## 5. Color as Hierarchy

Gray scale IS the hierarchy. Max 4 levels per screen:

```text
--text-display (100%) → Hero numbers. One per screen.
--text-primary (90%)  → Body text, primary content.
--text-secondary (60%) → Labels, captions, metadata.
--text-disabled (40%) → Disabled, timestamps, hints.
```

**Red (#D71921) is an interrupt.** "Look HERE, NOW." If nothing is urgent, no red.

**Data status colors** (success green, warning amber, accent red) are exempt when encoding values. Apply color to **value**, not labels or backgrounds. See `nothing-design-skill/tokens.md`.

## 6. Consistency vs. Variance

**Consistent:** Font families, label treatment (Space Mono ALL CAPS), spacing rhythm, color roles, shapes, alignment.

**Break pattern in exactly ONE place per screen:** Oversized number, circular widget, red accent, Doto headline, vast gap.

This single break IS the design. Without it: sterile grid. With more than one: visual chaos.

## 7. Compositional Balance

**Asymmetry > symmetry.** Favor deliberately unbalanced composition:
- **Large left, small right:** Hero metric + metadata stack.
- **Top-heavy:** Big headline near top, sparse content below.
- **Edge-anchored:** Elements pinned to edges, negative space in center.

Balance heavy elements with empty space, not more heavy elements.

## 8. The Nothing Vibe

1. **Confidence through emptiness.** Large uninterrupted backgrounds.
2. **Precision.** Letter-spacing, exact grays, 4px gaps.
3. **Data as beauty.** `36GB/s` in Space Mono at 48px IS the visual.
4. **Mechanical honesty.** Controls look like controls. Toggle = switch. Gauge = instrument.
5. **Surprise.** Dot-matrix headline, circular widget, or red dot. Restraint makes it powerful.
6. **Percussive.** Transitions feel mechanical and precise.

## 9. Visual Variety in Data-Dense Screens

Vary visual form for 3+ data sections:

| Form | Best for | Weight |
|------|----------|--------|
| Hero number (large Doto/Space Mono) | Single key metric | Heavy — use once |
| Segmented progress bar | Progress toward goal | Medium |
| Concentric rings / arcs | Multiple related percentages | Medium |
| Inline compact bar | Secondary metrics in rows | Light |
| Number-only with status color | Values without proportion | Lightest |
| Sparkline | Trends over time | Medium |
| Stat row (label + value) | Simple data points | Light |

Lead section -> heaviest treatment. Secondary -> different form. Tertiary -> lightest.
