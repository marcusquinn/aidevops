---
description: "Runway API - AI video, image, and audio generation (Gen-4, Veo 3, Act Two, ElevenLabs)"
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Runway API

Runway provides AI-powered video, image, and audio generation through a REST API with official Node.js and Python SDKs. Generate videos from images/text/video, create images from text with references, and produce speech, sound effects, voice dubbing, and voice isolation.

## When to Use

Read this subagent when working with:

- AI video generation (image-to-video, text-to-video, video-to-video)
- AI image generation (text-to-image with reference images)
- Character performance transfer (Act Two)
- Cinematic video generation (Veo 3/3.1)
- Text-to-speech and speech-to-speech voice conversion
- Sound effect generation
- Voice dubbing (multi-language) and voice isolation
- Programmatic media generation pipelines

## Quick Reference

| Endpoint | Purpose | Models |
|----------|---------|--------|
| `POST /v1/image_to_video` | Image to video | `gen4_turbo`, `veo3`, `veo3.1`, `veo3.1_fast` |
| `POST /v1/text_to_video` | Text to video | `veo3`, `veo3.1`, `veo3.1_fast` |
| `POST /v1/video_to_video` | Video to video | `gen4_aleph` |
| `POST /v1/text_to_image` | Text/image to image | `gen4_image`, `gen4_image_turbo`, `gemini_2.5_flash` |
| `POST /v1/character_performance` | Character control | `act_two` |
| `POST /v1/text_to_speech` | Text to speech | `eleven_multilingual_v2` |
| `POST /v1/speech_to_speech` | Voice conversion | `eleven_multilingual_sts_v2` |
| `POST /v1/sound_effect` | Sound effect gen | `eleven_text_to_sound_v2` |
| `POST /v1/voice_dubbing` | Multi-language dub | `eleven_voice_dubbing` |
| `POST /v1/voice_isolation` | Isolate voice | `eleven_voice_isolation` |
| `GET /v1/tasks/{id}` | Poll task status | - |
| `DELETE /v1/tasks/{id}` | Cancel/delete task | - |
| `POST /v1/uploads` | Upload ephemeral file | - |
| `GET /v1/organization` | Org info + credits | - |
| `POST /v1/organization/usage` | Credit usage query | - |

**Base URL**: `https://api.dev.runwayml.com`

**API Version**: `2024-11-06` (required header: `X-Runway-Version: 2024-11-06`)

## Authentication

Bearer token via `Authorization` header:

```bash
Authorization: Bearer $RUNWAYML_API_SECRET
```

Store the API secret:

```bash
aidevops secret set RUNWAYML_API_SECRET
```

Or in `~/.config/aidevops/credentials.sh`:

```bash
export RUNWAYML_API_SECRET="your-api-secret"
```

The SDKs automatically read `RUNWAYML_API_SECRET` from the environment.

## Models and Pricing

1 credit = $0.01.

### Video Models

| Model | Input | Pricing | Best For |
|-------|-------|---------|----------|
| `gen4_turbo` | Image | 5 credits/sec | Fast image-to-video, general purpose |
| `gen4_aleph` | Video + text/image | 15 credits/sec | Video-to-video transformation |
| `act_two` | Image or video | 5 credits/sec | Character facial/body performance |
| `veo3` | Text or image | 40 credits/sec | Cinematic with audio |
| `veo3.1` | Text or image | 40 credits/sec (audio), 20 (no audio) | Highest quality cinematic |
| `veo3.1_fast` | Text or image | 15 credits/sec (audio), 10 (no audio) | Fast cinematic |

### Image Models

| Model | Input | Pricing | Best For |
|-------|-------|---------|----------|
| `gen4_image` | Text + references | 5 credits (720p), 8 credits (1080p) | High quality with references |
| `gen4_image_turbo` | Text + references | 2 credits (any resolution) | Fast, cost-effective |
| `gemini_2.5_flash` | Text + references | 5 credits | Alternative style |

### Audio Models

| Model | Purpose | Pricing |
|-------|---------|---------|
| `eleven_multilingual_v2` | Text to speech | 1 credit per 50 characters |
| `eleven_text_to_sound_v2` | Sound effects | 1 credit per second of audio |
| `eleven_multilingual_sts_v2` | Speech to speech | 1 credit per 3s of audio |
| `eleven_voice_dubbing` | Voice dubbing | 1 credit per 2s of output audio |
| `eleven_voice_isolation` | Voice isolation | 1 credit per 6s of audio |

