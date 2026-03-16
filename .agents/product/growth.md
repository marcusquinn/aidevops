---
description: Product growth and acquisition playbook - ASO, SEO, content marketing, paid acquisition, referral, community, launch strategy
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Product Growth - Acquisition and Growth Playbook

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Acquire users, grow installs/signups, and build sustainable growth loops
- **Applies to**: Mobile apps, browser extensions, web apps, SaaS
- **Principle**: Build one channel to profitability before adding the next
- **Tools**: GSC (SEO), App Store Connect (ASO), PostHog (funnel), Stripe (revenue)

**Growth channel decision tree**:

```text
Product has strong search intent? (people search for it)
  -> SEO (web) + ASO (mobile/extension)

Product solves a visible problem in communities?
  -> Community + content marketing

Product has viral mechanics (sharing, collaboration)?
  -> Referral / viral loops

Product has high LTV (> $100)?
  -> Paid acquisition (Meta, Google Ads)

Product is developer-facing?
  -> GitHub, Hacker News, Dev.to, Product Hunt

Product is B2B?
  -> LinkedIn outreach + content + cold email
```

<!-- AI-CONTEXT-END -->

## App Store Optimisation (ASO)

ASO is the highest-ROI channel for mobile apps and browser extensions. Organic store search drives 65%+ of installs for most apps.

### ASO Fundamentals

| Element | Impact | Notes |
|---------|--------|-------|
| Title | Very high | Include primary keyword naturally |
| Subtitle (iOS) | High | Secondary keyword, value prop |
| Keywords field (iOS) | High | 100 chars, comma-separated, no spaces |
| Short description (Android) | High | 80 chars, keyword-rich |
| Long description | Medium | Keyword density, feature highlights |
| Screenshots | Very high | First 2-3 are shown in search results |
| Preview video | High | Autoplay in search, shows core value |
| Ratings and reviews | Very high | Prompt at right moment, respond to all |
| Icon | High | Drives click-through from search results |

### Keyword Research

1. **Seed keywords**: What would your target user search for?
2. **Competitor keywords**: What keywords do top competitors rank for?
3. **Long-tail keywords**: Lower competition, higher intent
4. **Tools**: AppFollow, AppTweak, Sensor Tower (paid); App Store search suggestions (free)

### Screenshot Strategy

- First screenshot: Core value proposition (not a feature list)
- Screenshots 2-3: Key features with real UI
- Use device frames and captions
- A/B test screenshot order and copy
- Localise screenshots for key markets

### Review Strategy

- Prompt for reviews after positive moments (completed goal, streak, achievement)
- Never prompt after errors or frustrating experiences
- Respond to every negative review with a solution
- Use review themes to prioritise features

## Search Engine Optimisation (SEO)

For web apps and SaaS, SEO compounds over time and drives high-intent traffic.

### Quick Wins

1. **Title tag**: Include primary keyword, keep under 60 chars
2. **Meta description**: Compelling, includes keyword, under 160 chars
3. **H1**: One per page, matches search intent
4. **Page speed**: Core Web Vitals — LCP < 2.5s, CLS < 0.1, INP < 200ms
5. **Mobile-friendly**: Responsive design, touch targets
6. **Structured data**: Product, FAQ, HowTo schema where relevant

### Content Strategy

- Target keywords with clear commercial intent ("best X tool", "X alternative", "how to X")
- Comparison pages: "Product vs Competitor" (high conversion intent)
- Use case pages: "X for [specific audience]"
- Integration pages: "X + [popular tool]"

See `seo/dataforseo.md` for keyword research tooling and `seo/google-search-console.md` for monitoring.

## Content Marketing

Content builds trust, drives SEO, and creates shareable assets.

### Content Types by ROI

| Type | ROI | Effort | Notes |
|------|-----|--------|-------|
| Tutorial/how-to | High | Medium | Targets "how to X" searches |
| Comparison | High | Medium | Targets "X vs Y" searches |
| Case study | High | High | Social proof + SEO |
| Changelog/release notes | Medium | Low | Keeps users engaged |
| Video demo | High | Medium | YouTube SEO + social |
| Newsletter | Medium | Medium | Retention + re-engagement |

### Distribution

