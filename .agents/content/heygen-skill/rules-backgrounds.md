---
name: backgrounds
description: Solid colors, images, and video backgrounds for HeyGen videos
metadata:
  tags: backgrounds, color, image, video, customization
---

# Video Backgrounds

## Background Types

| Type | Description | Key field |
|------|-------------|-----------|
| `color` | Solid color | `value` (hex) |
| `image` | Static image | `url` |
| `video` | Looping video | `url` |

## Complete Example

One full scene showing background placement within `video_inputs`:

```typescript
const videoConfig = {
  video_inputs: [
    {
      character: {
        type: "avatar",
        avatar_id: "josh_lite3_20230714",
        avatar_style: "normal",
      },
      voice: {
        type: "text",
        input_text: "Hello with a colored background!",
        voice_id: "1bd001e7e50f421d891986aad5158bc8",
      },
      background: {
        type: "color",
        value: "#FFFFFF",
      },
    },
  ],
};
```

All examples below show only the `background` object — it replaces the `background` field in the scene above.

## Color Backgrounds

```typescript
background: { type: "color", value: "#FFFFFF" }
```

### Common Colors

| Color | Hex | Use Case |
|-------|-----|----------|
| White | `#FFFFFF` | Clean, professional |
| Black | `#000000` | Dramatic, cinematic |
| Blue | `#0066CC` | Corporate, trustworthy |
| Green | `#00FF00` | Chroma key (compositing) |
| Gray | `#808080` | Neutral, modern |

Green screen (`#00FF00`) enables post-production compositing.

## Image Backgrounds

### From URL

```typescript
background: {
  type: "image",
  url: "https://example.com/my-background.jpg",
}
```

### From Uploaded Asset

Upload first, then reference the asset URL:

```typescript
const assetId = await uploadFile("./background.jpg", "image/jpeg");

background: {
  type: "image",
  url: `https://files.heygen.ai/asset/${assetId}`,
}
```

### Image Requirements

- **Formats**: JPEG, PNG
- **Recommended size**: Match video dimensions (e.g., 1920x1080 for 1080p)
- **Aspect ratio**: Must match video aspect ratio
- **File size**: Under 10MB recommended

## Video Backgrounds

```typescript
background: {
  type: "video",
  url: "https://example.com/background-loop.mp4",
}
```

### Video Requirements

- **Format**: MP4 (H.264 codec recommended)
- **Looping**: Auto-loops if shorter than avatar content
- **Audio**: Background video audio is muted (add music in post-production)
- **File size**: Under 100MB recommended

## Different Backgrounds Per Scene

Each entry in `video_inputs` can have its own background. Mix types freely:

```typescript
const multiBackgroundConfig = {
  video_inputs: [
    {
      character: { type: "avatar", avatar_id: "josh_lite3_20230714", avatar_style: "normal" },
      voice: { type: "text", input_text: "Let me start with an introduction.", voice_id: "1bd001e7e50f421d891986aad5158bc8" },
      background: { type: "image", url: "https://example.com/office-bg.jpg" },
    },
    {
      character: { type: "avatar", avatar_id: "josh_lite3_20230714", avatar_style: "closeUp" },
      voice: { type: "text", input_text: "Now let me show you our product.", voice_id: "1bd001e7e50f421d891986aad5158bc8" },
      background: { type: "image", url: "https://example.com/product-bg.jpg" },
    },
    {
      character: { type: "avatar", avatar_id: "josh_lite3_20230714", avatar_style: "normal" },
      voice: { type: "text", input_text: "Get started today!", voice_id: "1bd001e7e50f421d891986aad5158bc8" },
      background: { type: "color", value: "#1a1a2e" },
    },
  ],
};
```

## Helper Functions

```typescript
type BackgroundType = "color" | "image" | "video";

interface Background {
  type: BackgroundType;
  value?: string; // for color
  url?: string;   // for image/video
}

function createColorBackground(hexColor: string): Background {
  return { type: "color", value: hexColor };
}

function createImageBackground(imageUrl: string): Background {
  return { type: "image", url: imageUrl };
}

function createVideoBackground(videoUrl: string): Background {
  return { type: "video", url: videoUrl };
}

// Presets
const backgrounds = {
  white: createColorBackground("#FFFFFF"),
  black: createColorBackground("#000000"),
  greenScreen: createColorBackground("#00FF00"),
  corporate: createColorBackground("#0066CC"),
};
```

## Best Practices

1. **Match dimensions** — background should match video dimensions
2. **Consider avatar position** — leave space where avatar will appear
3. **Use contrasting colors** — ensure avatar visibility against background
4. **Optimize file sizes** — compress images/videos for faster processing
5. **Test with green screen** — for professional post-production workflows
6. **Keep backgrounds simple** — avoid distracting elements behind avatar

## Common Issues

### Background Not Showing

```typescript
// Wrong: missing url/value
background: { type: "image" }

// Correct
background: { type: "image", url: "https://example.com/bg.jpg" }
```

### Aspect Ratio Mismatch

Background is cropped or stretched if dimensions don't match. Always match background to video dimensions:
- 1920x1080 video → 1920x1080 background
- 1080x1920 portrait → 1080x1920 background

### Video Background Audio

Background video audio is muted to avoid conflicting with the avatar's voice. Add background music as a separate audio track in post-production.
