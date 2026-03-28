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
| **Text post** | Thought leadership, updates | 3,000 char limit |
| **Article** | Long-form content | Published on LinkedIn's platform |
| **Carousel** | Multi-page visual content | PDF upload, up to 300 pages |
| **Document** | Whitepapers, guides | PDF/PPT/DOC, 100MB max |
| **Poll** | Audience engagement | 2-4 options, 1-2 week duration |
| **Image post** | Visual content | Up to 9 images per post |
| **Video** | Native video content | Up to 10 min recommended |

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

## Post Structure

Effective LinkedIn posts follow a consistent structure:

1. **Hook line** - First 1-2 lines visible before "see more" (~210 chars)
2. **Body** - Main content with line breaks for readability
3. **CTA** - Call to action (comment, share, visit link)
4. **Hashtags** - 3-5 relevant hashtags at the end

### Formatting

- **Bold/Italic**: Use Unicode characters (not supported natively in API)
- **Line breaks**: `\n` in API; blank lines for paragraph separation
- **Emoji**: Sparingly as visual anchors (1-3 per post)
- **Limits**: 3,000 chars for posts, ~210 visible before "see more" fold

## Content Best Practices

- **Hashtags**: 3-5 max, mix broad (#Leadership) with niche (#DevOpsAutomation), place at end
- **Timing**: Tue-Thu, 7-8am / 12pm / 5-6pm audience timezone, 3-5 posts/week
- **Engagement**: Open with question or bold statement, end with CTA question
- **Personal stories**: "I" narratives perform 2-3x better than generic content
- **Reply fast**: Respond to comments within first hour to boost algorithmic reach

## Analytics

### Key Metrics

| Metric | Target | API Field |
|--------|--------|-----------|
| Impressions | Track trend | `impressionCount` |
| Engagement rate | >2% good, >5% excellent | `engagementRate` |
| Click-through | >1% for link posts | `clickCount` |
| Shares | Indicates high-value content | `shareCount` |

## Automation Patterns

### Content Repurposing Pipeline

| Source | LinkedIn Format |
|--------|----------------|
| Blog post | Extract key points into text post + link |
| Tweet thread | Expand into single LinkedIn post |
| Conference talk | Carousel with key slides |
| Documentation | How-to post with code snippets |
| Reddit answer | Reframe as thought leadership |

**Cross-post workflow**: Draft content once, adapt for LinkedIn (professional tone, hashtags), X/Twitter (concise, threads - see [bird.md](bird.md)), Reddit (subreddit-appropriate - see [reddit.md](reddit.md)).

## Troubleshooting

| Issue | Solution |
|-------|----------|
| 401 Unauthorized | Token expired; re-authenticate OAuth flow |
| 403 Forbidden | Missing API scope or app not approved |
| 429 Rate limited | Daily limit ~100 API calls; implement backoff |
| Post not visible | Check visibility setting; may need `PUBLIC` scope |
| Image upload fails | Register upload first, then PUT binary to upload URL |
