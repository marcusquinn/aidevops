# Cloudflare Bot Management

Multi-tier bot detection using ML/heuristics, bot scores, JavaScript detections, and verified bot handling.

- **Free (Bot Fight Mode)**: Auto-blocks definite bots, no config
- **Pro/Business (Super Bot Fight Mode)**: Configurable actions, static resource protection, analytics groupings
- **Enterprise (Bot Management)**: Granular 1-99 scores, WAF integration, JA3/JA4 fingerprinting, Workers API, Advanced Analytics

## Quick Start

```txt
# Dashboard: Security > Bots
# Enterprise: Deploy rule template
(cf.bot_management.score eq 1 and not cf.bot_management.verified_bot) → Block
(cf.bot_management.score le 29 and not cf.bot_management.verified_bot) → Managed Challenge
```

## Core Concepts

**Bot Scores**: 1-99 (1 = automated, 99 = human). Threshold: <30 = bot traffic. Enterprise gets granular 1-99; Pro/Business get groupings only.

**Detection Engines**: Heuristics (known fingerprints → score=1), ML (supervised learning), Anomaly Detection (optional baseline), JavaScript Detections (headless browser detection).

**Verified Bots**: Allowlisted good bots (search engines, AI crawlers) verified via reverse DNS or Web Bot Auth. Fields: `cf.bot_management.verified_bot`, `cf.verified_bot_category`.

## Platform Limits

| Plan | Bot Scores | JA3/JA4 | Custom Rules | Analytics Retention |
|------|------------|---------|--------------|---------------------|
| Free | No (auto-block only) | No | 5 | N/A |
| Pro/Business | Groupings only | No | 20/100 | 30 days (72h at a time) |
| Enterprise | 1-99 granular | Yes | 1,000+ | 30 days (1 week at a time) |

## Basic Patterns

```typescript
// Workers: block score < 30, allow verified bots
export default {
  async fetch(request: Request): Promise<Response> {
    const botScore = request.cf?.botManagement?.score;
    if (botScore && botScore < 30 && !request.cf?.botManagement?.verifiedBot) {
      return new Response('Bot detected', { status: 403 });
    }
    return fetch(request);
  }
};
```

```txt
(cf.bot_management.score eq 1 and not cf.bot_management.verified_bot)
(cf.bot_management.score lt 50 and http.request.uri.path in {"/login" "/checkout"} and not cf.bot_management.verified_bot)
```

## In This Reference

- [patterns.md](./patterns.md) - E-commerce, API protection, mobile app allowlisting, SEO-friendly handling
- [gotchas.md](./gotchas.md) - False positives/negatives, score=0 issues, JSD limitations, CSP requirements

## See Also

- [waf](../waf/) - WAF custom rules for bot enforcement
- [workers](../workers/) - Workers request.cf.botManagement API
- [api-shield](../api-shield/) - API-specific bot protection
