# Cloudflare API Shield Reference

Expert guidance for API Shield - comprehensive API security suite for discovery, protection, and monitoring.

## Reading Order

| Task | Files to Read |
|------|---------------|
| Initial setup | README → configuration.md |
| Implement JWT validation | configuration.md → api.md |
| Add schema validation | configuration.md → patterns.md |
| Detect API attacks | patterns.md → api.md |
| Debug issues | gotchas.md |

## Feature Selection

What protection do you need?

```text
├─ Validate request/response structure → Schema Validation 2.0 (https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/api-shield/configuration.md)
├─ Verify auth tokens → JWT Validation (https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/api-shield/configuration.md)
├─ Client certificates → mTLS (https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/api-shield/configuration.md)
├─ Detect BOLA attacks → BOLA Detection (https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/api-shield/patterns.md)
├─ Track auth coverage → Auth Posture (https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/api-shield/patterns.md)
├─ Stop volumetric abuse → Abuse Detection (https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/api-shield/patterns.md)
└─ Discover shadow APIs → API Discovery (https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/api-shield/api.md)
```

## In This Reference

- **[configuration.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/api-shield/configuration.md)** - Setup, session identifiers, rules, token/mTLS configs
- **[api.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/api-shield/api.md)** - Endpoint management, discovery, validation APIs, GraphQL operations
- **[patterns.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/api-shield/patterns.md)** - Common patterns, progressive rollout, OWASP mappings, workflows
- **[gotchas.md](api-shield-gotchas.md)** - Troubleshooting, false positives, performance, best practices

## Quick Start

API Shield: Enterprise-grade API security (Discovery, Schema Validation 2.0, JWT, mTLS, BOLA Detection, Auth Posture). Available as Enterprise add-on with preview access.

## See Also

- [API Shield Docs](https://developers.cloudflare.com/api-shield/index.md)
- [API Reference](https://developers.cloudflare.com/api/resources/api_gateway/index.md)
- [OWASP API Security Top 10](https://owasp.org/www-project-api-security/)
