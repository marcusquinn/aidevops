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
│   ├── welcome.tsx      # Welcome screen
│   ├── setup.tsx        # Setup preferences
│   └── ready.tsx        # Ready to use
├── _layout.tsx          # Root layout
├── +not-found.tsx       # 404 screen
└── modal.tsx            # Modal screen
components/
├── ui/                  # Reusable UI components
├── forms/               # Form components
└── shared/              # Shared utilities
constants/
├── Colors.ts            # Colour palette
├── Layout.ts            # Spacing, sizing
└── Typography.ts        # Font families, sizes
hooks/                   # Custom React hooks
services/                # API clients, data services
stores/                  # State management
assets/                  # Images, fonts, icons
```

## Development Standards

### TypeScript

Always use TypeScript. Define interfaces for all props, state, and API responses.

### Styling

Prefer `StyleSheet.create()` for performance. Use a design token system:

```typescript
// constants/Colors.ts
export const Colors = {
  light: {
    primary: '#007AFF',
    background: '#FFFFFF',
    surface: '#F2F2F7',
    text: '#000000',
    textSecondary: '#8E8E93',
    border: '#C6C6C8',
    success: '#34C759',
    warning: '#FF9500',
    error: '#FF3B30',
  },
  dark: {
    primary: '#0A84FF',
    background: '#000000',
    surface: '#1C1C1E',
    text: '#FFFFFF',
    textSecondary: '#8E8E93',
    border: '#38383A',
    success: '#30D158',
    warning: '#FF9F0A',
    error: '#FF453A',
  },
};
```

### Animations

Use `react-native-reanimated` for performant animations. Avoid `Animated` API for complex animations.

Key patterns:

- `useSharedValue` + `useAnimatedStyle` for UI animations
- `withSpring` for natural-feeling transitions
- `withTiming` for precise duration control
- `Layout` animations for list item enter/exit
- `expo-haptics` paired with animations for tactile feedback

### Navigation

Use Expo Router file-based routing:

- `(group)` folders for layout groups (tabs, auth, onboarding)
- `[param]` for dynamic routes
- `_layout.tsx` for shared layout per group
- `+not-found.tsx` for 404 handling

### State Management

For most apps, use React Context + `useReducer` or Zustand:

- **Simple state**: React Context + `useReducer`
- **Complex state**: Zustand (lightweight, no boilerplate)
- **Server state**: TanStack Query (React Query) for API data
- **Persistent state**: `@react-native-async-storage/async-storage`
- **Secure state**: `expo-secure-store` for tokens and credentials

### Native Features

Expo provides managed access to device capabilities:

| Feature | Package | Use Case |
|---------|---------|----------|
| Haptics | `expo-haptics` | Button feedback, success/error signals |
| Sensors | `expo-sensors` | Motion tracking, step counting |
| Location | `expo-location` | GPS, geofencing |
| Camera | `expo-camera` | Photo/video capture |
| Biometrics | `expo-local-authentication` | Face ID, fingerprint |
| Notifications | `expo-notifications` | Push and local notifications |
| Secure storage | `expo-secure-store` | Tokens, credentials |
| File system | `expo-file-system` | Local file management |
| Sharing | `expo-sharing` | Share content to other apps |
| Clipboard | `expo-clipboard` | Copy/paste |
| Linking | `expo-linking` | Deep links, URL schemes |

### Performance

- Use `expo-image` instead of `Image` for optimised loading
- Implement `FlatList` with `getItemLayout` for long lists
- Use `React.memo` for expensive list items
- Lazy load screens with `React.lazy` + `Suspense`
- Profile with React DevTools and Flipper

## EAS Build and Submit

### Build for Testing

```bash
# Install EAS CLI
npm install -g eas-cli

# Configure
eas build:configure

# Build for iOS simulator
eas build --platform ios --profile development

# Build for Android emulator
eas build --platform android --profile development

# Build for TestFlight
eas build --platform ios --profile preview

# Build for production
eas build --platform ios --profile production
```

### Submit to Stores

```bash
# Submit to App Store
eas submit --platform ios

# Submit to Google Play
eas submit --platform android
```

## Local Development

```bash
# Start dev server
npx expo start

# Run on iOS simulator
npx expo run:ios

# Run on Android emulator
npx expo run:android

# Prebuild native projects (for custom native code)
npx expo prebuild
```

## Testing Integration

After building, use the aidevops mobile testing stack:

1. `xcodebuild-mcp` to build and deploy to simulator
2. `agent-device` for AI-driven interaction testing
3. `maestro` for repeatable E2E test flows
4. `ios-simulator-mcp` for simulator screenshots and verification
5. `playwright-emulation` for web-based mobile layout testing

## Related

- `mobile-app-dev/swift.md` - Swift alternative for iOS-only
- `mobile-app-dev/testing.md` - Full testing guide
- `mobile-app-dev/publishing.md` - Store submission
- `tools/mobile/` - Mobile testing tools
