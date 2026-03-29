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
    {
      expression: "not http.request.uri.path matches \"^/api/\"",
      action: "execute",
      action_parameters: {
        id: managedRulesetId,
        overrides: { sensitivity_level: "default", action: "block" },
      },
    },
    {
      expression: "http.request.uri.path matches \"^/api/\"",
      action: "execute",
      action_parameters: {
        id: managedRulesetId,
        overrides: { sensitivity_level: "low", action: "managed_challenge" },
      },
    },
  ],
};
```

## Progressive Enhancement

Gradual rollout: MONITORING (week 1) → LOW (week 2) → MEDIUM (week 3) → HIGH (week 4).

```typescript
enum ProtectionLevel { MONITORING = "monitoring", LOW = "low", MEDIUM = "medium", HIGH = "high" }

async function setProtectionLevel(zoneId: string, level: ProtectionLevel, managedRulesetId: string, apiToken: string) {
  const levelConfig = {
    [ProtectionLevel.MONITORING]: { action: "log", sensitivity: "eoff" },
    [ProtectionLevel.LOW]: { action: "managed_challenge", sensitivity: "low" },
    [ProtectionLevel.MEDIUM]: { action: "managed_challenge", sensitivity: "medium" },
    [ProtectionLevel.HIGH]: { action: "block", sensitivity: "default" },
  } as const;

  const settings = levelConfig[level];
  const config = {
    description: `DDoS protection level: ${level}`,
    rules: [{
      expression: "true",
      action: "execute",
      action_parameters: {
        id: managedRulesetId,
        overrides: { action: settings.action, sensitivity_level: settings.sensitivity },
      },
    }],
  };

  return fetch(/* ... */);
}
```

## Dynamic Response

Worker that auto-escalates on attack detection, de-escalates via cron when quiet.

```typescript
// Env: CLOUDFLARE_API_TOKEN, ZONE_ID, KV_NAMESPACE (KVNamespace)
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.url.includes("/attack-detected")) {
      await env.KV_NAMESPACE.put(`attack:${Date.now()}`, await request.text(), { expirationTtl: 86400 });
      const recentAttacks = await getRecentAttacks(env.KV_NAMESPACE);
      if (recentAttacks.length > 5) {
        await increaseProtection(env.ZONE_ID, "managed-ruleset-id", env.CLOUDFLARE_API_TOKEN);
        return new Response("Protection increased", { status: 200 });
      }
    }
    return new Response("OK");
  },

  async scheduled(_event: ScheduledEvent, env: Env): Promise<void> {
    if ((await getRecentAttacks(env.KV_NAMESPACE)).length === 0) {
      await normalizeProtection(env.ZONE_ID, "managed-ruleset-id", env.CLOUDFLARE_API_TOKEN);
    }
  },
};
```

## Multi-Rule Tiered Protection (Enterprise Advanced)

Up to 10 rules with different conditions per zone.

```typescript
const config = {
  description: "Multi-tier DDoS protection",
  rules: [
    { // Unknown traffic — strictest
      expression: "not ip.src in $known_ips and not cf.bot_management.score gt 30",
      action: "execute",
      action_parameters: {
        id: managedRulesetId,
        overrides: { sensitivity_level: "default", action: "block" },
      },
    },
    { // Verified bots — medium
      expression: "cf.bot_management.verified_bot",
      action: "execute",
      action_parameters: {
        id: managedRulesetId,
        overrides: { sensitivity_level: "medium", action: "managed_challenge" },
      },
    },
    { // Trusted IPs — low
      expression: "ip.src in $trusted_ips",
      action: "execute",
      action_parameters: {
        id: managedRulesetId,
        overrides: { sensitivity_level: "low" },
      },
    },
  ],
};
```

## Defense in Depth

Layer DDoS with WAF custom rules, Rate Limiting, and Bot Management. Each operates at a different phase — DDoS fires first (L3/4 then L7), then WAF, then rate limiting. See `waf-patterns.md`, `bot-management-patterns.md`.
