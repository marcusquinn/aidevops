---
name: captions
description: Auto-generated captions and subtitle options for HeyGen videos
metadata:
  tags: captions, subtitles, accessibility, srt
---

# Video Captions

HeyGen auto-generates captions (subtitles) for videos, improving accessibility and engagement.

## Enabling Captions

Add `caption: true` to the video config for default styling, or pass a `CaptionConfig` object:

```typescript
const videoConfig = {
  video_inputs: [
    {
      character: { type: "avatar", avatar_id: "josh_lite3_20230714", avatar_style: "normal" },
      voice: { type: "text", input_text: "Hello! This video will have automatic captions.", voice_id: "1bd001e7e50f421d891986aad5158bc8" },
    },
  ],
  caption: true, // or CaptionConfig object below
};
```

## Caption Configuration

```typescript
interface CaptionConfig {
  enabled: boolean;
  style?: {
    font_family?: string;
    font_size?: number;    // px — minimum 24 for standard, larger for mobile
    font_color?: string;
    background_color?: string;
    position?: "top" | "bottom";
  };
  language?: string; // auto-detected from voice language if omitted
}
```

Styled example:

```typescript
caption: {
  enabled: true,
  style: {
    font_family: "Arial",
    font_size: 32,
    font_color: "#FFFFFF",
    background_color: "rgba(0, 0, 0, 0.7)",
    position: "bottom",
  },
}
```

Multi-language: captions are generated in the voice's language automatically. No extra config needed.

## Caption Presets

| Preset | Font | Size | Color | Background | Position |
|--------|------|------|-------|------------|----------|
| default | Arial | 32 | #FFFFFF | rgba(0,0,0,0.7) | bottom |
| minimal | Arial | 28 | #FFFFFF | transparent | bottom |
| bold | Arial | 36 | #FFFFFF | rgba(0,0,0,0.9) | bottom |
| branded | Roboto | 30 | #00D1FF | rgba(26,26,46,0.9) | bottom |

```typescript
interface CaptionStyle {
  font_family: string;
  font_size: number;
  font_color: string;
  background_color: string;
  position: "top" | "bottom";
}

const captionPresets: Record<string, CaptionStyle> = {
  default: { font_family: "Arial", font_size: 32, font_color: "#FFFFFF", background_color: "rgba(0, 0, 0, 0.7)", position: "bottom" },
  minimal: { font_family: "Arial", font_size: 28, font_color: "#FFFFFF", background_color: "transparent", position: "bottom" },
  bold:    { font_family: "Arial", font_size: 36, font_color: "#FFFFFF", background_color: "rgba(0, 0, 0, 0.9)", position: "bottom" },
  branded: { font_family: "Roboto", font_size: 30, font_color: "#00D1FF", background_color: "rgba(26, 26, 46, 0.9)", position: "bottom" },
};

function createCaptionConfig(preset: keyof typeof captionPresets) {
  return { enabled: true, style: captionPresets[preset] };
}
```

## Working with SRT Files

### Downloading SRT

```typescript
async function downloadSrt(videoId: string): Promise<string> {
  const response = await fetch(
    `https://api.heygen.com/v1/video/${videoId}/srt`,
    { headers: { "X-Api-Key": process.env.HEYGEN_API_KEY! } }
  );
  if (!response.ok) throw new Error("Failed to download SRT");
  return response.text();
}
```

### SRT Format

```srt
1
00:00:00,000 --> 00:00:03,000
Hello! This video will have

2
00:00:03,000 --> 00:00:06,000
automatic captions generated.

3
00:00:06,000 --> 00:00:09,000
They sync with the audio.
```

### Custom SRT for Translation

Provide your own SRT when translating videos:

```typescript
const translationConfig = {
  input_video_id: "original_video_id",
  output_languages: ["es-ES", "fr-FR"],
  srt_key: "path/to/custom.srt",
  srt_role: "input", // "input" or "output"
};
```

## Platform-Specific Positioning

- **TikTok / Instagram Reels**: Use `position: "top"` with `font_size: 42`+. Avoid bottom 20% (covered by platform UI).
- **YouTube**: Standard bottom captions. Also supports closed captions upload via YouTube Studio.
- **LinkedIn**: Captions highly recommended (many watch without sound). Professional styling preferred.

## Video Translation Integration

When using video translation, captions are auto-generated in the target language:

```typescript
const translationConfig = {
  input_video_id: "original_video_id",
  output_languages: ["es-ES"],
  // Captions generated in target language automatically
};
```

See [video-translation.md](video-translation.md) for details.

## Accessibility Best Practices

1. **Always enable captions** — improves accessibility for deaf/hard-of-hearing viewers
2. **Use high contrast** — white text on dark background or vice versa
3. **Readable font size** — at least 24px standard, larger for mobile
4. **Avoid covering content** — position captions away from key visual elements
5. **Sync timing** — ensure captions match audio timing accurately

## Limitations

- Caption styles may be limited by subscription tier
- Some advanced features require the web interface
- Multi-speaker caption detection has limited availability
- Caption accuracy depends on audio quality and speech clarity
