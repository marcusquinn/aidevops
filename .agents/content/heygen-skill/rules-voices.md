---
name: voices
description: Listing voices, locales, speed/pitch configuration for HeyGen
metadata:
  tags: voices, voice-id, locales, languages, tts, speech
---

# HeyGen Voices

## Listing Voices

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

Response: `{ error: null, data: { voices: Voice[] } }`. Each voice includes `voice_id`, `name`, `language`, `gender`, `preview_audio`, `support_pause`, `emotion_support`.

Filter example: `voices.find(v => v.language.toLowerCase().includes("english") && v.gender === "female" && v.emotion_support)`

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

## Voice Configuration

```typescript
// Basic TTS
voice: {
  type: "text",
  input_text: "Hello! Welcome to our presentation.",
  voice_id: "1bd001e7e50f421d891986aad5158bc8",
}

// Speed: 0.5-2.0 (default 1.0), Pitch: -20 to 20
voice: { ...above, speed: 1.2, pitch: 10 }

// Custom audio instead of TTS
voice: {
  type: "audio",
  audio_url: "https://example.com/my-audio.mp3",
}
```

## SSML Break Tags

Format: `<break time="Xs"/>` (X in seconds). Rules:

- Seconds with "s" suffix: `<break time="1.5s"/>`
- Space required before and after tag
- Self-closing only
- Consecutive breaks auto-combine (e.g., `1s` + `0.5s` = `1.5s`)
- Typical range: 0.5s-2s

```typescript
const script = `Welcome to our product demo. <break time="1s"/>
Today I'll show you three key features. <break time="0.5s"/>
First, let's look at the dashboard. <break time="1.5s"/>
As you can see, it's incredibly intuitive.`;
```

## Matching Voice to Avatar

**Preferred:** Use the avatar's `default_voice_id` (pre-matched).

```typescript
const { data } = await fetch(
  "https://api.heygen.com/v3/avatar_group.list?include_public=true",
  { headers: { "X-Api-Key": process.env.HEYGEN_API_KEY! } }
).then((r) => r.json());
const avatar = data.avatar_group_list.find((a: any) => a.default_voice_id);
// Use avatar.default_voice_id in voice config
```

See [avatars.md](avatars.md) for complete examples.

**Fallback** — match gender manually:

```typescript
const [avatars, voices] = await Promise.all([listAvatars(), listVoices()]);
const gender = preferredGender || "male";
const avatar = avatars.find((a) => a.gender === gender);
const voice = voices.find(
  (v) => v.gender === gender && v.language.toLowerCase().includes("english")
);
if (!avatar || !voice) throw new Error(`No ${gender} avatar/voice available`);
return { avatarId: avatar.avatar_id, voiceId: voice.voice_id };
```

## Best Practices

| Rule | Detail |
|------|--------|
| Match gender to avatar | Male voices with male avatars, female with female |
| Use default_voice_id | Pre-matched to avatar when available |
| Test previews | Listen to `preview_audio` before selecting |
| Match locale to audience | Consider accent and regional variant |
| Natural pacing | Adjust speed 0.9-1.1x for clarity |
| Add pauses | Use SSML breaks for natural speech flow |
| Validate availability | Verify voice_id exists before using |
| Multi-language | Assign different `voice_id` per scene in `video_inputs` |
