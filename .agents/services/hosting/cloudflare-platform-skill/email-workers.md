# Cloudflare Email Workers Skill

Process incoming emails programmatically (routing, filtering, auto-responders, ticket systems). **Use ES modules format — Service Worker format is deprecated.**

## ForwardableEmailMessage API

```typescript
interface ForwardableEmailMessage {
  readonly from: string;        // Envelope From
  readonly to: string;          // Envelope To
  readonly headers: Headers;    // Message headers
  readonly raw: ReadableStream; // Raw message stream
  readonly rawSize: number;     // Message size in bytes
  setReject(reason: string): void;
  forward(rcptTo: string, headers?: Headers): Promise<void>;
  reply(message: EmailMessage): Promise<void>;
}
```

| Method | Behaviour |
|--------|-----------|
| `setReject(reason)` | Reject with permanent SMTP error |
| `forward(rcptTo, headers?)` | Forward to verified destination (only `X-*` headers allowed) |
| `reply(message)` | Reply to sender with new EmailMessage |

```typescript
import { EmailMessage } from "cloudflare:email";
const msg = new EmailMessage(from, to, rawMimeContent);
```

## Common Patterns

### Allowlist / Blocklist
```typescript
export default {
  async email(message, env, ctx) {
    const allowList = ["friend@example.com"];
    if (!allowList.includes(message.from)) message.setReject("Address not allowed");
    else await message.forward("inbox@corp.example.com");
  },
};
```

### Parse Email (postal-mime)
```typescript
import * as PostalMime from 'postal-mime';
export default {
  async email(message, env, ctx) {
    const parser = new PostalMime.default();
    const email = await parser.parse(await new Response(message.raw).arrayBuffer());
    // email: { headers, from, to, subject, html, text, attachments }
    await message.forward("inbox@example.com");
  },
};
```

### Auto-Reply
```typescript
import { EmailMessage } from "cloudflare:email";
import { createMimeMessage } from 'mimetext';
export default {
  async email(message, env, ctx) {
    const msg = createMimeMessage();
    msg.setSender({ name: 'Support Team', addr: 'support@example.com' });
    msg.setRecipient(message.from);
    msg.setHeader('In-Reply-To', message.headers.get('Message-ID'));
    msg.setSubject('Re: Your inquiry');
    msg.addMessage({ contentType: 'text/plain', data: 'We will respond within 24 hours.' });
    await message.reply(new EmailMessage('support@example.com', message.from, msg.asRaw()));
    await message.forward("team@example.com");
  },
};
```

### Subject-Based Routing
```typescript
export default {
  async email(message, env, ctx) {
    const subject = (message.headers.get('Subject') || '').toLowerCase();
    if (subject.includes('billing')) await message.forward("billing@example.com");
    else if (subject.includes('support')) await message.forward("support@example.com");
    else await message.forward("general@example.com");
  },
};
```

### Async Operations (ctx.waitUntil)
```typescript
export default {
  async email(message, env, ctx) {
    await message.forward("inbox@example.com");
    ctx.waitUntil(Promise.all([logToAnalytics(message), notifySlack(message)]));
  },
};
```

### Snippets
```typescript
// Size filtering
if (message.rawSize > 10 * 1024 * 1024) message.setReject("Message too large");
else await message.forward("inbox@example.com");

// Store in KV/R2
const key = `email:${Date.now()}:${message.from}`;
await env.EMAIL_ARCHIVE.put(key, JSON.stringify({ from: email.from, subject: email.subject }));

// Multi-tenant routing
const tenantId = extractTenantId(message.to.split('@')[0]);
const config = await env.TENANT_CONFIG.get(tenantId, 'json');
if (config?.forwardTo) await message.forward(config.forwardTo);
else message.setReject("Unknown recipient");
```

## Wrangler Configuration

```toml
name = "email-worker"
main = "src/index.ts"
compatibility_date = "2024-01-01"

[[send_email]]
name = "EMAIL"

[[kv_namespaces]]
binding = "EMAIL_ARCHIVE"
id = "your-kv-namespace-id"
```

## Local Development

```bash
npx wrangler dev
# Test email receive:
curl --request POST 'http://localhost:8787/cdn-cgi/handler/email' \
  --url-query 'from=sender@example.com' \
  --url-query 'to=recipient@example.com' \
  --header 'Content-Type: application/json' \
  --data-raw 'From: sender@example.com
To: recipient@example.com
Subject: Test Email

Hello world'
```

Wrangler writes sent emails to local `.eml` files.

## Deployment

1. Enable Email Routing in Cloudflare dashboard
2. Add verified destination address
3. `npx wrangler deploy`
4. Dashboard → Email Routing → Email Workers → create route → bind to Worker

## Limits & Best Practices

| Limit | Value |
|-------|-------|
| Max message size | 25 MiB |
| Max rules | 200 |
| Max destination addresses | 200 |

- `forward()` only works with verified destination addresses
- Use `ctx.waitUntil()` for non-critical async ops (analytics, webhooks, large emails >20MB)
- Parse headers safely: `message.headers.get('Subject') || '(no subject)'`
- Add type safety: `async email(message: ForwardableEmailMessage, env: Env, ctx: ExecutionContext)`
- CPU limit errors (`EXCEEDED_CPU` in `npx wrangler tail`): upgrade to Paid plan or offload via `ctx.waitUntil()`

## Dependencies

| Package | Type | Version |
|---------|------|---------|
| `postal-mime` | runtime | `^2.3.3` |
| `mimetext` | runtime | `^4.0.0` |
| `@cloudflare/workers-types` | dev | `^4.0.0` |
| `wrangler` | dev | `^3.0.0` |

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Email not forwarding | Verify destination in dashboard; check Email Routing enabled; check `wrangler tail` |
| CPU limit errors | Upgrade to Paid plan; use `ctx.waitUntil()` for heavy ops |
| Local dev not working | Ensure `send_email` binding in wrangler config; use correct curl format |

## Related Documentation

- [Email Routing Setup](https://developers.cloudflare.com/email-routing/get-started/enable-email-routing/)
- [Workers Platform](https://developers.cloudflare.com/workers/)
- [Wrangler CLI](https://developers.cloudflare.com/workers/wrangler/)
- [Workers Limits](https://developers.cloudflare.com/workers/platform/limits/)
