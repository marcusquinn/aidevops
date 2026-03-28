---
description: Expo (React Native) mobile app development - project setup, navigation, state, APIs
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
  context7_*: true
---

# Expo Development - Cross-Platform Mobile Apps

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Build iOS + Android apps with Expo (React Native)
- **Docs**: Use Context7 MCP for latest Expo and React Native documentation
- **CLI**: `npx create-expo-app`, `npx expo start`, `npx expo prebuild`
- **Router**: Expo Router (file-based routing, like Next.js for mobile)
- **Build**: EAS Build (`eas build`) or local (`npx expo run:ios`)

**Project scaffold**:

```bash
npx create-expo-app my-app --template tabs
cd my-app
npx expo start
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

<!-- AI-CONTEXT-END -->

## Project Structure

Follow Expo Router conventions:

```text
app/
├── (tabs)/              # Tab navigator group
│   ├── index.tsx        # Home tab
│   ├── explore.tsx      # Explore tab
│   └── profile.tsx      # Profile tab
├── (auth)/              # Auth flow group
│   ├── login.tsx        # Login screen
│   └── register.tsx     # Registration screen
├── (onboarding)/        # First-run experience
│   ├── welcome.tsx
│   ├── setup.tsx
│   └── ready.tsx
├── _layout.tsx          # Root layout
├── +not-found.tsx       # 404 screen
└── modal.tsx
components/
├── ui/                  # Reusable UI components
├── forms/               # Form components
└── shared/              # Shared utilities
constants/
├── Colors.ts            # Colour palette (light/dark tokens)
├── Layout.ts            # Spacing, sizing
└── Typography.ts        # Font families, sizes
hooks/                   # Custom React hooks
services/                # API clients, data services
stores/                  # State management
assets/                  # Images, fonts, icons
```

## Development Standards

**TypeScript**: Always use TypeScript. Define interfaces for all props, state, and API responses.

**Styling**: Prefer `StyleSheet.create()` for performance. Use a design token system in `constants/Colors.ts` with `light` and `dark` variants covering `primary`, `background`, `surface`, `text`, `textSecondary`, `border`, `success`, `warning`, `error`.

**Navigation** (Expo Router file-based routing):

- `(group)` folders for layout groups (tabs, auth, onboarding)
- `[param]` for dynamic routes
- `_layout.tsx` for shared layout per group
- `+not-found.tsx` for 404 handling

**Animations**: Use `react-native-reanimated` — not the `Animated` API — for complex animations. Key APIs: `useSharedValue` + `useAnimatedStyle`, `withSpring`, `withTiming`, `Layout` animations. Pair with `expo-haptics` for tactile feedback.

**State Management**:

- **Simple**: React Context + `useReducer`
- **Complex**: Zustand (lightweight, no boilerplate)
- **Server**: TanStack Query (React Query) for API data
- **Persistent**: `@react-native-async-storage/async-storage`
- **Secure**: `expo-secure-store` for tokens and credentials

**Performance**:

- Use `expo-image` instead of `Image` for optimised loading
- `FlatList` with `getItemLayout` for long lists
- `React.memo` for expensive list items
- `useDeferredValue` for heavy non-critical renders
- Profile with React DevTools and Flipper

## EAS Build and Submit

```bash
npm install -g eas-cli
eas build:configure

eas build --platform ios --profile development    # iOS simulator
eas build --platform android --profile development # Android emulator
eas build --platform ios --profile preview         # TestFlight
eas build --platform ios --profile production      # App Store

eas submit --platform ios      # Submit to App Store
eas submit --platform android  # Submit to Google Play
```

## Local Development

```bash
npx expo start           # Start dev server
npx expo run:ios         # Run on iOS simulator
npx expo run:android     # Run on Android emulator
npx expo prebuild        # Generate native projects (for custom native code)
```

## Testing Integration

After building, use the aidevops mobile testing stack:

1. `xcodebuild-mcp` to build and deploy to simulator
2. `agent-device` for AI-driven interaction testing
3. `maestro` for repeatable E2E test flows
4. `ios-simulator-mcp` for simulator screenshots and verification
5. `playwright-emulation` for web-based mobile layout testing

## Related

- `tools/mobile/app-dev/swift.md` - Swift alternative for iOS-only
- `tools/mobile/app-dev/testing.md` - Full testing guide
- `tools/mobile/app-dev/publishing.md` - Store submission
- `tools/mobile/` - Mobile testing tools
- `tools/api/better-auth.md` - Authentication (has `@better-auth/expo` package)
- `tools/ui/tailwind-css.md` - Tailwind CSS (via NativeWind for React Native)
- `tools/api/hono.md` - API framework for backend
- `tools/api/drizzle.md` - Database ORM for backend
- `services/payments/revenuecat.md` - In-app subscription management
