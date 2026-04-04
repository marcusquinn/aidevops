---
name: video-agent
description: One-shot prompt video generation with HeyGen Video Agent API
metadata:
  tags: video-agent, prompt, ai, automated, one-shot
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

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
| `config` | object | | See Config below |
| `files` | array | | Asset references (`{ asset_id: string }[]`) — upload first via `assets.md` |
| `callback_id` | string | | Custom ID for tracking |
| `callback_url` | string | | Webhook URL for completion notification |

### Config Object

| Field | Type | Description |
|-------|------|-------------|
| `duration_sec` | integer | Approximate duration (5-300s) |
| `avatar_id` | string | Lock a specific avatar (agent selects if omitted) |
| `orientation` | string | `"portrait"` or `"landscape"` |

## Response

```json
{
  "error": null,
  "data": { "video_id": "abc123" }
}
```

Poll `video_id` with the standard status endpoint — see [video-status.md](video-status.md).

## curl Example

```bash
curl -X POST "https://api.heygen.com/v1/video_agent/generate" \
  -H "X-Api-Key: $HEYGEN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Create a 60-second product demo for a new AI-powered calendar app. Professional but friendly tone, targeting busy professionals. Highlight smart scheduling and time zone handling.",
    "config": { "duration_sec": 60, "orientation": "landscape" },
    "files": [{ "asset_id": "uploaded_logo_id" }]
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

async function generateWithVideoAgent(
  request: VideoAgentRequest
): Promise<string> {
  const response = await fetch(
    "https://api.heygen.com/v1/video_agent/generate",
    {
      method: "POST",
      headers: {
        "X-Api-Key": process.env.HEYGEN_API_KEY!,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(request),
    }
  );

  const json = await response.json();
  if (json.error) throw new Error(`Video Agent failed: ${json.error}`);
  return json.data.video_id;
}

// Basic
const id1 = await generateWithVideoAgent({
  prompt: "Create a 30-second welcome video for new employees at a tech startup.",
});

// With config + files
const id2 = await generateWithVideoAgent({
  prompt: "Present quarterly sales results. Professional tone, data-focused.",
  config: { duration_sec: 120, avatar_id: "josh_lite3_20230714", orientation: "landscape" },
  files: [{ asset_id: "chart_screenshot_id" }],
});
```

## Writing Effective Prompts

Include: **purpose** ("product demo", "tutorial"), **duration hint** ("60-second"), **tone** ("professional", "casual"), **audience** ("for beginners", "enterprise"), **key points** ("highlight AI features and pricing").

```text
# Product demo
Create a 90-second product demo for our project management tool.
Target: startup founders and small team leads.
Highlight: Kanban boards, time tracking, Slack integration.
Tone: Professional but approachable.

# Educational
Explain how blockchain works in simple terms.
Duration: 2 minutes. Audience: complete beginners.
Use analogies, avoid jargon.

# Marketing
Create an energetic 30-second ad for our fitness app launch.
Target: health-conscious millennials.
Key message: AI-powered personalized workouts.
End with a strong call-to-action to download.
```

## Limitations and Best Practices

**Limitations:** Less control over exact script wording, scene composition, and avatar selection (unless `avatar_id` is set). Duration is approximate. May not match precise brand guidelines.

**Best practices:**

1. **Be specific** — more prompt detail = better results
2. **Set `duration_sec`** — for predictable length
3. **Lock avatar** — use `avatar_id` for consistency across videos
4. **Upload reference files** — help the agent understand your brand/product
5. **Use for drafts** — iterate on prompts before final production with `v2/video/generate`
