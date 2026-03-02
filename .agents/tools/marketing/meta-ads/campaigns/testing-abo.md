# Creative Testing Campaign (ABO)

> The testing campaign is where you discover what works. Every winning ad starts here.

---

## Table of Contents
1. [Purpose & Philosophy](#purpose--philosophy)
2. [Campaign Structure](#campaign-structure)
3. [Testing Methodology](#testing-methodology)
4. [Metrics & Decision Making](#metrics--decision-making)
5. [Testing Frameworks](#testing-frameworks)
6. [From Test to Scale](#from-test-to-scale)

---

## Purpose & Philosophy

### Why ABO for Testing?

**Campaign Budget Optimization (CBO) Problem:**
When you add new creative to a CBO campaign, the algorithm favors proven performers. New ads get starved of budget before they can prove themselves.

**Ad Set Budget Optimization (ABO) Solution:**
Each ad set gets its allocated budget regardless of performance. This ensures every creative gets a fair test.

### The Testing Mindset

1. **You are a scientist** — Form hypotheses, test them, learn
2. **Most things fail** — 80% of creative won't work, that's normal
3. **Speed matters** — Fast iteration beats perfect planning
4. **Data, not feelings** — Let numbers decide, not emotions

---

## Campaign Structure

### Optimal Setup

```
Campaign: Creative Testing
├── Objective: Conversions (Purchases or Leads)
├── Budget Type: Ad Set Budget (ABO)
├── Advantage Campaign Budget: OFF
│
├── Ad Set 1: [Creative Angle A]
│   ├── Budget: $30-100/day
│   ├── Audience: Broad or proven audience
│   ├── Placements: Advantage+ Placements
│   └── Ads: 1-2 variations of same angle
│
├── Ad Set 2: [Creative Angle B]
│   ├── Budget: $30-100/day
│   ├── Audience: Same as Ad Set 1
│   ├── Placements: Advantage+ Placements
│   └── Ads: 1-2 variations of same angle
│
└── Ad Set 3: [Creative Angle C]
    ├── Budget: $30-100/day
    ├── Audience: Same as Ad Set 1
    ├── Placements: Advantage+ Placements
    └── Ads: 1-2 variations of same angle
```

### Budget Per Ad Set

**Minimum Viable Budget:**
- Aim for 50 conversions per ad set per week
- Budget = Target CPA × 50 ÷ 7

**Example:**
```
Target CPA: $30
Weekly conversions needed: 50
Weekly budget needed: $30 × 50 = $1,500
Daily budget per ad set: $1,500 ÷ 7 = ~$215
```

**Practical Minimums:**
| Target CPA | Min Daily Budget |
|------------|------------------|
| $10 | $50-75 |
| $25 | $75-125 |
| $50 | $150-250 |
| $100 | $300-500 |

**If You Can't Afford 50 Conversions:**
Test with minimum $30-50/day per ad set for 5-7 days. You'll have directional data, not statistical significance.

### Audience Selection for Testing

**Best Practice: Use Your Scaling Audience**

Don't test with a different audience than you'll scale with. If you plan to scale with broad targeting, test with broad targeting.

**Recommended Testing Audience:**
- Broad (minimal restrictions)
- 18-65+ age
- Your target geography
- No interest/behavior targeting
- Advantage+ Audience: ON

**Why Broad for Testing?**
- Results reflect what you'll see at scale
- Algorithm learns faster with more data
- No audience bias affecting creative judgment

### Ads Per Ad Set

**Optimal: 1-2 ads per ad set**

**Why Not More?**
- Each ad competes for the same budget
- Too many ads = not enough data per ad
- One clear angle per ad set makes learning clear

**Structure Options:**

**Option A: Single Ad (Clearest Learning)**
- 1 ad per ad set
- Each ad set = one creative angle
- Winner is obvious

**Option B: Same Angle, Different Formats (Recommended)**
- 2 ads per ad set
- Same messaging, different formats (video + static)
- Learn which format works for each angle

**Avoid:**
- Mixing different angles in same ad set
- More than 3 ads per ad set
- Adding new ads to active ad sets

### Placements

**Use Advantage+ Placements**

Let Meta optimize placement delivery. Testing creative, not placements.

**Exception:** If you have a strong hypothesis about placement (e.g., "Reels-only creative"), create separate ad set for that test.

---

## Testing Methodology

### What to Test (Priority Order)

**Tier 1: Creative Concept/Angle (Highest Impact)**
- Problem vs benefit messaging
- Testimonial vs product demo
- UGC vs polished production
- Pain point A vs pain point B

**Tier 2: Hook (High Impact)**
- First 3 seconds of video
- First line of copy
- Opening visual

**Tier 3: Format (Medium Impact)**
- Video vs static image
- Carousel vs single image
- Long video vs short video

**Tier 4: Copy Elements (Medium Impact)**
- Headlines
- Body copy length
- CTA variation

**Tier 5: Visual Elements (Lower Impact)**
- Colors
- Fonts
- Minor design changes

### Variable Isolation

**Test One Thing at a Time**

```
Bad Test:
Ad A: Video + Pain point + Long copy
Ad B: Static + Benefit + Short copy

What won? No idea — too many variables.

Good Test:
Ad A: Video + Pain point + Medium copy
Ad B: Video + Benefit + Medium copy

What won? Benefit messaging beats pain point.
```

### Dynamic Creative Testing (DCT)

**What It Is:**
Upload multiple assets (headlines, images, videos), Meta tests combinations automatically.

**Pros:**
- Tests many combinations
- Algorithm optimizes
- Less manual work

**Cons:**
- Can't see what specific combination worked
- Less learning for future creative
- "Black box" problem

**When to Use DCT:**
- High volume accounts (100+ conversions/day)
- When you have many assets but limited time
- For optimization, not learning

**When to Use Manual Testing:**
- Lower volume accounts
- When you need clear learnings
- For concept testing

### Sample Size Requirements

**For Statistical Significance:**
- Minimum 50 conversions per variation
- 95% confidence interval preferred
- 7+ days of data

**For Directional Guidance (Faster but Less Certain):**
- 20-30 conversions per variation
- 3-5 days of data
- Use when you can't afford full significance

**Online Calculator:**
Use tools like ABTestGuide.com to calculate required sample size based on your baseline conversion rate and desired lift detection.

---

## Metrics & Decision Making

### Primary Metrics by Objective

**For Purchases:**
| Metric | Target | Priority |
|--------|--------|----------|
| CPA (Cost Per Acquisition) | At or below target | #1 |
| ROAS | At or above target | #1 |
| Purchase Volume | Enough for learning | #2 |

**For Leads:**
| Metric | Target | Priority |
|--------|--------|----------|
| CPL (Cost Per Lead) | At or below target | #1 |
| Lead Quality | Tracked via CRM | #1 |
| Lead Volume | Enough for learning | #2 |

### Secondary Metrics

**Use These to Diagnose Problems:**

| Metric | What It Tells You |
|--------|-------------------|
| CTR | Is the ad compelling enough to click? |
| Hook Rate (3s video) | Is the opening grabbing attention? |
| Hold Rate (15s video) | Is the content engaging? |
| ThruPlay Rate | Did they watch the full message? |
| CPM | Is the audience too competitive? |
| CPC | Is the ad relevant to clickers? |
| Landing Page Views | Are clicks turning into actual visits? |
| Outbound CTR | For content, are they clicking through? |

### Diagnostic Framework

```
Low Conversions, Where's the Problem?

1. Check CPM
   └── High CPM (>$20)? → Audience or quality issue
   
2. Check CTR
   └── Low CTR (<0.8%)? → Creative not compelling
   
3. Check Landing Page Views
   └── Clicks ≠ LPV? → Page load issues
   
4. Check CVR (Conv/Clicks)
   └── Low CVR (<5%)? → Landing page or offer issue
```

### When to Kill an Ad

**Kill Immediately If:**
- CTR below 0.3% after 1,000+ impressions
- Zero conversions after 2x target CPA spend
- Quality Ranking: "Below Average (Bottom 20%)"

**Kill After 3-5 Days If:**
- CPA 50%+ above target with 10+ conversions
- CTR below 0.5% sustained
- No improvement trend visible

**Kill After 7 Days If:**
- CPA 25%+ above target with 30+ conversions
- Performance declining day-over-day
- Better performers identified

### When to Declare a Winner

**Winner Criteria:**
- CPA at or below target for 3+ consecutive days
- 50+ conversions (ideally 100+)
- CTR above 1%
- Stable or improving trend

**Confidence Levels:**
| Conversions | Confidence | Action |
|-------------|------------|--------|
| 20-50 | Directional | Proceed cautiously |
| 50-100 | Good | Move to scale |
| 100+ | High | Scale aggressively |

### Handling Outliers

**What If Day 1 Is Amazing?**
- Don't get excited yet
- Could be algorithmic testing
- Wait for 3 days of consistent data

**What If Day 1 Is Terrible?**
- Don't kill immediately
- Learning phase can be rocky
- Wait at least 3 days (unless truly catastrophic)

**What If Performance Is Wildly Inconsistent?**
- Check frequency (ad fatigue?)
- Check external factors (weekend vs weekday)
- May need to optimize for higher-funnel event

---

## Testing Frameworks

### The "3-2-2" Method

**Structure:**
- 3 ad sets (different creative angles)
- 2 ads per ad set (same angle, different formats)
- 2 weeks of testing

**Budget:**
- Equal budget across ad sets
- Minimum $50/ad set/day

**Process:**
1. Week 1: Let all run, gather data
2. Week 2: Kill obvious losers, keep testing
3. After 2 weeks: Identify winners, move to scale

### The "Rapid Fire" Method

**For Fast Learning:**
- 5+ ad sets
- 1 ad per ad set
- 3-5 day tests
- $30-50/ad set/day

**Process:**
1. Launch 5 different angles
2. After 3 days: Kill bottom 2
3. After 5 days: Kill bottom 1-2 more
4. Winner(s) move to scale

**Best For:**
- Early stage testing
- When you have many ideas
- Smaller budgets

### Concept Testing vs Iteration Testing

**Concept Testing:**
Testing fundamentally different approaches.

```
Ad Set 1: Testimonial UGC video
Ad Set 2: Product demo video
Ad Set 3: Founder talking head
Ad Set 4: Static image comparison
```

**Goal:** Find which CONCEPT resonates

**Iteration Testing:**
Testing variations of a proven concept.

```
Ad Set 1: Testimonial - Hook A
Ad Set 2: Testimonial - Hook B
Ad Set 3: Testimonial - Hook C
```

**Goal:** Optimize a winning concept

**Process:**
1. Start with concept testing (big swings)
2. Find winning concept
3. Move to iteration testing (small improvements)

### Hook Testing Framework

**Why Hooks Matter:**
First 3 seconds determine if someone watches. First line determines if someone reads.

**Hook Categories to Test:**

| Category | Video Example | Text Example |
|----------|---------------|--------------|
| Curiosity | "Nobody talks about this..." | "The secret nobody talks about..." |
| Pain | "Tired of [problem]?" | "Still struggling with [problem]?" |
| Benefit | "[Result] in [timeframe]" | "How I got [result] in [timeframe]" |
| Controversy | "Unpopular opinion..." | "[Industry] is lying to you" |
| Story | "Last year I was [bad situation]..." | "I used to [struggle]..." |
| Social Proof | "How [Company] got [result]" | "[X] companies use this to..." |
| Question | "What if you could [desire]?" | "Ever wondered why [thing]?" |

**Testing Process:**
1. Identify winning creative
2. Create 3-5 hook variations
3. Keep body/middle the same
4. Test hooks head-to-head
5. Winner hook + winner body = optimized ad

### Body Testing Framework

**After Finding Winning Hook:**

Test body elements:
- Feature focus vs benefit focus
- Short body vs detailed body
- Social proof vs no social proof
- Urgency vs no urgency

### CTA Testing Framework

**Test Different CTAs:**
- "Shop Now" vs "Learn More"
- "Get Started" vs "Try Free"
- "Book a Demo" vs "See How It Works"

**CTA Impact:**
Usually lower impact than hook/body, but can move needle 5-20% in some cases.

---

## From Test to Scale

### When to Graduate

**Winner Checklist:**
- [ ] CPA at or below target for 3+ days
- [ ] 50+ conversions minimum
- [ ] CTR above 0.8% (ideally 1%+)
- [ ] Stable or improving trend
- [ ] Creative not fatigued (frequency <3)

### How to Move Winners

**Option 1: Duplicate to Scale Campaign**
1. Go to winning ad set
2. Duplicate → Choose scale campaign
3. Turn on in scale campaign
4. Keep original running OR pause

**Option 2: Duplicate Ad Only**
1. Go to winning ad
2. Duplicate → Choose scale campaign ad set
3. Add to existing scale ad set

**Best Practice:** Duplicate the whole ad set to preserve learning history.

### Post-Graduation Testing

After moving winner to scale:

1. **Keep testing new concepts** — Always have tests running
2. **Test iterations of winner** — Can you beat the winner?
3. **Test for different audiences** — What works for cold vs warm?

### Testing Velocity

**Recommendations:**

| Spend Level | New Concepts/Week | New Iterations/Week |
|-------------|-------------------|---------------------|
| <$5K/mo | 2-3 | 2-3 |
| $5-20K/mo | 4-6 | 4-6 |
| $20-50K/mo | 6-10 | 6-10 |
| $50K+/mo | 10+ | 10+ |

**Rule of Thumb:** 20% of budget should be testing new concepts

---

## Testing Campaign Checklist

### Before Launching:
- [ ] Objective matches goal (Conversions)
- [ ] ABO enabled (not CBO)
- [ ] Budget per ad set calculated
- [ ] Same audience across ad sets
- [ ] Advantage+ Placements on
- [ ] 1-2 ads per ad set
- [ ] Testing one variable per test
- [ ] Pixel/CAPI configured correctly
- [ ] UTM parameters added

### Daily Monitoring:
- [ ] Check spend vs budget
- [ ] Review early metrics (CTR, CPM)
- [ ] No ad disapprovals

### Day 3 Review:
- [ ] Any obvious losers to kill?
- [ ] Any technical issues?
- [ ] Metrics trending as expected?

### Day 7 Review:
- [ ] Kill underperformers
- [ ] Identify potential winners
- [ ] Plan next round of tests

### Day 14 Review:
- [ ] Declare winners
- [ ] Move to scale campaign
- [ ] Document learnings
- [ ] Plan iteration tests

---

*Next: [Scaling Campaign (CBO)](scaling-cbo.md)*