## Image-to-Video (Gen-4 Turbo)

The primary video generation endpoint. Transforms a static image into an animated video.

### cURL

```bash
curl -X POST https://api.dev.runwayml.com/v1/image_to_video \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RUNWAYML_API_SECRET" \
  -H "X-Runway-Version: 2024-11-06" \
  -d '{
    "model": "gen4_turbo",
    "promptImage": "https://example.com/image.jpg",
    "promptText": "A timelapse on a sunny day with clouds flying by",
    "ratio": "1280:720",
    "duration": 5
  }'
```

### Node.js SDK

```javascript
import RunwayML from '@runwayml/sdk';
const client = new RunwayML();

const task = await client.imageToVideo
  .create({
    model: 'gen4_turbo',
    promptImage: 'https://example.com/image.jpg',
    promptText: 'A timelapse on a sunny day with clouds flying by',
    ratio: '1280:720',
    duration: 5,
  })
  .waitForTaskOutput();
```

### Python SDK

```python
from runwayml import RunwayML
client = RunwayML()

task = client.image_to_video.create(
    model='gen4_turbo',
    prompt_image='https://example.com/image.jpg',
    prompt_text='A timelapse on a sunny day with clouds flying by',
    ratio='1280:720',
    duration=5,
).wait_for_task_output()
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `model` | string | Yes | `gen4_turbo`, `veo3`, `veo3.1`, `veo3.1_fast` |
| `promptImage` | string/array | Yes | HTTPS URL, data URI, or runway:// URI |
| `promptText` | string | No | Up to 1000 chars describing the animation |
| `ratio` | string | Yes | Output resolution (see below) |
| `duration` | integer | No | 2-10 seconds |
| `seed` | integer | No | 0-4294967295 for reproducibility |

### Supported Ratios (Gen-4 Turbo)

```text
Landscape: 1280:720, 1584:672, 1104:832
Portrait:  720:1280, 832:1104
Square:    960:960
```

## Text-to-Video (Veo 3/3.1)

Generate video from text only. Available with Veo models.

```bash
curl -X POST https://api.dev.runwayml.com/v1/text_to_video \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RUNWAYML_API_SECRET" \
  -H "X-Runway-Version: 2024-11-06" \
  -d '{
    "model": "veo3.1",
    "promptText": "A cinematic shot of a mountain landscape at golden hour",
    "ratio": "1920:1080",
    "duration": 8,
    "audio": true
  }'
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `model` | string | Yes | `veo3`, `veo3.1`, `veo3.1_fast` |
| `promptText` | string | Yes | Up to 1000 chars |
| `ratio` | string | Yes | `1280:720`, `720:1280`, `1080:1920`, `1920:1080` |
| `duration` | number | No | 4, 6, or 8 seconds |
| `audio` | boolean | No | Generate audio (default: true, affects pricing) |

## Video-to-Video (Gen-4 Aleph)

Transform an existing video with text guidance and optional image references.

```bash
curl -X POST https://api.dev.runwayml.com/v1/video_to_video \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RUNWAYML_API_SECRET" \
  -H "X-Runway-Version: 2024-11-06" \
  -d '{
    "model": "gen4_aleph",
    "videoUri": "https://example.com/input.mp4",
    "promptText": "Add dramatic lighting and cinematic color grading",
    "references": [
      {"type": "image", "uri": "https://example.com/style-ref.jpg"}
    ]
  }'
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `model` | string | Yes | `gen4_aleph` |
| `videoUri` | string | Yes | HTTPS URL, data URI, or runway:// URI |
| `promptText` | string | Yes | Up to 1000 chars |
| `references` | array | No | Up to 1 image reference |
| `seed` | integer | No | 0-4294967295 |

## Text/Image to Image (Gen-4 Image)

Generate images from text with optional reference images. Use `@tag` syntax in prompts to reference tagged images.

```bash
curl -X POST https://api.dev.runwayml.com/v1/text_to_image \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RUNWAYML_API_SECRET" \
  -H "X-Runway-Version: 2024-11-06" \
  -d '{
    "model": "gen4_image",
    "promptText": "@subject in a cyberpunk city at night",
    "ratio": "1920:1080",
    "referenceImages": [
      {"uri": "https://example.com/person.jpg", "tag": "subject"}
    ]
  }'
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `model` | string | Yes | `gen4_image`, `gen4_image_turbo`, `gemini_2.5_flash` |
| `promptText` | string | Yes | Up to 1000 chars, use `@tag` for references |
| `ratio` | string | Yes | See supported ratios below |
| `referenceImages` | array | Varies | 1-3 images with `uri` and optional `tag` |
| `seed` | integer | No | 0-4294967295 |

