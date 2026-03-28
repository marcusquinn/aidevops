---
description: Product growth and user acquisition - 5 growth channels for B2C apps, extensions, and SaaS
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Product Growth - User Acquisition Playbook

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Acquire users for B2C products across all platforms
- **Channels**: UGC creators, influencers, faceless content, founder-led content, paid ads
- **Principle**: Money follows attention — master distribution, not just product
- **Applies to**: Mobile apps, browser extensions, desktop apps, web apps, SaaS

**Channel decision tree**:

```text
Have budget for creators?
  -> UGC creators (volume) + Influencers (spikes)

No budget?
  -> Faceless content accounts (free, scalable)
  -> Founder-led content (free, builds brand)

Have proven creatives?
  -> Paid ads (scalable, predictable)

All of the above?
  -> Run all 5 channels in parallel for maximum growth
```

**Related agents**:

- `content/distribution-short-form.md` - TikTok/Reels/Shorts production
- `marketing-sales/ad-creative.md` - Ad creative production
- `marketing-sales/meta-ads.md` - Meta Ads campaigns
- `marketing-sales/direct-response-copy.md` - Copywriting frameworks
- `services/outreach/cold-outreach.md` - Creator outreach at scale

<!-- AI-CONTEXT-END -->

## The 5 Growth Channels

### 1. UGC Creators (Paid — Volume Play)

Hire creators to post authentic-feeling product content from their own accounts, generating organic reach at scale.

**Process**: Hire 3-10 creators posting 30-60 videos/month each. Provide briefs with hook options, talking points, and product access. When one creator cracks a viral format, have all others replicate it.

**Payment structure**:

| Component | Amount | Notes |
|-----------|--------|-------|
| Base rate | $15-25/video | Covers production cost |
| 100k views | $150 bonus | Incentivises quality |
| 250k views | $300 bonus | Rewards viral content |
| 500k views | $600 bonus | Significant reach |
| 1M+ views | $800 bonus | Jackpot territory |

Total per viral video: ~$850. If 1M views generates $5k+ in revenue, the ROI is strong.

**Finding creators**:

- **Manual sourcing** (recommended): Scroll TikTok/Instagram in your niche, DM creators with 1k-50k followers. Send 50-100 outreach messages/day.
- **Platforms**: Sideshift, Billo, Insense — more expensive, less control
- **Delegation**: Hire someone to scroll and send outreach DMs daily. Optimise their feed to surface relevant creators.

**Management**:

- Sign contracts covering content rights, exclusivity, payment terms
- Use UGC brief template: `marketing-sales/meta-ads-creative-briefs-ugc-brief.md`
- Communicate daily — connected creators produce better content
- Track per-creator performance — double down on top performers, replace underperformers
- Provide brand guidelines but allow creative freedom in delivery

### 2. Influencers (Paid — Spike Play)

Unlike UGC (volume over time), influencers deliver concentrated bursts of attention.

**Deal structure — CPM model (recommended)**: $1 CPM (per 1,000 views). 500k views = $500. Cap at $1,000-2,000/video to limit downside. If they don't perform, you don't lose money.

**Finding influencers**: Same as UGC — scroll your niche, DM relevant accounts. Target 50k-500k followers (large enough for reach, small enough to negotiate). Check engagement rate (likes + comments / followers) — aim for > 3%.

