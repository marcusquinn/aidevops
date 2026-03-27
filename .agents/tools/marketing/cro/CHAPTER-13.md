# Chapter 13: Heatmap and Session Recording Analysis

Heatmaps and session recordings reveal how users actually interact with your site.

## Heatmap Types

| Type | Shows | Key Questions |
|------|-------|---------------|
| **Click** | Where users click/tap | CTAs clicked? Non-clickable elements clicked? Wrong elements clicked? |
| **Scroll** | How far users scroll | Does CTA fall below fold? Where do users drop off? |
| **Move** | Mouse cursor movement (desktop) | Where is attention? Hesitation points (hover without click)? |
| **Attention** | Time spent per area | What gets read vs ignored? Where do users spend time before converting? |

### Click Heatmap Examples

```text
1,000 clicks on product image (not clickable) + 0 clicks on "View Details"
→ Action: Make image clickable or add "Click to enlarge" text

500 clicks on "Free Shipping" text (looks like button)
→ Action: Make it a button or visually differentiate it
```

### Scroll Heatmap Examples

```text
60% never scroll past hero; CTA at 70% page depth
→ Action: Add CTA above fold OR create sticky CTA

90% engagement at top → 40% middle → 10% bottom
→ Action: Move important content higher, cut fluff, add visual breaks
```

### Move/Attention Heatmap Examples

```text
Cursors hover over price 10+ seconds, then leave without clicking
→ Action: Add guarantees/testimonials near pricing

Users read first 3 bullets, skip rest
→ Action: Limit to 3–5 bullets, restructure for scannability

2s on headline, 30s on image, 0s on benefits section
→ Action: Make benefits more visual/scannable or reposition

20+ seconds on navigation (confusion signal)
→ Action: Simplify navigation labels or structure
```

## Reading Heatmaps

**Colour scale:** Red = high activity → Yellow/Orange = medium → Blue/Green = low → White/Gray = none

### Good Patterns

| Page | Signals |
|------|---------|
| Hero | Red on headline + CTA; some attention on value prop |
| Product | High clicks on "Add to Cart"; high attention on images; moderate on description |
| Landing | 80%+ scroll depth reaches CTA; high CTA clicks; even attention across benefits |

### Bad Patterns

| Pattern | Causes | Action |
|---------|--------|--------|
| **Rage clicks** (rapid repeated clicks) | Non-clickable element, broken JS, slow response | Fix the broken/misleading element |
| **Dead clicks** (clicks on non-interactive elements) | Visual cue implies clickability | Make functional or remove visual cue |
| **Scroll abandonment** (90% leave before 30%) | Boring content, no visual breaks, CTA too low | Add engaging content, visual hierarchy, raise CTA |
| **Ignored CTA** (near-zero clicks despite traffic) | Poor placement, weak copy, not visually distinct, low value prop | Redesign, reposition, or rewrite CTA |

## Heatmap Tools

| Tool | Key Features | Cost |
|------|-------------|------|
| **Hotjar** | Click/scroll/move heatmaps, session recordings, surveys | Free plan available |
| **Crazy Egg** | Click heatmaps, scroll maps, confetti (segment by source), A/B testing | Paid |
| **Microsoft Clarity** | Heatmaps, session recordings, rage/dead click detection, GA integration | Free |
| **Mouseflow** | Heatmaps, session recordings, form analytics, funnel analysis | Paid |
| **FullStory** | Session recordings, retroactive funnels, heatmaps, error tracking | Premium |

## Session Recordings: What to Watch For

| Signal | Indicates | Action |
|--------|-----------|--------|
| Hover 10+ seconds without clicking | Uncertainty, fear, unclear value | Add guarantees, testimonials, clearer benefits |
| Clicks multiple nav items, backtracks | Poor navigation, confusing copy | Simplify nav, improve content clarity |
| Rage clicks (5–10 rapid clicks) | Broken element, slow load, misleading design | Fix technical issue or redesign element |
| Starts form, abandons at phone field | Privacy concerns | Make phone optional |
| Starts form, abandons at credit card | Not ready to pay, security concerns | Add trust signals, simplify checkout |
| Fast scroll to bottom, leaves | Not finding what they need, wrong audience | Audit message-match, improve scannability |
| Slow careful scroll | High intent, engaged, likely to convert | Reinforce conversion path |
| Back-and-forth scrolling | Seeking info that's hard to find | Improve information architecture |
| Zooming in, struggling to tap | Poor mobile optimization | Larger fonts, bigger buttons, fix responsive design |

### Common Exit Points

| Page | Why They Leave | Action |
|------|---------------|--------|
| Pricing | Too expensive or unclear value | Add value context, comparison, guarantees |
| Checkout | Surprise fees, friction, trust issues | Remove friction, add trust signals |
| Form | Too long, too invasive | Reduce required fields, add reassurance |
| Product | Not enough info, poor images | Improve content, add better images |

## Session Recording Methodology

**Don't watch randomly.** Segment first:

1. **Converters** — see what worked
2. **Abandoners** — see what broke
3. **Bounces** — see what turned them off

**Filters:** Traffic source (paid ≠ organic ≠ email) | Device (mobile vs desktop)

**Sample size:** 20–30 recordings per segment is enough to identify patterns.

**Note-taking template:**

```text
Issue: Users confused by navigation
Frequency: 8/20 recordings
Action: Simplify nav labels
Priority: High
```

## Sample Size Guidelines

| Traffic Level | Sessions/Month | Data Needed |
|--------------|---------------|-------------|
| High | 10,000+ | 1–2 weeks |
| Medium | 1,000–10,000 | 2–4 weeks |
| Low | <1,000 | 1–3 months |

**Minimums:** 100–200 sessions for initial patterns · 500–1,000 for reliable insights · 2,000+ for confident insights

**Conversion pages:** Minimum 50 conversions + 500 non-conversions to compare.

**Segment analysis:** Minimum 200–500 sessions per segment (mobile vs desktop, traffic source).

> Too little data (20 sessions) = noise from one odd user. Too much (5,000+) = diminishing returns.

## Heatmap Analysis Checklist

**Click:** CTAs getting clicked? Non-clickable elements clicked? Wrong elements clicked? Unexpected patterns? Mobile tap targets large enough?

**Scroll:** % reaching CTA? Where do most drop off? Important content below average scroll depth? Visual barriers preventing scrolling?

**Move:** Where are cursors spending time? Reading desired content? Hesitation patterns? Move/click alignment?

**Attention:** What gets most attention (is it what you want)? What gets ignored? Time on key sections? Logical attention distribution?

## Combining Heatmaps with Analytics

Heatmaps answer **"what happened"** · Analytics answer **"how much"**

| Scenario | Analytics | Heatmap | Recording | Insight | Action | Result |
|----------|-----------|---------|-----------|---------|--------|--------|
| Low CTA clicks | 2% click rate | Near-zero CTA clicks | Users click image above CTA | Image looks like the CTA | Make image clickable OR redesign CTA | 2% → 8% |
| High bounce | 70% bounce rate | 90% never scroll past hero | Read headline, immediately leave | Headline ≠ ad promise ("free trial" ad → "request demo" page) | Align headline with ad | 70% → 45% bounce |
| Form abandonment | 60% abandon at phone field | High attention on phone, zero submits | Fill email/name, hesitate at phone, leave | Phone field = privacy friction | Make phone optional | +35% form completion |

---

*Continues in [Chapter 14: Landing Page Teardowns](./CHAPTER-14.md) and [Chapter 15: Personalization](./CHAPTER-15.md).*