### Supported Ratios (Gen-4 Image)

```text
Square:    1024:1024, 1080:1080, 720:720
Landscape: 1168:880, 1360:768, 1440:1080, 1808:768, 1920:1080, 2112:912, 1280:720, 960:720, 1680:720
Portrait:  1080:1440, 1080:1920, 720:1280, 720:960
```

## Character Performance (Act Two)

Control a character's facial expressions and body movements using a reference performance video.

```javascript
const task = await client.characterPerformance
  .create({
    model: 'act_two',
    character: {
      type: 'image',
      uri: 'https://example.com/character.jpg',
    },
    reference: {
      type: 'video',
      uri: 'https://example.com/performance.mp4',
    },
    ratio: '1280:720',
    bodyControl: true,
    expressionIntensity: 4,
  })
  .waitForTaskOutput();
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `model` | string | Yes | `act_two` |
| `character` | object | Yes | `{type: "image"/"video", uri: "..."}` |
| `reference` | object | Yes | `{type: "video", uri: "..."}` (3-30s video) |
| `bodyControl` | boolean | No | Enable body movement transfer |
| `expressionIntensity` | integer | No | 1-5 (default: 3) |
| `ratio` | string | No | Output resolution |

## Text-to-Speech

Generate speech from text using ElevenLabs voices via Runway.

```javascript
const task = await client.textToSpeech
  .create({
    model: 'eleven_multilingual_v2',
    promptText: 'The quick brown fox jumps over the lazy dog',
    voice: {
      type: 'runway-preset',
      presetId: 'Leslie',
    },
  })
  .waitForTaskOutput();
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `model` | string | Yes | `eleven_multilingual_v2` |
| `promptText` | string | Yes | Up to 1000 chars of text to speak |
| `voice` | object | Yes | `{type: "runway-preset", presetId: "..."}` |

### Available Voice Presets

```text
Maya, Arjun, Serene, Bernard, Billy, Mark, Clint, Mabel, Chad, Leslie,
Eleanor, Elias, Elliot, Grungle, Brodie, Sandra, Kirk, Kylie, Lara, Lisa,
Malachi, Marlene, Martin, Miriam, Monster, Paula, Pip, Rusty, Ragnar,
Xylar, Maggie, Jack, Katie, Noah, James, Rina, Ella, Mariah, Frank,
Claudia, Niki, Vincent, Kendrick, Myrna, Tom, Wanda, Benjamin, Kiana, Rachel
```

## Speech-to-Speech

Convert speech from one voice to another in audio or video files.

```javascript
const task = await client.speechToSpeech
  .create({
    model: 'eleven_multilingual_sts_v2',
    media: {
      type: 'audio',
      uri: 'https://example.com/audio.mp3',
    },
    voice: {
      type: 'runway-preset',
      presetId: 'Maggie',
    },
    removeBackgroundNoise: true,
  })
  .waitForTaskOutput();
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `model` | string | Yes | `eleven_multilingual_sts_v2` |
| `media` | object | Yes | `{type: "audio"/"video", uri: "..."}` |
| `voice` | object | Yes | `{type: "runway-preset", presetId: "..."}` |
| `removeBackgroundNoise` | boolean | No | Remove background noise |

## Sound Effects

Generate sound effects from text descriptions.

```javascript
const task = await client.soundEffect
  .create({
    model: 'eleven_text_to_sound_v2',
    promptText: 'A thunderstorm with heavy rain',
    duration: 10,
    loop: true,
  })
  .waitForTaskOutput();
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `model` | string | Yes | `eleven_text_to_sound_v2` |
| `promptText` | string | Yes | Up to 3000 chars describing the sound |
| `duration` | number | No | 0.5-30 seconds (auto if omitted) |
| `loop` | boolean | No | Seamless loop output (default: false) |

## Voice Dubbing

