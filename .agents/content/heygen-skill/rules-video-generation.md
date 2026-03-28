---
name: video-generation
description: POST /v2/video/generate workflow and multi-scene videos for HeyGen
metadata:
  tags: video, generation, v2, scenes, workflow
---

# Video Generation

The `/v2/video/generate` endpoint creates AI avatar videos with HeyGen.

## Video Output Formats

| Endpoint | Format | Use Case |
|----------|--------|----------|
| `/v2/video/generate` | MP4 | **Standard** — videos with background (most common) |
| `/v1/video.webm` | WebM | Transparent background — only when overlaying avatar on video content |

## Basic Request

```bash
curl -X POST "https://api.heygen.com/v2/video/generate" \
  -H "X-Api-Key: $HEYGEN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "video_inputs": [{
      "character": {
        "type": "avatar",
        "avatar_id": "josh_lite3_20230714",
        "avatar_style": "normal"
      },
      "voice": {
        "type": "text",
        "input_text": "Hello! Welcome to HeyGen.",
        "voice_id": "1bd001e7e50f421d891986aad5158bc8"
      }
    }],
    "dimension": {"width": 1920, "height": 1080}
  }'
```

## Request Fields

### Top-Level

| Field | Type | Req | Description |
|-------|------|:---:|-------------|
| `video_inputs` | array | Y | 1-50 video input objects |
| `dimension` | object | | `{width, height}` |
| `title` | string | | Video name |
| `test` | boolean | | Watermarked, no credits consumed |
| `caption` | boolean | | Enable auto-captions |
| `callback_id` | string | | Custom ID for webhook tracking |
| `callback_url` | string | | URL for completion notification |
| `folder_id` | string | | Storage folder ID |

### video_inputs[].character

| Field | Type | Req | Description |
|-------|------|:---:|-------------|
| `type` | string | Y | `"avatar"` or `"talking_photo"` |
| `avatar_id` | string | Y* | Required when type=`"avatar"` |
| `talking_photo_id` | string | Y* | Required when type=`"talking_photo"` |
| `avatar_style` | string | | `"normal"`, `"closeUp"`, or `"circle"` |
| `scale` | number | | Avatar scale factor |
| `offset` | object | | Position offset `{x, y}` |

### video_inputs[].voice

| Field | Type | Req | Description |
|-------|------|:---:|-------------|
| `type` | string | Y | `"text"`, `"audio"`, or `"silence"` |
| `voice_id` | string | Y* | Required when type=`"text"` |
| `input_text` | string | Y* | Required when type=`"text"` |
| `audio_url` | string | Y* | Required when type=`"audio"` |
| `duration` | number | Y* | Seconds, required when type=`"silence"` |
| `speed` | number | | 0.5-2.0 (default 1.0) |
| `pitch` | number | | -20 to 20 (default 0) |

### video_inputs[].background

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | `"color"`, `"image"`, or `"video"` |
| `value` | string | Hex color (when type=`"color"`) |
| `url` | string | Image/video URL |
| `fit` | string | `"cover"` or `"contain"` |

## Multi-Scene Videos

Pass multiple objects in `video_inputs` (max 50). Each scene can have different style, background, and voice.

```typescript
const multiSceneConfig = {
  video_inputs: [
    {
      character: { type: "avatar", avatar_id: "josh_lite3_20230714", avatar_style: "normal" },
      voice: { type: "text", input_text: "Hello! Today I'll show you three key features.", voice_id: "1bd001e7e50f421d891986aad5158bc8" },
      background: { type: "color", value: "#1a1a2e" },
    },
    {
      character: { type: "avatar", avatar_id: "josh_lite3_20230714", avatar_style: "closeUp" },
      voice: { type: "text", input_text: "First, let's look at our dashboard.", voice_id: "1bd001e7e50f421d891986aad5158bc8" },
      background: { type: "image", url: "https://example.com/dashboard-bg.jpg" },
    },
  ],
  dimension: { width: 1920, height: 1080 },
};
```

## Production Workflow

Auto-selects first available avatar and its default voice when none specified. Uses polling from [video-status.md](video-status.md).

