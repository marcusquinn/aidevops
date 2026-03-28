# Chapter 13: Heatmap and Session Recording Analysis

Heatmaps and session recordings reveal how users actually interact with your site.

## Heatmap Types

| Type | What It Shows | Key Question |
|------|--------------|--------------|
| **Click** | Where users click/tap | Are CTAs getting clicked? Are non-clickable elements being clicked? |
| **Scroll** | How far users scroll | Do users reach the CTA? Where do they drop off? |
| **Move** | Mouse cursor movement (desktop) | Where is attention? Are there hesitation points? |
| **Attention** | Time spent per area | What content gets read vs ignored? |

### Click Heatmap — Example Insights

```text
1,000 clicks on product image (not clickable) / 0 clicks on "View Details"
→ Action: Make image clickable or add "Click to enlarge" text

500 clicks on "Free Shipping" text (looks like button, isn't)
→ Action: Make it a button or visually differentiate it
```

### Scroll Heatmap — Example Insights

```text
60% of users never scroll past hero section / CTA at 70% page depth
→ Action: Add CTA above fold OR create sticky CTA

90% engagement at top → 40% middle → 10% bottom
→ Action: Move important content higher, cut fluff, add visual breaks
```

### Move Heatmap — Example Insights

```text
Cursors hovering over price 10+ seconds, then leaving without clicking
→ Action: Add guarantees/testimonials near pricing

Users reading first 3 bullets, skipping rest
→ Action: Limit to 3–5 bullets, restructure for scannability
```

### Attention Heatmap — Example Insights

```text
2s on headline / 30s on image / 0s on benefits section
→ Action: Make benefits more visual/scannable or reposition

20+ seconds on navigation menu (confusion signal)
→ Action: Simplify navigation labels or structure
```

## Reading Heatmaps

**Colour scale:** Red = high activity → Orange/Yellow = medium → Blue/Green = low → White/Gray = none

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

**Don't watch randomly** — segment first.

| Segment | Purpose | Sample Size |
|---------|---------|-------------|
| Converters | See what worked | 20–30 recordings |
| Abandoners | See what broke | 20–30 recordings |
| Bounces | See what turned them off | 20–30 recordings |

**Additional filters:** traffic source (paid vs organic vs email), device (mobile vs desktop).

**Note-taking template:**

```text
Issue: Users confused by navigation
Frequency: 8/20 recordings
Action: Simplify nav labels
Priority: High
```

## Analysis Checklists

### Click Heatmap
- [ ] Are CTAs getting clicked? If not, why?
- [ ] Are users clicking non-clickable elements?
- [ ] Are users clicking the wrong elements?
- [ ] Are there unexpected click patterns?
- [ ] Mobile: Are tap targets large enough?

### Scroll Heatmap
- [ ] What % of users reach the CTA?
- [ ] Where do most users drop off?
- [ ] Is important content below average scroll depth?
- [ ] Are there visual barriers preventing scrolling?

### Move Heatmap
- [ ] Where are cursors spending the most time?
- [ ] Are there hesitation patterns (hovering without clicking)?
- [ ] Do move patterns align with click patterns?

### Attention Heatmap
- [ ] What gets the most attention? Is it what you want?
- [ ] What gets ignored? Should it be more prominent?
- [ ] Is attention distributed logically?

## Sample Size Guidelines

| Traffic Level | Sessions/Month | Data Needed |
|--------------|---------------|-------------|
| High | 10,000+ | 1–2 weeks |
| Medium | 1,000–10,000 | 2–4 weeks |
| Low | <1,000 | 1–3 months |

**Thresholds:**
- 100–200 sessions: initial patterns
- 500–1,000: reliable insights
- 2,000+: statistically confident
- Conversion pages: minimum 50 conversions + 500 non-conversions
- Per-segment analysis: minimum 200–500 sessions per segment

> Too little data (< 20 sessions) = noise from single outlier users. Too much (> 5,000) = diminishing returns; patterns stabilise.

## Combining Heatmaps with Analytics

Heatmaps answer **"what happened"**. Analytics answer **"how much"**.

| Scenario | Analytics | Heatmap | Session Recording | Insight | Action | Result |
|----------|-----------|---------|-------------------|---------|--------|--------|
| Low CTA clicks | 2% click rate | Near-zero CTA clicks | Users clicking image above CTA | Image perceived as CTA | Make image clickable OR redesign CTA | Click rate → 8% |
| High bounce rate | 70% bounce | 90% never scroll past hero | Users read headline, immediately leave | Headline/ad mismatch ("free trial" ad → "request demo" page) | Align headline with ad | Bounce rate → 45% |
| Form abandonment | 60% abandon at phone field | High attention on phone field, zero submits | Users fill email/name, hesitate at phone, leave | Phone field creates friction | Make phone optional | Completion rate +35% |

---

*Continues in [Chapter 14: Landing Page Teardowns](./CHAPTER-14.md) and [Chapter 15: Personalization](./CHAPTER-15.md).*
