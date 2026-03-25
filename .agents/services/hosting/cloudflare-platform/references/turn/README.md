# Cloudflare TURN Service

Managed TURN relay for WebRTC on Cloudflare's global anycast network (310+ cities). Free with Cloudflare Calls SFU; otherwise $0.05/GB outbound.

## Service Addresses

| Protocol | Primary | Alternate |
|----------|---------|-----------|
| STUN/UDP | `stun.cloudflare.com:3478` | `:53/udp` (avoid — blocked by many ISPs) |
| TURN/UDP | `turn.cloudflare.com:3478` | `:53/udp` |
| TURN/TCP | `turn.cloudflare.com:3478` | `:80/tcp` |
| TURN/TLS | `turn.cloudflare.com:5349` | `:443/tcp` |

## API Endpoints

Base URL: `https://api.cloudflare.com/client/v4` — requires API token with "Calls Write" permission.

```
GET    /accounts/{account_id}/calls/turn_keys
GET    /accounts/{account_id}/calls/turn_keys/{key_id}
POST   /accounts/{account_id}/calls/turn_keys          body: {"name": "my-turn-key"}
PUT    /accounts/{account_id}/calls/turn_keys/{key_id} body: {"name": "updated-name"}
DELETE /accounts/{account_id}/calls/turn_keys/{key_id}
```

Create response includes `uid`, `key` (secret — only returned once), `name`, `created`, `modified`.

## Generate Temporary Credentials

```
POST https://rtc.live.cloudflare.com/v1/turn/keys/{key_id}/credentials/generate
Authorization: Bearer {key_secret}
Content-Type: application/json

{"ttl": 86400}
```

Response:

```json
{
  "iceServers": {
    "urls": [
      "stun:stun.cloudflare.com:3478",
      "turn:turn.cloudflare.com:3478?transport=udp",
      "turn:turn.cloudflare.com:3478?transport=tcp",
      "turns:turn.cloudflare.com:5349?transport=tcp"
    ],
    "username": "generated-username",
    "credential": "generated-credential"
  }
}
```

## Implementation

### Browser — fetch credentials from backend

```typescript
async function getTURNConfig(): Promise<RTCIceServer[]> {
  const { iceServers } = await fetch('/api/turn-credentials').then(r => r.json());
  return [
    { urls: 'stun:stun.cloudflare.com:3478' },
    { urls: iceServers.urls, username: iceServers.username, credential: iceServers.credential }
  ];
}

const peerConnection = new RTCPeerConnection({ iceServers: await getTURNConfig() });
```

### Backend — generate credentials (Node.js/TypeScript)

```typescript
async function generateTURNCredentials(keyId: string, keySecret: string, ttl = 86400) {
  const res = await fetch(
    `https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/generate`,
    {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${keySecret}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ttl })
    }
  );
  if (!res.ok) throw new Error(`TURN credential generation failed: ${res.status}`);
  const { iceServers } = await res.json();
  return { username: iceServers.username, credential: iceServers.credential, urls: iceServers.urls };
}
```

### Cloudflare Worker

```typescript
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (new URL(request.url).pathname !== '/turn-credentials') return new Response('Not found', { status: 404 });
    if (!request.headers.get('Authorization')) return new Response('Unauthorized', { status: 401 });

    const res = await fetch(
      `https://rtc.live.cloudflare.com/v1/turn/keys/${env.TURN_KEY_ID}/credentials/generate`,
      {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${env.TURN_KEY_SECRET}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ ttl: 3600 })
      }
    );
    if (!res.ok) return new Response('Failed to generate credentials', { status: 500 });
    const { iceServers } = await res.json();
    return new Response(JSON.stringify({ iceServers: [
      { urls: 'stun:stun.cloudflare.com:3478' },
      { urls: iceServers.urls, username: iceServers.username, credential: iceServers.credential }
    ]}), { headers: { 'Content-Type': 'application/json' } });
  }
};
```

### Credential Caching

Cache credentials client-side; refresh 60s before expiry:

```typescript
class TURNCredentialsManager {
  private cache: { username: string; credential: string; urls: string[]; expiresAt: number } | null = null;