Dub audio content to a target language with optional voice cloning.

```javascript
const task = await client.voiceDubbing
  .create({
    model: 'eleven_voice_dubbing',
    audioUri: 'https://example.com/audio.mp3',
    targetLang: 'es',
  })
  .waitForTaskOutput();
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `model` | string | Yes | `eleven_voice_dubbing` |
| `audioUri` | string | Yes | HTTPS URL, data URI, or runway:// URI |
| `targetLang` | string | Yes | Target language code (see below) |
| `disableVoiceCloning` | boolean | No | Use generic voice instead of cloning |
| `dropBackgroundAudio` | boolean | No | Remove background audio |
| `numSpeakers` | integer | No | Number of speakers (auto-detected) |

### Supported Languages

```text
en, hi, pt, zh, es, fr, de, ja, ar, ru, ko, id, it, nl, tr, pl, sv,
fil, ms, ro, uk, el, cs, da, fi, bg, hr, sk, ta
```

## Voice Isolation

Isolate voice from background audio. Input must be 4.6s-3600s duration.

```javascript
const task = await client.voiceIsolation
  .create({
    model: 'eleven_voice_isolation',
    audioUri: 'https://example.com/audio.mp3',
  })
  .waitForTaskOutput();
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `model` | string | Yes | `eleven_voice_isolation` |
| `audioUri` | string | Yes | HTTPS URL, data URI, or runway:// URI |

## Task Management

All generation endpoints return a task ID. Tasks are processed asynchronously.

### Poll Task Status

```bash
curl https://api.dev.runwayml.com/v1/tasks/{task_id} \
  -H "Authorization: Bearer $RUNWAYML_API_SECRET" \
  -H "X-Runway-Version: 2024-11-06"
```

**Status values**: `PENDING`, `THROTTLED`, `RUNNING`, `SUCCEEDED`, `FAILED`

**Polling interval**: 5+ seconds recommended, with jitter and exponential backoff.

### Cancel/Delete Task

```bash
curl -X DELETE https://api.dev.runwayml.com/v1/tasks/{task_id} \
  -H "Authorization: Bearer $RUNWAYML_API_SECRET" \
  -H "X-Runway-Version: 2024-11-06"
```

### SDK Built-in Polling

Both SDKs provide `.waitForTaskOutput()` / `.wait_for_task_output()` which handles polling automatically with a 10-minute default timeout.

```javascript
// Node.js - handles polling, throws TaskFailedError on failure
import { TaskFailedError } from '@runwayml/sdk';
try {
  const task = await client.imageToVideo
    .create({ model: 'gen4_turbo', promptImage: '...', ratio: '1280:720' })
    .waitForTaskOutput({ timeout: 5 * 60 * 1000 });
} catch (error) {
  if (error instanceof TaskFailedError) {
    console.error('Failed:', error.taskDetails);
  }
}
```

## File Uploads

Upload local files for use in generation requests. Returns a `runway://` URI.

```javascript
import fs from 'node:fs';
const uploadUri = await client.uploads.createEphemeral(
  fs.createReadStream('./input.mp4')
);
// Use uploadUri in videoUri, promptImage, etc.
```

**Ephemeral uploads expire after 24 hours.**

## Input Requirements

### Images

- Formats: JPEG, PNG, WebP (no GIF)
- URL size limit: 16MB, data URI: 5MB, ephemeral upload: 200MB
- Minimum recommended: 640x640px, maximum: 4K

### Videos

- Formats: MP4 (H.264/H.265/AV1), MOV, MKV, WebM
- URL size limit: 32MB, data URI: 16MB, ephemeral upload: 200MB

### Audio

- Formats: MP3, WAV, FLAC, M4A (AAC/ALAC), AAC
- URL size limit: 32MB, data URI: 16MB, ephemeral upload: 200MB
- Voice isolation requires 4.6s-3600s duration

### Data URI Support

Pass base64-encoded images directly instead of URLs:

```javascript
const imageBuffer = fs.readFileSync('example.png');
const dataUri = `data:image/png;base64,${imageBuffer.toString('base64')}`;
// Use dataUri in promptImage field
```

Note: base64 encoding increases size by ~33%. A 5MB data URI limit means ~3.3MB binary max.

## Organization and Credits

### Check Credit Balance

```javascript
const details = await client.organization.retrieve();
console.log(details.creditBalance);
```

