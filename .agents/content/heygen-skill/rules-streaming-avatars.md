---
name: streaming-avatars
description: Real-time interactive avatar sessions for HeyGen via WebRTC — live customer service, virtual assistants, interactive apps
---

# Streaming Avatars

## Create Session

`POST https://api.heygen.com/v1/streaming.new`

| Field | Type | Req | Description |
|-------|------|:---:|-------------|
| `avatar_id` | string | ✓ | Avatar to use |
| `voice_id` | string | ✓ | Voice for TTS |
| `quality` | string | | `"low"` (480p ~500kbps) / `"medium"` (720p ~1Mbps) / `"high"` (1080p ~2Mbps) |
| `video_encoding` | string | | `"H264"` / `"VP8"` |

**Response:** `{ session_id, access_token, url, ice_servers[] }`

```typescript
const res = await fetch("https://api.heygen.com/v1/streaming.new", {
  method: "POST",
  headers: { "X-Api-Key": process.env.HEYGEN_API_KEY!, "Content-Type": "application/json" },
  body: JSON.stringify({ avatar_id, voice_id, quality: "high" }),
});
const { data } = await res.json(); // { session_id, access_token, url, ice_servers }
```

## Send Text (Avatar Speaks)

`POST https://api.heygen.com/v1/streaming.task`

| Field | Type | Req | Description |
|-------|------|:---:|-------------|
| `session_id` | string | ✓ | Active session ID |
| `text` | string | ✓ | Text to speak |
| `task_type` | string | ✓ | `"talk"` or `"repeat"` |
| `task_mode` | string | | `"sync"` or `"async"` |

## Session Management

| Action | Endpoint | Body |
|--------|----------|------|
| Stop | `POST https://api.heygen.com/v1/streaming.stop` | `{ session_id }` |
| Interrupt speech | `POST https://api.heygen.com/v1/streaming.interrupt` | `{ session_id }` — then send new task |
| List active | `GET https://api.heygen.com/v1/streaming.list` | — returns `{ data: { sessions: string[] } }` |

## WebRTC Integration Pattern

```typescript
const session = await createSession({ avatar_id, voice_id, quality: "high" });
const pc = new RTCPeerConnection({ iceServers: session.ice_servers });
const stream = new MediaStream();
pc.ontrack = (e) => e.streams[0].getTracks().forEach(t => stream.addTrack(t));
const offer = await pc.createOffer();
await pc.setLocalDescription(offer);
// Exchange SDP with server via signaling, then attach stream to <video>
```

## Best Practices

- Send a ping task every 30s to prevent session timeout
- Implement reconnection logic for disconnections
- Adjust `quality` based on available bandwidth
- Close unused sessions promptly — credits consumed per session-second
- WebRTC requires modern browser support
