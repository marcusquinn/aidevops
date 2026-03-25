---
name: voices
description: Listing voices, locales, speed/pitch configuration for HeyGen
metadata:
  tags: voices, voice-id, locales, languages, tts, speech
---

# HeyGen Voices

HeyGen provides AI voices for different languages, accents, and styles.

## Listing Available Voices

```bash
curl -X GET "https://api.heygen.com/v2/voices" \
  -H "X-Api-Key: $HEYGEN_API_KEY"
```

```typescript
interface Voice {
  voice_id: string;
  name: string;
  language: string;
  gender: "male" | "female";
  preview_audio: string;
  support_pause: boolean;
  emotion_support: boolean;
}

async function listVoices(): Promise<Voice[]> {
  const response = await fetch("https://api.heygen.com/v2/voices", {
    headers: { "X-Api-Key": process.env.HEYGEN_API_KEY! },
  });
  const json = await response.json();
  if (json.error) throw new Error(json.error);
  return json.data.voices;
}
```

```python
import requests, os

def list_voices() -> list:
    data = requests.get(
        "https://api.heygen.com/v2/voices",
        headers={"X-Api-Key": os.environ["HEYGEN_API_KEY"]}
    ).json()
    if data.get("error"): raise Exception(data["error"])
    return data["data"]["voices"]
```

## Response Format

```json
{
  "error": null,
  "data": {
    "voices": [
      {
        "voice_id": "1bd001e7e50f421d891986aad5158bc8",
        "name": "Sara",
        "language": "English",
        "gender": "female",
        "preview_audio": "https://files.heygen.ai/...",
        "support_pause": true,
        "emotion_support": true
      }
    ]
  }
}
```

## Supported Languages

| Language | Code | Language | Code |
|----------|------|----------|------|
| English (US) | en-US | Japanese | ja-JP |
| English (UK) | en-GB | Korean | ko-KR |
| Spanish | es-ES | Italian | it-IT |
| Spanish (Latin) | es-MX | Dutch | nl-NL |
| French | fr-FR | Polish | pl-PL |
| German | de-DE | Arabic | ar-SA |
| Portuguese | pt-BR | Chinese (Mandarin) | zh-CN |

## Using Voices in Video Generation

```typescript
// Basic usage
voice: {
  type: "text",
  input_text: "Hello! Welcome to our presentation.",
  voice_id: "1bd001e7e50f421d891986aad5158bc8",
}

// With speed adjustment (range: 0.5–2.0, default 1.0)
voice: { ...above, speed: 1.2 }

// With pitch adjustment (range: -20 to 20)
voice: { ...above, pitch: 10 }

// Custom audio instead of TTS
voice: {
  type: "audio",
  audio_url: "https://example.com/my-audio.mp3",
}
```

## Adding Pauses with Break Tags

HeyGen supports SSML-style `<break>` tags. Format: `<break time="Xs"/>` where X is seconds.

**Rules:**
- Use seconds with "s" suffix: `<break time="1.5s"/>`
- Must have space before and after tag: `word <break time="1s"/> word`
- Self-closing tag only

```typescript
const script = `Welcome to our product demo. <break time="1s"/>
Today I'll show you three key features. <break time="0.5s"/>
First, let's look at the dashboard. <break time="1.5s"/>
As you can see, it's incredibly intuitive.`;
```

Multiple consecutive breaks are automatically combined (e.g., `1s` + `0.5s` = `1.5s`).

**Best practices:** 0.5s–2s is typical; longer feels unnatural. Add pauses where a human would breathe.

## Filtering Voices

```typescript
// Combined filter helper
async function findVoice(criteria: {
  language?: string;
  gender?: "male" | "female";
  supportPause?: boolean;
  emotionSupport?: boolean;
}): Promise<Voice | null> {
  const voices = await listVoices();
  return voices.find((v) => {
    if (criteria.language && !v.language.toLowerCase().includes(criteria.language.toLowerCase())) return false;
    if (criteria.gender && v.gender !== criteria.gender) return false;
    if (criteria.supportPause !== undefined && v.support_pause !== criteria.supportPause) return false;
    if (criteria.emotionSupport !== undefined && v.emotion_support !== criteria.emotionSupport) return false;
    return true;
  }) || null;
}

// Usage
const voice = await findVoice({ language: "english", gender: "female", emotionSupport: true });
```

## Matching Voice to Avatar

**Recommended:** Use the avatar's `default_voice_id` — it's pre-matched.

```typescript
const response = await fetch(
  "https://api.heygen.com/v3/avatar_group.list?include_public=true",
  { headers: { "X-Api-Key": process.env.HEYGEN_API_KEY! } }
);
const { data } = await response.json();
const avatar = data.avatar_group_list.find((a: any) => a.default_voice_id);
// Use avatar.default_voice_id in voice config
```

See [avatars.md](avatars.md) for complete examples.

**Fallback:** If no default voice, match gender manually:

```typescript
async function findMatchingAvatarAndVoice(preferredGender?: "male" | "female") {
  const [avatars, voices] = await Promise.all([listAvatars(), listVoices()]);
  const gender = preferredGender || "male";
  const avatar = avatars.find((a) => a.gender === gender);
  const voice = voices.find((v) => v.gender === gender && v.language.toLowerCase().includes("english"));
  if (!avatar || !voice) throw new Error(`No ${gender} avatar/voice available`);
  return { avatarId: avatar.avatar_id, voiceId: voice.voice_id, gender };
}
```

## Multi-Language Videos

Assign different `voice_id` values per scene in `video_inputs` — each scene can use a different language voice.

## Best Practices

| Rule | Detail |
|------|--------|
| Match gender to avatar | Male voices with male avatars, female with female |
| Use default_voice_id | Pre-matched to avatar when available |
| Test previews | Listen to `preview_audio` before selecting |
| Match locale to audience | Consider accent and regional variant |
| Natural pacing | Adjust speed 0.9–1.1x for clarity |
| Add pauses | Use SSML breaks for natural speech flow |
| Validate availability | Verify voice_id exists before using |
