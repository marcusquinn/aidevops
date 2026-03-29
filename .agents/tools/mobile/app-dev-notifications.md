---
description: Mobile push notifications - Expo notifications, FCM, local notifications, scheduling
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

# App Notifications - Engagement Without Annoyance

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Expo**: `expo-notifications` (free, built-in push service)
- **Swift**: `UserNotifications` framework + APNs
- **Cross-platform**: Firebase Cloud Messaging (FCM), OneSignal, ntfy (self-hosted)

| Need | Solution | Cost |
|------|----------|------|
| Expo app, simple push | Expo Push Notifications | Free |
| Cross-platform, managed | Firebase Cloud Messaging | Free |
| Cross-platform, feature-rich | OneSignal | Free tier |
| Self-hosted, privacy-first | ntfy on Coolify | Free (self-hosted) |
| Local reminders only | expo-notifications (local) | Free |

<!-- AI-CONTEXT-END -->

## Notification Strategy

**Only notify when valuable, timely, and actionable.**

| Good | Bad |
|------|-----|
| User's chosen daily reminder | "We miss you!" (guilt trip) |
| Streak about to break (opted in) | Random feature announcements |
| Meaningful event (message, goal) | "Check out what's new!" |
| Time-sensitive (delivery, appointment) | Marketing promotions |

**Permission timing:** Never request during onboarding. Wait until user completes first core action → show value proposition → system dialog. If denied, respect it; offer again in settings.

**Frequency:**

| App Type | Frequency |
|----------|-----------|
| Habit tracker | 1x daily (user-chosen time) |
| Social app | Real-time messages, batched likes/follows |
| News/content | 1-3x daily, user-configurable |
| Utility | Only when actionable |
| E-commerce | Order updates only, not promotions |

## Expo Push Notifications

```bash
npx expo install expo-notifications expo-device expo-constants
```

**Register for push:**

```typescript
import * as Notifications from 'expo-notifications';
import * as Device from 'expo-device';
import Constants from 'expo-constants';

async function registerForPushNotifications() {
  if (!Device.isDevice) return null; // Simulators can't receive push

  const { status: existingStatus } = await Notifications.getPermissionsAsync();
  let finalStatus = existingStatus;

  if (existingStatus !== 'granted') {
    const { status } = await Notifications.requestPermissionsAsync();
    finalStatus = status;
  }

  if (finalStatus !== 'granted') return null;

  const token = await Notifications.getExpoPushTokenAsync({
    projectId: Constants.expoConfig?.extra?.eas?.projectId,
  });

  return token.data;
}
```

**Send push (server-side):**

```bash
curl -X POST https://exp.host/--/api/v2/push/send \
  -H "Content-Type: application/json" \
  -d '{
    "to": "ExponentPushToken[xxxxxx]",
    "title": "Daily Reminder",
    "body": "Time for your daily check-in!",
    "sound": "default"
  }'
```

**Local notifications** (no server needed):

```typescript
await Notifications.scheduleNotificationAsync({
  content: { title: "Daily Reminder", body: "Time for your daily check-in!", sound: true },
  trigger: { type: 'daily', hour: 9, minute: 0 },
});
```

## Self-Hosted: ntfy

Open-source, deployable on Coolify. HTTP PUT/POST to send; Android/iOS/web/CLI clients. No usage limits when self-hosted. See https://ntfy.sh.

## Content Best Practices

- **Title**: < 50 chars, actionable
- **Body**: One sentence, specific value, < 100 chars
- **Deep link**: Tap → relevant screen directly
- **Rich media**: Only when it adds value
- **Grouping**: Batch related (e.g., "3 new messages")
- **Silent**: Use for background data sync

## Related

- `product/onboarding.md` - Permission request timing
- `product/analytics.md` - Notification engagement tracking
- `tools/mobile/app-dev/backend.md` - Server-side notification sending
- `tools/deployment/coolify.md` - Self-hosting ntfy