### Query Usage

```javascript
const usage = await client.organization.retrieveUsage({
  startDate: '2026-01-01',
  beforeDate: '2026-02-01',
});
```

## Helper Script

Use `runway-helper.sh` for CLI-based generation:

```bash
# Check credit balance
runway-helper.sh credits

# Generate video from image
runway-helper.sh video --image https://example.com/photo.jpg \
  --prompt "Camera slowly pans across the scene" \
  --model gen4_turbo --ratio 1280:720 --duration 5

# Generate video from text (Veo models)
runway-helper.sh video --prompt "A cinematic mountain landscape" \
  --model veo3.1 --ratio 1920:1080 --duration 8

# Generate image
runway-helper.sh image --prompt "@subject in a garden" \
  --ref https://example.com/person.jpg:subject \
  --model gen4_image --ratio 1920:1080

# Text-to-speech
runway-helper.sh tts --text "Hello world" --voice Leslie

# Speech-to-speech voice conversion
runway-helper.sh sts --audio https://example.com/audio.mp3 --voice Maggie

# Sound effects
runway-helper.sh sfx --prompt "A thunderstorm with heavy rain" --duration 10

# Voice dubbing
runway-helper.sh dub --audio https://example.com/audio.mp3 --lang es

# Voice isolation
runway-helper.sh isolate --audio https://example.com/audio.mp3

# Check task status
runway-helper.sh status {task-id}

# Cancel a task
runway-helper.sh cancel {task-id}

# Query usage
runway-helper.sh usage --start 2026-01-01 --end 2026-02-01
```

## Model Selection Guide

| Use Case | Recommended Model | Cost Example |
|----------|-------------------|--------------|
| Quick image-to-video | `gen4_turbo` | $0.50 / 10s |
| Cinematic with audio | `veo3.1` | $4.00 / 10s |
| Fast cinematic | `veo3.1_fast` | $1.50 / 10s |
| Video transformation | `gen4_aleph` | $1.50 / 10s |
| Character animation | `act_two` | $0.50 / 10s |
| Fast image gen | `gen4_image_turbo` | $0.02 / image |
| Quality image gen | `gen4_image` (1080p) | $0.08 / image |
| Text-to-speech | `eleven_multilingual_v2` | $0.01 / 50 chars |
| Sound effects | `eleven_text_to_sound_v2` | $0.01 / second |
| Voice conversion | `eleven_multilingual_sts_v2` | $0.01 / 3s |
| Voice dubbing | `eleven_voice_dubbing` | $0.01 / 2s |
| Voice isolation | `eleven_voice_isolation` | $0.01 / 6s |

## Content Moderation

Runway applies automatic content moderation. You can adjust the public figure threshold:

```json
{
  "contentModeration": {
    "publicFigureThreshold": "low"
  }
}
```

Set to `"low"` to be less strict about recognizable public figures.

## Error Handling

| HTTP Code | Meaning |
|-----------|---------|
| 200 | Task created successfully |
| 400 | Bad request (invalid parameters) |
| 401 | Invalid API key |
| 404 | Task not found or deleted |
| 429 | Rate limit exceeded |

SDK error classes:

- `TaskFailedError` - Generation failed (check `.taskDetails`)
- `TaskTimedOutError` - Polling timeout exceeded

## Runway vs Higgsfield

| Feature | Runway | Higgsfield |
|---------|--------|------------|
| Video models | Gen-4, Veo 3/3.1, Aleph, Act Two | DOP, Kling, Seedance |
| Image models | Gen-4 Image, Gemini 2.5 Flash | Soul, Popcorn, Seedream |
| Audio models | ElevenLabs TTS/STS/SFX/dubbing/isolation | None |
| Auth | Bearer token (single key) | API key + secret (dual) |
| SDKs | Official Node.js + Python | Python SDK |
| Task polling | Built-in `.waitForTaskOutput()` | Manual polling |
| Character control | Act Two (performance transfer) | Character consistency (reference ID) |
| Best for | Full media pipeline (video+image+audio) | Multi-model access, budget options |

## Related

- `tools/video/higgsfield.md` - Higgsfield API (alternative multi-model platform)
- `tools/video/video-prompt-design.md` - Video prompt engineering
- `content/production/video.md` - Video production pipeline
- `tools/vision/image-generation.md` - Image generation overview
