# Email Routing

Use routing rules for address-based forwarding; use an Email Worker when incoming mail needs custom processing. Fetch the linked docs before implementing APIs, DNS, configuration, or limits.

| Task | Start here |
| --- | --- |
| Forward incoming mail to an existing mailbox | [Route emails](https://developers.cloudflare.com/email-service/get-started/route-emails/index.md) |
| Manage addresses, verification, catch-all rules, or subaddressing | [Routing rules and addresses](https://developers.cloudflare.com/email-service/configuration/email-routing-addresses/index.md) |
| Filter, parse, reply to, or store incoming mail | [Email Workers](email-workers.md) |
| Send a new outbound message | [Send emails](https://developers.cloudflare.com/email-service/get-started/send-emails/index.md) — Workers binding, REST API, or SMTP |

Forwarding requires verified destinations. Replying within an incoming email event and sending a new outbound message have different requirements; use the relevant API docs.

## Reference map

- [Configuration](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/email-routing/configuration.md): domains, rules, deployment, and local testing.
- [API](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/email-routing/api.md): routing management and inbound/outbound operations.
- [Patterns](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/email-routing/patterns.md): filtering, parsing, storage, and notifications.
- [Troubleshooting](email-routing-gotchas.md): authentication, delivery, and current limits.
