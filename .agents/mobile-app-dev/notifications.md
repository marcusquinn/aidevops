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

- **Purpose**: Implement push and local notifications that drive retention without annoying users
- **Expo**: `expo-notifications` (free, built-in push service)
- **Swift**: `UserNotifications` framework + APNs
- **Cross-platform**: Firebase Cloud Messaging (FCM), OneSignal, ntfy (self-hosted)

**Notification decision tree**:

| Need | Solution | Cost |
|------|----------|------|
| Expo app, simple push | Expo Push Notifications | Free |
| Cross-platform, managed | Firebase Cloud Messaging | Free |
| Cross-platform, feature-rich | OneSignal | Free tier |
| Self-hosted, privacy-first | ntfy on Coolify | Free (self-hosted) |
| Local reminders only | expo-notifications (local) | Free |

<!-- AI-CONTEXT-END -->

## Notification Strategy

### When to Notify

Notifications should be **valuable, timely, and actionable**:

| Good Notifications | Bad Notifications |
|-------------------|-------------------|
| Reminder for user's chosen daily action | "We miss you!" (guilt trip) |
| Streak about to break (if user opted in) | Random feature announcements |
| Meaningful event (message received, goal achieved) | "Check out what's new!" |
| Time-sensitive information (delivery, appointment) | Marketing promotions |

### Permission Request Timing

Never request notification permission during onboarding. Instead:

1. User completes their first core action
2. Show value proposition: "Want a daily reminder to keep your streak?"
3. User taps "Yes, remind me"
4. System permission dialog appears
5. If denied, respect it — offer again later in settings

### Frequency Guidelines

| App Type | Recommended Frequency |
|----------|----------------------|
| Habit tracker | 1x daily (user-chosen time) |
| Social app | Real-time for messages, batched for likes/follows |
| News/content | 1-3x daily, user-configurable |
| Utility | Only when actionable (e.g., task due) |
| E-commerce | Sparingly (order updates, not promotions) |

## Expo Push Notifications

### Setup

```bash
npx expo install expo-notifications expo-device expo-constants
```

### Register for Push

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

### Send Push (Server-Side)

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

### Local Notifications

For reminders and scheduled notifications that don't need a server:

```typescript
await Notifications.scheduleNotificationAsync({
  content: {
    title: "Daily Reminder",
    body: "Time for your daily check-in!",
    sound: true,
  },
  trigger: {
    type: 'daily',
    hour: 9,
    minute: 0,
  },
});
```

## Self-Hosted: ntfy

Open-source push notification service, deployable on Coolify:

- **URL**: https://ntfy.sh
- **Self-host**: Docker image available, deploy on Coolify
- **Free**: No usage limits when self-hosted
- **Simple**: HTTP PUT/POST to send, subscribe via URL
- **Cross-platform**: Android app, iOS app, web, CLI

## Notification Content Best Practices

- **Title**: Short, clear, actionable (< 50 characters)
- **Body**: One sentence, specific value (< 100 characters)
- **Deep link**: Tap should go directly to relevant screen
- **Rich media**: Use images/icons when they add value
- **Grouping**: Batch related notifications (e.g., "3 new messages")
- **Silent**: Use silent notifications for background data sync

## Related

- `mobile-app-dev/onboarding.md` - Permission request timing
- `mobile-app-dev/analytics.md` - Notification engagement tracking
- `mobile-app-dev/backend.md` - Server-side notification sending
- `tools/deployment/coolify.md` - Self-hosting ntfy
