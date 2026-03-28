---
name: video-agent
description: One-shot prompt video generation with HeyGen Video Agent API
metadata:
  tags: video-agent, prompt, ai, automated, one-shot
---

# Video Agent API

Generates complete videos from a single text prompt. Automatically handles script writing, avatar selection, visuals, voiceover, pacing, and captions.

## When to Use

| Use Case | API |
|----------|-----|
| Quick video from idea / prototype / draft | Video Agent |
| Automated content generation at scale | Video Agent |
| Precise control over scenes, avatars, timing | Standard `v2/video/generate` |
| Specific avatar with exact script | Standard `v2/video/generate` |
| Brand-consistent production video | Standard `v2/video/generate` |

## Endpoint

```text
POST https://api.heygen.com/v1/video_agent/generate
```

## Request Fields

| Field | Type | Req | Description |
|-------|------|:---:|-------------|
| `prompt` | string | ✓ | Text prompt describing the video |
| `config` | object | | Configuration options (see below) |
| `files` | array | | Asset files to reference in generation |
| `callback_id` | string | | Custom ID for tracking |
| `callback_url` | string | | Webhook URL for completion notification |

### Config Object

| Field | Type | Description |
|-------|------|-------------|
| `duration_sec` | integer | Approximate duration in seconds (5-300) |
| `avatar_id` | string | Specific avatar (agent selects if omitted) |
| `orientation` | string | `"portrait"` or `"landscape"` |

### Files Array

| Field | Type | Description |
|-------|------|-------------|
| `asset_id` | string | Asset ID of uploaded file to reference |

## Response

```json
{
  "error": null,
  "data": { "video_id": "abc123" }
}
```

## curl Example

```bash
curl -X POST "https://api.heygen.com/v1/video_agent/generate" \
  -H "X-Api-Key: $HEYGEN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Create a 60-second product demo for a new AI-powered calendar app. Professional but friendly tone, targeting busy professionals. Highlight smart scheduling and time zone handling."
  }'
```

## TypeScript

```typescript
interface VideoAgentConfig {
  duration_sec?: number;       // 5-300 seconds
  avatar_id?: string;
  orientation?: "portrait" | "landscape";
}

interface VideoAgentRequest {
  prompt: string;
  config?: VideoAgentConfig;
  files?: { asset_id: string }[];
  callback_id?: string;
  callback_url?: string;
}

interface VideoAgentResponse {
  error: string | null;
  data: { video_id: string };
}

async function generateWithVideoAgent(
  prompt: string,
  config?: VideoAgentConfig
): Promise<string> {
  const response = await fetch(
    "https://api.heygen.com/v1/video_agent/generate",
    {
      method: "POST",
      headers: {
        "X-Api-Key": process.env.HEYGEN_API_KEY!,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ prompt, ...(config && { config }) }),
    }
  );

  const json: VideoAgentResponse = await response.json();
  if (json.error) throw new Error(`Video Agent failed: ${json.error}`);
  return json.data.video_id;
}
```

## Examples

### Basic

```typescript
const videoId = await generateWithVideoAgent(
  "Create a 30-second welcome video for new employees at a tech startup. Energetic and modern."
);
```

### With Duration and Orientation

```typescript
const videoId = await generateWithVideoAgent(
  "Explain the benefits of cloud computing for small businesses. Simple language, real-world examples.",
  { duration_sec: 90, orientation: "landscape" }
);
```

### With Specific Avatar

```typescript
const videoId = await generateWithVideoAgent(
  "Present quarterly sales results. Professional tone, data-focused.",
  { duration_sec: 120, avatar_id: "josh_lite3_20230714", orientation: "landscape" }
);
```

### With Reference Files

Upload assets first (see `assets.md`), then pass their IDs:

```typescript
const videoId = await generateWithVideoAgent(
  "Create a product demo showcasing our new dashboard. Use the uploaded screenshots as visual references.",
  { duration_sec: 60, orientation: "landscape" }
  // Pass files separately in the raw request body:
  // files: [{ asset_id: logoAssetId }, { asset_id: productImageId }]
);
```

## Writing Effective Prompts

Include: **purpose** ("product demo", "tutorial"), **duration hint** ("60-second"), **tone** ("professional", "casual"), **audience** ("for beginners", "enterprise"), **key points** ("highlight AI features and pricing").

**Product Demo:**

```text
Create a 90-second product demo for our project management tool.
Target: startup founders and small team leads.
Highlight: Kanban boards, time tracking, Slack integration.
Tone: Professional but approachable.
```

**Educational:**

```text
Explain how blockchain works in simple terms.
Duration: 2 minutes. Audience: complete beginners.
Use analogies, avoid jargon.
```

**Marketing:**

```text
Create an energetic 30-second ad for our fitness app launch.
Target: health-conscious millennials.
Key message: AI-powered personalized workouts.
End with a strong call-to-action to download.
```

## Checking Video Status

Video Agent returns a `video_id` — poll with the standard status endpoint:

```typescript
const videoUrl = await waitForVideo(videoId);
```

See [video-status.md](video-status.md) for polling implementation.

## Limitations

- Less control over exact script wording
- Avatar selection may vary if not specified
- Scene composition is automated
- May not match precise brand guidelines
- Duration is approximate, not exact

## Best Practices

1. **Be specific** — more detail in the prompt = better results
2. **Specify duration** — use `config.duration_sec` for predictable length
3. **Lock avatar if needed** — use `config.avatar_id` for consistency
4. **Upload reference files** — help the agent understand your brand/product
5. **Iterate on prompts** — refine based on results
6. **Use for drafts** — great for quick iterations before final production
