# Cloudflare RealtimeKit

SDK suite built on Realtime SFU — abstracts WebRTC complexity with pre-built UI components, global performance (300+ cities), and production features (recording, transcription, chat, polls).

**Use cases**: Team meetings, webinars, social video, audio calls, interactive plugins

## Core Concepts

- **App**: Workspace grouping meetings, participants, presets, recordings. Use separate Apps for staging/production
- **Meeting**: Re-usable virtual room. Each join creates new **Session**
- **Session**: Live meeting instance. Created on first join, ends after last leave
- **Participant**: User added via REST API. Returns `authToken` for client SDK. **Do not reuse tokens**
- **Preset**: Reusable permission/UI template (permissions, meeting type, theme). Applied at participant creation
- **Peer ID** (`id`): Unique per session, changes on rejoin
- **Participant ID** (`userId`): Persistent across sessions

## Quick Start

### 1. Create App & Meeting (Backend)

```bash
curl -X POST 'https://api.cloudflare.com/client/v4/accounts/<account_id>/realtime/kit/apps' \
  -H 'Authorization: Bearer <api_token>' \
  -d '{"name": "My RealtimeKit App"}'

curl -X POST 'https://api.cloudflare.com/client/v4/accounts/<account_id>/realtime/kit/<app_id>/meetings' \
  -H 'Authorization: Bearer <api_token>' \
  -d '{"title": "Team Standup"}'

curl -X POST 'https://api.cloudflare.com/client/v4/accounts/<account_id>/realtime/kit/<app_id>/meetings/<meeting_id>/participants' \
  -H 'Authorization: Bearer <api_token>' \
  -d '{"name": "Alice", "preset_name": "host"}'
# Returns: { authToken }
```

### 2. Client Integration

**React**:

```tsx
import { RtkMeeting } from '@cloudflare/realtimekit-react-ui';
function App() {
  return <RtkMeeting authToken="<participant_auth_token>" onLeave={() => {}} />;
}
```

**Core SDK**:

```typescript
import RealtimeKitClient from '@cloudflare/realtimekit';
const meeting = new RealtimeKitClient({ authToken: '<token>', video: true, audio: true });
await meeting.join();
```

## References

- [Patterns](./realtimekit-patterns.md) — Common workflows, code examples
- [Gotchas](./realtimekit-gotchas.md) — Common issues, troubleshooting, limits
- [Workers](../workers/) — Backend integration
- [D1](../d1/) — Meeting metadata storage
- [R2](../r2/) — Recording storage
- [KV](../kv/) — Session management
- [Official Docs](https://developers.cloudflare.com/realtime/realtimekit/)
- [API Reference](https://developers.cloudflare.com/api/resources/realtime_kit/)
- [Examples](https://github.com/cloudflare/realtimekit-web-examples)
- [Dashboard](https://dash.cloudflare.com/?to=/:account/realtime/kit)
