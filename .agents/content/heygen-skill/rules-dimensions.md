---
name: dimensions
description: Resolution options (720p/1080p) and aspect ratios for HeyGen videos
metadata:
  tags: dimensions, resolution, aspect-ratio, 720p, 1080p, portrait, landscape
---

# Video Dimensions and Resolution

## Supported Resolutions

| Aspect Ratio | 720p (W x H) | 1080p (W x H) | Platforms |
|--------------|---------------|----------------|-----------|
| 16:9 | 1280 x 720 | 1920 x 1080 | YouTube, LinkedIn |
| 9:16 | 720 x 1280 | 1080 x 1920 | TikTok, Instagram Reels, YouTube Shorts |
| 1:1 | 720 x 720 | 1080 x 1080 | Instagram Feed |
| 4:3 | 960 x 720 | 1440 x 1080 | Presentations |
| 4:5 | 576 x 720 | 864 x 1080 | Instagram portrait |

**Platform defaults:** YouTube/LinkedIn → 16:9 1080p. TikTok/Reels/Shorts → 9:16 1080p. Instagram Feed → 1:1 1080p. Twitter/X → 16:9 720p.

## API Shape

```bash
curl -X POST "https://api.heygen.com/v2/video/generate" \
  -H "X-Api-Key: $HEYGEN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "video_inputs": [...],
    "dimension": {
      "width": 1920,
      "height": 1080
    }
  }'
```

## Dimension Helper

```typescript
type AspectRatio = "16:9" | "9:16" | "1:1" | "4:3" | "4:5";
type Quality = "720p" | "1080p";

interface Dimensions {
  width: number;
  height: number;
}

function getDimensions(aspectRatio: AspectRatio, quality: Quality): Dimensions {
  const configs: Record<AspectRatio, Record<Quality, Dimensions>> = {
    "16:9": {
      "720p": { width: 1280, height: 720 },
      "1080p": { width: 1920, height: 1080 },
    },
    "9:16": {
      "720p": { width: 720, height: 1280 },
      "1080p": { width: 1080, height: 1920 },
    },
    "1:1": {
      "720p": { width: 720, height: 720 },
      "1080p": { width: 1080, height: 1080 },
    },
    "4:3": {
      "720p": { width: 960, height: 720 },
      "1080p": { width: 1440, height: 1080 },
    },
    "4:5": {
      "720p": { width: 576, height: 720 },
      "1080p": { width: 864, height: 1080 },
    },
  };

  return configs[aspectRatio][quality];
}

// Usage
const youTubeDimensions = getDimensions("16:9", "1080p");
const tikTokDimensions = getDimensions("9:16", "1080p");
const instagramDimensions = getDimensions("1:1", "1080p");
```

## Avatar IV Dimensions

Photo-based avatars use orientation instead of explicit dimensions:

```typescript
type VideoOrientation = "portrait" | "landscape" | "square";

function getAvatarIVDimensions(orientation: VideoOrientation): Dimensions {
  switch (orientation) {
    case "portrait":
      return { width: 720, height: 1280 };
    case "landscape":
      return { width: 1280, height: 720 };
    case "square":
      return { width: 720, height: 720 };
  }
}
```

## Custom Dimensions

### Constraints

- **Minimum**: 128px on any side
- **Maximum**: 4096px on any side
- **Must be even numbers**: Both width and height must be divisible by 2

```typescript
function validateDimensions(width: number, height: number): boolean {
  if (width < 128 || height < 128) {
    throw new Error("Dimensions must be at least 128px");
  }
  if (width > 4096 || height > 4096) {
    throw new Error("Dimensions cannot exceed 4096px");
  }
  if (width % 2 !== 0 || height % 2 !== 0) {
    throw new Error("Dimensions must be even numbers");
  }
  return true;
}
```

## Credit Cost

| Resolution | Relative Cost |
|------------|---------------|
| 720p | Base rate |
| 1080p | ~1.5x base rate |

Use 720p for drafts/testing, 1080p for final output.

## Background Matching

Match background image/video dimensions to your video dimensions:

```typescript
const config = {
  video_inputs: [
    {
      character: {...},
      voice: {...},
      background: {
        type: "image",
        url: "https://example.com/1920x1080-background.jpg" // Match video dimensions
      }
    }
  ],
  dimension: { width: 1920, height: 1080 }
};
```

## Video Config Factory

Combines platform lookup, quality scaling, and avatar/voice config:

```typescript
interface VideoConfigOptions {
  script: string;
  avatarId: string;
  voiceId: string;
  platform: "youtube" | "tiktok" | "instagram_feed" | "instagram_story" | "linkedin";
  quality?: "720p" | "1080p";
}

function createVideoConfig(options: VideoConfigOptions) {
  const platformDimensions: Record<string, Dimensions> = {
    youtube: { width: 1920, height: 1080 },
    tiktok: { width: 1080, height: 1920 },
    instagram_feed: { width: 1080, height: 1080 },
    instagram_story: { width: 1080, height: 1920 },
    linkedin: { width: 1920, height: 1080 },
  };

  const dimension = { ...platformDimensions[options.platform] };

  // Scale down for 720p if requested
  if (options.quality === "720p") {
    dimension.width = Math.round((dimension.width * 720) / 1080);
    dimension.height = Math.round((dimension.height * 720) / 1080);
  }

  return {
    video_inputs: [
      {
        character: {
          type: "avatar",
          avatar_id: options.avatarId,
          avatar_style: "normal",
        },
        voice: {
          type: "text",
          input_text: options.script,
          voice_id: options.voiceId,
        },
      },
    ],
    dimension,
  };
}

// Usage
const tiktokVideo = createVideoConfig({
  script: "Hey everyone! Check this out!",
  avatarId: "josh_lite3_20230714",
  voiceId: "1bd001e7e50f421d891986aad5158bc8",
  platform: "tiktok",
  quality: "1080p",
});
```
