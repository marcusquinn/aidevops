# DDoS Gotchas

## Always-on Protection

DDoS managed rulesets cannot be fully disabled. Minimum mitigation: `sensitivity_level: "eoff"`.

## Attacks Getting Through

Sensitivity too low or wrong action. Fix — increase to default (high) sensitivity:

```typescript
const config = {
  rules: [{
    expression: "true",
    action: "execute",
    action_parameters: {
      id: managedRulesetId,
      overrides: { sensitivity_level: "default", action: "block" },
    },
  }],
};
```

## False Positives

Legitimate traffic blocked/challenged. Diagnose via GraphQL API:

```typescript
const query = `
  query {
    viewer {
      zones(filter: { zoneTag: "${zoneId}" }) {
        httpRequestsAdaptiveGroups(
          filter: { ruleId: "${ruleId}", action: "log" }
          limit: 100
          orderBy: [datetime_DESC]
        ) {
          dimensions {
            clientCountryName
            clientRequestHTTPHost
            clientRequestPath
            userAgent
          }
          count
        }
      }
    }
  }
`;
```

Fix:

1. Lower sensitivity for specific rule/category
2. Use `log` action first to validate (Enterprise Advanced)
3. Add exception with custom expression (e.g., allowlist IPs)
4. Reduce category sensitivity: `{ category: "http-flood", sensitivity_level: "low" }`

## Adaptive Rules Not Working

Needs 7 days of traffic history for baseline. Check dashboard for adaptive rule status.

## Zone vs Account Override Conflict

Account overrides ignored when zone has overrides. Configure at zone level OR remove zone overrides to use account-level.

## Log Action Not Available

Requires Enterprise Advanced DDoS plan. Workaround: use `managed_challenge` with low sensitivity for testing.

## Rule Limits

| Plan | Override rules |
|------|---------------|
| Free/Pro/Business | 1 |
| Enterprise Advanced | Up to 10 |

Workaround: combine conditions in single expression using `and`/`or`.

## Read-only Managed Rules

Some rules cannot be overridden — API response indicates if rule is read-only.

## Tuning Strategy

1. Start with `log` action + `medium` sensitivity
2. Monitor 24-48 hours, identify false positives, add exceptions
3. Gradually increase to `default` sensitivity
4. Escalate action: `log` → `managed_challenge` → `block`
5. Document all adjustments

Best practices: test during low-traffic periods, use zone-level for per-site tuning, reference IP lists for easier management, set appropriate alert thresholds (avoid noise), combine with WAF for layered defense, avoid over-tuning.

See [patterns.md](./patterns.md) for progressive rollout examples.
