---
name: social-media
description: Social media management - content scheduling, analytics, engagement, multi-platform strategy
mode: subagent
subagents:
  # Social tools
  - bird
  - linkedin
  - reddit
  # Content
  - guidelines
  - summarize
  # Research
  - crawl4ai
  - serper
  # Built-in
  - general
  - explore
---

# Social Media - Main Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Social media management and strategy
- **Platforms**: Twitter/X, LinkedIn, Facebook, Instagram, YouTube, TikTok

**Typical Tasks**:
- Content planning and scheduling
- Engagement monitoring
- Analytics and reporting
- Multi-platform strategy
- Audience growth
- Hashtag research
- Competitor analysis

<!-- AI-CONTEXT-END -->

## Social Media Workflows

### Content Planning

- Editorial calendar management
- Content pillars and themes
- Platform-specific formatting
- Optimal posting times
- Content repurposing across platforms

### Engagement

- Community management
- Response templates
- Sentiment monitoring
- Influencer identification
- User-generated content curation

### Analytics

- Performance metrics tracking
- Audience insights
- Competitor benchmarking
- ROI measurement
- Trend analysis

### Platform-Specific

| Platform | Focus Areas |
|----------|-------------|
| Twitter/X | Real-time engagement, threads, hashtags |
| LinkedIn | Professional content, thought leadership |
| Facebook | Community building, groups, events |
| Instagram | Visual content, stories, reels |
| YouTube | Video SEO, thumbnails, descriptions |
| TikTok | Short-form video, trends, sounds |

### Integration Points

- `tools/social-media/bird.md` - X/Twitter CLI (read, post, reply, search)
- `tools/social-media/linkedin.md` - LinkedIn API (posts, articles, carousels, analytics)
- `tools/social-media/reddit.md` - Reddit API via PRAW (read, post, reply)
- `content.md` - Content creation workflows
- `marketing.md` - Campaign coordination
- `seo.md` - Keyword and hashtag research
- `research.md` - Competitor and trend analysis
