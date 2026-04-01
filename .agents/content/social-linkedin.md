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

# LinkedIn Content Subagent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Create, publish, and analyze LinkedIn content
- **API**: Community Management API (v2) via OAuth 2.0
- **Docs**: https://learn.microsoft.com/en-us/linkedin/marketing/
- **Auth**: OAuth 2.0 three-legged flow, scopes: `w_member_social`, `r_organization_social`
- **Related**: [bird.md](bird.md) (X/Twitter), [reddit.md](reddit.md) (Reddit)

## Post Types

| Type | Use Case | Notes |
|------|----------|-------|
| **Text** | Thought leadership | 3k char limit |
| **Article** | Long-form | Native platform |
| **Carousel** | Visual | PDF, 300 pgs max |
| **Document** | Guides | PDF/PPT/DOC, 100MB |
| **Poll** | Engagement | 2-4 options, 1-2 wks |
| **Image** | Visual | Up to 9 images |
| **Video** | Native | 10 min max |

<!-- AI-CONTEXT-END -->

## API Access

### OAuth 2.0 Setup

1. Create app at https://www.linkedin.com/developers/apps
2. Request Community Management API access (requires app review)
3. Configure redirect URI and obtain client ID/secret

```bash
# Store credentials securely
aidevops secret set LINKEDIN_CLIENT_ID
aidevops secret set LINKEDIN_CLIENT_SECRET
aidevops secret set LINKEDIN_ACCESS_TOKEN
```

### Key Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v2/userinfo` | GET | Authenticated user profile |
| `/v2/posts` | POST | Create text/media posts |
| `/v2/images?action=initializeUpload` | POST | Register image upload |
| `/v2/organizationalEntityShareStatistics` | GET | Post analytics |

```bash
# Create a text post
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.linkedin.com/v2/posts" \
  -d '{"author":"urn:li:person:ID","lifecycleState":"PUBLISHED","visibility":"PUBLIC","commentary":"Post text here","distribution":{"feedDistribution":"MAIN_FEED"}}'
```

## Post Structure & Formatting

1. **Hook** — first 1-2 lines (~210 chars)
2. **Body** — content with `\n` breaks; blank lines for paragraphs
3. **CTA** — call to action (comment, share, link)
4. **Hashtags** — 3-5 relevant tags at end

Bold/italic via Unicode. Emoji 1-3 per post. Limit: 3k chars.

## Content Best Practices

- **Hashtags**: 3-5 max, mix broad (#Leadership) with niche (#DevOps)
- **Timing**: Tue-Thu, 7-8am / 12pm / 5-6pm, 3-5 posts/week
- **Engagement**: Open with hook/bold statement, end with CTA question
- **Stories**: "I" narratives perform 2-3x better
- **Reply**: Respond within 1h for algorithmic boost

## Analytics

| Metric | Target | API Field |
|--------|--------|-----------|
| Impressions | Trend | `impressionCount` |
| Engagement | >2% good | `engagementRate` |
| Click-through | >1% links | `clickCount` |
| Shares | High-value | `shareCount` |

## Content Repurposing

| Source | LinkedIn Format |
|--------|----------------|
| Blog | Key points + link |
| Tweet | Expand into post |
| Talk | Carousel slides |
| Docs | How-to + code |
| Reddit | Thought leadership |

**Cross-post**: Adapt for LinkedIn (professional), X/Twitter (concise — [bird.md](bird.md)), Reddit (subreddit-appropriate — [reddit.md](reddit.md)).

## Troubleshooting

| Issue | Solution |
|-------|----------|
| 401 | Token expired; re-auth |
| 403 | Missing scope/approval |
| 429 | Daily limit ~100; backoff |
| Hidden | Check visibility; `PUBLIC` |
| Upload | Register first, then PUT |
