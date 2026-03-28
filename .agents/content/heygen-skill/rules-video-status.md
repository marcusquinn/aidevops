---
name: video-status
description: Polling patterns, status types, and retrieving download URLs for HeyGen videos
metadata:
  tags: video, status, polling, download, webhook
---

# Video Status and Polling

HeyGen processes videos asynchronously. After generating, poll until complete.

## Check Status

```bash
curl -X GET "https://api.heygen.com/v1/video_status.get?video_id=YOUR_VIDEO_ID" \
  -H "X-Api-Key: $HEYGEN_API_KEY"
```

```typescript
async function getVideoStatus(videoId: string) {
  const res = await fetch(
    `https://api.heygen.com/v1/video_status.get?video_id=${videoId}`,
    { headers: { "X-Api-Key": process.env.HEYGEN_API_KEY! } }
  );
  const json = await res.json();
  if (json.error) throw new Error(json.error);
  return json.data;
}
```

## Status Types

| Status | Description |
|--------|-------------|
| `pending` | Queued for processing |
| `processing` | Being generated |
| `completed` | Ready for download |
| `failed` | Generation failed |

## Response Format

```json
// completed
{ "error": null, "data": { "video_id": "abc123", "status": "completed",
  "video_url": "https://files.heygen.ai/video/abc123.mp4",
  "thumbnail_url": "https://files.heygen.ai/thumbnail/abc123.jpg", "duration": 45.2 } }

// failed
{ "error": null, "data": { "video_id": "abc123", "status": "failed",
  "error": "Script too long for selected avatar" } }
```

## Generation Times

Typically **5–15 min**; up to 20+ min at peak load or for long scripts.

| Factor | Impact |
|--------|--------|
| Script length | Longer = significantly more time |
| Resolution | 1080p > 720p |
| Queue load | Peak hours add 15–20+ min |
| Multiple scenes | Each scene adds time |

Set timeout to **15–20 min** (900,000–1,200,000 ms). For scripts > 2 min of speech, expect 15+ min.

## Polling

```typescript
async function waitForVideo(
  videoId: string,
  maxWaitMs = 900000,   // 15 min
  pollIntervalMs = 5000
): Promise<string> {
  const start = Date.now();
  while (Date.now() - start < maxWaitMs) {
    const status = await getVideoStatus(videoId);
    if (status.status === "completed") return status.video_url!;
    if (status.status === "failed") throw new Error(status.error || "Video generation failed");
    await new Promise(r => setTimeout(r, pollIntervalMs));
  }
  throw new Error("Video generation timed out");
}
```

Pass an optional `onProgress?: (status: string, elapsed: number) => void` callback if you need progress reporting — call it before the switch on each iteration.

## Download (with retry)

The URL may not be immediately accessible after `completed`. Use exponential backoff.

```typescript
import fs from "fs";

async function downloadVideo(videoUrl: string, outputPath: string, maxRetries = 5): Promise<void> {
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      const res = await fetch(videoUrl);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      fs.writeFileSync(outputPath, Buffer.from(await res.arrayBuffer()));
      return;
    } catch (err) {
      if (attempt === maxRetries - 1) throw err;
      await new Promise(r => setTimeout(r, 2000 * Math.pow(2, attempt)));
    }
  }
}
```

## Resumable Pattern

For long generations, save `video_id` and check later rather than blocking a process.

```typescript
// generate-video.ts — start and exit
fs.writeFileSync("pending-video.json", JSON.stringify({ videoId, createdAt: new Date().toISOString() }));
process.exit(0);

// check-status.ts — check once or wait
const { videoId } = JSON.parse(fs.readFileSync("pending-video.json", "utf-8"));
const args = process.argv.slice(2);
if (args.includes("--wait")) {
  const url = await waitForVideo(videoId);
  console.log("Done:", url);
} else {
  const status = await getVideoStatus(videoId);
  console.log("Status:", status.status, status.video_url ?? "");
}
```

## Webhooks

For production systems, prefer webhooks over polling — no idle connections. See [webhooks.md](webhooks.md).

## Best Practices

1. **Exponential backoff** — increase poll intervals for long-running jobs
2. **Timeout 15–20 min** — most complete within 10 min; allow headroom
3. **Handle failures** — check `error` field for actionable messages
4. **Retry downloads** — URL may not be immediately accessible after `completed`
5. **Cache URLs** — video URLs are valid for a limited time; don't re-fetch unnecessarily