  async getCredentials(keyId: string, keySecret: string): Promise<RTCIceServer[]> {
    const now = Date.now();
    if (!this.cache || this.cache.expiresAt <= now) {
      const ttl = 3600;
      const creds = await generateTURNCredentials(keyId, keySecret, ttl);
      this.cache = { ...creds, expiresAt: now + ttl * 1000 - 60000 };
    }
    return [
      { urls: 'stun:stun.cloudflare.com:3478' },
      { urls: this.cache.urls, username: this.cache.username, credential: this.cache.credential }
    ];
  }
}
```

## Configuration

### Environment Variables

```bash
CLOUDFLARE_ACCOUNT_ID=your_account_id
CLOUDFLARE_API_TOKEN=your_api_token
TURN_KEY_ID=your_turn_key_id
TURN_KEY_SECRET=your_turn_key_secret
```

### Wrangler

```toml
name = "turn-credentials-api"
main = "src/index.ts"
compatibility_date = "2024-01-01"

[vars]
TURN_KEY_ID = "your-turn-key-id"

# Store TURN_KEY_SECRET via: wrangler secret put TURN_KEY_SECRET
```

## Limits

Per allocation (per user): >5 new unique IPs/sec, 5–10k pps, 50–100 Mbps. Exceeding limits causes packet drops.

## TLS

Supported: TLS 1.1, 1.2, 1.3. Recommended ciphers: `AEAD-AES128-GCM-SHA256`, `AEAD-AES256-GCM-SHA384`, `AEAD-CHACHA20-POLY1305-SHA256` (TLS 1.3); `ECDHE-ECDSA-AES128-GCM-SHA256`, `ECDHE-RSA-AES128-GCM-SHA256` (TLS 1.2).

## Security Best Practices

1. **Never expose TURN key secrets client-side** — always generate credentials server-side
2. **Rate-limit credential generation** — 5s cooldown per client minimum
3. **Set appropriate TTLs** — 1800–3600s for short sessions; 86400s max
4. **Validate client authentication** before generating credentials
5. **Monitor usage** — track generation requests, alert on anomalies

## Troubleshooting

| Issue | Check |
|-------|-------|
| Credentials not working | Key ID/secret correct? TTL expired? Can reach `rtc.live.cloudflare.com`? |
| Slow connection | ICE candidate gathering, firewall blocking WebRTC ports, try TURN over TLS `:443` |
| High packet loss | Rate limits (5–10k pps, 50–100 Mbps), client network quality |

### Debug ICE

```typescript
pc.addEventListener('icecandidate', e => e.candidate && console.log('ICE:', e.candidate.type, e.candidate.protocol));
pc.addEventListener('iceconnectionstatechange', () => console.log('ICE state:', pc.iceConnectionState));
```

## Architecture

- **Anycast**: BGP routes clients to nearest location — no region selection needed
- **Use TURN when**: symmetric NATs, corporate firewalls, carrier-grade NAT, predictable connectivity required
- **`iceTransportPolicy: 'all'`**: try direct first (recommended); `'relay'`: force TURN (IoT/predictability)
- **With Cloudflare Calls SFU**: TURN is free and automatically coordinated

## Cost Optimization

- Use `iceTransportPolicy: 'all'` (not `'relay'`) to prefer direct connections
- Cache credentials — reuse within TTL window
- Use with Cloudflare Calls SFU for free TURN

## Related Services

- **Cloudflare Calls SFU**: Managed SFU — TURN is free when used together
- **Cloudflare Stream**: WHIP/WHEP video streaming
- **Cloudflare Workers**: Backend for credential generation
- **Cloudflare KV**: Credential caching

## Resources

- [Cloudflare TURN Docs](https://developers.cloudflare.com/realtime/turn/)
- [Cloudflare Calls Docs](https://developers.cloudflare.com/calls/)
- [API Reference](https://developers.cloudflare.com/api/resources/calls/subresources/turn/)
- [Orange Meets (example)](https://github.com/cloudflare/orange)