```typescript
async function generateVideo(config: VideoGenerateRequest): Promise<string> {
  const res = await fetch("https://api.heygen.com/v2/video/generate", {
    method: "POST",
    headers: { "X-Api-Key": process.env.HEYGEN_API_KEY!, "Content-Type": "application/json" },
    body: JSON.stringify(config),
  });
  const json = await res.json();
  if (json.error) throw new Error(json.error);
  return json.data.video_id;
}

async function generateAvatarVideo(script: string, options: { avatarId?: string; width?: number; height?: number } = {}) {
  const { width = 1920, height = 1080 } = options;
  let { avatarId } = options;

  if (!avatarId) {
    const list = await fetch("https://api.heygen.com/v2/avatars", {
      headers: { "X-Api-Key": process.env.HEYGEN_API_KEY! },
    }).then(r => r.json());
    if (!list.data?.avatars?.length) throw new Error("No avatars available");
    avatarId = list.data.avatars[0].avatar_id;
  }

  const { data: avatar } = await fetch(`https://api.heygen.com/v2/avatar/${avatarId}/details`, {
    headers: { "X-Api-Key": process.env.HEYGEN_API_KEY! },
  }).then(r => r.json());
  if (!avatar.default_voice_id) throw new Error(`Avatar ${avatar.name} has no default voice`);

  const videoId = await generateVideo({
    video_inputs: [{ character: { type: "avatar", avatar_id: avatar.id, avatar_style: "normal" },
      voice: { type: "text", input_text: script, voice_id: avatar.default_voice_id, speed: 1.0 },
      background: { type: "color", value: "#1a1a2e" } }],
    dimension: { width, height },
  });
  return { videoId, videoUrl: await waitForVideo(videoId), avatarId: avatar.id, voiceId: avatar.default_voice_id };
}
```

For polling (`waitForVideo`) and download patterns, see [video-status.md](video-status.md). Generation typically takes 10-15 min — set timeouts to 15-20 min.

## Script Features

**Pauses:** `<break time="1s"/>` — must have spaces before and after. See [voices.md](voices.md).

**Script length limits:**

| Tier | Max Characters |
|------|----------------|
| Free | ~500 |
| Creator | ~1,500 |
| Team | ~3,000 |
| Enterprise | ~5,000+ |

**Test mode:** `test: true` — watermarked output, no credits consumed.

## Transparent Background Videos (WebM)

Use WebM **only** when compositing the avatar over video content (e.g., Loom-style overlay). For overlays on top of the avatar, standard MP4 is sufficient. WebM only supports `normal` and `closeUp` styles — no `circle`. Apply circular masking in post.

### WebM Request Fields

| Field | Type | Req | Description |
|-------|------|:---:|-------------|
| `avatar_pose_id` | string | Y | Avatar pose ID |
| `avatar_style` | string | Y | `"normal"` or `"closeUp"` only |
| `input_text` | string | Y* | Required if not using `input_audio` |
| `voice_id` | string | Y* | Required with `input_text` |
| `input_audio` | string | Y* | Required if not using `input_text` |
| `dimension` | object | | `{width, height}` (default: 1280x720) |

```typescript
async function generateTransparentVideo(script: string, avatarPoseId: string, voiceId: string): Promise<string> {
  const { data } = await fetch("https://api.heygen.com/v1/video.webm", {
    method: "POST",
    headers: { "X-Api-Key": process.env.HEYGEN_API_KEY!, "Content-Type": "application/json" },
    body: JSON.stringify({ avatar_pose_id: avatarPoseId, avatar_style: "normal",
      input_text: script, voice_id: voiceId, dimension: { width: 1920, height: 1080 } }),
  }).then(r => r.json());
  return data.video_id;
}
```

WebM videos use the same status polling endpoint as MP4. For Loom-style compositing and other Remotion patterns, see [remotion-integration.md](rules-remotion-integration.md).

## Error Handling

Wrap `generateVideo()` in try/catch. Common error keywords: `"quota"` (insufficient credits), `"avatar"` (invalid avatar ID), `"voice"` (invalid voice ID), `"script"` (script too long or invalid).

## Best Practices

1. **Preview avatars first** — download `preview_image_url` before committing to generation (see [avatars.md](avatars.md))
2. **Use avatar's default voice** — `default_voice_id` is pre-matched for natural results; fallback: match gender manually (see [voices.md](voices.md))
3. **Use test mode** — validate configurations without consuming credits
4. **Set generous timeouts** — 15-20 min; generation often takes 10-15 min
5. **Consider async patterns** — save `video_id` and check status later for long videos (see [video-status.md](video-status.md))
6. **Match dimensions to use case** — see [dimensions.md](dimensions.md)
