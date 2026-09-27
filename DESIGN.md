---
version: alpha
name: AI DevOps
description: Terminal-native, high-contrast brand system shared by aidevops.sh and the AI DevOps apps - black surfaces, sparing cyan accent, cyan-tinted borders, Inter with Menlo for commands, and the cyan prompt-glyph mark.
colors:
  primary: "#66d9f2"
  primary-hover: "#8ce8ff"
  primary-strong: "#42c8e8"
  on-primary: "#001014"
  primary-subtle: "#102327"
  neutral: "#000000"
  background: "#030707"
  background-tertiary: "#0b1012"
  surface: "#050606"
  surface-raised: "#0b0d0e"
  on-surface: "#ffffff"
  secondary: "#dbdbdb"
  muted: "#a8a8a8"
  outline: "#12272c"
  outline-hover: "#2b5b66"
  success: "#56d364"
  warning: "#d29922"
  error: "#da3633"
  error-text: "#ff7b72"
  light-background: "#f7fbfc"
  light-surface: "#ffffff"
  light-on-surface: "#071013"
  light-primary: "#0d6f84"
  light-primary-strong: "#064f60"
  light-on-primary: "#ffffff"
typography:
  headline-display:
    fontFamily: "Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: 48px
    fontWeight: 700
    lineHeight: 1.05
    letterSpacing: -0.03em
  headline-lg:
    fontFamily: "Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: 28px
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: -0.02em
  headline-md:
    fontFamily: "Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: 18px
    fontWeight: 600
    lineHeight: 1.3
  body-lg:
    fontFamily: "Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.6
  body-md:
    fontFamily: "Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.5
  body-sm:
    fontFamily: "Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.45
  label-md:
    fontFamily: "Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: 12px
    fontWeight: 600
    lineHeight: 1.2
  code-md:
    fontFamily: "Menlo, Monaco, Consolas, 'Liberation Mono', 'Courier New', monospace"
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.5
rounded:
  none: 0px
  sm: 6px
  md: 10px
  lg: 12px
  xl: 16px
  full: 9999px
spacing:
  unit: 4px
  xs: 4px
  sm: 8px
  md: 12px
  lg: 16px
  xl: 24px
  gutter: 16px
  margin: 24px
components:
  page:
    backgroundColor: "{colors.neutral}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    padding: 24px
  page-section-alt:
    backgroundColor: "{colors.background}"
    textColor: "{colors.secondary}"
  panel-tertiary:
    backgroundColor: "{colors.background-tertiary}"
    textColor: "{colors.secondary}"
    rounded: "{rounded.lg}"
  card:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.xl}"
    padding: 24px
  card-border:
    backgroundColor: "{colors.outline}"
    textColor: "{colors.muted}"
  card-border-hover:
    backgroundColor: "{colors.outline-hover}"
    textColor: "{colors.on-surface}"
  command-pill:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.primary}"
    typography: "{typography.code-md}"
    rounded: "{rounded.lg}"
    padding: 16px 24px
  input-default:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.lg}"
    padding: 8px 12px
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    typography: "{typography.label-md}"
    rounded: "{rounded.md}"
    padding: 10px 16px
  button-primary-hover:
    backgroundColor: "{colors.primary-hover}"
    textColor: "{colors.on-primary}"
    rounded: "{rounded.md}"
  button-primary-pressed:
    backgroundColor: "{colors.primary-strong}"
    textColor: "{colors.on-primary}"
    rounded: "{rounded.md}"
  button-secondary:
    backgroundColor: "{colors.primary-subtle}"
    textColor: "{colors.on-surface}"
    typography: "{typography.label-md}"
    rounded: "{rounded.md}"
    padding: 10px 16px
  button-danger:
    backgroundColor: "{colors.error}"
    textColor: "{colors.on-surface}"
    typography: "{typography.label-md}"
    rounded: "{rounded.md}"
    padding: 10px 16px
  button-primary-light:
    backgroundColor: "{colors.light-primary}"
    textColor: "{colors.light-on-primary}"
    typography: "{typography.label-md}"
    rounded: "{rounded.md}"
    padding: 10px 16px
  button-primary-light-hover:
    backgroundColor: "{colors.light-primary-strong}"
    textColor: "{colors.light-on-primary}"
    rounded: "{rounded.md}"
  page-light:
    backgroundColor: "{colors.light-background}"
    textColor: "{colors.light-on-surface}"
    typography: "{typography.body-md}"
  card-light:
    backgroundColor: "{colors.light-surface}"
    textColor: "{colors.light-on-surface}"
    rounded: "{rounded.xl}"
  status-success:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.success}"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    padding: 4px 8px
  status-warning:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.warning}"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    padding: 4px 8px
  status-error:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.error-text}"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    padding: 4px 8px
  headline:
    textColor: "{colors.on-surface}"
    typography: "{typography.headline-display}"
  section-title:
    textColor: "{colors.on-surface}"
    typography: "{typography.headline-lg}"
  card-title:
    textColor: "{colors.on-surface}"
    typography: "{typography.headline-md}"
  lead-copy:
    textColor: "{colors.secondary}"
    typography: "{typography.body-lg}"
  meta-copy:
    textColor: "{colors.muted}"
    typography: "{typography.body-sm}"
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: AI DevOps

