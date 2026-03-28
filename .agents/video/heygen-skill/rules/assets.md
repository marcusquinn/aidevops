---
name: assets
description: Uploading images, videos, and audio for use in HeyGen video generation
metadata:
  tags: assets, upload, images, audio, video, s3
---

# Asset Upload and Management

HeyGen allows you to upload custom assets (images, videos, audio) for use in video generation, such as backgrounds, talking photo sources, and custom audio.

## Upload Flow

Asset uploads use a two-step process:
1. Get a presigned upload URL from HeyGen
2. Upload the file to the presigned URL

## Getting an Upload URL

### Request Fields

| Field | Type | Req | Description |
|-------|------|:---:|-------------|
| `content_type` | string | ✓ | MIME type of file to upload |

### curl

```bash
curl -X POST "https://api.heygen.com/v1/asset" \
  -H "X-Api-Key: $HEYGEN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"content_type": "image/jpeg"}'
```

### TypeScript

```typescript
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
```

### Python

```python
import requests, os

def get_upload_url(content_type: str) -> dict:
    response = requests.post(
        "https://api.heygen.com/v1/asset",
        headers={"X-Api-Key": os.environ["HEYGEN_API_KEY"], "Content-Type": "application/json"},
        json={"content_type": content_type}
    )
    data = response.json()
    if data.get("error"):
        raise Exception(data["error"])
    return data["data"]
```

## Supported Content Types

| Type | Content-Type | Use Case |
|------|--------------|----------|
| JPEG | `image/jpeg` | Backgrounds, talking photos |
| PNG | `image/png` | Backgrounds, overlays |
| MP4 | `video/mp4` | Video backgrounds |
| MP3 | `audio/mpeg` | Custom audio input |
| WAV | `audio/wav` | Custom audio input |

## Uploading Files

### TypeScript (supports streaming for large files)

```typescript
import fs from "fs";
import { stat } from "fs/promises";

async function uploadFile(filePath: string, contentType: string): Promise<string> {
  const { url, asset_id } = await getUploadUrl(contentType);
  const fileStats = await stat(filePath);
  const fileStream = fs.createReadStream(filePath);

  const uploadResponse = await fetch(url, {
    method: "PUT",
    headers: { "Content-Type": contentType, "Content-Length": fileStats.size.toString() },
    body: fileStream as any,
    // @ts-ignore - duplex is needed for streaming
    duplex: "half",
  });

  if (!uploadResponse.ok) throw new Error(`Upload failed: ${uploadResponse.status}`);
  return asset_id;
}
```

### Python

```python
def upload_file(file_path: str, content_type: str) -> str:
    upload_data = get_upload_url(content_type)
    with open(file_path, "rb") as f:
        response = requests.put(
            upload_data["url"],
            headers={"Content-Type": content_type},
            data=f
        )
    if not response.ok:
        raise Exception(f"Upload failed: {response.status_code}")
    return upload_data["asset_id"]
```

## Uploading from URL

```typescript
async function uploadFromUrl(sourceUrl: string, contentType: string): Promise<string> {
  const { url, asset_id } = await getUploadUrl(contentType);
  const sourceResponse = await fetch(sourceUrl);
  if (!sourceResponse.ok || !sourceResponse.body) {
    throw new Error(`Failed to download from source: ${sourceResponse.status}`);
  }
  await fetch(url, {
    method: "PUT",
    headers: { "Content-Type": contentType },
    body: sourceResponse.body,
    // @ts-expect-error duplex is needed for streaming uploads
    duplex: "half",
  });
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

Full video config example with custom background:

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

## Asset Limitations

- **File size**: Varies by asset type (typically 10-100MB max)
- **Image dimensions**: Recommended to match video dimensions
- **Audio duration**: Should match expected video length
- **Retention**: Assets may be deleted after a period of inactivity

## Best Practices

1. **Optimize images** - Resize to match video dimensions before uploading
2. **Use appropriate formats** - JPEG for photos, PNG for graphics with transparency
3. **Validate before upload** - Check file type and size locally first
4. **Handle upload errors** - Implement retry logic for failed uploads
5. **Cache asset IDs** - Reuse assets across multiple video generations
