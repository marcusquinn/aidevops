---
name: quota
description: Credit system, usage limits, and checking remaining quota for HeyGen
metadata:
  tags: quota, credits, limits, usage, billing
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# HeyGen Quota and Credits

HeyGen uses a credit-based system. Check quota before generating to prevent failed requests.

## Endpoint

```http
GET https://api.heygen.com/v1/video_generate.quota
X-Api-Key: $HEYGEN_API_KEY
```

Response:

```json
{
  "error": null,
  "data": {
    "remaining_quota": 450,
    "used_quota": 50
  }
}
```

## Credit Consumption

| Operation | Credit Cost |
|-----------|-------------|
| Standard video | ~1 credit/min |
| 1080p video | ~1.5x standard rate |
| Video translation | ~1 credit/min of source |
| Streaming avatar | Per session (varies by plan) |

## TypeScript — Quota Check and Guard

```typescript
interface QuotaResponse {
  error: null | string;
  data: { remaining_quota: number; used_quota: number };
}

async function getQuota(): Promise<QuotaResponse["data"]> {
  const res = await fetch("https://api.heygen.com/v1/video_generate.quota", {
    headers: { "X-Api-Key": process.env.HEYGEN_API_KEY! },
  });
  const { data }: QuotaResponse = await res.json();
  return data;
}

async function generateVideoWithQuotaCheck(videoConfig: VideoConfig) {
  const quota = await getQuota();
  const requiredCredits = Math.ceil(videoConfig.estimatedDuration / 60);

  if (quota.remaining_quota < requiredCredits) {
    throw new Error(
      `Insufficient credits. Need ${requiredCredits}, have ${quota.remaining_quota}`
    );
  }

  return generateVideo(videoConfig);
}
```

## Best Practices

- **Monitor usage**: Log `remaining_quota` / `used_quota` before batch jobs.
- **Alert threshold**: Warn when `remaining_quota < 50` (or your chosen threshold).
- **Test mode**: Set `test: true` in `video_inputs` during development — avoids credit consumption but adds watermarks.
- **Error handling**: Catch errors containing `"quota"` or `"credit"`, call `getQuota()` to surface current balance, then advise: upgrade subscription, wait for reset, or purchase credits.
- **Subscription**: API access requires Creator tier or higher. Enterprise provides custom limits and priority support.
