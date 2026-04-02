# Cloudflare Stream

Managed video upload, encoding, storage, delivery, and live streaming on Cloudflare's network.

## Overview

Use Stream when you need hosted VOD or live video without running your own transcoding or delivery stack.

- **Uploads**: TUS/API uploads, URL import, and direct creator uploads for user-generated content
- **Playback**: Hosted iframe player, HLS/DASH for custom players, and thumbnail generation
- **Access control**: Public playback, `requireSignedURLs`, `allowedOrigins`, and geo/IP token rules
- **Live**: RTMPS/SRT ingest, automatic recording, simulcast, and browser/WebRTC support
- **Operations**: Webhooks, GraphQL analytics, captions, watermarks, and downloadable MP4s

Prefer direct creator uploads for end-user content so API tokens never reach the frontend.

## Quick Start

**Upload from URL**

```bash
curl -X POST \
  "https://api.cloudflare.com/client/v4/accounts/{account_id}/stream/copy" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://example.com/video.mp4"}'
```

**Embed the hosted player**

```html
<iframe
  src="https://customer-<CODE>.cloudflarestream.com/<VIDEO_ID>/iframe"
  style="border: none;"
  height="720" width="1280"
  allow="accelerometer; gyroscope; autoplay; encrypted-media; picture-in-picture;"
  allowfullscreen="true"
></iframe>
```

**Create a live input**

```bash
curl -X POST \
  "https://api.cloudflare.com/client/v4/accounts/{account_id}/stream/live_inputs" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"recording": {"mode": "automatic"}}'
```

## Resources

- Dashboard: https://dash.cloudflare.com/?to=/:account/stream
- API docs: https://developers.cloudflare.com/api/resources/stream/
- Product docs: https://developers.cloudflare.com/stream/

## In This Reference

- [stream-patterns.md](./stream-patterns.md) - Direct uploads, polling/webhooks, live workflows, and best practices
- [stream-gotchas.md](./stream-gotchas.md) - Errors, limits, troubleshooting, and security pitfalls

## See Also

- [workers.md](./workers.md) - Handle uploads, tokens, and webhooks in Workers
- [pages.md](./pages.md) - Build upload and playback UIs on Pages
- [workers-ai.md](./workers-ai.md) - Add AI-generated captions and media enrichment
