---
description: Mobile app backend services - Supabase, Firebase, Coolify self-hosted, API design
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

# App Backend - Server-Side Services

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Choose and configure backend services for mobile apps
- **Principle**: Use managed services for speed, self-host on Coolify for cost control
- **Docs**: Use Context7 MCP for latest Supabase, Firebase, and Expo documentation

**Do you need a backend?**

```text
App stores data locally only?           -> No backend needed
App needs user accounts?                -> Yes (auth provider)
App needs data sync across devices?     -> Yes (database + auth)
App needs server-side logic?            -> Yes (API/functions)
App needs file uploads?                 -> Yes (storage)
App needs real-time features?           -> Yes (WebSocket/realtime)
```

**Backend decision tree**:

| Need | Recommended | Alternative |
|------|-------------|-------------|
| Quick start, managed | Supabase | Firebase |
| Cost control, self-hosted | Coolify + Supabase/Postgres | Coolify + custom API |
| Maximum control | Custom API on Coolify | Hetzner + Docker |

<!-- AI-CONTEXT-END -->

## Supabase (Recommended)

Open-source Firebase alternative with Postgres, auth, storage, and realtime.

### Why Supabase

- Open-source (can self-host on Coolify)
- Postgres database (SQL, not NoSQL)
- Built-in auth (email, OAuth, magic link)
- Row-level security (RLS) for data access control
- Realtime subscriptions
- Storage for files and images
- Edge Functions for server-side logic
- Generous free tier

### Setup with Expo

```bash
npx expo install @supabase/supabase-js @react-native-async-storage/async-storage
```

### Setup with Swift

Add via Swift Package Manager: `https://github.com/supabase/supabase-swift.git`

### Self-Hosting on Coolify

Deploy Supabase on Coolify for full control and no usage limits:

```text
Coolify Dashboard -> New Service -> Supabase -> Deploy
```

See `tools/deployment/coolify.md` for detailed setup.

## Firebase

Google's app development platform. Good for rapid prototyping.

### When to Use Firebase Over Supabase

- Need Firebase-specific features (ML Kit, Remote Config, A/B Testing)
- Team already has Firebase expertise
- Need Firestore's document model (vs Postgres relational)
- Google Cloud ecosystem integration

### Key Services

| Service | Purpose |
|---------|---------|
| Authentication | User sign-in (email, OAuth, phone) |
| Firestore | NoSQL document database |
| Realtime Database | Low-latency sync |
| Cloud Storage | File uploads |
| Cloud Functions | Server-side logic |
| Cloud Messaging | Push notifications |
| Crashlytics | Crash reporting |
| Remote Config | Feature flags |

## API Design

### REST API Patterns

For custom backends, follow these patterns:

- Use consistent URL structure: `/api/v1/resources`
- Return appropriate HTTP status codes
- Paginate list endpoints
- Use JSON for request/response bodies
- Implement rate limiting
- Version your API from day one

### Authentication

- JWT tokens for stateless auth
- Refresh token rotation for security
- Secure token storage (`expo-secure-store` or Keychain)
- Token expiry: 15 minutes access, 7 days refresh

## Notifications Backend

See `mobile-app-dev/notifications.md` for push notification setup.

Options:

- **Expo Push Notifications**: Free, works with Expo apps
- **Firebase Cloud Messaging (FCM)**: Free, works with any app
- **OneSignal**: Free tier, cross-platform
- **Self-hosted**: ntfy (open-source, Coolify-deployable)

## Related

- `tools/api/hono.md` - Hono API framework (recommended for custom APIs)
- `tools/api/drizzle.md` - Drizzle ORM for type-safe database queries
- `tools/api/better-auth.md` - Better Auth (supports Expo via `@better-auth/expo`)
- `services/database/postgres-drizzle-skill.md` - Postgres + Drizzle deep reference
- `services/database/multi-org-isolation.md` - Multi-tenant patterns
- `tools/deployment/coolify.md` - Self-hosted deployment
- `mobile-app-dev/notifications.md` - Push notification setup
