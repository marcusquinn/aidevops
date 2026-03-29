---
name: photo-avatars
description: Creating avatars from photos (talking photos) for HeyGen
metadata:
  tags: photo-avatar, talking-photo, avatar-iv, image-to-video
---

# Photo Avatars (Talking Photos)

Photo avatars animate a static photo to speak. Three tiers of quality:

| Type | Quality |
|------|---------|
| Talking Photo | Good |
| Photo Avatar | Better |
| Avatar IV | Best |

## Talking Photo

```typescript
// 1. Upload photo
const assetId = await uploadFile("./portrait.jpg", "image/jpeg");

// 2. Create talking photo
const response = await fetch("https://api.heygen.com/v2/talking_photo", {
  method: "POST",
  headers: { "X-Api-Key": process.env.HEYGEN_API_KEY!, "Content-Type": "application/json" },
  body: JSON.stringify({ image_url: `https://files.heygen.ai/asset/${assetId}` }),
});
const { data: { talking_photo_id } } = await response.json();

// 3. Use in video
const videoConfig = {
  video_inputs: [{
    character: { type: "talking_photo", talking_photo_id },
    voice: { type: "text", input_text: "Hello!", voice_id: "1bd001e7e50f421d891986aad5158bc8" },
  }],
  dimension: { width: 1920, height: 1080 },
};
const videoId = await generateVideo(videoConfig);
```

## Avatar IV

```typescript
const response = await fetch("https://api.heygen.com/v2/video/av4/generate", {
  method: "POST",
  headers: { "X-Api-Key": process.env.HEYGEN_API_KEY!, "Content-Type": "application/json" },
  body: JSON.stringify({
    photo_s3_key: "path/to/photo.jpg",
    script: "Hello! This is Avatar IV.",
    voice_id: "1bd001e7e50f421d891986aad5158bc8",
    video_orientation: "portrait",   // "portrait" | "landscape" | "square"
    fit: "cover",                    // "cover" (fill, may crop) | "contain" (fit, may show bg)
    custom_motion_prompt: "nodding head and smiling",
    enhance_custom_motion_prompt: true,
  }),
});
const { data: { video_id } } = await response.json();
```

**Orientations:** `portrait` (720×1280, TikTok/Stories), `landscape` (1280×720, YouTube/Web), `square` (720×720, Instagram Feed).

## Generating AI Photo Avatars

> **IMPORTANT: All 8 fields are REQUIRED.** The API rejects requests missing any field. When a user asks to "generate an AI avatar", ask for or select values for ALL fields below.

| Field | Type | Allowed Values |
|-------|------|----------------|
| `name` | string | Name for the avatar |
| `age` | enum | `"Young Adult"`, `"Early Middle Age"`, `"Late Middle Age"`, `"Senior"`, `"Unspecified"` |
| `gender` | enum | `"Woman"`, `"Man"`, `"Unspecified"` |
| `ethnicity` | enum | `"White"`, `"Black"`, `"Asian American"`, `"East Asian"`, `"South East Asian"`, `"South Asian"`, `"Middle Eastern"`, `"Pacific"`, `"Hispanic"`, `"Unspecified"` |
| `orientation` | enum | `"square"`, `"horizontal"`, `"vertical"` |
| `pose` | enum | `"half_body"`, `"close_up"`, `"full_body"` |
| `style` | enum | `"Realistic"`, `"Pixar"`, `"Cinematic"`, `"Vintage"`, `"Noir"`, `"Cyberpunk"`, `"Unspecified"` |
| `appearance` | string | Clothing, mood, lighting, background. Max 1000 chars |

```typescript
// Generate
const genResponse = await fetch("https://api.heygen.com/v2/photo_avatar/photo/generate", {
  method: "POST",
  headers: { "X-Api-Key": process.env.HEYGEN_API_KEY!, "Content-Type": "application/json" },
  body: JSON.stringify({
    name: "Tech Demo Presenter",
    age: "Early Middle Age",
    gender: "Man",
    ethnicity: "East Asian",
    orientation: "horizontal",
    pose: "half_body",
    style: "Realistic",
    appearance: "Professional man in a modern office, dark gray suit, confident expression, soft natural lighting",
  }),
});
const { data: { generation_id } } = await genResponse.json();

// Poll for completion
async function waitForPhotoGeneration(generationId: string): Promise<string> {
  for (let i = 0; i < 60; i++) {
    const r = await fetch(`https://api.heygen.com/v2/photo_avatar/generation/${generationId}`,
      { headers: { "X-Api-Key": process.env.HEYGEN_API_KEY! } });
    const { data } = await r.json();
    if (data.status === "completed") return data.image_key!;
    if (data.status === "failed") throw new Error("Photo generation failed");
    await new Promise(r => setTimeout(r, 5000));
  }
  throw new Error("Photo generation timed out");
}
```

**Vague requests:** ask for missing fields OR apply defaults: `"Early Middle Age"`, `"Realistic"` style, `"half_body"` pose, `"horizontal"` orientation.

**Appearance tips:** Be specific — "Professional woman with shoulder-length brown hair, light blue button-down, warm smile, soft studio lighting, clean white background". Avoid vague descriptions, conflicting attributes, or specific real people.

## Photo Avatar Groups

```typescript
// Create group
const createResp = await fetch("https://api.heygen.com/v2/photo_avatar/avatar_group/create", {
  method: "POST",
  headers: { "X-Api-Key": process.env.HEYGEN_API_KEY!, "Content-Type": "application/json" },
  body: JSON.stringify({ image_key: imageKey, name }),
});
const { data: { id: groupId } } = await createResp.json();

// Add photos to group
await fetch("https://api.heygen.com/v2/photo_avatar/avatar_group/add", {
  method: "POST",
  headers: { "X-Api-Key": process.env.HEYGEN_API_KEY!, "Content-Type": "application/json" },
  body: JSON.stringify({ group_id: groupId, image_keys: imageKeys, name }),
});
```

## Photo Requirements

| Aspect | Requirement |
|--------|-------------|
| Format | JPEG, PNG |
| Resolution | Minimum 512×512px |
| File size | Under 10MB |
| Face | Clear, front-facing, centered |
| Lighting | Even, natural |
| Expression | Neutral or slight smile |
| Background | Simple, uncluttered |

Side-profile and full-body photos have limited animation support. Some expressions may look unnatural; processing time varies by complexity.

## Managing Photo Avatars

```typescript
// Get details
const avatar = await fetch(`https://api.heygen.com/v2/photo_avatar/${id}`,
  { headers: { "X-Api-Key": process.env.HEYGEN_API_KEY! } }).then(r => r.json());

// Delete
await fetch(`https://api.heygen.com/v2/photo_avatar/${id}`, {
  method: "DELETE",
  headers: { "X-Api-Key": process.env.HEYGEN_API_KEY! },
});
```
