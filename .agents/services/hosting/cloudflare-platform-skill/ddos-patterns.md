<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# DDoS Protection Patterns

## Allowlist Trusted IPs

```typescript
// PUT accounts/${accountId}/rulesets/phases/ddos_l7/entrypoint
const config = {
  description: "Allowlist trusted IPs",
  rules: [{
    expression: "ip.src in { 203.0.113.0/24 192.0.2.1 }",
    action: "execute",
    action_parameters: {
      id: managedRulesetId,
      overrides: { sensitivity_level: "eoff" },
    },
  }],
};
```

## Route-Specific Sensitivity

Bursty API endpoints need lower sensitivity than static pages.

```typescript
const config = {
  description: "Route-specific protection",
  rules: [
    { expression: "not http.request.uri.path matches \"^/api/\"",
      action: "execute", action_parameters: { id: managedRulesetId, overrides: { sensitivity_level: "default", action: "block" } } },
    { expression: "http.request.uri.path matches \"^/api/\"",
      action: "execute", action_parameters: { id: managedRulesetId, overrides: { sensitivity_level: "low", action: "managed_challenge" } } },
  ],
};
```

## Progressive Enhancement

Gradual rollout: MONITORING (week 1) → LOW (week 2) → MEDIUM (week 3) → HIGH (week 4).

```typescript
type ProtectionLevel = "monitoring" | "low" | "medium" | "high";

const levelConfig: Record<ProtectionLevel, { action: string; sensitivity: string }> = {
  monitoring: { action: "log", sensitivity: "eoff" },
  low:        { action: "managed_challenge", sensitivity: "low" },
  medium:     { action: "managed_challenge", sensitivity: "medium" },
  high:       { action: "block", sensitivity: "default" },
};

async function setProtectionLevel(zoneId: string, level: ProtectionLevel, managedRulesetId: string, apiToken: string) {
  const { action, sensitivity } = levelConfig[level];
  // PUT zones/${zoneId}/rulesets/phases/ddos_l7/entrypoint
  return fetch(`https://api.cloudflare.com/client/v4/zones/${zoneId}/rulesets/phases/ddos_l7/entrypoint`, {
    method: "PUT",
    headers: { Authorization: `Bearer ${apiToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      rules: [{
        expression: "true", action: "execute",
        action_parameters: { id: managedRulesetId, overrides: { action, sensitivity_level: sensitivity } },
      }],
    }),
  });
}
```

## Dynamic Response

Worker that auto-escalates on attack detection, de-escalates via scheduled cron when quiet.

```typescript
// Bindings: CLOUDFLARE_API_TOKEN, ZONE_ID, KV_NAMESPACE (KVNamespace)
export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    if (!req.url.includes("/attack-detected")) return new Response("OK");
    await env.KV_NAMESPACE.put(`attack:${Date.now()}`, await req.text(), { expirationTtl: 86400 });
    if ((await getRecentAttacks(env.KV_NAMESPACE)).length > 5) {
      await increaseProtection(env.ZONE_ID, "managed-ruleset-id", env.CLOUDFLARE_API_TOKEN);
      return new Response("Protection increased", { status: 200 });
    }
    return new Response("OK");
  },

  async scheduled(_event: ScheduledEvent, env: Env): Promise<void> {
    if ((await getRecentAttacks(env.KV_NAMESPACE)).length === 0)
      await normalizeProtection(env.ZONE_ID, "managed-ruleset-id", env.CLOUDFLARE_API_TOKEN);
  },
};
```

## Multi-Rule Tiered Protection (Enterprise Advanced)

Up to 10 rules with different conditions per zone.

```typescript
const config = {
  description: "Multi-tier DDoS protection",
  rules: [
    { expression: "not ip.src in $known_ips and not cf.bot_management.score gt 30", // unknown — strictest
      action: "execute", action_parameters: { id: managedRulesetId, overrides: { sensitivity_level: "default", action: "block" } } },
    { expression: "cf.bot_management.verified_bot", // verified bots — medium
      action: "execute", action_parameters: { id: managedRulesetId, overrides: { sensitivity_level: "medium", action: "managed_challenge" } } },
    { expression: "ip.src in $trusted_ips", // trusted — low
      action: "execute", action_parameters: { id: managedRulesetId, overrides: { sensitivity_level: "low" } } },
  ],
};
```

## Defense in Depth

Layer DDoS with WAF custom rules, Rate Limiting, and Bot Management. Each operates at a different phase — DDoS fires first (L3/4 then L7), then WAF, then rate limiting. See `waf-patterns.md`, `bot-management-patterns.md`.
