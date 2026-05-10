---
name: create-screenshots
description: Create polished branded static PNG screenshots from supplied or browser-captured UI, using DESIGN.md branding, clean wallpaper backgrounds, and windowed foreground treatments.
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

# Create Screenshots

Create static, production-ready PNG screenshots for launch pages, docs, app stores, social posts, and PR/demo assets. Use the same brand-aware capture and composition approach as onboarding videos, but optimize for a single clear image.

## Quick Reference

- **Use when**: the user asks for static product screenshots, branded app screenshots, demo images, launch visuals, or PNG exports.
- **Output**: `.png` image files, plus optional source project or composition files when generated programmatically.
- **Style**: clean wallpaper-style background with a crisp UI slice or windowed screenshot in the foreground, rounded corners, soft shadow, subtle border, and brand-complementary colour treatment.
- **Related agents**: `tools/browser/browser-automation.md`, `tools/design/design-md.md`, `tools/vision/image-generation.md`, `tools/vision/image-editing.md`, `tools/video/create-onboarding-video.md`.

## Intake

Collect before creating assets:

1. **Purpose and placement** — website hero, docs, app store, social, README, PR evidence, or investor deck.
2. **Source UI** — uploaded screenshot, local file, user-provided URL, local dev server, or authorised live browser session.
3. **Target state** — what data, page, modal, component, or interaction state must be visible.
4. **Brand source** — `DESIGN.md` first; otherwise ask for brand colours, typography, logo, and mood.
5. **Dimensions** — exact canvas size, aspect ratio, dark/light mode, and safe areas.
6. **Privacy** — confirm whether real data is acceptable. Prefer seeded, anonymised, or demo data.

Ask when browser access, target state, dimensions, or privacy expectations are unclear.

## Capture Workflow

1. Read project `DESIGN.md` when present. Extract palette, background, surface, radius, shadows/elevation, typography, and tone.
2. Use `tools/browser/browser-automation.md` for authorised browser capture. Choose Playwright or dev-browser for repeatable captures; use Chrome DevTools or Stagehand when inspection is needed.
3. Set deterministic viewport, theme, timezone, locale, feature flags, and seeded data where possible.
4. Capture the smallest useful region: selector screenshot, component screenshot, modal, card, chart, or window. Capture full viewport only when the composition requires it.
5. Avoid `fullPage: true` for AI review or draft inspection; use bounded captures and resize large images before analysis.
6. Save raw captures under `screenshots/raw/` or the user's requested asset path, then compose final images under `screenshots/final/` or the requested output path. For any user-provided destination, resolve the real path after creating or checking the parent directory and confirm it remains within the project or another explicitly allowed asset directory; this prevents path traversal through `..` segments or symlinks.

## Composition Rules

- **Focal element first**: the foreground UI must communicate the product value without requiring a caption.
- **Wallpaper background**: generate a brand-complementary gradient, mesh, abstract surface, or clean desktop-like background from `DESIGN.md` tokens. Keep contrast low enough that the foreground remains dominant.
- **Foreground treatment**: apply rounded corners, subtle border, soft drop shadow, and optional ambient glow. Match source UI radius and elevation where possible.
- **Brand consistency**: use `DESIGN.md` colours, typography, spacing, and tone. If generating a wallpaper, derive it from primary/accent/neutral tokens and add complementary hues sparingly.
- **Data hygiene**: remove secrets, personal data, private repo names, tokens, internal URLs, and customer information unless the user explicitly confirms publication scope.
- **No fake UI**: do not invent product screens when a real capture is expected. If a designed mock is desired, label it as a mockup.

## Recommended Variants

Offer variants when useful:

- **Hero**: 16:9 or 3:2 canvas, large windowed screenshot, spacious brand wallpaper.
- **Social**: 1200×630, 1080×1080, or 1080×1350, headline-safe margin, strong contrast.
- **Docs/README**: transparent or neutral background, minimal shadow, compressed but readable.
- **App Store / mobile**: portrait device or cropped app screen, platform-safe margins, no misleading device chrome.
- **PR evidence**: unstyled factual screenshot plus optional polished marketing variant.

## Tooling Guidance

- For browser capture, prefer selector screenshots and explicit viewport setup.
- For image generation, use `tools/vision/image-generation.md` only for non-product backgrounds or abstract wallpaper, not for factual UI.
- For editing/compositing, use deterministic scripts or a checked-in source file when the result must be reproducible.
- For animated variants, hand off to `tools/video/create-onboarding-video.md`.

## Verification

Before claiming completion:

1. Confirm final PNG paths and dimensions.
2. Inspect the image for cropped content, blurry scaling, unreadable text, or over-strong shadows.
3. Verify brand fit against `DESIGN.md` or the user's supplied brand guidance.
4. Verify sensitive data is absent or intentionally present.
5. Provide the raw capture path, final path, and command or source method used.
