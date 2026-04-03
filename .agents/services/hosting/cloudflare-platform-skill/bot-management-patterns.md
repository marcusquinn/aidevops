# Bot Management Patterns

WAF custom rules, rate limiting, and Workers patterns for Cloudflare Bot Management. Enterprise-only features (granular scores, JA3/JA4) are noted inline.

## WAF Rule Patterns

### Sensitive flows

```txt
(cf.bot_management.score lt 50 and http.request.uri.path in {"/checkout" "/cart/add"} and not cf.bot_management.verified_bot and not cf.bot_management.corporate_proxy)
Action: Managed Challenge
```

### APIs

```txt
(http.request.uri.path matches "^/api/" and (cf.bot_management.score lt 30 or not cf.bot_management.js_detection.passed) and not cf.bot_management.verified_bot)
Action: Block
```

### Search engine access

```txt
(cf.bot_management.score lt 30 and not cf.verified_bot_category in {"Search Engine Crawler"})
Action: Managed Challenge
```

### AI crawlers

```txt
(cf.verified_bot_category eq "AI Crawler")
Action: Block
```

Dashboard alternative: Security > Settings > Bot Management > Block AI Bots.

### Mobile apps (Enterprise)

```txt
(cf.bot_management.ja4 in {"fingerprint1" "fingerprint2"})
Action: Skip (all remaining rules)
```

## Thresholds and Layering

| Context | Threshold | Notes |
|---------|-----------|-------|
| Public content | score < 10 | High tolerance |
| Authenticated | score < 30 | Standard threshold |
| Sensitive (checkout, login) | score < 50 | Add JavaScript Detections |

```txt
1. Bot Management (score-based)
2. JavaScript Detections (JS-capable clients)
3. Rate Limiting (fallback)
4. WAF Managed Rules (OWASP, etc.)
```

Zero-trust baseline: deny lower-score traffic first, then allowlist verified bots, mobile apps (JA3/JA4), corporate proxies, and static resources.

## Rate Limiting

```txt
(cf.bot_management.score lt 50)
Rate: 10 requests per 10 seconds

(cf.bot_management.score ge 50)
Rate: 100 requests per 10 seconds
```

```txt
Rate limiting > Custom rules
- Field: lookup_json_string(http.request.jwt.claims["{config_id}"][0], "sub")
- Matches: user ID claim
- Additional condition: cf.bot_management.score lt 50
```

## Workers

```typescript
export default {
  async fetch(request: Request): Promise<Response> {
    const cf = request.cf as any;
    const botMgmt = cf?.botManagement;
    const url = new URL(request.url);

    if (botMgmt?.staticResource) return fetch(request);

    if (url.pathname.startsWith('/api/')) {
      const jsDetectionPassed = botMgmt?.jsDetection?.passed ?? false;
      const score = botMgmt?.score ?? 100;

      if (!jsDetectionPassed || score < 30) {
        return new Response('Unauthorized', { status: 401 });
      }
    }

    return fetch(request);
  }
};
```

## Integration Points

- **WAF Custom Rules** — primary enforcement point
- **Rate Limiting Rules** — stricter quotas for lower bot scores
- **Transform Rules** — forward score to origin in a custom header
- **Workers** — add programmatic enforcement and custom scoring
- **Configuration Rules** — zone-level or path-specific overrides
