# RealtimeKit Gotchas & Troubleshooting

## Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| Cannot connect to meeting | Token invalid/expired; API token lacks **Realtime / Realtime Admin** perms; firewall blocks WebRTC | Verify token; check perms; enable TURN for restrictive networks |
| No video/audio tracks | Browser permissions not granted; `video: true, audio: true` not set; device in use or unavailable | Request permissions explicitly; verify init config; `meeting.self.getAllDevices()` to debug; close competing apps |
| Participant count mismatch | `meeting.participants` excludes `meeting.self` | Total = `meeting.participants.joined.size() + 1` |
| Events not firing | Listeners registered after actions; wrong event name; wrong namespace (`meeting.self` vs `meeting.participants`) | Register listeners before `meeting.join()`; check names against API docs; verify namespace |
| CORS errors in API calls | REST calls made client-side | All REST API calls **must** be server-side (Workers, backend). Never expose API tokens to clients |
| Preset not applying | Preset doesn't exist; `preset_name` case mismatch; participant created before preset | Verify via Dashboard/API; check exact spelling+case; create preset before adding participants |
| Token reuse errors | Reusing participant tokens across sessions | Fresh token per session. Use refresh endpoint if token expires mid-session |
| Poor video quality | Bandwidth insufficient; resolution/bitrate too high; CPU overload | Lower `mediaConfiguration.video` resolution/frameRate; reduce participant count or grid size |
| Echo / audio feedback | Multiple devices picking up same source | `echoCancellation: true` in `mediaConfiguration.audio`; use headphones; mute when not speaking |
| Screen share not working | Browser unsupported; permission denied; wrong `displaySurface` | Chrome/Edge/Firefox (Safari limited); check permissions; try `displaySurface` values: `window`, `monitor`, `browser` |

## Limits

| Resource | Limit |
|----------|-------|
| Participants per session | 100 |
| Concurrent sessions per App | 1000 |
| Recording duration | 6 hours |
| Meeting duration | 24 hours |
| Chat message length | 4000 chars |
| Preset name length | 64 chars |
| Meeting title length | 256 chars |
| Participant name length | 256 chars |
| Token expiration | 24 hours (default) |
| WebRTC ports required | UDP 1024-65535 |

## Network Requirements

Allow outbound UDP/TCP to `*.cloudflare.com` ports 443, 80 and UDP 1024-65535 (WebRTC media).

### TURN Service

Enable for users behind restrictive firewalls/proxies:

```jsonc
// wrangler.jsonc
{
  "vars": {
    "TURN_SERVICE_ID": "your_turn_service_id"
  }
  // Set secret: wrangler secret put TURN_SERVICE_TOKEN
}
```

TURN automatically configured in SDK when enabled in account.

## Debugging

```typescript
// Device debugging
const devices = await meeting.self.getAllDevices();
meeting.self.on('deviceListUpdate', ({ added, removed, devices }) =>
  console.log('Devices:', { added, removed, devices }));

// Participant monitoring
meeting.participants.joined.on('participantJoined', (p) =>
  console.log(`${p.name} joined:`, { id: p.id, userId: p.userId,
    audioEnabled: p.audioEnabled, videoEnabled: p.videoEnabled }));

// Room state on join
meeting.self.on('roomJoined', () =>
  console.log('Room:', { meetingId: meeting.meta.meetingId,
    meetingTitle: meeting.meta.meetingTitle,
    participantCount: meeting.participants.joined.size() + 1,
    audioEnabled: meeting.self.audioEnabled,
    videoEnabled: meeting.self.videoEnabled }));

// Bulk event logging
['roomJoined', 'audioUpdate', 'videoUpdate', 'screenShareUpdate',
 'deviceUpdate', 'deviceListUpdate'].forEach(event =>
  meeting.self.on(event, (data) => console.log(`[self] ${event}:`, data)));
['participantJoined', 'participantLeft'].forEach(event =>
  meeting.participants.joined.on(event, (data) =>
    console.log(`[participants] ${event}:`, data)));
meeting.chat.on('chatUpdate', (data) => console.log('[chat]:', data));
```

Security and performance best practices: see [patterns.md](./patterns.md) §Security and §Performance.

## In This Reference

- [realtimekit.md](./realtimekit.md) — Overview, core concepts, quick start
- [realtimekit-patterns.md](./realtimekit-patterns.md) — Common patterns, React hooks, backend integration
