---
name: webhooks
description: Registering webhook endpoints and event types for HeyGen
metadata:
  tags: webhooks, callbacks, events, notifications
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Webhooks

Push notifications to your server when async operations complete, avoiding polling.

## Endpoint Requirements

- Accept POST; return 200 within 5 seconds
- Respond first, then process asynchronously (use job queues for expensive work)
- Handle duplicate deliveries (same event may arrive multiple times)

```typescript
import express from "express";
const app = express();
app.use(express.json());

app.post("/webhook/heygen", async (req, res) => {
  res.status(200).send("OK"); // Acknowledge immediately
  processWebhookEvent(req.body).catch(console.error);
});

async function processWebhookEvent(event: HeyGenWebhookEvent) {
  switch (event.event_type) {
    case "avatar_video.success": await handleVideoSuccess(event); break;
    case "avatar_video.fail": await handleVideoFailure(event); break;
    case "video_translate.success": await handleTranslationSuccess(event); break;
    default: console.log(`Unknown event type: ${event.event_type}`);
  }
}
```

**Local testing:** `ngrok http 3000` — register the ngrok URL as your webhook endpoint.

## Event Types

| Event Type | Description |
|------------|-------------|
| `avatar_video.success` | Video generation completed |
| `avatar_video.fail` | Video generation failed |
| `video_translate.success` | Translation completed |
| `video_translate.fail` | Translation failed |
| `instant_avatar.success` | Instant avatar created |
| `instant_avatar.fail` | Instant avatar creation failed |

## Event Payloads

```typescript
interface VideoSuccessEvent {
  event_type: "avatar_video.success";
  event_data: {
    video_id: string;
    video_url: string;       // e.g. "https://files.heygen.ai/video/abc123.mp4"
    thumbnail_url: string;   // e.g. "https://files.heygen.ai/thumbnail/abc123.jpg"
    duration: number;
    callback_id?: string;    // Your custom identifier from video generation
  };
}

interface VideoFailureEvent {
  event_type: "avatar_video.fail";
  event_data: {
    video_id: string;
    error: string;           // e.g. "Script too long for selected avatar"
    callback_id?: string;
  };
}
```

## Registering a Webhook

| Field | Type | Req | Description |
|-------|------|:---:|-------------|
| `url` | string | ✓ | Your webhook endpoint URL |
| `events` | array | ✓ | Event types to subscribe to |
| `secret` | string | | Shared secret for signature verification |

```bash
curl -X POST "https://api.heygen.com/v1/webhook.add" \
  -H "X-Api-Key: $HEYGEN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://your-domain.com/webhook/heygen",
    "events": ["avatar_video.success", "avatar_video.fail"]
  }'
```

## Callback IDs

Pass `callback_id` during video generation to correlate webhooks to your records:

```typescript
const videoConfig = {
  video_inputs: [...],
  callback_id: "order_12345",
};

async function handleVideoSuccess(event: VideoSuccessEvent) {
  const { video_id, video_url, callback_id } = event.event_data;
  if (callback_id) {
    const order = await getOrderByCallbackId(callback_id);
    await updateOrderWithVideo(order.id, video_url);
  }
}
```

## Security — Signature Verification

Validate `x-heygen-signature` header using HMAC-SHA256:

```typescript
import crypto from "crypto";

function verifyWebhookSignature(
  payload: string, signature: string, secret: string
): boolean {
  const expected = crypto
    .createHmac("sha256", secret)
    .update(payload)
    .digest("hex");
  return crypto.timingSafeEqual(
    Buffer.from(signature),
    Buffer.from(expected)
  );
}

app.post("/webhook/heygen", (req, res) => {
  const signature = req.headers["x-heygen-signature"] as string;
  const payload = JSON.stringify(req.body);
  if (!verifyWebhookSignature(payload, signature, WEBHOOK_SECRET)) {
    return res.status(401).send("Invalid signature");
  }
});
```

## Retry Handling

```typescript
async function processWebhookEvent(event: HeyGenWebhookEvent) {
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      await handleEvent(event);
      return;
    } catch (error) {
      console.error(`Attempt ${attempt} failed:`, error);
      if (attempt < 3) {
        await new Promise((r) => setTimeout(r, Math.pow(2, attempt) * 1000));
      }
    }
  }
  await storeFailedEvent(event); // Manual review queue
}
```
