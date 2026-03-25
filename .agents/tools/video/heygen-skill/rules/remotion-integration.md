---
name: remotion-integration
description: Using HeyGen avatar videos in Remotion compositions
metadata:
  tags: remotion, integration, workflow, video, composition
---

# HeyGen + Remotion Integration

## Quick Start

```typescript
// 1. Generate video (MP4 with background — most common)
const videoId = await generateVideo({
  video_inputs: [{
    character: { type: "avatar", avatar_id: avatarId, avatar_style: "normal" },
    voice: { type: "text", input_text: script, voice_id: voiceId },
    background: { type: "color", value: "#1a1a2e" },
  }],
  dimension: { width: 1920, height: 1080 },
});

// 2. Poll for completion (10-15+ min), then use in Remotion with OffthreadVideo
```

## Choosing the Right Output Format

| Your Composition | Recommended | Why |
|------------------|-------------|-----|
| Avatar as presenter with overlays | MP4 + background | Simpler, overlays go on top |
| Loom-style (avatar over screen recording) | WebM + `closeUp`, mask in Remotion | Need transparency, apply circle mask in CSS |
| Avatar overlaid ON other video/content | WebM (transparent) | Need to see through to content behind |
| Full-screen avatar | MP4 + background | Standard approach |

**Use MP4 with background for most cases.** Use WebM when you need to see content *behind* the avatar.

**Note:** WebM only supports `normal` and `closeUp` styles. For circular framing, use CSS `border-radius: 50%` in Remotion.

## Parallel Development Workflow

HeyGen video generation takes **10-15+ minutes**. Don't wait — work in parallel:

1. **Start HeyGen generation** — save `video_id` to a file, exit immediately
2. **Build Remotion composition** — use a placeholder or the avatar's `preview_video_url` (a short loop)
3. **Check HeyGen status** periodically or when done building
4. **Swap placeholder** for real video URL once ready

**Estimate duration from script**: ~150 words/minute → `wordCount / 150 * 60 * fps` frames.

**Composition tip**: Design components to work with or without the avatar video so motion graphics can be tested independently.

## Dimension Alignment

**Critical**: Match HeyGen output dimensions to your Remotion composition.

```typescript
// Shared dimension constants — use in both HeyGen and Remotion
const DIMENSIONS = {
  landscape_1080p: { width: 1920, height: 1080 },
  landscape_720p:  { width: 1280, height: 720 },
  portrait_1080p:  { width: 1080, height: 1920 },
  portrait_720p:   { width: 720,  height: 1280 },
  square_1080p:    { width: 1080, height: 1080 },
  square_720p:     { width: 720,  height: 720 },
} as const;
type DimensionPreset = keyof typeof DIMENSIONS;
```

## Generating Avatar Video

### Standard: MP4 with Background

```typescript
async function generateAvatarForRemotion(
  script: string,
  avatarId: string,
  voiceId: string,
  preset: DimensionPreset = "landscape_1080p",
  options: { style?: "normal" | "closeUp"; backgroundColor?: string } = {}
): Promise<string> {
  const { style = "normal", backgroundColor = "#1a1a2e" } = options;
  const response = await fetch("https://api.heygen.com/v2/video/generate", {
    method: "POST",
    headers: {
      "X-Api-Key": process.env.HEYGEN_API_KEY!,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      video_inputs: [{
        character: { type: "avatar", avatar_id: avatarId, avatar_style: style },
        voice: { type: "text", input_text: script, voice_id: voiceId },
        background: { type: "color", value: backgroundColor },
      }],
      dimension: DIMENSIONS[preset],
    }),
  });
  const { data } = await response.json();
  return data.video_id;
}
```

### Transparent Background (WebM)

Only use when you need to see content *behind* the avatar:

```typescript
// Different endpoint and structure from /v2/video/generate
const response = await fetch("https://api.heygen.com/v1/video.webm", {
  method: "POST",
  headers: {
    "X-Api-Key": process.env.HEYGEN_API_KEY!,
    "Content-Type": "application/json",
  },
  body: JSON.stringify({
    avatar_pose_id: avatarPoseId,   // Required: avatar pose ID
    avatar_style: "normal",         // "normal" or "closeUp" only
    input_text: script,
    voice_id: voiceId,
    dimension: { width: 1920, height: 1080 },
  }),
});
```

## Using HeyGen Video in Remotion

### Always Use OffthreadVideo

**Always use `OffthreadVideo` instead of `Video`** for HeyGen avatar videos. The basic `Video` component uses the browser's video decoder which isn't frame-accurate, causing jitter during rendering. `OffthreadVideo` extracts frames via FFmpeg for smooth, accurate playback. It's included in core `remotion` — no additional install needed.

### Composition Patterns

**Basic usage:**

```tsx
import { OffthreadVideo } from "remotion";

export const AvatarComposition: React.FC<{ avatarVideoUrl: string }> = ({ avatarVideoUrl }) => (
  <div style={{ flex: 1, backgroundColor: "#1a1a2e" }}>
    <OffthreadVideo src={avatarVideoUrl} style={{ width: "100%", height: "100%", objectFit: "contain" }} />
  </div>
);
```

**WebM with transparent background (layered):**