## Overview

AI DevOps has one brand and two design files:

| File | Owns |
|---|---|
| `marcusquinn/aidevops.sh` → `DESIGN.md` | The public website: page layout, hero, social graph image, favicon and avatar asset generation, website responsive rules |
| `marcusquinn/aidevops` → `DESIGN.md` (this file) | The apps and framework surfaces: desktop/web GUI, dashboards, chat sidebar, generated reports, README hero, agent avatars, and design/print artwork produced by agents (Affinity, reports, flyers) |

The **Brand core** section below is byte-identical in both files. Change it in both repos in the same session, then verify with the sync check in that section. Everything outside the brand core is owned by the file it lives in.

Source-of-truth order when values disagree: the aidevops.sh `styles.css` `:root` custom properties and `favicon.svg` → the Brand core → the app layer below → the YAML tokens (a dark-theme projection of the core with alpha colours pre-composited over black, so report and lint tooling can read plain hex).

<!-- BRAND-CORE:START (keep byte-identical in marcusquinn/aidevops and marcusquinn/aidevops.sh DESIGN.md) -->

## Brand core

### Identity and messaging

- Formal product name: `AI DevOps`. Wordmark: lowercase `aidevops` beside the prompt glyph. Domain signature: `aidevops.sh`.
- Positioning: `AI DevOps Assistant & OpenCode Plugin`.
- Approved headline (the elevator pitch): `Token-efficiency harness & curated skills for speed, teamwork, and secure 24/7 development agents.` Supporting line: `The open-source OpenCode plugin for AI Git workflow automation`. Eyebrow: `24/7 DEVELOPMENT`. Two-line layouts break after `for`, keeping the speed/teamwork/secure list together.
- Install command: `bash <(curl -fsSL aidevops.sh/install)`.
- Voice: terminal-native, precise, autonomous, trustworthy. Short declarative copy; no hype, exclamation marks, or emoji in brand surfaces.

### Look properties

Apply these to every brand surface - website, apps, reports, social images, print, and agent-made artwork:

1. **Black first.** Dark theme is the default brand expression: pure black `#000000` page, near-black `#030707` alternate sections, `#050606`/`#0b0d0e` surfaces. Never navy, slate, or GitHub grey (`#0d1117`, `#161b22`, `#21262d`).
2. **One accent.** Cyan `#66d9f2` is the only brand hue. Use it sparingly for the mark, primary action, active/focus state, key numbers, links, and command text - roughly 5-10% of a composition. No second brand colour.
3. **Light from the accent.** Depth comes from soft cyan radial glows (`rgba(102,217,242,0.18)` fading to transparent, heavily blurred) behind hero content, and from cyan-tinted hairline borders (`rgba(102,217,242,0.18)`, `0.42` on hover). Drop shadows are black, soft, and reserved for the app icon, the install box, and primary buttons.
4. **High contrast text.** White headlines; secondary copy at 86% white and muted copy at 66% white, never lower for readable text.
5. **Terminal motifs.** Prompt glyph `>_`, monospace command pills in cyan on a near-black surface, window-frame dots (`#ff5f57`, `#febc2e`, `#28c840`) only on terminal/window chrome.
6. **Generous, rounded, calm.** Rounded cards (12-16px), rounded buttons (10-16px), generous padding, centred hero compositions, restrained motion (0.2-0.3s ease).

