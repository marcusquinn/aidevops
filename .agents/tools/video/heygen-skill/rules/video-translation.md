---
name: video-translation
description: Translating videos, quality/fast modes, and dubbing for HeyGen
metadata:
  tags: translation, dubbing, localization, multi-language
---

# Video Translation

HeyGen translates and dubs existing videos into multiple languages with lip-sync and voice cloning.

## Creating a Translation Job

**Endpoint:** `POST https://api.heygen.com/v2/video_translate`

| Field | Type | Req | Description |
|-------|------|:---:|-------------|
| `video_url` | string | ✓* | URL of video to translate (*or `video_id`) |
| `video_id` | string | ✓* | HeyGen video ID (*or `video_url`) |
| `output_language` | string | ✓ | Target language code (e.g., `es-ES`) |
| `title` | string | | Name for the translated video |
| `translate_audio_only` | boolean | | Audio only, no lip-sync (faster) |
| `speaker_num` | number | | Number of speakers in video |
| `callback_id` | string | | Custom ID for webhook tracking |
| `callback_url` | string | | URL for completion notification |

**Either** `video_url` **or** `video_id` required.

```bash
curl -X POST "https://api.heygen.com/v2/video_translate" \
  -H "X-Api-Key: $HEYGEN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"video_url": "https://example.com/original.mp4", "output_language": "es-ES", "title": "Spanish Version"}'
```

```typescript
async function translateVideo(config: {
  video_url?: string; video_id?: string; output_language: string;
  title?: string; translate_audio_only?: boolean; speaker_num?: number;
  callback_id?: string; callback_url?: string;
}): Promise<string> {
  const res = await fetch("https://api.heygen.com/v2/video_translate", {
    method: "POST",
    headers: { "X-Api-Key": process.env.HEYGEN_API_KEY!, "Content-Type": "application/json" },
    body: JSON.stringify(config),
  });
  const json = await res.json();
  if (json.error) throw new Error(json.error);
  return json.data.video_translate_id;
}
```

## Supported Languages

| Language | Code | Language | Code |
|----------|------|----------|------|
| English (US) | en-US | Japanese | ja-JP |
| Spanish (Spain) | es-ES | Korean | ko-KR |
| Spanish (Mexico) | es-MX | Chinese (Mandarin) | zh-CN |
| French | fr-FR | Hindi | hi-IN |
| German | de-DE | Arabic | ar-SA |
| Italian | it-IT | Portuguese (Brazil) | pt-BR |

## Advanced Options (v4 API)

**Endpoint:** `POST https://api.heygen.com/v2/video_translate` (v4 fields)

| Field | Type | Description |
|-------|------|-------------|
| `input_video_id` | string | HeyGen video ID (v4 alternative to `video_url`) |
| `google_url` | string | Google Drive/Cloud URL |
| `output_languages` | string[] | Multiple target languages |
| `name` | string | Job name (required in v4) |
| `srt_key` | string | Path to custom SRT file |
| `srt_role` | `"input"` \| `"output"` | Use SRT as source transcript or output |
| `instruction` | string | Translation guidance |
| `vocabulary` | string[] | Terms to preserve as-is |
| `brand_voice_id` | string | Brand voice profile |
| `input_language` | string | Override source language detection |
| `keep_the_same_format` | boolean | Preserve original formatting |
| `enable_video_stretching` | boolean | Stretch video to fit translated audio |
| `disable_music_track` | boolean | Remove background music |
| `enable_speech_enhancement` | boolean | Improve audio quality |

**Multi-language + vocabulary example:**

```typescript
const config = {
  input_video_id: "original_video_id",
  output_languages: ["es-ES", "fr-FR", "de-DE"],
  name: "Multi-language translations",
  vocabulary: ["SuperWidget", "Pro Max", "TechCorp"],
  srt_key: "path/to/custom-subtitles.srt",
  srt_role: "input" as const,
};
```

## Checking Translation Status

**Endpoint:** `GET https://api.heygen.com/v1/video_translate/{translate_id}`

```bash
curl "https://api.heygen.com/v1/video_translate/{translate_id}" \
  -H "X-Api-Key: $HEYGEN_API_KEY"
```

**Status values:** `pending` | `processing` | `completed` | `failed`

```typescript
async function getTranslateStatus(translateId: string) {
  const res = await fetch(`https://api.heygen.com/v1/video_translate/${translateId}`,
    { headers: { "X-Api-Key": process.env.HEYGEN_API_KEY! } });
  const json = await res.json();
  if (json.error) throw new Error(json.error);
  return json.data; // { id, status, video_url?, message? }
}
```

## Polling for Completion

```typescript
async function waitForTranslation(
  translateId: string,
  maxWaitMs = 1800000, // 30 min — translations take longer than generation
  pollIntervalMs = 30000
): Promise<string> {
  const start = Date.now();
  while (Date.now() - start < maxWaitMs) {
    const status = await getTranslateStatus(translateId);
    if (status.status === "completed") return status.video_url!;
    if (status.status === "failed") throw new Error(status.message || "Translation failed");
    await new Promise((r) => setTimeout(r, pollIntervalMs));
  }
  throw new Error("Translation timed out");
}
```

## Complete Workflow

```typescript
// Single language
const translateId = await translateVideo({ video_url: videoUrl, output_language: "es-ES" });
const translatedUrl = await waitForTranslation(translateId);

// Batch — parallel dispatch, sequential wait
const jobs = await Promise.all(
  ["es-ES", "fr-FR", "de-DE", "ja-JP"].map(async (lang) => ({
    lang,
    translateId: await translateVideo({ video_url: sourceUrl, output_language: lang }),
  }))
);
const results: Record<string, string> = {};
for (const job of jobs) {
  try { results[job.lang] = await waitForTranslation(job.translateId); }
  catch (e) { results[job.lang] = `error: ${e.message}`; }
}
```

## Error Handling

```typescript
try {
  const url = await waitForTranslation(translateId);
} catch (error) {
  if (error.message.includes("quota"))    throw new Error("Insufficient credits");
  if (error.message.includes("duration")) throw new Error("Video too long");
  if (error.message.includes("format"))   throw new Error("Unsupported video format");
  throw error;
}
```

## Features

| Feature | Behaviour |
|---------|-----------|
| Lip sync | Auto-adjusts speaker lip movements to match translated audio |
| Voice cloning | Matches original speaker's voice characteristics in target language |
| Music track | Use `disable_music_track: true` to remove background music |
| Speech enhancement | Use `enable_speech_enhancement: true` to improve audio quality |
| Audio-only mode | `translate_audio_only: true` — faster, no lip-sync |

## Best Practices & Limitations

**Best practices:**
- Use high-quality source video with clear speech
- Single-speaker content yields best results
- Moderate pacing — very fast speech reduces quality
- Test with short clips before translating long videos
- Allow extra processing time vs. standard generation

**Limitations:**
- Max video duration varies by subscription tier
- Background noise reduces translation accuracy
- Multi-speaker detection has limits
- Complex audio scenarios may reduce quality
