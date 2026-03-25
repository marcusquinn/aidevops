# Cloudflare Email Workers Skill

Expert guidance for building, configuring, and deploying Cloudflare Email Workers.

## Overview

Email Workers let you programmatically process incoming emails using Cloudflare Workers runtime. Use them to build custom email routing logic, spam filters, auto-responders, ticket systems, notification handlers, and more.

## Core Architecture

```typescript
// ES Modules format (use for all new projects)
export default {
  async email(message, env, ctx) {
    await message.forward("destination@example.com");
  },
};
```

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

- **`setReject(reason)`**: Reject with permanent SMTP error
- **`forward(rcptTo, headers?)`**: Forward to verified destination (only `X-*` headers allowed)
- **`reply(message)`**: Reply to sender with new EmailMessage

```typescript
// EmailMessage for sending
import { EmailMessage } from "cloudflare:email";
const msg = new EmailMessage(from, to, rawMimeContent);
```

## Common Patterns

### 1. Allowlist / Blocklist

```typescript
export default {
  async email(message, env, ctx) {
    const allowList = ["friend@example.com", "coworker@example.com"];
    if (!allowList.includes(message.from)) {
      message.setReject("Address not allowed");
    } else {
      await message.forward("inbox@corp.example.com");
    }
  },
};
```

### 2. Parse Email with postal-mime

```typescript
import * as PostalMime from 'postal-mime';

export default {
  async email(message, env, ctx) {
    const parser = new PostalMime.default();
    const email = await parser.parse(await new Response(message.raw).arrayBuffer());
    // email contains: headers, from, to, subject, html, text, attachments
    await message.forward("inbox@example.com");
  },
};
```

### 3. Auto-Reply

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

### 4. Conditional Routing by Subject

```typescript
export default {
  async email(message, env, ctx) {
    const subject = (message.headers.get('Subject') || '').toLowerCase();
    if (subject.includes('billing')) {
      await message.forward("billing@example.com");
    } else if (subject.includes('support')) {
      await message.forward("support@example.com");
    } else {
      await message.forward("general@example.com");
    }
  },
};
```

### 5. Store Email in KV/R2

```typescript
import * as PostalMime from 'postal-mime';

export default {
  async email(message, env, ctx) {
    const email = await new PostalMime.default().parse(await new Response(message.raw).arrayBuffer());
    await env.EMAIL_ARCHIVE.put(`email:${Date.now()}:${message.from}`, JSON.stringify({
      from: email.from, subject: email.subject, receivedAt: new Date().toISOString(),
    }));
    await message.forward("inbox@example.com");
  },
};
```

### 6. Webhook Notification

```typescript
export default {
  async email(message, env, ctx) {
    ctx.waitUntil(
      fetch('https://hooks.slack.com/services/YOUR/WEBHOOK/URL', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text: `New email from ${message.from}: ${message.headers.get('Subject')}` }),
      })
    );
    await message.forward("inbox@example.com");
  },
};
```

### 7. Size-Based Filtering

```typescript
export default {
  async email(message, env, ctx) {
    if (message.rawSize > 10 * 1024 * 1024) {
      message.setReject("Message too large");
    } else {
      await message.forward("inbox@example.com");
    }
  },
};
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

[vars]
WEBHOOK_URL = "https://example.com/webhook"
```

## Local Development

**Test receiving email**:

```bash
npx wrangler dev
curl --request POST 'http://localhost:8787/cdn-cgi/handler/email' \
  --url-query 'from=sender@example.com' \
  --url-query 'to=recipient@example.com' \
  --header 'Content-Type: application/json' \
  --data-raw 'From: sender@example.com
To: recipient@example.com
Subject: Test Email

Hello world'
```

**Test sending email** (Wrangler writes to local `.eml` files):

```typescript
import { EmailMessage } from "cloudflare:email";
import { createMimeMessage } from 'mimetext';

export default {
  async fetch(request, env, ctx) {
    const msg = createMimeMessage();
    msg.setSender({ name: 'Test', addr: 'sender@example.com' });
    msg.setRecipient('recipient@example.com');
    msg.setSubject('Test from Worker');
    msg.addMessage({ contentType: 'text/plain', data: 'Hello from Email Worker' });
    await env.EMAIL.send(new EmailMessage('sender@example.com', 'recipient@example.com', msg.asRaw()));
    return Response.json({ ok: true });
  }
};
```

Visit `http://localhost:8787/` to trigger. Check terminal for `.eml` file path.

## Deployment

