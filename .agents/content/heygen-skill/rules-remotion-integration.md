---
name: remotion-integration
description: Using HeyGen avatar videos in Remotion compositions
metadata:
  tags: remotion, integration, workflow, video, composition
---

# HeyGen + Remotion Integration

## Critical Rules

- **Always use `OffthreadVideo`** (not `Video`) — extracts frames via FFmpeg for frame-accurate rendering. `Video` uses the browser decoder and causes jitter.
- **HeyGen default is 25 fps.** Either set Remotion to `fps: 25`, or use `<OffthreadVideo playbackRate={25/30} />` at 30 fps.
- **HeyGen URLs expire ~24h.** Download for production; URL-direct is fine for dev iteration.
- **Match dimensions** between HeyGen output and Remotion composition — use shared constants (below).

## Output Format Selection

| Composition Type | Format | Reason |
|------------------|--------|--------|
| Avatar as presenter with overlays | MP4 + background | Overlays go on top |
| Loom-style (avatar over screen recording) | WebM + `closeUp`, CSS mask | Need transparency |
| Avatar overlaid on other content | WebM (transparent) | See through to content behind |
| Full-screen avatar | MP4 + background | Standard approach |

**Default to MP4 with background.** Use WebM only when content must show *behind* the avatar. WebM supports only `normal` and `closeUp` styles — use CSS `border-radius: 50%` for circular framing.

## Shared Dimension Constants

```typescript
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

### MP4 with Background (Standard)

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

## Parallel Development Workflow

HeyGen generation takes **10-15+ min**. Work in parallel:

1. Start generation — save `video_id`, exit immediately
2. Build Remotion composition with placeholder or `preview_video_url` (short loop)
3. Check status periodically
4. Swap placeholder for real URL once ready

**Duration estimate**: ~150 words/min → `wordCount / 150 * 60 * fps` frames. Design components to work with or without the avatar video for independent testing.

## Composition Patterns

### Basic (MP4 with background)

```tsx
import { OffthreadVideo } from "remotion";

export const AvatarComposition: React.FC<{ avatarVideoUrl: string }> = ({ avatarVideoUrl }) => (
  <div style={{ flex: 1, backgroundColor: "#1a1a2e" }}>
    <OffthreadVideo src={avatarVideoUrl} style={{ width: "100%", height: "100%", objectFit: "contain" }} />
  </div>
);
```

### WebM with Transparent Background (Layered)

```tsx
import { OffthreadVideo, AbsoluteFill, Sequence } from "remotion";

export const AvatarWithMotionGraphics: React.FC<{ avatarWebmUrl: string }> = ({ avatarWebmUrl }) => (
  <AbsoluteFill>
    <AbsoluteFill style={{ backgroundColor: "#1a1a2e" }}>
      <YourMotionGraphics />
    </AbsoluteFill>
    <OffthreadVideo
      src={avatarWebmUrl}
      transparent
      style={{ position: "absolute", bottom: 0, right: 0, width: "50%", height: "auto" }}
    />
    <Sequence from={30}><AnimatedTitle text="Welcome!" /></Sequence>
  </AbsoluteFill>
);
```

### Loom-Style (Circle Avatar over Screen Recording)

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

WebM doesn't support `circle` style — use `normal`/`closeUp` with CSS circular masking.

## Dynamic Duration

Use `calculateMetadata` to set composition duration from the avatar video. See `tools/video/remotion/calculate-metadata.md` for full patterns.

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

## Complete End-to-End Workflow

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

## Download with Retry (Production)

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

## Avatar Positioning Presets

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
| Video not playing | CORS or format issue | Check URL accessibility; try downloading locally |
| Dimension mismatch | HeyGen/Remotion dimensions differ | Use shared `DIMENSIONS` constant for both |
| Video jitter/stutter | Using `Video` instead of `OffthreadVideo` | Switch to `OffthreadVideo`; add `transparent` for WebM |
| Audio drift | Frame rate mismatch or encoding issue | Verify source fps; re-encode with consistent settings |