**Negotiation**: Lead with CPM. Offer hybrid if needed: small base ($100-200) + CPM bonus. Start with one test video before committing to a series. Request content approval before posting (don't over-edit — authenticity matters).

### 3. Faceless Content (Free — Consistency Play)

Faceless accounts post without showing a face — slideshows, screen recordings, text-on-screen, stock clips with captions, product demos with hooks. Most underrated growth channel.

**Posting cadence**: 3-5 posts/day across TikTok, Reels, and Shorts.

**Brand consistency is the key** — most faceless accounts fail because they look random:

- Consistent visual style — same colour palette, fonts, layout
- Consistent character/mascot (optional but powerful)
- Consistent content structure — same hook format, pacing, CTA placement
- Pinterest-feed aesthetic is death — if every post looks different, you have no brand

**When a format hits**: Identify which structure got engagement → create 10+ variations (same hook structure, different topics) → post across all platforms. Faceless pages hit millions of views from systematically scaling proven formats, not single viral videos.

See `content/distribution-short-form.md` for production workflows, hook formulas, and platform-specific optimisation.

### 4. Founder-Led Content (Free — Authority Play)

Founder/team member creates content showing their face, sharing insights, building personal brand around the product.

**Why it works**: Builds trust faceless can't match. Creates personal audience connection. Develops "viral sense" — understanding what resonates, which you relay to UGC creators. Compounds as personal brand grows.

**Format replication**: Find viral formats in your niche (200k+ views) → study structure (hook, pacing, visual style, CTA) → recreate with your content → test and iterate.

**Content ideas**: Behind-the-scenes building, user success stories, "I tried X" experiments, industry hot takes, product updates/feature reveals.

**Even with budget for paid channels**, founder-led content develops the instinct for what goes viral — knowledge you apply to directing UGC creators and influencers.

### 5. Paid Ads (Paid — Scale Play)

Most scalable and predictable channel. Once you crack a good CPA with winning creatives, scale spend with confidence. Scalable, predictable, testable, compounding.

**Platform priority**:

| Platform | Best For | Minimum Budget |
|----------|----------|---------------|
| TikTok Ads | B2C apps, younger demographics | $50/day |
| Meta (Facebook/Instagram) | Broad demographics, retargeting | $50/day |
| Google Ads (UAC/App campaigns) | High-intent search traffic | $50/day |
| Apple Search Ads | iOS app installs (high intent) | $20/day |
| Reddit Ads | Niche communities, tech products | $20/day |

**Creative-led scaling** — the creative is everything. Mediocre product with great creatives outperforms great product with mediocre creatives:

1. Start with 5-10 ad creatives (UGC-style, product demos, testimonials)
2. Run each at $10-20/day for 3-5 days
3. Kill anything with CPA > 2x target
4. Scale winners: increase budget 20-30% every 2-3 days
5. Continuously test new creatives to combat ad fatigue

**TikTok Spark Ads**: Boost organic TikTok posts (yours or UGC creators') as ads. Preserves organic feel with paid reach. Particularly effective when organic post is already performing.

**Attribution**:

- **Mobile**: MMP (Singular, Adjust, AppsFlyer) for cross-platform attribution
- **Web/Desktop**: UTM parameters + analytics (PostHog, GA4)
- **Extensions**: Chrome Web Store referral tracking + UTM on landing pages

See `marketing-sales/meta-ads.md` for Meta Ads campaign setup and `marketing-sales/ad-creative.md` for creative production.

## Channel Sequencing

### Phase 1: Validation (Week 1-2)

- **Faceless content** (free, tests messaging) + **founder-led content** (builds brand from day one)
- Goal: Find 1-2 content formats that get engagement

### Phase 2: Amplification (Week 3-4)

- Hire 2-3 **UGC creators** to replicate winning formats + 1-2 **influencer** CPM deals
- Goal: First significant traffic spike

### Phase 3: Scale (Month 2+)

- Best organic content → **paid ads**. Scale UGC roster to 5-10. A/B test creatives systematically.
- Goal: Predictable, profitable CPA

## Metrics to Track

| Metric | What It Tells You | Target |
|--------|-------------------|--------|
| CPI (Cost Per Install) | Paid acquisition efficiency | < $2 for B2C apps |
| CPA (Cost Per Acquisition) | Cost to get a paying user | < LTV/3 |
| ROAS (Return on Ad Spend) | Revenue per ad dollar | > 2x |
| Organic/Paid ratio | Channel health | > 50% organic |
| Viral coefficient | Users bringing other users | > 0.5 |
| Content velocity | Posts per week across all channels | 20+ |

## Related

- `content/distribution-short-form.md` - TikTok/Reels/Shorts production
- `marketing-sales/ad-creative.md` - Ad creative production (12 chapters)
- `marketing-sales/meta-ads.md` - Meta Ads campaigns
- `marketing-sales/direct-response-copy.md` - Copywriting frameworks
- `marketing-sales/cro.md` - Landing page optimisation
- `services/outreach/cold-outreach.md` - Creator outreach at scale
- `product/monetisation.md` - Revenue models (feeds growth ROI calculations)
- `product/analytics.md` - Attribution and metrics tracking
- `product/validation.md` - Market research before growth spend
