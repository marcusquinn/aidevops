---
description: Expo (React Native) mobile app development - project setup, navigation, state, APIs
mode: subagent
tools: [read, write, edit, bash, glob, grep, webfetch, task, context7_*]
---

# Expo Development - Cross-Platform Mobile Apps

## Quick Reference

- **Docs**: Use Context7 MCP for latest Expo and React Native docs
- **CLI**: `npx create-expo-app`, `npx expo start`, `npx expo prebuild`
- **Router**: Expo Router (file-based routing, like Next.js for mobile)
- **Build**: EAS Build (`eas build`) or local (`npx expo run:ios`)

```bash
npx create-expo-app my-app --template tabs
cd my-app && npx expo start
```

**Key dependencies** (verify versions via Context7 before installing):

| Package | Purpose |
|---------|---------|
| `expo-router` | File-based navigation |
| `expo-notifications` | Push notifications |
| `expo-secure-store` | Secure credential storage |
| `expo-haptics` | Tactile feedback |
| `expo-image` | Optimised image loading |
| `expo-av` | Audio/video playback |
| `expo-sensors` | Accelerometer, gyroscope, etc. |
| `expo-location` | GPS and geolocation |
| `expo-camera` | Camera access |
| `expo-local-authentication` | Biometric auth (Face ID, fingerprint) |
| `expo-file-system` | Local file management |
| `expo-sharing` | Share content to other apps |
| `expo-clipboard` | Copy/paste |
| `expo-linking` | Deep links, URL schemes |
| `react-native-reanimated` | Performant animations |
| `react-native-gesture-handler` | Touch gestures |
| `@react-native-async-storage/async-storage` | Local data persistence |

## Project Structure

```text
app/
├── (tabs)/              # Tab navigator group
│   ├── index.tsx
│   ├── explore.tsx
│   └── profile.tsx
├── (auth)/              # Auth flow group
│   ├── login.tsx
│   └── register.tsx
├── (onboarding)/
│   ├── welcome.tsx
│   ├── setup.tsx
│   └── ready.tsx
├── _layout.tsx          # Root layout
├── +not-found.tsx       # 404 screen
└── modal.tsx
components/ui/           # Reusable UI components
components/forms/
constants/Colors.ts      # Colour tokens (light/dark: primary, background, surface, text, border, success, warning, error)
constants/Layout.ts      # Spacing, sizing
constants/Typography.ts  # Font families, sizes
hooks/                   # Custom React hooks
services/                # API clients
stores/                  # State management
assets/                  # Images, fonts, icons
```

## Development Standards

**TypeScript**: Always. Define interfaces for all props, state, and API responses.

**Styling**: `StyleSheet.create()` for performance. Design tokens in `constants/Colors.ts` with `light`/`dark` variants.

**Navigation** (Expo Router): `(group)` for layout groups, `[param]` for dynamic routes, `_layout.tsx` per group, `+not-found.tsx` for 404.

**Animations**: `react-native-reanimated` (not `Animated` API). Key APIs: `useSharedValue` + `useAnimatedStyle`, `withSpring`, `withTiming`, `Layout` animations. Pair with `expo-haptics`.

**State Management**:
- Simple: React Context + `useReducer`
- Complex: Zustand
- Server: TanStack Query (React Query)
- Persistent: `@react-native-async-storage/async-storage`
- Secure: `expo-secure-store` for tokens/credentials

**Performance**: `expo-image` over `Image`; `FlatList` with `getItemLayout`; `React.memo` for list items; `useDeferredValue` for heavy renders.

## EAS Build and Submit

```bash
npm install -g eas-cli && eas build:configure

eas build --platform ios --profile development    # iOS simulator
eas build --platform android --profile development # Android emulator
eas build --platform ios --profile preview         # TestFlight
eas build --platform ios --profile production      # App Store

eas submit --platform ios      # App Store
eas submit --platform android  # Google Play
```

## Local Development

```bash
npx expo start           # Start dev server
npx expo run:ios         # iOS simulator
npx expo run:android     # Android emulator
npx expo prebuild        # Generate native projects
```

## Testing Integration

1. `xcodebuild-mcp` — build and deploy to simulator
2. `agent-device` — AI-driven interaction testing
3. `maestro` — repeatable E2E test flows
4. `ios-simulator-mcp` — screenshots and verification
5. `playwright-emulation` — web-based mobile layout testing

## Related

- `tools/mobile/app-dev-swift.md` — Swift (iOS-only)
- `tools/mobile/app-dev-testing.md` — full testing guide
- `tools/mobile/app-dev-publishing.md` — store submission
- `tools/api/better-auth.md` — auth (`@better-auth/expo`)
- `tools/ui/tailwind-css.md` — Tailwind via NativeWind
- `tools/api/hono.md` — API backend
- `tools/api/drizzle.md` — database ORM
- `services/payments/revenuecat.md` — in-app subscriptions
