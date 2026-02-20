---
description: Mobile app UI/UX design standards - aesthetics, animations, icons, branding, accessibility
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Mobile App UI Design - Beautiful by Default

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Ensure every app is simple, clean, stylish, and beautiful
- **Principle**: Aesthetics drive downloads; usability drives retention
- **Standards**: Apple HIG, Material Design 3, WCAG 2.1 AA accessibility
- **Tools**: Vision AI for asset generation, Remotion for animated previews, Gemini for SVG design

**Shared with**: `browser-extension-dev.md` (same design principles apply to extensions)

**Design pillars**:

1. **Simple** - Remove everything that isn't essential
2. **Clean** - Generous whitespace, clear hierarchy, consistent spacing
3. **Stylish** - Modern typography, refined colour palettes, subtle animations
4. **Beautiful** - Attention to detail in every pixel, delightful micro-interactions
5. **Accessible** - Usable by everyone, passes WCAG 2.1 AA

<!-- AI-CONTEXT-END -->

## Design System Foundation

### Colour Palette

Every app needs a coherent colour system:

| Role | Purpose | Example |
|------|---------|---------|
| Primary | Brand colour, CTAs, active states | Blue, purple, coral |
| Secondary | Supporting actions, accents | Complementary to primary |
| Background | Screen backgrounds | White/near-white (light), black/near-black (dark) |
| Surface | Cards, sheets, elevated elements | Slightly tinted background |
| Text | Primary content | Near-black (light), near-white (dark) |
| Text secondary | Labels, captions, metadata | Grey |
| Success | Positive actions, confirmations | Green |
| Warning | Caution states | Amber/orange |
| Error | Destructive actions, errors | Red |
| Border | Dividers, input borders | Light grey |

**Dark mode is mandatory**. Design both light and dark themes from the start. Use semantic colour tokens, not hardcoded values.

### Typography

- **System fonts preferred** (SF Pro for iOS, Roboto for Android) — they render best on each platform
- **Custom fonts** only when brand identity requires it
- **Type scale**: Title, Headline, Body, Caption, Footnote — no more than 5 sizes
- **Line height**: 1.4-1.6x for body text, 1.2x for headings
- **Weight contrast**: Use weight (not size) to create hierarchy where possible

### Spacing and Layout

- **8px grid**: All spacing in multiples of 8 (8, 16, 24, 32, 48)
- **Safe areas**: Always respect device safe areas (notch, home indicator, status bar)
- **Touch targets**: Minimum 44x44pt (iOS) / 48x48dp (Android)
- **Content width**: Max 600px for readability on tablets
- **Card padding**: 16px minimum internal padding

### Icons

**App icon requirements**:

- Must be distinctive at 29x29pt (smallest size) and 1024x1024pt (App Store)
- No text in the icon (illegible at small sizes)
- Simple, recognisable silhouette
- Consistent with app's colour palette and mood
- Test against competitor icons — must stand out in search results

**In-app icons**:

- SF Symbols (iOS) or Material Icons (Android) for consistency
- Consistent weight and size throughout the app
- Use filled variants for selected/active states, outlined for inactive

### Animations and Micro-Interactions

Animations should feel natural and purposeful:

| Type | When | Duration |
|------|------|----------|
| Page transitions | Navigation between screens | 250-350ms |
| Button feedback | Tap response | 100-150ms |
| Loading states | Data fetching | Skeleton screens, not spinners |
| Success feedback | Completed action | 200-400ms with haptics |
| Error feedback | Failed action | Shake animation + haptics |
| List items | Enter/exit | Staggered 50ms delay per item |
| Pull to refresh | Content refresh | Spring physics |

**Haptic feedback** should accompany meaningful interactions:

- Light impact: Button taps, toggles
- Medium impact: Successful actions, selections
- Success: Task completion, achievement
- Warning: Approaching limits, caution
- Error: Failed actions, destructive confirmations

### Onboarding Screens

See `mobile-app-dev/onboarding.md` for detailed guidance.

Key design principles:

- 3-5 screens maximum
- One concept per screen
- Large, clear illustrations or animations
- Minimal text (headline + one sentence)
- Skip option always visible
- Progress indicator (dots or bar)

## Asset Generation

### App Icons

Use vision AI tools for icon generation:

- `tools/vision/image-generation.md` for AI-generated icon concepts
- Gemini Pro for SVG icon design (strong at clean vector graphics)
- Test multiple concepts with model contests for best results

### Screenshots and Preview Videos

- `tools/browser/remotion-best-practices-skill.md` for animated App Store preview videos
- `tools/vision/` for marketing graphics and feature illustrations
- Playwright device emulation for automated screenshot capture across devices

## Design Inspiration Resources

See `tools/design/design-inspiration.md` for the full catalogue of 60+ design inspiration resources.

**Quick picks for mobile app design**:

| Resource | URL | Best For |
|----------|-----|----------|
| **Mobbin** | https://mobbin.com | Real-world mobile UI patterns, flows, and screenshots |
| **Screenlane** | https://screenlane.com | Mobile UI screenshots by component type (free) |
| **Page Flows** | https://pageflows.com | Recorded user flows with annotations |
| **PaywallPro** | https://paywallpro.app | 46,000+ iOS paywall screenshots |
| **Apple HIG** | https://developer.apple.com/design/ | iOS design standards |
| **Material Design** | https://m3.material.io/ | Android design standards |

**Research workflow**: Search Mobbin/Screenlane for your app category. Study onboarding flows, navigation patterns, paywall designs, empty states, and dark mode implementations from top-rated apps. Use browser tools to capture screenshots for reference.

### Illustration Style

Choose one illustration style and maintain consistency:

- **Flat**: Clean, modern, minimal shadows
- **3D**: Depth, lighting, premium feel
- **Hand-drawn**: Warm, approachable, personal
- **Geometric**: Abstract, tech-forward, clean
- **Photographic**: Real imagery, authentic feel

## Platform-Specific Guidelines

### iOS (Apple Human Interface Guidelines)

- Use native navigation patterns (tab bar, navigation stack)
- Respect system gestures (swipe back, pull down to dismiss)
- Support Dynamic Type for accessibility
- Use SF Symbols for consistent iconography
- Support both orientations unless app specifically requires one

### Android (Material Design 3)

- Use Material You dynamic colour theming
- Bottom navigation bar for primary destinations
- FAB (Floating Action Button) for primary actions
- Support edge-to-edge display
- Predictive back gesture support

## Accessibility Checklist

- [ ] Colour contrast ratio >= 4.5:1 for text, >= 3:1 for large text
- [ ] All interactive elements have accessibility labels
- [ ] Screen reader navigation order is logical
- [ ] Touch targets are >= 44x44pt (iOS) / 48x48dp (Android)
- [ ] Animations respect "Reduce Motion" system setting
- [ ] Text scales with Dynamic Type / system font size
- [ ] No information conveyed by colour alone
- [ ] Focus indicators visible for keyboard/switch navigation

See `services/accessibility/accessibility-audit.md` for comprehensive auditing.

## Related

- `mobile-app-dev/onboarding.md` - Onboarding flow design
- `mobile-app-dev/assets.md` - Asset generation and management
- `tools/vision/overview.md` - Image generation tools
- `tools/browser/remotion-best-practices-skill.md` - Animated previews
- `tools/ui/tailwind-css.md` - Tailwind CSS (web and NativeWind for React Native)
- `tools/ui/shadcn.md` - shadcn/ui component library
- `tools/ui/i18next.md` - Internationalisation
- `services/accessibility/accessibility-audit.md` - Accessibility auditing
