---
description: Expo (React Native) mobile app development - project setup, navigation, state, APIs
mode: subagent
tools: [read, write, edit, bash, glob, grep, webfetch, task, context7_*]
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Expo Development - Cross-Platform Mobile Apps

## Quick Reference

- **Docs**: Context7 MCP for latest Expo/React Native docs
- **CLI**: `npx create-expo-app`, `npx expo start`, `npx expo prebuild`
- **Router**: Expo Router (file-based, like Next.js for mobile)
- **Build**: EAS Build (`eas build`) or local (`npx expo run:ios`)

```bash
npx create-expo-app my-app --template tabs
cd my-app && npx expo start
```

**Key packages** (verify versions via Context7):
`expo-router` (navigation), `expo-notifications`, `expo-secure-store` (credentials), `expo-haptics`, `expo-image`, `expo-av` (audio/video), `expo-sensors`, `expo-location`, `expo-camera`, `expo-local-authentication` (biometrics), `expo-file-system`, `expo-sharing`, `expo-clipboard`, `expo-linking` (deep links), `react-native-reanimated` (animations), `react-native-gesture-handler`, `@react-native-async-storage/async-storage`

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
components/ui/           # Reusable UI
components/forms/
constants/Colors.ts      # Colour tokens (light/dark)
constants/Layout.ts      # Spacing, sizing
constants/Typography.ts  # Font families, sizes
hooks/                   # Custom React hooks
services/                # API clients
stores/                  # State management
assets/                  # Images, fonts, icons
```

## Development Standards

**TypeScript**: Always. Interfaces for all props, state, API responses.

**Styling**: `StyleSheet.create()`. Design tokens in `constants/Colors.ts` with `light`/`dark` variants.

**Navigation** (Expo Router): `(group)` for layouts, `[param]` for dynamic routes, `_layout.tsx` per group, `+not-found.tsx` for 404.

**Animations**: `react-native-reanimated` (not `Animated` API). `useSharedValue` + `useAnimatedStyle`, `withSpring`, `withTiming`, `Layout` animations. Pair with `expo-haptics`.

**State management**: Simple → React Context + `useReducer`. Complex → Zustand. Server → TanStack Query. Persistent → `async-storage`. Secure → `expo-secure-store`.

**Performance**: `expo-image` over `Image`; `FlatList` with `getItemLayout`; `React.memo` for list items; `useDeferredValue` for heavy renders.

## EAS Build and Submit

```bash
npm install -g eas-cli && eas build:configure
eas build --platform ios --profile development      # Simulator
eas build --platform android --profile development  # Emulator
eas build --platform ios --profile preview           # TestFlight
eas build --platform ios --profile production        # App Store
eas submit --platform ios                            # App Store
eas submit --platform android                        # Google Play
```

## Local Development

```bash
npx expo start           # Dev server
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
