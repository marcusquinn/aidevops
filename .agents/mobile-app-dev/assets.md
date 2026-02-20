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

# App Assets - Icons, Graphics, and Preview Media

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Generate and manage app icons, splash screens, screenshots, and preview videos
- **Icon generation**: Vision AI models, Gemini Pro for SVG, model contests for best results
- **Preview videos**: Remotion (React-based video creation)
- **Screenshots**: Automated via Playwright emulation or simulator tools

**Asset generation stack**:

| Asset | Tool | Notes |
|-------|------|-------|
| App icon | Vision AI + Gemini Pro (SVG) | Test multiple models via contests |
| Splash screen | Vision AI | Match app colour palette |
| Screenshots | ios-simulator-mcp / agent-device | Automated capture across devices |
| Preview video | Remotion | Up to 30s for App Store |
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
- **Consistent with brand**: Match app's colour palette and mood

### Generation Workflow

1. **Describe the concept**: "A minimalist icon for a meditation app, using a lotus flower silhouette in soft purple gradient on a dark background"
2. **Generate with multiple models**: Use model contests to compare outputs from different vision AI models
3. **Gemini Pro for SVG**: Particularly strong at clean vector icon design
4. **Nano Banana for editing**: Refine generated icons with AI image editing
5. **Test at multiple sizes**: Verify readability at 29pt, 60pt, and 1024pt
6. **Test against competitors**: Place icon alongside competitor icons to verify it stands out

See `tools/vision/overview.md` for the full vision AI tool decision tree.

## Splash Screen

- Match app's primary colour or gradient
- Include app icon or logo (centred)
- Keep it simple — users see it for < 2 seconds
- Support both light and dark mode
- Expo: Configure in `app.json` under `splash`
- Swift: Configure in `Assets.xcassets` or via LaunchScreen storyboard

## App Store Screenshots

### Automated Capture

Use simulator tools to capture screenshots across devices:

```bash
# Using agent-device
agent-device open "My App" --platform ios --device "iPhone 16 Pro Max"
agent-device screenshot ./screenshots/home-6.9.png

# Using ios-simulator-mcp
# screenshot tool saves to specified path
```

### Screenshot Design

- **Show the app in use** (not empty states)
- **Add captions** above or below the screenshot (short, benefit-focused)
- **Consistent style** across all screenshots
- **First screenshot is critical** (shown in search results)
- **Show both light and dark mode** if the app supports it
- **Localise** for target markets

### Required Sizes

See `mobile-app-dev/publishing.md` for full screenshot size requirements.

## App Store Preview Videos

Use Remotion to create animated preview videos:

- **Duration**: Up to 30 seconds (App Store), 30 seconds (Play Store)
- **Content**: Show the app's core value in action
- **Style**: Screen recording with animated captions and transitions
- **Audio**: Optional background music (no voiceover required)

See `tools/browser/remotion-best-practices-skill.md` for Remotion patterns.

### Remotion Workflow

1. Capture screen recordings from simulator
2. Create Remotion composition with recordings + captions
3. Add transitions between scenes
4. Render at required resolution
5. Upload to App Store Connect / Play Store Console

## In-App Graphics

### Onboarding Illustrations

- Consistent style throughout onboarding
- Simple, clear, related to the screen's message
- Consider Lottie animations for movement
- Generate with vision AI, refine with image editing tools

### Empty States

- Friendly illustration when no data exists
- Clear call to action ("Add your first item")
- Don't leave screens blank

### Error States

- Empathetic illustration (not just an error code)
- Clear explanation of what went wrong
- Actionable next step

## Video Assets

For apps that include video content or need promotional videos:

- `tools/video/wavespeed.md` - 200+ video generation models
- `tools/video/real-video-enhancer.md` - Upscale and enhance video
- `tools/video/remotion.md` - Programmatic video creation
- Seedance 3.0 via `tools/video/higgsfield.md` - AI video generation

## Related

- `mobile-app-dev/ui-design.md` - Design standards
- `mobile-app-dev/publishing.md` - Screenshot requirements
- `tools/vision/overview.md` - Image generation tools
- `tools/browser/remotion-best-practices-skill.md` - Video creation
- `tools/video/` - Video generation and enhancement