### Colour tokens

Dark (default) - from aidevops.sh `styles.css` `:root`:

| Role | Value |
|---|---|
| Background primary / secondary / tertiary | `#000000` / `#030707` / `#0b1012` |
| Surface / raised surface / code surface | `#050606` / `#0b0d0e` / `#050606` |
| Text primary / secondary / muted | `#ffffff` / `rgba(255,255,255,0.86)` / `rgba(255,255,255,0.66)` |
| Accent / hover / strong | `#66d9f2` / `#8ce8ff` / `#42c8e8` |
| Text on accent fill | `#001014` |
| Accent subtle fill / glow / hover fill | `rgba(102,217,242,0.16)` / `0.18` / `0.22` |
| Border / border hover | `rgba(102,217,242,0.18)` / `rgba(102,217,242,0.42)` |

Light - from aidevops.sh `styles.css` `[data-theme="light"]`:

| Role | Value |
|---|---|
| Background primary / secondary / tertiary | `#f7fbfc` / `#edf6f8` / `#ffffff` |
| Surface / raised surface | `#ffffff` / `#f8fdff` |
| Text primary / secondary / muted | `#071013` / `rgba(7,16,19,0.84)` / `rgba(7,16,19,0.62)` |
| Accent / hover / strong | `#0d6f84` / `#0a8ca8` / `#064f60` |
| Text on accent fill | `#ffffff` |
| Border / border hover | `rgba(13,111,132,0.18)` / `rgba(13,111,132,0.38)` |

The accent hue is 191°; app themes may vary saturation/lightness for contrast modes but never the hue. Verified contrast: `#001014` on `#66d9f2` ≈ 11.8:1, white on `#0d6f84` ≈ 5.8:1, `#66d9f2` on black ≈ 12.8:1.

### Typography

- UI, marketing, and print copy: `Inter`, falling back to `ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif`.
- Commands, code, and terminal surfaces: `Menlo, Monaco, Consolas, 'Liberation Mono', 'Courier New', monospace`.
- Headlines: weight 700, tight tracking (`-0.02em` to `-0.03em`). The hero wordmark `AI DevOps` may use a white→cyan 135° text gradient on dark (white→`#064f60` on light).
- Body: weight 400, line-height 1.5-1.6, `text-wrap: pretty` for paragraphs and `balance` for headings.

### Brand mark and app icon

- The mark is the cyan terminal prompt glyph (Font Awesome `terminal` path, viewBox `0 0 576 512`) used in the aidevops.sh navigation. Never reintroduce the old `AI` letter mark.
- Inline/nav use: glyph in accent cyan beside the `aidevops` wordmark in primary text colour.
- App icon construction on a `1024x1024` canvas, as in aidevops.sh `favicon.svg` - reproduce every layer; a flat tint over the tile is off-brand:
  1. Tile: `848x848` at `88,88`, corner radius `188`, linear gradient top-left→bottom-right `#000000`→`#030707`.
  2. Glow: same tile shape filled with a radial gradient centred at 50%, radius 62%, `#66d9f2` at 22% opacity fading to 0%.
  3. Ring: `792x792` at `116,116`, radius `160`, stroke `#66d9f2` at 36% opacity, width `18`, no fill.
  4. Shadow on tile + glow + ring: offset `0,34`, blur `38`, black at 45%.
  5. Glyph: fill `#8ce8ff`, placement `translate(512 522) scale(0.94) translate(-288 -256)` - optically centred, nudged right/down because `>` is left-heavy.
