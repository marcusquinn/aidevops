<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Chapter 13: Heatmap and Session Recording Analysis

Heatmaps and session recordings reveal how users actually interact with your site.

## Heatmap Types

| Type | What It Shows | Check |
|------|--------------|-------|
| **Click** | Where users click/tap | CTAs clicked? Non-clickable elements clicked? Tap targets large enough (mobile)? |
| **Scroll** | How far users scroll | % reaching CTA? Where do most drop off? Important content below scroll depth? |
| **Move** | Mouse cursor movement (desktop) | Where is attention? Hesitation points (hover without click)? Aligns with clicks? |
| **Attention** | Time spent per area | What gets read vs ignored? Attention distributed logically? |

**Colour scale:** Red = high → Orange/Yellow = medium → Blue/Green = low → White/Gray = none

### Example Insights by Type

| Type | Pattern | Action |
|------|---------|--------|
| Click | 1,000 clicks on product image (not clickable), 0 on "View Details" | Make image clickable or add "Click to enlarge" |
| Click | 500 clicks on "Free Shipping" text (looks like button) | Make it a button or visually differentiate |
| Scroll | 60% never scroll past hero; CTA at 70% depth | Add CTA above fold or sticky CTA |
| Scroll | 90% top → 40% middle → 10% bottom | Move key content higher; add visual breaks |
| Move | Cursors hover over price 10+ seconds, then leave | Add guarantees/testimonials near pricing |
| Move | Users read first 3 bullets, skip rest | Limit to 3–5 bullets; restructure for scannability |
| Attention | 2s on headline / 30s on image / 0s on benefits | Make benefits more visual/scannable or reposition |
| Attention | 20+ seconds on nav menu | Simplify navigation labels or structure |

## Reading Heatmaps

### Good Patterns

| Page | Signals |
|------|---------|
| Hero | Red on headline + CTA; some attention on value prop |
| Product | High clicks on "Add to Cart"; high attention on images; low clicks on unrelated elements |
| Landing | 80%+ scroll depth reaching CTA; high CTA clicks; even attention across benefits |

### Bad Patterns — Diagnosis and Fix

| Pattern | Cause | Action |
|---------|-------|--------|
| **Rage clicks** (rapid repeated clicks) | Element looks clickable but isn't; broken JS; slow response | Fix the broken/misleading element |
| **Dead clicks** (non-clickable elements) | Visual cue implies interactivity | Make functional or remove visual cue |
| **Scroll abandonment** (90% leave at 30%) | Boring content; no visual breaks; CTA too low | Add engaging content, visual hierarchy, move CTA up |
| **Ignored CTA** (near-zero clicks) | Poor placement; weak copy; not visually distinct; wrong audience | Redesign, reposition, or rewrite CTA |

## Heatmap Tools

| Tool | Key Features | Cost |
|------|-------------|------|
| **Hotjar** | Click/scroll/move maps, session recordings, surveys | Free plan available |
| **Crazy Egg** | Click maps (desktop + mobile), scroll maps, confetti (segment by source), A/B testing | Paid |
| **Microsoft Clarity** | Heatmaps, session recordings, rage/dead click detection, GA integration | Free |
| **Mouseflow** | Heatmaps, session recordings, form analytics, funnel analysis | Paid |
| **FullStory** | Session recordings, retroactive funnels, heatmaps, error tracking | Premium |

## Session Recordings — What to Watch For

| Signal | Indicates | Action |
|--------|-----------|--------|
| Hovering 10+ seconds without clicking | Uncertainty, lack of trust, unclear value | Add guarantees, testimonials, clearer benefits |
| Clicking multiple nav items, backtracking | Poor navigation, confusing copy | Simplify nav, improve content clarity |
| Rapid clicks same spot (rage clicks) | Broken element, slow load, misleading design | Fix technical issue or redesign element |
| Form started then abandoned | Friction at specific field | Simplify form, reduce required fields, add reassurance |
| Fast scroll to bottom then leave | Not finding what they need; wrong audience | Review messaging/targeting |
| Slow, careful scrolling | High intent, engaged | Likely to convert — don't interrupt |
| Back-and-forth scrolling | Seeking info that's hard to find | Improve content findability |
| Zooming in, struggling to tap (mobile) | Poor mobile optimisation | Larger fonts, bigger buttons, fix responsive design |

### Form Abandonment — Field-Level Diagnosis

| Field | Likely Cause | Fix |
|-------|-------------|-----|
| Email | Privacy concern or not ready to commit | Add privacy reassurance |
| Phone | Don't want to be called | Make optional |
| Credit card | Not ready to pay or security concern | Add trust signals; consider free trial |
| Complex field | Confused about what to enter | Add placeholder/help text |

### Common Exit Points

| Page | Why They Leave | Fix |
|------|---------------|-----|
| Pricing | Too expensive or unclear value | Add comparison, guarantees |
| Checkout | Surprise fees, friction, trust issues | Show total early, add trust badges |
| Form | Too long, too invasive | Reduce fields |
| Product | Not enough info, poor images | Improve content and imagery |

## Session Recording Methodology

**Don't watch randomly** — segment first. Log each finding as: Issue / Frequency (e.g. 8/20 recordings) / Action / Priority.

| Segment | Purpose | Sample Size |
|---------|---------|-------------|
| Converters | See what worked | 20–30 recordings |
| Abandoners | See what broke | 20–30 recordings |
| Bounces | See what turned them off | 20–30 recordings |

**Additional filters:** traffic source (paid vs organic vs email), device (mobile vs desktop).

## Sample Size Guidelines

| Traffic Level | Sessions/Month | Data Needed | Threshold |
|--------------|---------------|-------------|-----------|
| High | 10,000+ | 1–2 weeks | 2,000+ = statistically confident |
| Medium | 1,000–10,000 | 2–4 weeks | 500–1,000 = reliable insights |
| Low | <1,000 | 1–3 months | 100–200 = initial patterns |

Conversion pages: minimum 50 conversions + 500 non-conversions. Per-segment: minimum 200–500 sessions. < 20 sessions = noise; > 5,000 = diminishing returns.

## Combining Heatmaps with Analytics

Heatmaps answer **"what happened"**. Analytics answer **"how much"**.

| Scenario | Analytics | Heatmap | Session Recording | Insight | Action | Result |
|----------|-----------|---------|-------------------|---------|--------|--------|
| Low CTA clicks | 2% click rate | Near-zero CTA clicks | Users clicking image above CTA | Image perceived as CTA | Make image clickable OR redesign CTA | Click rate → 8% |
| High bounce rate | 70% bounce | 90% never scroll past hero | Users read headline, immediately leave | Headline/ad mismatch ("free trial" ad → "request demo" page) | Align headline with ad | Bounce rate → 45% |
| Form abandonment | 60% abandon at phone field | High attention on phone field, zero submits | Users fill email/name, hesitate at phone, leave | Phone field creates friction | Make phone optional | Completion rate +35% |

---

*Continues in [Chapter 14: Landing Page Teardowns](./CHAPTER-14.md) and [Chapter 15: Personalization](./CHAPTER-15.md).*
