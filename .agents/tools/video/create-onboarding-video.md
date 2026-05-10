---
name: create-onboarding-video
description: Create short branded onboarding, app preview, and feature-demo videos from screenshots or browser-captured UI slices, using Remotion, DESIGN.md branding, and clean wallpaper-style backgrounds.
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  grep: true
  webfetch: true
  task: true
model: sonnet
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Create Onboarding Video

Produce short, punchy onboarding videos that show one feature working. The output should feel like a polished App Store preview or product-launch clip: isolated UI moments, branded motion, clean desktop-like backgrounds, and windowed foreground screenshots or animations with soft drop shadows.

## Quick Reference

- **Use when**: the user asks to create an onboarding video, app preview, feature demo clip, product walkthrough snippet, launch animation, or short UI-first video.
- **Output**: Remotion project rendering MP4, plus optional portrait, landscape, and social variants.
- **Default format**: 1080×1920 portrait, 30fps, 3–8 seconds per beat, rarely over 30 seconds total.
- **Core style**: crop, mask, or extract the UI component that proves the feature works; avoid full-screen tours unless the user explicitly needs whole-screen context.
- **Related agents**: `tools/video/remotion.md`, `tools/browser/browser-automation.md`, `tools/design/design-md.md`, `tools/vision/image-generation.md`, `tools/vision/create-screenshots.md`.

## Intake

Do not start building until the evidence and intent are clear. Collect:

1. **Feature intent** — one or two sentences describing what the screen does and what user outcome the video should prove.
2. **Flow order** — the sequence of screens, interactions, or states.
3. **Source UI** — supplied screenshots, a local app URL, a staging URL from the user, or a browser session the user authorises you to inspect.
4. **State coverage** — 2–4 stills or captured states per beat: resting, interaction, result, and any important variants.
5. **Brand source** — project `DESIGN.md` first; otherwise ask for brand colour/accent, logo, font, and tone.
6. **Output target** — aspect ratio, duration, platform, file path, and whether an end card or CTA is needed.

Ask a focused question when stills, browser access, feature intent, or branding are missing. Do not invent proprietary UI from a description when screenshots or browser capture are required.

## Source and Brand Discovery

1. **Read `DESIGN.md`** in the project root when present. Extract colours, typography, radius, elevation, spacing, product tone, and agent prompt guidance.
2. If `DESIGN.md` is absent, use `tools/design/design-md.md` to create or derive a lightweight design brief before composing visuals.
3. Use browser automation only from authorised user-provided app URLs or local dev servers. Prefer `tools/browser/browser-automation.md` to choose Playwright, dev-browser, Chrome DevTools, or Stagehand.
4. Capture assets at render-friendly dimensions. Prefer UI slices, DOM elements, and state screenshots over full-page images. Avoid `fullPage: true` unless explicitly needed for the deliverable.
5. Store source stills under `public/<flow-or-screen>/<state>.png`. Treat `<flow-or-screen>` and `<state>` as user-provided path components: sanitize directory and file names, then validate that the resolved real path stays inside `public/` before writing. This prevents path traversal vulnerabilities. Document the selector, viewport, state setup, and capture command in the project README or notes.

## Visual Direction

- **Show the feature in action**: button tap, toggle flip, row reorder, modal reveal, chart fill, search completion, or success state.
- **Use UI pieces, not a screen recording**: isolate cards, sheets, rows, inputs, charts, or nav sections. Blur, crop, mask, or omit the rest.
- **Use clean wallpaper backgrounds**: generate or render brand-complementary gradients, soft mesh fields, subtle grain, abstract shapes, or light desktop-like surfaces that do not compete with the UI.
- **Foreground treatment**: place the cropped UI or windowed screenshot on the wallpaper with rounded corners, realistic drop shadow, soft border, and optional subtle reflection or ambient glow. Think CleanShot, Xnapper, Shottr, and modern product screenshots.
- **Wallpaper palette**: start from `DESIGN.md` primary/accent colours; add complementary hues, lower saturation for backgrounds, and preserve WCAG contrast for captions.
- **Motion**: prefer springs, masked reveals, shared-element swaps, crossfades, slides, scale, parallax, and depth. Avoid linear, generic slideshow motion.

## Shot Planning

For each beat, write a compact shot plan before code:

```text
Beat: <name>
Intent: <what this proves>
Source: public/<screen>/<state>.png or browser selector
Focal element: <button/card/input/etc.>
Motion: <cursor/tap/reveal/transition>
Caption: <short line or none>
Duration: <frames>
Transition out: <shared element/crossfade/etc.>
```

Rules:

- One feature per video. If the user lists unrelated features, propose separate videos.
- One clear idea per beat. Remove supporting UI that does not advance the proof.
- Captions, if used, are short headline callouts. Let the UI motion carry the message.
- Match the product's design language from `DESIGN.md` and source screenshots; do not restyle the app chrome arbitrarily.

## Remotion Build Rules

Load `tools/video/remotion.md` before authoring or modifying the composition. Apply these constraints:

- Use `spring()`, `interpolate()`, `useCurrentFrame()`, and `<Sequence>`/`<Series>`; never CSS transitions, timers, or React state for animation values.
- One `<Composition>` per onboarding flow; one sequence per beat.
- Put scene components in `src/scenes/`, reusable motion in `src/transitions/`, brand tokens in `src/brand.ts`, and wallpaper utilities in `src/wallpaper/` or equivalent.
- Load stills via `staticFile()` from `public/`.
- Crop with CSS masks, `overflow: hidden`, `clip-path`, object positioning, or pre-cropped assets.
- Expose width, height, fps, theme, and asset paths as props where practical.

## Caption and Pointer Rules

- Captions stay at a consistent top-of-frame position and remain visible for the whole beat.
- Captions rise from below with opacity in the first 10–14 frames; continuation beats with identical caption text keep the caption static to avoid flicker.
- Interactive beats need a visible pointer or tap indicator that leads the action. The pointer fades in near the focal center, moves in a single straight line to the target, taps, and only resets when the UI context changes.
- Multiple taps on the same UI should keep the pointer visible and glide directly from one target to the next.

## Verification

Before claiming completion:

1. Run the relevant Remotion build/render command and capture the output path.
2. Render at least one representative preview frame or short draft.
3. Verify visual alignment against `DESIGN.md`: colours, type, radius, elevation, and spacing.
4. Check readability at target platform size.
5. Ask the user which beats need slower timing, stronger crop, different wallpaper, or restaging.

## Provenance

Adapted from the public `create-onboarding-video` skill referenced by the user, with aidevops additions for `DESIGN.md`, authorised browser capture, and branded wallpaper-style foreground composition.