- Scale every value proportionally for other canvas sizes; keep the glyph recognisable at 16px.
- Circular avatars: `1024x1024`, background inside radius `504`, essential detail inside radius `451`, glyph `translate(512 521) scale(1.08) translate(-288 -256)`.
- Content-bearing icon SVGs carry `<title>` and `<desc>`.

### Actions and status

- Primary action: cyan `#66d9f2` fill, `#001014` text, weight 700, hover `#8ce8ff` (light theme: `#0d6f84` fill, white text, hover `#064f60`; light `#0a8ca8` is for link/text hover only because white on it is 3.9:1). One primary action per view or artwork.
- Secondary action: accent-subtle fill (`rgba(102,217,242,0.16)`), primary text colour, hover `0.22`.
- Focus: 3px ring in border-hover cyan; never remove focus without a visible replacement.
- Green, amber, and red are **status and destructive semantics only** (success/running, warning, error/delete) - never a brand or primary-action colour. Always pair status colour with a text label.

### Artwork, print, and social

- Composition: black-to-near-black background, one soft cyan radial glow behind the focal area, the app icon or glyph as the anchor, white Inter headline, muted supporting copy, one cyan primary CTA or command pill, `aidevops.sh` signature in accent cyan.
- Social graph image: `1200x630`, icon top-left without a circular blob behind it, approved eyebrow/title/headline/supporting line, install command pill, right-aligned `aidevops.sh`.
- Print: design in sRGB with live Inter text and vector marks; PDF export keeps text live. Full-bleed black needs 3mm bleed for commercial print; proof `#66d9f2` because bright cyan can fall outside coated CMYK gamuts.
- Don't: GitHub-dark palettes, green or blue primary buttons, flat cyan tint over icon tiles, glassmorphism, multiple accent hues, low-contrast grey body text, or stock-photo backgrounds.

### Sync check

Run from a directory containing both checkouts; no output means the cores match:

```sh
diff <(sed -n '/BRAND-CORE:START/,/BRAND-CORE:END/p' aidevops/DESIGN.md) <(sed -n '/BRAND-CORE:START/,/BRAND-CORE:END/p' aidevops.sh/DESIGN.md)
```

<!-- BRAND-CORE:END -->

## Colors

App surfaces apply the Brand core tokens. The shipped GUI (`packages/gui-web/src/styles.css`) expresses the accent as `--accent-hue: 191` with theme-specific saturation/lightness, supports light and dark themes plus medium/high contrast modes, and uses `Inter` via `--font-family-app`. New app tokens must stay on hue 191 and map to a Brand core role.

App-specific rules:

- The YAML front matter is the dark projection: `outline` (`#12272c`), `outline-hover` (`#2b5b66`), `primary-subtle` (`#102327`), `secondary` (`#dbdbdb`), and `muted` (`#a8a8a8`) are the Brand core alpha values pre-composited over black. In CSS, prefer the alpha forms so borders pick up the surface beneath.
- Status colours: success `#56d364`, warning `#d29922`, error text `#ff7b72`, destructive fill `#da3633` with white text. Use them for state, never for primary actions or decoration.
- Info notifications use the accent cyan, not GitHub blue.

## Typography

- App UI: Inter at 14px base (`--font-size-app`), body 400, labels/buttons 600-700.
- Scale: display 48px/700 for report covers and artwork headlines; large heading 28px/700; card titles 18px/600; body 14px/400; metadata 12px (never below 12px, and only muted for non-critical text).
- Commands, paths, and logs use the Menlo stack in cyan or primary text on the code surface.

## Layout

Use a 4px base with an 8px rhythm:

- Page padding 24px on dashboard-like pages; grid gap 16px; card padding 16-24px.
- Dashboard cards use `repeat(auto-fill, minmax(300px, 1fr))`.
- Workspace scroll containers and page/form grids use content-sized rows (`align-content: start`, form grid items `align-items: start`) so cards and controls never stretch vertically to fill spare viewport space.
- Form controls fill their column with a 44px minimum height; labels stay attached to controls with an 8px gap.
- Sidebar width: 420px default, 320px minimum, 640px maximum (`.opencode/ui/chat-sidebar/constants.ts`).
- Message and panel content keeps a readable max width near 600px outside dashboard grids.

