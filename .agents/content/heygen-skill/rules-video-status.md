---
name: video-status
description: Polling patterns, status types, and retrieving download URLs for HeyGen videos
metadata:
  tags: video, status, polling, download, webhook
---

# Video Status and Polling

HeyGen video generation is asynchronous: store the `video_id`, poll until terminal state, then download or hand off to a webhook flow.

**Production:** Prefer webhooks over polling; see [rules-webhooks.md](rules-webhooks.md). Cache `video_url` — values expire.

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

## States and Response Shape

| Status | Meaning |
|--------|---------|
| `pending` | Queued for processing |
| `processing` | Being generated |
| `completed` | Ready for download |
| `failed` | Generation failed |

```json
// completed
{ "error": null, "data": { "video_id": "abc123", "status": "completed",
  "video_url": "https://files.heygen.ai/video/abc123.mp4",
  "thumbnail_url": "https://files.heygen.ai/thumbnail/abc123.jpg", "duration": 45.2 } }

// failed
{ "error": null, "data": { "video_id": "abc123", "status": "failed",
  "error": "Script too long for selected avatar" } }
```

## Timing

Typical: **5-15 min**. Peak load, long scripts, or 1080p: **20+ min**. Timeout: **15-20 min** (`900000-1200000` ms).

## Polling Pattern

Poll every few seconds with exponential backoff. For UI feedback, add `onProgress?: (status: string, elapsed: number) => void` on each iteration.

```typescript
async function waitForVideo(
  videoId: string,
  maxWaitMs = 900000,
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

## Download With Retry

`completed` means metadata is ready; the file URL may still take a moment to serve. Use exponential backoff.

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

## Resumable Workflow

Persist `video_id` to disk; don't hold an idle process open for long generations.

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
