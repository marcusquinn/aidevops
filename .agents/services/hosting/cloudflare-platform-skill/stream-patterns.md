<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Stream Patterns

## Direct Upload (Backend + Frontend)

**Backend API** — request signed upload URL:

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

**Frontend** — fetch upload URL from backend, POST file as FormData to the signed URL. Use `XMLHttpRequest` for upload progress (`xhr.upload` `progress` event). The upload URL is single-use and expires.

## Video Status Polling

Poll `GET /accounts/{id}/stream/{videoId}` until `readyToStream` or `error`:

```typescript
interface VideoState {
  uid: string;
  readyToStream: boolean;
  status: { state: 'queued' | 'inprogress' | 'ready' | 'error'; pctComplete?: string };
}

async function waitForVideoReady(
  accountId: string, videoId: string, apiToken: string,
  maxAttempts = 60, intervalMs = 5000
): Promise<VideoState> {
  for (let i = 0; i < maxAttempts; i++) {
    const res = await fetch(
      `https://api.cloudflare.com/client/v4/accounts/${accountId}/stream/${videoId}`,
      { headers: { 'Authorization': `Bearer ${apiToken}` } }
    );
    const { result } = await res.json();
    if (result.readyToStream || result.status.state === 'error') return result;
    await new Promise(r => setTimeout(r, intervalMs));
  }
  throw new Error('Video processing timeout');
}
```

Prefer webhooks over polling for production use.

## Webhook Handler (Workers)

Receive status updates via signed webhook:

```typescript
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const signature = request.headers.get('Webhook-Signature');
    if (!signature) return new Response('No signature', { status: 401 });

    const body = await request.text();
    // Verify HMAC-SHA256: parse time1,sig1 from header, check 5min window, compare digest
    const isValid = await verifySignature(signature, body, env.WEBHOOK_SECRET);
    if (!isValid) return new Response('Invalid', { status: 401 });

    const payload = JSON.parse(body);
    if (payload.readyToStream) console.log(`Video ${payload.uid} ready`);
    return new Response('OK');
  }
};
```

## Live Streaming

**OBS**: `rtmps://live.cloudflare.com:443/live/` + Stream Key from API

**FFmpeg**: `ffmpeg -re -i input.mp4 -c:v libx264 -preset veryfast -b:v 3000k -c:a aac -f flv rtmps://live.cloudflare.com:443/live/<KEY>`

## Best Practices

- **Direct Creator Uploads** — avoid proxying video through servers
- **requireSignedURLs** — control access to private content
- **Signing keys for high volume** — self-sign tokens instead of API calls
- **allowedOrigins** — prevent hotlinking
- **Webhooks over polling** — efficient status updates
- **Cache video metadata** — reduce API calls
- **maxDurationSeconds** — prevent abuse on direct uploads
- **Creator metadata** — enable per-user filtering/analytics
- **Enable recordings for live** — automatic VOD after stream ends
- **GraphQL analytics** — track views, watch time, geo