## Elevation & Depth

- Depth is border-led in operational UI: cyan-tinted hairline borders over near-black surfaces; hover strengthens the border (`0.42` alpha) rather than moving content.
- Soft black shadows are for floating panels, dialogs, the app icon, and primary buttons; the GUI's `--shadow-soft` / `--glass-panel-shadow` are the app implementations.
- Cyan glows belong to brand moments (launch/empty states, hero areas, artwork), not to dense data views.

## Shapes

- 6px: tabs, code chips, small inline elements.
- 10px: buttons and compact controls.
- 12px: inputs, command pills, panels, report containers.
- 16px: cards and large surfaces.
- Full radius: status badges and pills.
- App icon tile radius is 22% of the tile edge (`188/848`).

## Components

- **Page shell:** black background, white text, Inter, 24px padding.
- **Cards:** raised surface, cyan-tinted border, 16px radius, 16-24px padding; hover strengthens the border.
- **Inputs, selects, textareas:** macOS-inspired inset fields - raised dark surface, subtle top highlight, 1px border, 12px radius, 8px 12px padding, 38-44px height, subdued disabled text, cyan focus ring. Dropdowns keep the same shell with a compact chevron.
- **Primary buttons:** cyan fill with `#001014` text; hover `#8ce8ff`; pressed `#42c8e8`.
- **Secondary buttons:** accent-subtle fill, primary text colour; hover accent-hover fill.
- **Danger buttons:** `#da3633` fill with white text; reserve for destructive actions and always label the consequence.
- **Status badges:** 4px 8px padding, full radius, 12px/600, coloured text or dot on a raised surface plus a text label.
- **Command pills:** Menlo in cyan on the code surface, copy affordance on the right, extra right padding.
- **Provider and integration cards:** group by auth or service family, show provider/account counts, render recommendations with an explicit thumbs-up badge plus text, and keep connection controls metadata-only until audited write routes exist.
- **Terminal session status glyphs:** show ⚪ from the first submitted root-session message and preserve it through descriptive title generation, 🔴 while retrying after errors, 🟡 when a permission decision is required, and 🟢 when the root session is awaiting input. Retain the descriptive title and opt-out so colour is never the only status affordance; keep glyphs out of stored session titles so issue/PR prefixes remain first in search results.

### Secrets and Vault access

- Treat Secrets as an operational metadata workspace, not a password manager. Its hierarchy is: explicit Vault state and safe action, value-custody boundary, aggregate readiness cards, then protected reference inventory.
- Locked views may show already-approved aggregate counts and readiness classes, but never reference names, usernames, provider identifiers, paths, masked fragments, prefixes, suffixes, lengths, checksums, values, or copy/reveal controls.
- Unlocked views may show reference names plus non-sensitive configured, missing, or unchecked health. Every row states that values are never displayed and routes management to a secure helper rather than a browser form.
- Distinguish `uninitialized`, `locked`, `unlocked`, `corrupted`, and `unknown` visually and in text. Setup is offered only after authoritative uninitialized metadata; helper errors, partial/legacy responses, and loading states must never open setup.
- Browser dialogs never collect Vault credentials. Desktop actions send only the fixed `init`, `unlock`, or `lock` enum to an AppKit overlay. The native wrapper owns the PTY and accepts passphrases only in `NSSecureTextField` after terminal echo is off; terminal streams and input never cross the WebKit bridge. The direct `aidevops vault init|unlock|lock` CLI remains an equivalent fallback.
- While the secure overlay is active, exclude the window from OS screen capture, disable app/page screenshots, cancel on close, quit, sleep, or session deactivation, and clear native input/output buffers on every exit.
- Populate unlocked reference inventory only from the deterministic names-only helper contract. Validate bounds, ordering, names, backend health, helper ownership, and a post-read unlocked state; locked, unknown, malformed, timed-out, and lock-raced responses clear names immediately.
- Use compact border-led cards, fluid 210px minimum metric/capability grids, a desktop table that becomes labelled cards below 720px, cyan primary setup/unlock actions (the standard primary button), and visible focus rings even when decorative borders are hidden.