```tsx
import { OffthreadVideo, AbsoluteFill, Sequence } from "remotion";

export const AvatarWithMotionGraphics: React.FC<{ avatarWebmUrl: string }> = ({ avatarWebmUrl }) => (
  <AbsoluteFill>
    {/* Layer 1: Background/content */}
    <AbsoluteFill style={{ backgroundColor: "#1a1a2e" }}>
      <YourMotionGraphics />
    </AbsoluteFill>
    {/* Layer 2: Avatar with transparent background */}
    <OffthreadVideo
      src={avatarWebmUrl}
      transparent
      style={{ position: "absolute", bottom: 0, right: 0, width: "50%", height: "auto" }}
    />
    {/* Layer 3: Overlays on top */}
    <Sequence from={30}><AnimatedTitle text="Welcome!" /></Sequence>
  </AbsoluteFill>
);
```

**Loom-style (circle avatar over screen recording):**

```tsx
export const LoomStyleComposition: React.FC<{
  screenRecordingUrl: string;
  avatarWebmUrl: string; // Generated with avatar_style: "closeUp" via /v1/video.webm
}> = ({ screenRecordingUrl, avatarWebmUrl }) => (
  <AbsoluteFill>
    <OffthreadVideo src={screenRecordingUrl} style={{ width: "100%", height: "100%" }} />
    <OffthreadVideo
      src={avatarWebmUrl}
      transparent
      style={{
        position: "absolute", bottom: 40, left: 40,
        width: 180, height: 180,
        borderRadius: "50%", overflow: "hidden", objectFit: "cover",
      }}
    />
  </AbsoluteFill>
);
```

**Note:** WebM doesn't support `circle` style — use `normal` or `closeUp` and apply circular masking via CSS.

### Dynamic Duration with calculateMetadata

```tsx
import { CalculateMetadataFunction } from "remotion";

export const calculateAvatarMetadata: CalculateMetadataFunction<AvatarCompositionProps> =
  async ({ props }) => {
    const duration = await getVideoDurationInSeconds(props.avatarVideoUrl);
    return { durationInFrames: Math.ceil(duration * 30), fps: 30, width: 1920, height: 1080 };
  };

// In Root.tsx
<Composition
  id="AvatarVideo"
  component={AvatarComposition}
  calculateMetadata={calculateAvatarMetadata}
  defaultProps={{ avatarVideoUrl: "" }}
/>
```

## Complete Workflow

```typescript
async function generateAvatarVideoForRemotion(script: string, outputPath: string) {
  // 1. Generate HeyGen video
  const videoId = await generateAvatarForRemotion(script, "josh_lite3_20230714",
    "1bd001e7e50f421d891986aad5158bc8", "landscape_1080p");

  // 2. Wait for completion
  const avatarVideoUrl = await waitForVideo(videoId);
  const durationInFrames = Math.ceil(await getVideoDuration(avatarVideoUrl) * 30);

  // 3. Bundle and render
  const bundleLocation = await bundle({ entryPoint: "./remotion/src/index.ts" });
  const composition = await selectComposition({
    serveUrl: bundleLocation, id: "AvatarVideo", inputProps: { avatarVideoUrl },
  });
  await renderMedia({
    composition: { ...composition, durationInFrames },
    serveUrl: bundleLocation,
    codec: "h264",
    outputLocation: outputPath,
    inputProps: { avatarVideoUrl },
  });
  return outputPath;
}
```

## Best Practices

### Frame Rate Matching

HeyGen default is 25 fps. Consider this when setting Remotion fps:

```typescript
// Option 1: Match HeyGen's 25 fps
fps: 25

// Option 2: Use 30 fps with playback rate adjustment
<OffthreadVideo src={avatarVideoUrl} playbackRate={25/30} />
```

### URL vs Download

**Use URL directly** for development (Remotion Studio preview, fast iteration).

**Download first** for production (URLs expire after ~24h, repeated renders, offline rendering):

```typescript
async function downloadVideoWithRetry(url: string, outputPath: string, maxRetries = 5): Promise<string> {
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      const response = await fetch(url);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      await fs.promises.writeFile(outputPath, Buffer.from(await response.arrayBuffer()));
      return outputPath;
    } catch (error) {
      await new Promise((r) => setTimeout(r, 2000 * Math.pow(2, attempt)));
    }
  }
  throw new Error("Download failed after retries");
}

// Hybrid: prefer local if available
const videoSrc = fs.existsSync(localPath) ? staticFile("avatar.mp4") : avatarVideoUrl;
```

### Avatar Positioning

```typescript
const AVATAR_POSITIONS = {
  fullscreen:       { width: "100%", height: "100%", position: "center" },
  bottomRight:      { width: "40%", bottom: 0, right: 0 },
  bottomLeft:       { width: "40%", bottom: 0, left: 0 },
  pictureInPicture: { width: "25%", bottom: 20, right: 20 },
  leftThird:        { width: "33%", left: 0, height: "100%" },
};
```

## Output Formats

- **HeyGen**: MP4 (H.264), AAC audio, resolution as specified
- **Remotion**: H.264 default (`crf: 18` for high quality), VP8/VP9/ProRes also supported

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| Video not playing | CORS or format issue | Check URL accessibility; try downloading locally first |
| Dimension mismatch | HeyGen/Remotion dimensions differ | Use shared `VIDEO_CONFIG` constant for both |
| Video jitter/stutter | Using `Video` instead of `OffthreadVideo` | Switch to `OffthreadVideo`; add `transparent` prop for WebM |
| Audio drift | Frame rate mismatch or encoding issue | Verify source fps; re-encode with consistent settings |
