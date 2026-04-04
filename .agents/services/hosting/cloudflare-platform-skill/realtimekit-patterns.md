<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# RealtimeKit Patterns

## UI Kit (Minimal Code)

```tsx
// React
import { RtkMeeting } from '@cloudflare/realtimekit-react-ui';
<RtkMeeting authToken="<token>" onLeave={() => console.log('Left')} />

// Angular
@Component({ template: `<rtk-meeting [authToken]="authToken" (rtkLeave)="onLeave($event)"></rtk-meeting>` })
export class AppComponent { authToken = '<token>'; onLeave(event: unknown) {} }

// HTML/Web Components
<script type="module" src="https://cdn.jsdelivr.net/npm/@cloudflare/realtimekit-ui/dist/realtimekit-ui/realtimekit-ui.esm.js"></script>
<rtk-meeting id="meeting"></rtk-meeting>
<script>document.getElementById('meeting').authToken = '<token>';</script>
```

## Core SDK Patterns

### Video Grid (React)

```typescript
function VideoGrid({ meeting }) {
  const [participants, setParticipants] = useState([]);
  useEffect(() => {
    const update = () => setParticipants(meeting.participants.joined.toArray());
    ['participantJoined', 'participantLeft'].forEach(e => meeting.participants.joined.on(e, update));
    update();
    return () => ['participantJoined', 'participantLeft'].forEach(e => meeting.participants.joined.off(e, update));
  }, [meeting]);
  return <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))' }}>
    {participants.map(p => <VideoTile key={p.id} participant={p} />)}
  </div>;
}

function VideoTile({ participant }) {
  const videoRef = useRef<HTMLVideoElement>(null);
  useEffect(() => {
    if (videoRef.current && participant.videoTrack)
      videoRef.current.srcObject = new MediaStream([participant.videoTrack]);
  }, [participant.videoTrack]);
  return <div><video ref={videoRef} autoPlay playsInline muted /><div>{participant.name}</div></div>;
}
```

### Device Selection

```typescript
const devices = await meeting.self.getAllDevices();
const audioInputs = devices.filter(d => d.kind === 'audioinput');
const videoInputs = devices.filter(d => d.kind === 'videoinput');
meeting.self.on('deviceListUpdate', ({ added, removed }) => console.log('Devices:', { added, removed }));
const switchCamera = async (id: string) => { const d = devices.find(x => x.deviceId === id); if (d) await meeting.self.setDevice(d); };
```

### Chat & Custom Hook (React)

```typescript
function ChatComponent({ meeting }) {
  const [messages, setMessages] = useState(meeting.chat.messages);
  const [input, setInput] = useState('');
  useEffect(() => {
    const handler = ({ messages }) => setMessages(messages);
    meeting.chat.on('chatUpdate', handler);
    return () => meeting.chat.off('chatUpdate', handler);
  }, [meeting]);
  const send = async () => { if (input.trim()) { await meeting.chat.sendTextMessage(input); setInput(''); } };
  return <div>
    <div>{messages.map((msg, i) => <div key={i}><strong>{msg.senderName}:</strong> {msg.text}</div>)}</div>
    <input value={input} onChange={e => setInput(e.target.value)} onKeyPress={e => e.key === 'Enter' && send()} />
    <button onClick={send}>Send</button>
  </div>;
}

export function useMeeting(authToken: string) {
  const [meeting, setMeeting] = useState<RealtimeKitClient | null>(null);
  const [joined, setJoined] = useState(false);
  const [participants, setParticipants] = useState([]);
  useEffect(() => {
    const client = new RealtimeKitClient({ authToken });
    client.self.on('roomJoined', () => setJoined(true));
    const update = () => setParticipants(client.participants.joined.toArray());
    ['participantJoined', 'participantLeft'].forEach(e => client.participants.joined.on(e, update));
    setMeeting(client);
    return () => { client.leave(); };
  }, [authToken]);
  return { meeting, joined, participants, join: async () => meeting?.join(), leave: async () => meeting?.leave() };
}
```

## Backend Integration

```typescript
// Express — token generation
app.post('/api/join-meeting', async (req, res) => {
  const { meetingId, userName, presetName } = req.body;
  const url = `https://api.cloudflare.com/client/v4/accounts/${process.env.ACCOUNT_ID}/realtime/kit/${process.env.APP_ID}/meetings/${meetingId}/participants`;
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${process.env.CLOUDFLARE_API_TOKEN}` },
    body: JSON.stringify({ name: userName, preset_name: presetName, custom_participant_id: req.user.id })
  });
  res.json({ authToken: (await response.json()).result.authToken });
});

// Workers — meeting creation
export interface Env { CLOUDFLARE_API_TOKEN: string; CLOUDFLARE_ACCOUNT_ID: string; REALTIMEKIT_APP_ID: string; }
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (new URL(request.url).pathname === '/api/create-meeting') {
      const url = `https://api.cloudflare.com/client/v4/accounts/${env.CLOUDFLARE_ACCOUNT_ID}/realtime/kit/${env.REALTIMEKIT_APP_ID}/meetings`;
      return fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${env.CLOUDFLARE_API_TOKEN}` },
        body: JSON.stringify({ title: 'Team Meeting' })
      });
    }
    return new Response('Not found', { status: 404 });
  }
};
```

## Best Practices

| Area | Guidance |
|------|----------|
| Security | Never expose API tokens client-side — server-side token generation only. Fresh token per session (refresh endpoint if expired). `custom_participant_id` maps to your user system |
| Performance | Event-driven updates, don't poll. `toArray()` only when needed. Set resolution/bitrate via `mediaConfiguration`. Enable `autoSwitchAudioDevice` |
| Architecture | Separate Apps for staging vs production. Presets at App level, reuse across meetings. Backend generates tokens, frontend receives via authenticated endpoint |

## In This Reference

- [realtimekit.md](./realtimekit.md) - Overview, core concepts, quick start
- [realtimekit-gotchas.md](./realtimekit-gotchas.md) - Common issues, troubleshooting, limits