## Logo and icon rules

App-specific rules; construction values live in the Brand core.

- Use the prompt-glyph mark for dock icons, launch/loading states, sidebar/header marks, and generated artwork. Never the old `AI` letter mark.
- Buzz specialist avatars reuse the circular avatar geometry from the Brand core. Assign one reviewed hue per stable `agent_id` across the spectrum while preserving the canonical saturation, lightness, near-black background, glow, rings, and wave accents; the Aidevops framework guide remains canonical cyan.
- Specialist avatar hues are decorative identity cues, not status, authority, risk, provider, or workload indicators. Keep assignments deterministic and source/display-name independent, inline them as bounded SVG data URLs for portable Buzz snapshots, and preserve text alternatives in the host interface.
- Distribute specialist hues across the full spectrum in a high-separation display order rather than a monotonic rainbow sequence; neighbouring cards should remain distinguishable at small avatar sizes while the Aidevops guide stays canonical cyan.
- The 3D Modelling, Audio, and Video primary avatars use stable hues 23°, 304°, and 177° respectively, filling unassigned spectrum positions without changing existing agent identities or the canonical cyan guide.
- Buzz specialist mention names use lowercase dashed `role-host` identifiers, such as `aidevops-marcus-macbook-pro-01` and `seo-marcus-macbook-pro-01`, so typing and provisioning-host identity remain predictable. A host suffix is not proof that model execution is local or on-device; do not encode status, provider, model, permission, or privacy claims in the name.
- Decorative duplicate icons are hidden from assistive technology.
- Third-party provider logos may use maintained icon libraries such as `react-icons`/Simple Icons when available; otherwise use a consistent monochrome glyph or initials fallback and keep the brand name visible in text.
- The desktop app launch path shows one branded loading treatment: defer native WebKit startup to the web loading shell, avoid replacing it with a second React-only loader during hydration, and use a compact cyan `>_` prompt followed by `Preparing local GUI` in Inter for any startup status chip.

## Agent-made artwork

Applies to Affinity (`tools/design/affinity.md`), report covers, flyers, and other generated brand artwork:

- Start from the Brand core look properties and artwork composition; build the app icon with all five construction layers (gradient tile, radial glow, ring, shadow, `#8ce8ff` glyph).
- Use Inter (Bold/Black for headlines) and Menlo for commands; approved messaging only unless the brief supplies copy.
- One cyan primary CTA or command pill per piece, `#001014` label text. No green, blue, or second accent.
- Render and inspect before export; export vector PDF/SVG with live text plus a raster PNG preview.

## README hero counts

