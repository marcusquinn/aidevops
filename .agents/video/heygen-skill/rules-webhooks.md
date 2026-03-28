---
name: webhooks
description: Registering webhook endpoints and event types for HeyGen
metadata:
  tags: webhooks, callbacks, events, notifications
---

# Webhooks

Webhooks push notifications to your server when async operations complete, avoiding polling.

## Endpoint Requirements

Your webhook endpoint must:

1. Accept POST requests
2. Return 200 within 5 seconds
3. Process events asynchronously (respond first, then handle)

```typescript
import express from "express";
import crypto from "crypto";

const app = express();
app.use(express.json());

app.post("/webhook/heygen", async (req, res) => {
  res.status(200).send("OK"); // Acknowledge immediately

  processWebhookEvent(req.body).catch(console.error);
});

async function processWebhookEvent(event: HeyGenWebhookEvent) {
  switch (event.event_type) {
    case "avatar_video.success":
      await handleVideoSuccess(event);
      break;
    case "avatar_video.fail":
      await handleVideoFailure(event);
      break;
    case "video_translate.success":
      await handleTranslationSuccess(event);
      break;
    default:
      console.log(`Unknown event type: ${event.event_type}`);
  }
}

app.listen(3000);
```

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

### Video Success

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
```

### Video Failure

```typescript
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

Configure via the HeyGen dashboard or API:

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

Track which video triggered a webhook by passing `callback_id` during generation:

```typescript
// In video generation config
const videoConfig = {
  video_inputs: [...],
  callback_id: "order_12345", // Your custom identifier
};

// In webhook handler — correlate back to your records
async function handleVideoSuccess(event: VideoSuccessEvent) {
  const { video_id, video_url, callback_id } = event.event_data;
  if (callback_id) {
    const order = await getOrderByCallbackId(callback_id);
    await updateOrderWithVideo(order.id, video_url);
  }
}
```

## Security

### Signature Verification

```typescript
import crypto from "crypto";

function verifyWebhookSignature(
  payload: string,
  signature: string,
  secret: string
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

  // Process event...
});
```

### Event Validation

```typescript
const VALID_EVENT_TYPES = [
  "avatar_video.success",
  "avatar_video.fail",
  "video_translate.success",
  "video_translate.fail",
];

function isValidHeygenEvent(event: any): boolean {
  return !!(event.event_type && event.event_data
    && VALID_EVENT_TYPES.includes(event.event_type));
}
```

## Retry Handling

```typescript
async function processWebhookEvent(event: HeyGenWebhookEvent) {
  const maxRetries = 3;

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      await handleEvent(event);
      return;
    } catch (error) {
      console.error(`Attempt ${attempt} failed:`, error);
      if (attempt < maxRetries) {
        await new Promise((r) => setTimeout(r, Math.pow(2, attempt) * 1000));
      }
    }
  }

  await storeFailedEvent(event); // Manual review queue
}
```

## Testing Locally

Use ngrok to expose your local endpoint:

```bash
ngrok http 3000
# Register the ngrok URL: https://abc123.ngrok.io/webhook/heygen
```

## Best Practices

1. **Respond first, process async** — return 200 within 5 seconds
2. **Handle duplicates** — same event may arrive multiple times
3. **Use callback IDs** — correlate webhooks to your original requests
4. **Verify signatures** — validate `x-heygen-signature` header with HMAC
5. **Retry with backoff** — handle transient processing failures
6. **Log payloads** — store raw webhook data for debugging
7. **Queue heavy work** — use job queues for expensive processing
8. **Prefer webhooks over polling** — lower latency, lower API usage
