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

Typically **5-15 min**; 20+ min at peak load or for long scripts. Set timeout to **15-20 min** (900,000-1,200,000 ms).

| Factor | Impact |
|--------|--------|
| Script length | Longer = significantly more time |
| Resolution | 1080p > 720p |
| Queue load | Peak hours add 15-20+ min |

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

For progress reporting, pass `onProgress?: (status: string, elapsed: number) => void` and call it each iteration. Use exponential backoff for long-running jobs.

## Download (with retry)

URL may not be immediately accessible after `completed`. Use exponential backoff.

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

For long generations, save `video_id` and check later rather than blocking.

```typescript
// generate-video.ts — start and exit
fs.writeFileSync("pending-video.json", JSON.stringify({ videoId, createdAt: new Date().toISOString() }));

// check-status.ts — check once or wait
const { videoId } = JSON.parse(fs.readFileSync("pending-video.json", "utf-8"));
if (process.argv.includes("--wait")) {
  console.log("Done:", await waitForVideo(videoId));
} else {
  const status = await getVideoStatus(videoId);
  console.log("Status:", status.status, status.video_url ?? "");
}
```

## Webhooks

For production, prefer webhooks over polling — no idle connections. See [webhooks.md](webhooks.md).

Cache video URLs — they expire. Don't re-fetch unnecessarily.
