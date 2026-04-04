<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare Workers for Platforms

Multi-tenant platform with isolated customer code execution at scale.

**NOT for general Workers** — only for Workers for Platforms architecture.

## Use Cases

- Multi-tenant SaaS running customer code
- AI-generated code execution in secure sandboxes
- Programmable platforms with isolated compute
- Edge functions/serverless platforms
- Website builders with static + dynamic content

## Architecture

**4 Components:**
1. **Dispatch Namespace** — Container for unlimited customer Workers; automatic isolation; untrusted mode
2. **Dynamic Dispatch Worker** — Entry point; routes requests; enforces platform logic (auth, limits, validation)
3. **User Workers** — Customer code in isolated sandboxes; API-deployed; optional bindings (KV/D1/R2/DO)
4. **Outbound Worker** (optional) — Intercepts external fetch; controls egress; logs subrequests

**Request Flow:**

```
Request → Dispatch Worker → env.DISPATCHER.get("customer") → User Worker
→ (Outbound Worker for external fetch) → Response → Dispatch Worker → Client
```

**Key capabilities:** unlimited Workers per namespace, custom CPU/subrequest limits per customer, hostname routing (subdomains/vanity domains), egress/ingress control, static assets, tags for bulk operations.

## Refs

- [Docs](https://developers.cloudflare.com/cloudflare-for-platforms/workers-for-platforms/)
- [Starter Kit](https://github.com/cloudflare/templates/tree/main/worker-publisher-template)
- [VibeSDK](https://github.com/cloudflare/vibesdk)
- [patterns.md](./workers-for-platforms-patterns.md), [gotchas.md](./workers-for-platforms-gotchas.md)