- **SEO**: Publish on your domain (not Medium/Substack — you lose the SEO value)
- **Social**: Repurpose content for Twitter/X, LinkedIn, Reddit
- **Communities**: Share in relevant subreddits, Discord servers, Slack groups (add value, don't spam)
- **Newsletter**: Build an email list from day one — it's the only channel you own

## Paid Acquisition

Paid works when LTV > 3x CAC. Calculate this before spending.

### Channel Selection

| Channel | Best For | Minimum Budget |
|---------|---------|----------------|
| Meta (Facebook/Instagram) | Consumer apps, visual products | $50/day |
| Google Search Ads | High-intent searches, B2B | $50/day |
| Apple Search Ads | iOS app installs | $20/day |
| Google UAC | Android app installs | $20/day |
| LinkedIn | B2B SaaS, professional tools | $100/day |
| Reddit | Developer/niche communities | $20/day |

### Creative Strategy

- Test 5-10 ad creatives before scaling
- Video outperforms static for most consumer products
- UGC (user-generated content) style outperforms polished ads
- Lead with the problem, not the solution
- Clear CTA: "Download free", "Try free", "Get started"

See `tools/marketing/meta-ads/SKILL.md` for Meta Ads guidance.

## Referral and Viral Loops

Referral is the highest-ROI growth channel when it works — CAC approaches zero.

### Referral Mechanics

| Type | Example | When It Works |
|------|---------|---------------|
| Invite for reward | "Give 1 month free, get 1 month free" | When product has clear value |
| Collaboration | "Share this with your team" | Collaborative products |
| Social proof | "Share your achievement" | Milestone-based products |
| Powered by | "Made with [Product]" | Creation tools |

### Viral Coefficient

- K-factor > 1: Product grows on its own
- K-factor 0.5-1: Referral supplements other channels
- K-factor < 0.5: Referral is a minor channel

Track: invites sent, invites accepted, conversion rate.

## Community Building

Community creates retention, word-of-mouth, and product feedback loops.

### Community Channels

| Channel | Best For | Notes |
|---------|---------|-------|
| Discord | Developer tools, games, communities | Real-time, high engagement |
| Slack | B2B SaaS, professional tools | Integrates with workflows |
| Reddit | Broad consumer products | Organic discovery |
| GitHub Discussions | Open-source, developer tools | Integrated with code |
| Circle / Discourse | Premium communities, courses | Owned, no algorithm |

### Community Strategy

1. Start with a small, high-quality group (invite-only or application)
2. Be present and responsive — community dies without founder engagement
3. Create rituals (weekly threads, monthly AMAs, release announcements)
4. Celebrate user wins and milestones
5. Use community feedback to prioritise features

## Launch Strategy

### Pre-Launch (4-8 weeks before)

- [ ] Build email waitlist (landing page + lead magnet)
- [ ] Engage target communities (add value, don't pitch)
- [ ] Prepare Product Hunt listing (screenshots, tagline, first comment)
- [ ] Line up beta testers for reviews and testimonials
- [ ] Create launch content (demo video, blog post, social assets)

### Launch Day

- [ ] Post on Product Hunt (Tuesday-Thursday, 12:01am PST)
- [ ] Email waitlist with launch announcement
- [ ] Post in relevant communities (Reddit, Discord, Slack, Hacker News)
- [ ] Ask beta testers to upvote and leave reviews
- [ ] Monitor and respond to all comments

### Post-Launch (first 30 days)

- [ ] Follow up with users who signed up but didn't activate
- [ ] Collect and publish case studies from early users
- [ ] Submit to directories (AlternativeTo, G2, Capterra, Slant)
- [ ] Reach out to relevant newsletters and podcasts for coverage
- [ ] Analyse funnel: where are users dropping off?

## Growth Metrics

Track these to understand growth health:

| Metric | Formula | Target |
|--------|---------|--------|
| Install/signup rate | Installs / Store views | > 3% (mobile), > 5% (web) |
| Activation rate | Activated / Installs | > 60% |
| Day 7 retention | Active day 7 / Installs | > 20% |
| Referral rate | Referrals / Active users | > 5% |
| CAC | Ad spend / New users | < LTV / 3 |
| LTV | ARPU × avg lifetime | > 3× CAC |

## Related

- `product/validation.md` - Market research before building
- `product/onboarding.md` - Activation funnel
- `product/monetisation.md` - Revenue from acquired users
- `product/analytics.md` - Measuring growth metrics
- `seo/dataforseo.md` - Keyword research tooling
- `seo/google-search-console.md` - SEO monitoring
- `tools/marketing/meta-ads/SKILL.md` - Meta Ads campaigns
- `tools/marketing/cro/SKILL.md` - Conversion rate optimisation
