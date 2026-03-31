# Bot Management Patterns

WAF custom rules, Workers code, and rate limiting patterns for Cloudflare Bot Management. Enterprise features (granular scores, JA3/JA4) noted where applicable.

## E-commerce Protection

```txt
(cf.bot_management.score lt 50 and http.request.uri.path in {"/checkout" "/cart/add"} and not cf.bot_management.verified_bot and not cf.bot_management.corporate_proxy)
Action: Managed Challenge
```

## API Protection

```txt
(http.request.uri.path matches "^/api/" and (cf.bot_management.score lt 30 or not cf.bot_management.js_detection.passed) and not cf.bot_management.verified_bot)
Action: Block
```

## SEO-Friendly Bot Handling

```txt
(cf.bot_management.score lt 30 and not cf.verified_bot_category in {"Search Engine Crawler"})
Action: Managed Challenge
```

## Block AI Scrapers

```txt
(cf.verified_bot_category eq "AI Crawler")
Action: Block
```

Dashboard alternative: Security > Settings > Bot Management > Block AI Bots.

## Rate Limiting by Bot Score

```txt
(cf.bot_management.score lt 50)
Rate: 10 requests per 10 seconds

(cf.bot_management.score ge 50)
Rate: 100 requests per 10 seconds
```

## Mobile App Allowlisting

```txt
(cf.bot_management.ja4 in {"fingerprint1" "fingerprint2"})
Action: Skip (all remaining rules)
```

## Score Threshold Strategy

| Context | Threshold | Notes |
|---------|-----------|-------|
| Public content | score < 10 | High tolerance |
| Authenticated | score < 30 | Standard threshold |
| Sensitive (checkout, login) | score < 50 | + JS Detection |

## Defense Layering

```txt
1. Bot Management (score-based)
2. JavaScript Detections (JS-capable clients)
3. Rate Limiting (fallback)
4. WAF Managed Rules (OWASP, etc.)
```

Zero-trust approach: default deny (scores < 30), then allowlist verified bots, mobile apps (JA3/JA4), corporate proxies, and static resources.

## Workers: Score + JS Detection

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

## Rate Limiting by JWT Claim + Bot Score

```txt
Rate limiting > Custom rules
- Field: lookup_json_string(http.request.jwt.claims["{config_id}"][0], "sub")
- Matches: user ID claim
- Additional condition: cf.bot_management.score lt 50
```

Enterprise only — combines bot score with JWT validation.

## WAF Integration Points

- **WAF Custom Rules** — primary enforcement mechanism
- **Rate Limiting Rules** — bot score as dimension, stricter limits for low scores
- **Transform Rules** — pass score to origin via custom header
- **Workers** — programmatic bot logic, custom scoring algorithms
- **Configuration Rules** — zone-level overrides, path-specific settings