1. Enable Email Routing in Cloudflare dashboard
2. Add verified destination address
3. `npx wrangler deploy`
4. In dashboard: Email Routing → Email Workers → create route → bind to Worker

## Limits

| Limit | Value |
|-------|-------|
| Max message size | 25 MiB |
| Max rules | 200 |
| Max destination addresses | 200 |

Monitor CPU limit errors with `npx wrangler tail`. Look for `EXCEEDED_CPU` — upgrade to Workers Paid plan or use `ctx.waitUntil()` for non-critical operations.

## Best Practices

1. **Verified destinations only** — `forward()` only works with verified addresses in your Cloudflare account
2. **Handle large emails** — use `ctx.waitUntil(processLargeEmail(...))` for emails >20MB, forward immediately
3. **Use `ctx.waitUntil` for async** — forward first, then run analytics/notifications/DB updates non-blocking
4. **Custom headers** — only `X-*` headers allowed when forwarding; use `new Headers()` with `X-Processed-By`, `X-Original-To`
5. **Parse headers safely** — always use `|| ''` or `|| '(no subject)'` fallbacks to avoid null errors
6. **Type safety** — define `interface Env { EMAIL: SendEmail; EMAIL_ARCHIVE: KVNamespace; ... }`

## Common Use Cases

1. Spam/Allowlist Filtering, 2. Auto-Responders, 3. Ticket Creation, 4. Email Archival (KV/R2/D1),
5. Notification Routing (Slack/Discord/webhooks), 6. Size Filtering, 7. Domain Routing,
8. Subject-Based Routing, 9. Attachment Handling, 10. Email Analytics

## Dependencies

```json
{
  "dependencies": {
    "postal-mime": "^2.3.3",
    "mimetext": "^4.0.0"
  },
  "devDependencies": {
    "@cloudflare/workers-types": "^4.0.0",
    "wrangler": "^3.0.0"
  }
}
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Email not forwarding | Verify destination in dashboard; check Email Routing enabled; check route binding; `wrangler tail` |
| CPU limit errors | Upgrade to Workers Paid; use `ctx.waitUntil()`; avoid sync parsing of large emails |
| Local dev not working | Ensure `send_email` binding in wrangler config; use correct curl format; check wrangler version |

## Advanced Patterns

### Multi-Tenant Email Processing

```typescript
export default {
  async email(message, env, ctx) {
    const [localPart] = message.to.split('@');
    const tenantId = extractTenantId(localPart);
    const config = await env.TENANT_CONFIG.get(tenantId, 'json');
    if (config?.forwardTo) {
      await message.forward(config.forwardTo);
    } else {
      message.setReject("Unknown recipient");
    }
  },
};
```

### Attachment Extraction

```typescript
import * as PostalMime from 'postal-mime';

export default {
  async email(message, env, ctx) {
    const email = await new PostalMime.default().parse(await new Response(message.raw).arrayBuffer());
    for (const attachment of email.attachments) {
      ctx.waitUntil(
        env.ATTACHMENTS.put(`attachments/${Date.now()}-${attachment.filename}`, attachment.content, {
          metadata: { contentType: attachment.mimeType, from: email.from.address },
        })
      );
    }
    await message.forward("inbox@example.com");
  },
};
```

### Conditional Auto-Reply with Rate Limiting

```typescript
import { EmailMessage } from "cloudflare:email";
import { createMimeMessage } from 'mimetext';

export default {
  async email(message, env, ctx) {
    const rateKey = `rate:${message.from}`;
    if (!await env.RATE_LIMIT.get(rateKey)) {
      const msg = createMimeMessage();
      msg.setSender({ name: 'Auto Reply', addr: 'noreply@example.com' });
      msg.setRecipient(message.from);
      msg.setSubject('Received your message');
      msg.addMessage({ contentType: 'text/plain', data: 'Thank you for contacting us.' });
      await message.reply(new EmailMessage('noreply@example.com', message.from, msg.asRaw()));
      ctx.waitUntil(env.RATE_LIMIT.put(rateKey, Date.now().toString(), { expirationTtl: 3600 }));
    }
    await message.forward("inbox@example.com");
  },
};
```

## Related Documentation

- [Email Routing Setup](https://developers.cloudflare.com/email-routing/get-started/enable-email-routing/)
- [Workers Platform](https://developers.cloudflare.com/workers/)
- [Wrangler CLI](https://developers.cloudflare.com/workers/wrangler/)
- [Workers Limits](https://developers.cloudflare.com/workers/platform/limits/)
