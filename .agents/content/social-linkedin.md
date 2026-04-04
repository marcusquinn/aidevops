---
description: LinkedIn content creation, posting, and analytics via API
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# LinkedIn Content Subagent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **API**: Community Management API (v2) via OAuth 2.0
- **Docs**: https://learn.microsoft.com/en-us/linkedin/marketing/
- **Auth**: OAuth 2.0 three-legged flow, scopes: `w_member_social`, `r_organization_social`
- **Related**: [bird.md](bird.md) (X/Twitter), [reddit.md](reddit.md) (Reddit)

**Post types**: Text (3k chars), Article (long-form), Carousel (PDF, 300p), Document (PDF/PPT/DOC, 100MB), Poll (2-4 options, 1-2 wks), Image (up to 9), Video (10 min max)

<!-- AI-CONTEXT-END -->

## API Setup

1. Create app at https://www.linkedin.com/developers/apps
2. Request Community Management API access (requires app review)
3. Configure redirect URI and obtain client ID/secret

```bash
aidevops secret set LINKEDIN_CLIENT_ID
aidevops secret set LINKEDIN_CLIENT_SECRET
aidevops secret set LINKEDIN_ACCESS_TOKEN
```

**Key endpoints**: `GET /v2/userinfo` (profile), `POST /v2/posts` (create), `POST /v2/images?action=initializeUpload` (media), `GET /v2/organizationalEntityShareStatistics` (analytics)

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.linkedin.com/v2/posts" \
  -d '{"author":"urn:li:person:ID","lifecycleState":"PUBLISHED","visibility":"PUBLIC","commentary":"Post text here","distribution":{"feedDistribution":"MAIN_FEED"}}'
```

## Content Best Practices

**Structure**: Hook (1-2 lines, ~210 chars) → Body (`\n` breaks) → CTA → Hashtags (3-5 at end). Bold/italic via Unicode. Emoji 1-3 per post. Limit: 3k chars.

- **Hashtags**: 3-5 max, mix broad (#Leadership) with niche (#DevOps)
- **Timing**: Tue-Thu, 7-8am / 12pm / 5-6pm, 3-5 posts/week
- **Engagement**: Open with hook/bold statement, end with CTA question
- **Stories**: "I" narratives perform 2-3x better
- **Reply**: Respond within 1h for algorithmic boost
- **Repurposing**: Blog → key points + link; Tweet → expand; Talk → carousel; Docs → how-to + code; Reddit → thought leadership

## Analytics

| Metric | Target | API Field |
|--------|--------|-----------|
| Impressions | Trend | `impressionCount` |
| Engagement | >2% good | `engagementRate` |
| Click-through | >1% links | `clickCount` |
| Shares | High-value | `shareCount` |

## Troubleshooting

| Issue | Solution |
|-------|----------|
| 401 | Token expired; re-auth |
| 403 | Missing scope/approval |
| 429 | Daily limit ~100; backoff |
| Hidden | Check visibility; `PUBLIC` |
| Upload | Register first, then PUT |
