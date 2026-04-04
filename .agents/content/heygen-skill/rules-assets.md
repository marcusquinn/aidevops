---
name: assets
description: Uploading images, videos, and audio for use in HeyGen video generation
metadata:
  tags: assets, upload, images, audio, video, s3
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Asset Upload and Management

Two-step flow: (1) get a presigned upload URL, (2) PUT the file to that URL.

## Get Upload URL

`POST https://api.heygen.com/v1/asset` with `content_type` (MIME type, required).

```bash
curl -X POST "https://api.heygen.com/v1/asset" \
  -H "X-Api-Key: $HEYGEN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"content_type": "image/jpeg"}'
```

Response: `{ "data": { "url": "<presigned-url>", "asset_id": "<id>" } }`

## Supported Content Types

| Content-Type | Use Case |
|--------------|----------|
| `image/jpeg` | Backgrounds, talking photos |
| `image/png` | Backgrounds, overlays |
| `video/mp4` | Video backgrounds |
| `audio/mpeg` | Custom audio input |
| `audio/wav` | Custom audio input |

## Upload Files

PUT to the presigned URL. `duplex: "half"` required for streaming uploads.

```typescript
import fs from "fs";
import { stat } from "fs/promises";

interface AssetUploadResponse {
  error: null | string;
  data: { url: string; asset_id: string };
}

async function getUploadUrl(contentType: string): Promise<AssetUploadResponse["data"]> {
  const response = await fetch("https://api.heygen.com/v1/asset", {
    method: "POST",
    headers: { "X-Api-Key": process.env.HEYGEN_API_KEY!, "Content-Type": "application/json" },
    body: JSON.stringify({ content_type: contentType }),
  });
  const json: AssetUploadResponse = await response.json();
  if (json.error) throw new Error(json.error);
  return json.data;
}

async function uploadFile(filePath: string, contentType: string): Promise<string> {
  const { url, asset_id } = await getUploadUrl(contentType);
  const fileStats = await stat(filePath);
  const fileStream = fs.createReadStream(filePath);

  await fetch(url, {
    method: "PUT",
    headers: { "Content-Type": contentType, "Content-Length": fileStats.size.toString() },
    body: fileStream as any,
    duplex: "half",
  });
  return asset_id;
}

async function uploadFromUrl(sourceUrl: string, contentType: string): Promise<string> {
  const { url, asset_id } = await getUploadUrl(contentType);
  const sourceResponse = await fetch(sourceUrl);
  if (!sourceResponse.ok || !sourceResponse.body) {
    throw new Error(`Failed to download: ${sourceResponse.status}`);
  }
  await fetch(url, { method: "PUT", headers: { "Content-Type": contentType }, body: sourceResponse.body, duplex: "half" });
  return asset_id;
}
```

## Using Uploaded Assets

Asset URL pattern: `https://files.heygen.ai/asset/${assetId}`

```typescript
// Background image
background: { type: "image", url: `https://files.heygen.ai/asset/${imageAssetId}` }

// Talking photo character
character: { type: "talking_photo", talking_photo_id: photoAssetId }

// Audio input
voice: { type: "audio", audio_url: `https://files.heygen.ai/asset/${audioAssetId}` }
```

Full video config with custom background:

```typescript
const config = {
  video_inputs: [{
    character: { type: "avatar", avatar_id: "josh_lite3_20230714", avatar_style: "normal" },
    voice: { type: "text", input_text: script, voice_id: "1bd001e7e50f421d891986aad5158bc8" },
    background: { type: "image", url: `https://files.heygen.ai/asset/${backgroundId}` },
  }],
  dimension: { width: 1920, height: 1080 },
};
```

## Constraints and Best Practices

| Constraint | Details |
|------------|---------|
| File size | 10-100 MB max (varies by type) |
| Image dimensions | Match target video dimensions |
| Audio duration | Match expected video length |
| Retention | Assets may be deleted after inactivity |

Optimize images to video dimensions before upload. JPEG for photos, PNG for transparency. Validate type/size locally. Implement retry logic. Cache asset IDs for reuse.
