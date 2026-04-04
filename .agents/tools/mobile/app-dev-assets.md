---
description: Mobile app assets - icons, splash screens, screenshots, preview videos, graphics generation
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# App Assets - Icons, Graphics, and Preview Media

<!-- AI-CONTEXT-START -->

## Quick Reference

| Asset | Tool | Notes |
|-------|------|-------|
| App icon | Vision AI + Gemini Pro (SVG) | Model contests for best results |
| Splash screen | Vision AI | Match app colour palette |
| Screenshots | ios-simulator-mcp / agent-device | Automated capture across devices |
| Preview video | Remotion | Up to 30s (App Store / Play Store) |
| Marketing graphics | Vision AI | Social media, website |
| In-app illustrations | Vision AI / Gemini SVG | Consistent style |
| Animations | Lottie / Remotion | Onboarding, transitions |

<!-- AI-CONTEXT-END -->

## App Icon Design

### Requirements

| Platform | Size | Format |
|----------|------|--------|
| iOS App Store | 1024x1024 | PNG, no alpha, no rounded corners (system applies mask) |
| iOS app | 180x180 (60pt @3x) | PNG |
| Android Play Store | 512x512 | PNG, 32-bit with alpha |
| Android adaptive | 108x108dp (foreground + background layers) | PNG |

### Design Principles

- **Recognisable at 29pt**: Must work at smallest size
- **No text**: Illegible at small sizes, doesn't localise
- **Simple silhouette**: Identifiable shape even as a shadow
- **Distinctive colour**: Stand out among competitors in search results

### Generation Workflow

1. Describe the concept (e.g. "minimalist lotus silhouette, soft purple gradient, dark background")
2. Generate with multiple models via model contests
3. Use Gemini Pro for clean SVG vector output
4. Refine with Nano Banana AI image editing
5. Test at 29pt, 60pt, and 1024pt; verify against competitor icons

See `tools/vision/overview.md` for the full vision AI decision tree.

## Splash Screen

- Match app's primary colour or gradient; include icon/logo centred
- Keep simple — visible for < 2 seconds; support light and dark mode
- Expo: `app.json` → `splash`; Swift: `Assets.xcassets` or LaunchScreen storyboard

## App Store Screenshots

```bash
# agent-device
agent-device open "My App" --platform ios --device "iPhone 16 Pro Max"
agent-device screenshot ./screenshots/home-6.9.png

# ios-simulator-mcp: screenshot tool saves to specified path
```

- Show app in use (not empty states); first screenshot shown in search results
- Add short benefit-focused captions; consistent style; localise for target markets
- Show light and dark mode if supported

See `tools/mobile/app-dev/publishing.md` for required sizes.

## App Store Preview Videos

- Duration: up to 30s (App Store and Play Store)
- Content: core value in action; screen recording + animated captions + transitions
- Audio: optional background music (no voiceover required)

Remotion workflow: capture simulator recordings → compose with captions → add transitions → render → upload to App Store Connect / Play Store Console.

See `tools/browser/remotion-best-practices-skill.md` for Remotion patterns.

## In-App Graphics

- **Onboarding**: consistent style, simple illustrations tied to screen message; consider Lottie for movement
- **Empty states**: friendly illustration + clear CTA ("Add your first item"); never leave blank
- **Error states**: empathetic illustration, plain-language explanation, actionable next step

## Related

- `product/ui-design.md` - Design standards
- `tools/mobile/app-dev/publishing.md` - Screenshot size requirements
- `tools/vision/overview.md` - Image generation tools
- `tools/browser/remotion-best-practices-skill.md` - Remotion best practices
- `tools/video/remotion.md` - Programmatic video creation
- `tools/video/` - Video generation and enhancement
- `content/video-wavespeed.md` - 200+ video generation models
- `content/video-real-video-enhancer.md` - Upscale and enhance video
- `content/video-higgsfield.md` - Seedance 3.0 AI video generation
