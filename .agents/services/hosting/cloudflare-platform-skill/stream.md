# Cloudflare Stream

Hosted VOD and live video — upload, encode, store, deliver, and stream without running your own transcoding stack. Supports TUS/API/URL uploads, direct creator uploads, iframe/HLS/DASH playback, RTMPS/SRT live ingest, `requireSignedURLs`, `allowedOrigins`, webhooks, GraphQL analytics, captions, and watermarks.

**Security:** Use direct creator uploads for end-user content — API tokens must never reach the frontend.

## Resources

- Dashboard: https://dash.cloudflare.com/?to=/:account/stream
- API docs: https://developers.cloudflare.com/api/resources/stream/
- Product docs: https://developers.cloudflare.com/stream/

## In This Reference

- [stream-patterns.md](./stream-patterns.md) — Direct uploads, polling/webhooks, live workflows, and best practices
- [stream-gotchas.md](./stream-gotchas.md) — Errors, limits, troubleshooting, and security pitfalls

## See Also

- [workers.md](./workers.md) — Handle uploads, tokens, and webhooks in Workers
- [pages.md](./pages.md) — Build upload and playback UIs on Pages
- [workers-ai.md](./workers-ai.md) — Add AI-generated captions and media enrichment
