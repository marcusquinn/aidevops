# Email Workers

Use an Email Worker's `email()` handler for custom processing of incoming mail. Use [routing rules](email-routing.md) for simple address-based forwarding. Fetch current documentation before implementing the handler or its dependencies.

| Operation | Documentation |
| --- | --- |
| Forward to a verified destination, reject, or reply within the incoming event | [Email handler API](https://developers.cloudflare.com/email-service/api/route-emails/email-handler/index.md) |
| Send a new message or a later response | [Sending Workers API](https://developers.cloudflare.com/email-service/api/send-emails/workers-api/index.md) |
| Parse and store mail for later processing | [Email storage and processing](https://developers.cloudflare.com/email-service/examples/email-routing/email-storage/index.md) |

`message.raw` is a single-use stream. If parsing and archiving both need the raw content, plan how to reuse it rather than reading the stream twice. Forwarding destinations must be verified; reply requirements are documented separately from outbound sending.

## Reference map

- [Configuration](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/email-workers/configuration.md): routing, bindings, local development, and types.
- [API](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/email-workers/api.md): message actions, MIME, and sending.
- [Patterns](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/email-workers/patterns.md): filtering, storage, attachments, and background processing.
- [Troubleshooting](email-workers-gotchas.md): stream handling, authentication, limits, and errors.