- Preserve the existing `1200x630` cyan terminal hero, headline, background, and installation copy in `docs/assets/og-image.png`. The editable `docs/assets/og-stats.svg` overlay replaces only the statistics card; do not regenerate the whole image just to change numbers.
- Hero copy edits use the transparent `docs/assets/og-copy.svg` browser overlay. Keep the capability top-line centred at `x=600` with measured bounds `x=82`, width `1036`, using 17px/800 type and `1.95px` letter spacing. Set the two-line Brand core headline in 30px/760 type with `-1.25px` letter spacing, and the Brand core supporting line at `x=268 y=347` in 23px/500 type at 76% white (as in the website `og-image.svg`). Copy rendering may change pixels only within the documented top-line (`1038x24+81+43`), headline (`851x79+267+230`), and supporting-line (`851x34+267+320`) rectangles; statistics and all other content remain pixel-identical.
- Use the user-approved, familiar hero labels exactly: **main agents**, **sub agents**, **helper scripts**, and **slash commands**. Keep the detailed inventory definitions in the README and SVG description rather than replacing these labels with internal terminology. Never add overlapping categories into a combined skills/helpers total. Keep each label directly beneath its figure, with cyan numbers, high-contrast grey labels, and the original rounded near-black card.
- The inventory is defined in `.agents/scripts/readme_inventory.py` and `readme_inventory_sources.py`, using tracked sources only. Main agents reuse `agent_config.SKIP_FILES`. Sub agents measure individually path-addressable Markdown modules, including callable skills, workflows, templates and references; do not require `mode: subagent` metadata or a narrow directory whitelist. Use the filename rules in `generate-opencode-agents.sh` (`*.md` excluding `README.md`, `AGENTS.md` and `*-skill.md` wrappers), plus demoted root profiles. Exclude test/fixture, generated/vendor/runtime source paths and symlink aliases. This is a source-module count, not a count of unique flattened runtime registrations.
- Helper scripts include production script/source files and supporting modules in `.agents/scripts/` across the scripting-language suffixes listed in `SCRIPT_SUFFIXES`, plus executable extensionless shebang scripts. Do not restrict them to `*-helper` filenames. Exclude tests, fixtures, generated/vendor files, TypeScript declarations and aliases. Slash commands are direct Markdown entry points in `scripts/commands`, including aliases only when their targets are tracked regular files inside `.agents`. A regular command source can also be a sub-agent module; disclose overlap instead of summing categories.
- Display the exact main-agent count; round sub agents down to 50 and helper scripts/slash commands down to 10. Small counts below those increments stay exact rather than showing `0+`. Keep README prose, architecture-tree comments, image alt text, SVG figures, and the exact inventory summary aligned. Do not relabel a broader file count as one of these categories.
- Audit with `bash .agents/scripts/readme-helper.sh counts --inventory` (counts, definitions, and every included path). `counts --json` gives exact totals; `counts --approx` gives hero figures. The Git index selects paths and modes; current worktree files validate target type, command aliases and extensionless shebangs. Stage new/deleted source paths and executable-bit changes before counting; untracked/deployed/custom files are excluded. `check` validates every matching README claim and all four structured SVG figures plus metadata. `update --apply` refreshes both text sources from the same inventory; it does not render or verify the PNG, which requires the visual step below.
- Render the SVG in an isolated browser at a `1200x630` viewport with zero page margins, transparent page background, and device scale 1. Capture the viewport with Playwright's `omitBackground: true` into a temporary `og-stats.png`, then composite that raster over the existing hero: `magick docs/assets/og-image.png "$OVERLAY_PNG" -composite -strip PNG24:docs/assets/og-image.png`. Set `OVERLAY_PNG` to the captured temporary PNG. Browser rendering avoids dependence on ImageMagick's optional font delegates.
- Inspect the `1200x630` output and verify the difference against the previous committed PNG with alpha disabled: `git show HEAD:docs/assets/og-image.png | magick - docs/assets/og-image.png -alpha off -compose difference -composite -format '%@' info:`. Changed pixels must stay within the card's antialiased bounds (`1038x104+81+385`). Commit the SVG, PNG, README, and counting-rule changes together. The README's separate LOC/language/dependency badges use `bash .agents/scripts/repo-metrics-helper.sh generate --legacy-badge-dir docs/metrics/badges`; those broader metrics are not the four hero categories.

## Design capture during harness sessions

- Treat `DESIGN.md` as the source of truth for visual direction, branding, UI/UX preferences, iconography, and generated brand handoffs.
- When a harness session receives, discovers, or implements design preferences, update `DESIGN.md` in the same PR as the UI/branding change. Brand core changes need matching PRs in both `marcusquinn/aidevops` and `marcusquinn/aidevops.sh`.
- If `DESIGN.md` is missing, create one or add a worker-ready task with the known files, observed preferences, and verification checklist.
- PR summaries for branding/UI/UX work should call out the `DESIGN.md` update or explicitly explain why no design-system change was needed.

## Do's and Don'ts

Do:

- Use Brand core roles and the YAML tokens before adding new hex values; new values stay on accent hue 191.
- Keep dashboards compact, structured, and border-defined, with cyan reserved for primary action, focus, selection, and key figures.
- For chart-heavy operational dashboards, prefer OpenPanel-style space efficiency and Bklit-style compact chart cards: KPI header, tiny delta, bar/sparkline combination, and dense legends that keep Pulse and worker health scannable at a glance.
- Brand charts use cyan series on black/near-black with muted grid lines; charts embedded in GitHub READMEs may match GitHub's light and dark surfaces, include accessible SVG titles/descriptions, and remain legible at README width without interaction.
- Preserve high contrast and readable 12px+ metadata.
- Keep generated reports and brand handoffs free of private local paths, secrets, raw transcripts, and unrelated repo names.

Don't:

- Use green or blue for primary actions, or GitHub-dark surface greys for brand surfaces.
- Add light-only UI surfaces without a matching dark-mode treatment.
- Hide error state in colour alone; pair colour with text labels.
- Put glassmorphism, rainbow gradients, or heavy shadows into operational tooling; cyan glow belongs to brand moments.
- Use skeleton placeholder brand values in UI or generated guidelines.

## Profile contribution chart

- Use repository-hosted, first-party SVGs for cumulative **Total Contributions**, not a third-party embed with a narrower metric.
- Match GitHub's light and dark README surfaces. This chart intentionally mirrors GitHub's contribution green, a subtle area fill, system typography, and an accessible title/description; no external fonts or executable SVG content. It is a GitHub-native exception, not a brand surface.
- Show the exact total, source, UTC data cutoff, and last successful update date. Publish aggregate monthly counts only, never private repository names or events.
- Keep the chart linked to the user's `commit-history.com` Total view, with a visible verification link and raw aggregate chart data alongside it.
- Request a new tab with `target="_blank" rel="noopener noreferrer"` on compatible renderers. GitHub strips those attributes: disclose Ctrl/Cmd-click rather than claim a forced new tab.
- Refresh once per UTC day through the existing profile updater. Retain the last successful chart on data failure and publish light/dark assets and README together.

## Responsive Behaviour

- Dashboard grids use auto-fit/auto-fill patterns and collapse to one column below the card minimum width.
- Chat sidebars keep the 320px-640px clamp and default to 420px.
- Button rows may wrap; primary and destructive actions remain visually distinct when wrapped.
- Generated report handoffs print cleanly to A4, US Letter, and 16:9 slides without clipped tables.
- Maintain keyboard and screen-reader access for every control; existing ARIA labels in `.opencode/ui/chat-sidebar/constants.ts` are the naming pattern.
- Operator workbenches use a compact left navigation rail that becomes a horizontally scrollable tab row below 700px. Evidence tables may scroll horizontally, while long source text wraps inside its card; all view actions retain 44px touch targets and visible cyan focus.

## Creative model inspector

- `.agents/templates/creative-viewer.html` uses a compact dark control rail beside
  an unframed, neutral-lit model stage. The stage lighting/background belongs to
  artifact inspection, not a new light-only operational theme.
- Below 700px, put the model above the controls; keep controls at least 44px high,
  allow normal page scrolling and retain accessible part/view selectors.
- Do not auto-spin models. Render on interaction/resize, retain visible focus and
  distinguish view-only changes from authoritative geometry configuration.
- Exports and verification state remain explicit. Missing outputs are unavailable,
  not fabricated download links or an implication of production certification.

## Agent Prompt Guide

When implementing AI DevOps UI or artwork:

1. Read `DESIGN.md` before changing any dashboard, sidebar, generated report, browser-facing interface, or brand artwork. For website work, read `marcusquinn/aidevops.sh` `DESIGN.md` instead; the Brand core is shared.
2. Reuse the YAML token names and Brand core roles. If a new state is needed, add a semantic token on hue 191 and explain the evidence source.
3. Match the look properties: black first, one cyan accent used sparingly, cyan-tinted borders, soft cyan glow only for brand moments, Inter plus Menlo, cyan primary action with `#001014` text, green/amber/red for status only.
4. Verify contrast for new text/background pairs and keep focus indicators visible.
5. Update this file whenever branding/UI/UX preferences change during a harness session, include it in the same PR, and keep the Brand core identical in both repos.
6. Regenerate brand guideline artifacts after changing this file with `aidevops design guidelines . --pdf`.
