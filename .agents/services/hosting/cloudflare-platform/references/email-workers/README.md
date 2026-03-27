# Cloudflare Email Workers

Process incoming emails with the Workers runtime: routing, spam filtering, auto-responders, ticket systems. **Use ES modules format** — Service Worker format is deprecated.

## ForwardableEmailMessage API

```typescript
interface ForwardableEmailMessage {
  readonly from: string;        // Envelope From
  readonly to: string;          // Envelope To
  readonly headers: Headers;    // Message headers
  readonly raw: ReadableStream; // Raw message stream
  readonly rawSize: number;     // Size in bytes
  setReject(reason: string): void;           // permanent SMTP rejection
  forward(rcptTo: string, headers?: Headers): Promise<void>; // verified dest only; X-* headers only
  reply(message: EmailMessage): Promise<void>;
}

// import { EmailMessage } from "cloudflare:email";
// new EmailMessage(from, to, rawMimeContent)
```

## Common Patterns

All patterns use `export default { async email(message, env, ctx) { ... } }`.

**Allowlist / Blocklist**

```typescript
const allowList = ["friend@example.com"];
if (!allowList.includes(message.from)) message.setReject("Address not allowed");
else await message.forward("inbox@corp.example.com");
```

**Parse Email (postal-mime)**

```typescript
import * as PostalMime from 'postal-mime';
const email = await new PostalMime.default().parse(await new Response(message.raw).arrayBuffer());
// email: { headers, from, to, subject, html, text, attachments }
await message.forward("inbox@example.com");
```

**Auto-Reply (mimetext)**

```typescript
import { EmailMessage } from "cloudflare:email";
import { createMimeMessage } from 'mimetext';
const msg = createMimeMessage();
msg.setSender({ name: 'Support', addr: 'support@example.com' });
msg.setRecipient(message.from);
msg.setHeader('In-Reply-To', message.headers.get('Message-ID'));
msg.setSubject('Re: Your inquiry');
msg.addMessage({ contentType: 'text/plain', data: 'We will respond within 24 hours.' });
await message.reply(new EmailMessage('support@example.com', message.from, msg.asRaw()));
```

**Subject-Based Routing**

```typescript
const subject = (message.headers.get('Subject') || '').toLowerCase();
if (subject.includes('billing')) await message.forward("billing@example.com");
else if (subject.includes('support')) await message.forward("support@example.com");
else await message.forward("general@example.com");
```

**Snippets**

```typescript
// Async ops
ctx.waitUntil(Promise.all([logToAnalytics(message), notifySlack(message)]));
// Size filtering
if (message.rawSize > 10 * 1024 * 1024) message.setReject("Message too large");
// Store in KV/R2
await env.EMAIL_ARCHIVE.put(`email:${Date.now()}:${message.from}`, JSON.stringify({ from: email.from, subject: email.subject }));
// Multi-tenant routing
const config = await env.TENANT_CONFIG.get(extractTenantId(message.to.split('@')[0]), 'json');
if (config?.forwardTo) await message.forward(config.forwardTo);
else message.setReject("Unknown recipient");
```

## Setup

**wrangler.toml**

```toml
name = "email-worker"
main = "src/index.ts"
compatibility_date = "2024-01-01"
[[send_email]]
name = "EMAIL"
# Add [[kv_namespaces]] binding = "EMAIL_ARCHIVE" if using KV storage
```

**Local dev** — `npx wrangler dev`, then test with:

```bash
curl --request POST 'http://localhost:8787/cdn-cgi/handler/email' \
  --url-query 'from=sender@example.com' --url-query 'to=recipient@example.com' \
  --header 'Content-Type: application/json' \
  --data-raw $'From: sender@example.com\nTo: recipient@example.com\nSubject: Test\n\nHello world'
```

Wrangler writes sent emails to `.eml` files locally.

**Deploy** — Enable Email Routing in dashboard → add verified destination → `npx wrangler deploy` → Dashboard → Email Routing → Email Workers → create route → bind to Worker.

## Limits, Best Practices & Troubleshooting

**Limits:** max message 25 MiB · max rules 200 · max destination addresses 200

| Issue / Rule | Detail |
|---|---|
| `forward()` requires verified destination | Add address in Email Routing dashboard first |
| Email not forwarding | Check Email Routing enabled; check `wrangler tail` |
| CPU limit errors | Upgrade to Paid plan; use `ctx.waitUntil()` for heavy ops |
| Local dev not working | Ensure `send_email` binding in wrangler.toml; use correct curl format |
| Large emails (>20MB) | Offload processing via `ctx.waitUntil()` before forwarding |
| Header safety | `message.headers.get('Subject') \|\| '(no subject)'` |
| Type safety | `async email(message: ForwardableEmailMessage, env: Env, ctx: ExecutionContext)` |
| Monitor CPU | `npx wrangler tail` — look for `EXCEEDED_CPU` |

**Dependencies:** `postal-mime@^2.3.3`, `mimetext@^4.0.0` (runtime); `@cloudflare/workers-types@^4.0.0`, `wrangler@^3.0.0` (dev)

## Related Documentation

- [Email Routing Setup](https://developers.cloudflare.com/email-routing/get-started/enable-email-routing/)
- [Workers Platform](https://developers.cloudflare.com/workers/)
- [Wrangler CLI](https://developers.cloudflare.com/workers/wrangler/)
- [Workers Limits](https://developers.cloudflare.com/workers/platform/limits/)
