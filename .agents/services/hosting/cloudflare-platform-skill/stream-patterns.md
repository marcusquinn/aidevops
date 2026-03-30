# Stream Patterns

## Direct Upload (Backend + Frontend)

**Backend** — request signed upload URL:

```typescript
// app/api/upload-url/route.ts
export async function POST(req: Request) {
  const { userId, videoName } = await req.json();
  const response = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${process.env.CF_ACCOUNT_ID}/stream/direct_upload`,
    {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${process.env.CF_API_TOKEN}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        maxDurationSeconds: 3600,
        requireSignedURLs: true,
        meta: { creator: userId, name: videoName }
      })
    }
  );
  const data = await response.json();
  return Response.json({ uploadURL: data.result.uploadURL, uid: data.result.uid });
}
```

**Frontend** — upload via XHR for progress tracking:

```typescript
// 1. Get signed URL from backend
const { uploadURL, uid } = await fetch('/api/upload-url', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ videoName: file.name })
}).then(r => r.json());

// 2. Upload with progress
const formData = new FormData();
formData.append('file', file);

const xhr = new XMLHttpRequest();
xhr.upload.addEventListener('progress', (e) => {
  if (e.lengthComputable) setProgress((e.loaded / e.total) * 100);
});
xhr.addEventListener('load', () => { /* redirect to /videos/${uid} */ });
xhr.open('POST', uploadURL);
xhr.send(formData);
```

## Video Status Polling

Poll for processing completion (max 60 attempts, 5s intervals):

```typescript
// VideoState: { uid, readyToStream, status: { state: 'queued'|'inprogress'|'ready'|'error', pctComplete? } }
async function waitForVideoReady(
  accountId: string, videoId: string, apiToken: string,
  maxAttempts = 60, intervalMs = 5000
): Promise<VideoState> {
  for (let i = 0; i < maxAttempts; i++) {
    const response = await fetch(
      `https://api.cloudflare.com/client/v4/accounts/${accountId}/stream/${videoId}`,
      { headers: { 'Authorization': `Bearer ${apiToken}` } }
    );
    const { result } = await response.json();
    if (result.readyToStream || result.status.state === 'error') return result;
    await new Promise(resolve => setTimeout(resolve, intervalMs));
  }
  throw new Error('Video processing timeout');
}
```

## Webhook Handler (Workers)

Receive status updates via signed webhook:

```typescript
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const signature = request.headers.get('Webhook-Signature');
    if (!signature) return new Response('No signature', { status: 401 });

    const body = await request.text();
    // Verify HMAC-SHA256: parse time/sig1, check 5min window, compare signature
    const isValid = await verifySignature(signature, body, env.WEBHOOK_SECRET);
    if (!isValid) return new Response('Invalid', { status: 401 });

    const payload = JSON.parse(body);
    if (payload.readyToStream) console.log(`Video ${payload.uid} ready`);
    return new Response('OK');
  }
};
// Full verifySignature impl in gotchas.md
```

## Live Streaming

**OBS**: `rtmps://live.cloudflare.com:443/live/` + Stream Key from API

**FFmpeg**: `ffmpeg -re -i input.mp4 -c:v libx264 -preset veryfast -b:v 3000k -c:a aac -f flv rtmps://live.cloudflare.com:443/live/<KEY>`

## Best Practices

- **Direct Creator Uploads** — avoid proxying video through servers; use `requireSignedURLs` for access control
- **Signing keys** — self-sign tokens for high volume instead of per-request API calls
- **allowedOrigins** — prevent hotlinking
- **Webhooks over polling** — efficient status updates (polling above is a fallback)
- **Cache video metadata** — reduce API calls
- **maxDurationSeconds** — prevent abuse on direct uploads
- **Creator metadata** — enable per-user filtering/analytics
- **Live recordings** — enable for automatic VOD after stream ends
- **GraphQL analytics** — track views, watch time, geo

## Related

- [README.md](./README.md) — overview and quick start
- [gotchas.md](./gotchas.md) — error codes, troubleshooting
- [workers](../workers/) — deploy Stream APIs in Workers
- [pages](../pages/) — integrate Stream with Pages
