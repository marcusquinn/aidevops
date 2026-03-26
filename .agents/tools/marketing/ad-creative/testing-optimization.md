## Creative Testing Methodology

### Testing Philosophy

**Core Principles:**

1. **Test ONE Variable at a Time**
   - Can't learn if you change everything
   - Isolate what's actually working
   - Build knowledge, don't guess

2. **Volume Matters**
   - Need statistical significance
   - More tests = faster learning
   - Launch 5-10 creatives per test

3. **Speed Wins**
   - Weekly test launches
   - Kill losers fast
   - Scale winners immediately

4. **Data Over Opinions**
   - Your preference doesn't matter
   - Customer response matters
   - Let metrics decide

### Testing Framework

**Level 1: Concept Testing**

**What to Test:**
- Different hooks/angles
- Problem-focused vs. benefit-focused
- Educational vs. promotional
- Emotional vs. logical

**How to Test:**
- Same format (all video or all image)
- Same audience
- Same budget per creative
- Minimum 3 days, ideally 7 days

**Success Criteria:**
- CPA below target
- Sufficient volume (can scale to $1K+/day)
- Creative doesn't fatigue quickly (>14 day lifespan)

**Example Test:**
```text
CONTROL: "Tired of [problem]?" hook
VARIANT 1: "How I [achieved result]" hook
VARIANT 2: "[Surprising statistic]" hook
VARIANT 3: "What if [hypothetical]?" hook
VARIANT 4: "Stop [bad behavior]" hook

Audience: Same cold prospecting audience
Budget: $50/day per creative
Duration: 7 days
Winner Criteria: Lowest CPA with >20 conversions
```

**Level 2: Format Testing**

**What to Test:**
- Image vs. video
- Short-form vs. long-form video
- UGC vs. professional
- Carousel vs. single image

**How to Test:**
- Same messaging/angle
- Different formats
- Same audience
- Equal budget

**Success Criteria:**
- CPA
- CTR (indicates stopping power)
- Hook rate (for videos)
- Engagement rate

**Example Test:**
```text
CONCEPT: "Before/After Transformation"

FORMAT A: Single image - before/after split screen
FORMAT B: 15-second video - transformation time-lapse
FORMAT C: 45-second UGC testimonial
FORMAT D: Carousel - 5 different transformations
FORMAT E: 60-second professional showcase video

All use same headline and primary text
Same audience
$50/day each
7-day test period
```

**Level 3: Element Testing**

**What to Test (One at a Time):**
- Headlines (5+ variations)
- Primary text (hook variations)
- CTAs
- Offers
- Images/thumbnails
- Video hooks (first 3 seconds)

**How to Test:**
- Everything else identical
- Only change one element
- Minimum 5 variations
- Let run until significance

**Success Criteria:**
- 95% statistical confidence
- Minimum 50 conversions per variant
- Clear winner emerges

**Example Test - Headlines:**
```text
CREATIVE: Same video, same primary text

HEADLINE 1: "How to [Benefit] in [Timeframe]"
HEADLINE 2: "[Number]+ [People] Trust [Product]"
HEADLINE 3: "[Benefit] Without [Objection]"
HEADLINE 4: "The Secret to [Outcome]"
HEADLINE 5: "[Result] Guaranteed"

Same audience
Equal budget
14-day test (need more data for text-only changes)
Winner: Lowest CPA + acceptable volume
```

**Level 4: Audience-Message Match**

**What to Test:**
- Same creative, different audiences
- Or: Different messaging for different audiences
- Pain point variations by segment

**How to Test:**
- Identify 3-5 distinct customer segments
- Create specific messaging for each
- Or test same message across all
- Track performance by segment

**Success Criteria:**
- CPA by audience
- Lifetime value by audience
- Volume available in each segment

**Example Test:**
```text
PRODUCT: Project management software

AUDIENCE 1: Marketing agencies
MESSAGE: "Manage 20+ client projects without chaos"
PAIN: Client project overwhelm

AUDIENCE 2: In-house marketing teams
MESSAGE: "Get your team aligned on priorities"
PAIN: Internal misalignment

AUDIENCE 3: Solopreneurs
MESSAGE: "Stop forgetting important tasks"
PAIN: Task management for one-person business

Each audience gets their specific message
Budget weighted by audience size
Test for 14 days
Measure CPA and LTV by segment
```

### Variable Isolation Method

**The Rule:**
When testing, change ONLY ONE of these at a time:

1. **Creative Type**
   - Image, video, carousel, etc.
   - Keep messaging/audience same

2. **Creative Content**
   - Hook, body, CTA
   - Keep format/audience same

3. **Audience**
   - Different targeting
   - Keep creative same

4. **Offer**
   - Discount, bonus, trial length
   - Keep creative/audience same

5. **Placement**
   - Feed, Stories, Reels, etc.
   - Keep creative/audience same

**Bad Test (Multiple Variables):**
```text
❌ New video creative + New headline + New audience + New offer

Result: If it wins or loses, you don't know why
```

**Good Test (Isolated Variable):**
```text
✅ New video creative + Same headline + Same audience + Same offer

Result: If it wins or loses, you know it's the video
```

### Statistical Significance

**Why It Matters:**
- Small sample sizes = random noise
- Can't make decisions on 10 conversions
- Need sufficient data for confidence

**Minimum Thresholds:**
- Image/text tests: 50+ conversions per variant
- Video tests: 30+ conversions per variant (faster learning from engagement metrics)
- Audience tests: 100+ conversions per audience
- Format tests: 20+ conversions per format

**Confidence Calculation:**
Use a statistical significance calculator (e.g., VWO, Optimizely, or Google's)

**Example:**
```text
Variant A: 100 conversions, 2.5% conversion rate, $40 CPA
Variant B: 100 conversions, 3.2% conversion rate, $31 CPA

Improvement: 28% lower CPA
Confidence: 96%
Decision: Winner, scale Variant B
```

### Creative Fatigue Detection

**What is Creative Fatigue:**
When an ad's performance degrades over time as the audience becomes oversaturated.

**Symptoms:**
- CTR decreasing week over week
- CPA increasing gradually
- Frequency rising (seeing same ad multiple times)
- Relevance score/quality ranking dropping

**Monitoring Schedule:**
- Daily: CTR, CPA, frequency
- Weekly: Week-over-week performance comparison
- Bi-weekly: Creative lifespan analysis

**Fatigue Benchmarks:**

| Metric | Fresh Creative | Fatigued Creative |
|--------|---------------|-------------------|
| CTR decline | Stable or rising | >20% decline from peak |
| CPA increase | Stable or decreasing | >25% increase from baseline |
| Frequency | <3 | >5 |
| Relevance Score | Good/Excellent | Average/Below Average |
| Hook Rate (video) | >50% | <35% |

**Refresh Strategies:**

**Level 1: Creative Refresh (Minor)**
- Change headline only
- Swap thumbnail (for video)
- Update offer/urgency
- Change CTA button
- Expected lifespan extension: +7-14 days

**Level 2: Creative Update (Moderate)**
- New hook (first 3 seconds of video)
- Different image/video
- Rewrite primary text
- Update social proof elements
- Expected lifespan extension: +14-30 days

**Level 3: New Creative (Major)**
- Entirely new concept
- Different angle/messaging
- Fresh format
- New creators (for UGC)
- Expected lifespan: 30-90 days

**Fatigue Prevention:**
- Rotate 5-10 creatives per ad set
- Launch new creatives weekly
- Retire bottom 20% performers bi-weekly
- Use larger audiences (more room before saturation)
- Implement frequency caps (max 4 impressions per 7 days)

### Winner Identification Process

**Step 1: Initial Assessment (Days 1-3)**
- Eliminate non-starters (0 conversions at $200+ spend)
- Identify early leaders
- Don't make final decisions yet

**Step 2: Data Accumulation (Days 4-7)**
- Let all remaining creatives accumulate data
- Monitor for statistical significance
- Track secondary metrics (CTR, engagement)

**Step 3: Winner Declaration (Day 7+)**
- Primary metric: CPA (or ROAS)
- Secondary: Volume (can it scale?)
- Tertiary: Longevity indicators (fatigue resistance)

**Winner Criteria:**

```text
A creative is a "winner" if:
✅ CPA is 20%+ better than target
✅ Volume is sufficient (>10 conversions/day potential)
✅ Statistical confidence >90%
✅ Shows stable performance (not declining)
```

**Example Decision Matrix:**

```text
CREATIVE A:
- CPA: $35 (target: $40)
- Daily conversions: 15
- CTR: 2.1%
- Hook rate: 52%
- Trend: Stable
- Verdict: WINNER - Scale

CREATIVE B:
- CPA: $38 (target: $40)
- Daily conversions: 8
- CTR: 1.8%
- Hook rate: 48%
- Trend: Slightly declining
- Verdict: KEEP MONITORING

CREATIVE C:
- CPA: $48 (target: $40)
- Daily conversions: 12
- CTR: 2.3%
- Hook rate: 55%
- Trend: Improving
- Verdict: KEEP (strong engagement, needs optimization)

CREATIVE D:
- CPA: $55 (target: $40)
- Daily conversions: 5
- CTR: 1.2%
- Hook rate: 38%
- Trend: Declining
- Verdict: KILL

CREATIVE E:
- CPA: $32 (target: $40)
- Daily conversions: 3
- CTR: 3.1%
- Hook rate: 61%
- Trend: N/A (new)
- Verdict: EXPAND AUDIENCE (great efficiency, low volume)
```

**Step 4: Scaling Winners**

**Gradual Scaling:**
```text
Day 1-7: Test budget ($50-100/day)
Day 8-14: If winner, 2x budget ($100-200/day)
Day 15-21: If still performing, 2x again ($200-400/day)
Day 22+: Continue scaling at 20-40% increases until performance degrades
```

**Rapid Scaling (for clear winners):**
```text
Day 1-7: Test budget
Day 8: If CPA is 30%+ below target, immediately 5x budget
Day 9+: Monitor closely, scale or roll back based on performance
```

**Step 5: Iteration on Winners**

**Don't stop at one winner. Create variations:**

```text
WINNING CREATIVE: UGC testimonial video
- CPA: $30
- Hook: "I tried everything for my acne..."

CREATE ITERATIONS:
Variant 1: Different creator, same script
Variant 2: Same creator, different hook
Variant 3: Shorter version (30s instead of 45s)
Variant 4: Different product focus (texture vs. scarring)
Variant 5: Same story, different editing style

Test all variants
Some may outperform original
Build a "creative cluster" around winning concept
```

### Testing Calendar Template

**Week 1:**
- Monday: Launch 5 new concept tests
- Wednesday: Check early data, kill non-starters
- Friday: Analyze mid-week performance

**Week 2:**
- Monday: Scale winners from Week 1, launch 5 new element tests
- Wednesday: Refresh fatigued creatives
- Friday: Analyze weekly performance, plan next tests

**Week 3:**
- Monday: Launch format tests based on winning concepts
- Wednesday: Audience expansion tests for best performers
- Friday: Monthly performance review

**Week 4:**
- Monday: Launch variations of top performers
- Wednesday: Kill bottom 25% of active creatives
- Friday: Plan next month's testing roadmap

**Monthly:**
- Creative audit (all active ads)
- Performance ranking
- Fatigue analysis
- Testing insights documentation
- New angle brainstorming

### Testing Tools & Resources

**A/B Testing Calculators:**
- VWO Significance Calculator
- Optimizely Stats Engine
- AB Test Guide Calculator
- Google Analytics Experiments

**Creative Testing Platforms:**
- Facebook Ads Manager (built-in creative testing)
- Google Ads Experiments
- TikTok Creative Center
- Motion.io (creative management)
- Smartly.io (campaign automation)

**Performance Tracking:**
- Google Sheets (manual tracking template)
- Supermetrics (automated reporting)
- Triple Whale (e-commerce)
- Hyros (advanced attribution)

**Creative Intelligence:**
- Foreplay.co (ad library inspiration)
- Madgicx (creative insights)
- Attest (consumer research)

---

## Ad Creative Scoring Rubrics

### Pre-Launch Creative Scorecard

**Category 1: Hook Quality (25 points)**

```text
5 points: PATTERN INTERRUPT
□ Stops the scroll visually (5)
□ Somewhat noticeable (3)
□ Generic/easily ignored (1)

5 points: RELEVANCE SIGNAL
□ Immediately clear who it's for (5)
□ Somewhat clear (3)
□ Unclear target (1)

5 points: CURIOSITY/DESIRE
□ Creates strong open loop (5)
□ Moderate interest (3)
□ No compelling reason to continue (1)

5 points: CLARITY
□ Message is crystal clear (5)
□ Somewhat clear (3)
□ Confusing or vague (1)

5 points: SPECIFICITY
□ Specific claim/stat/detail (5)
□ Somewhat specific (3)
□ Generic/vague (1)
```

**Category 2: Value Proposition (20 points)**

```text
5 points: BENEFIT CLARITY
□ Clear what customer gets (5)
□ Implied benefit (3)
□ Feature-focused, no clear benefit (1)

5 points: DIFFERENTIATION
□ Clear unique value (5)
□ Some differentiation (3)
□ Sounds like everyone else (1)

5 points: PROOF
□ Strong social proof/data (5)
□ Some credibility elements (3)
□ No proof provided (1)

5 points: RELEVANCE
□ Perfectly matches target pain/desire (5)
□ Somewhat relevant (3)
□ Mismatched to audience (1)
```

**Category 3: Creative Execution (20 points)**

```text
5 points: PRODUCTION QUALITY
□ High quality, platform-appropriate (5)
□ Adequate quality (3)
□ Poor quality (1)

5 points: NATIVE FEEL
□ Looks like content, not ad (5)
□ Somewhat native (3)
□ Screams "AD" (1)

5 points: MOBILE OPTIMIZATION
□ Perfect for mobile viewing (5)
□ Okay on mobile (3)
□ Not mobile-friendly (1)

5 points: BRANDING
□ Clear but not overwhelming (5)
□ Present but unclear (3)
□ Either missing or too heavy (1)
```

**Category 4: Copy Quality (20 points)**

```text
5 points: HEADLINE
□ Benefit-driven, compelling (5)
□ Adequate (3)
□ Weak/generic (1)

5 points: PRIMARY TEXT
□ Concise, punchy, clear (5)
□ Decent but could be tighter (3)
□ Too long, confusing, or boring (1)

5 points: CALL-TO-ACTION
□ Clear, specific, urgent (5)
□ Present but weak (3)
□ Unclear or missing (1)

5 points: TONE/VOICE
□ Matches brand and audience (5)
□ Close enough (3)
□ Tone-deaf or mismatched (1)
```

**Category 5: Offer & CTA (15 points)**

```text
5 points: OFFER STRENGTH
□ Compelling, hard to resist (5)
□ Decent offer (3)
□ Weak or no offer (1)

5 points: URGENCY/SCARCITY
□ Clear reason to act now (5)
□ Some urgency (3)
□ No urgency (1)

5 points: FRICTION REDUCTION
□ Easy next step, objections addressed (5)
□ Moderate friction (3)
□ High friction, confusing path (1)
```

**TOTAL SCORE: ___ / 100**

**Score Interpretation:**
- 90-100: Excellent - High confidence
- 75-89: Good - Launch with minor tweaks
- 60-74: Average - Needs improvement
- Below 60: Weak - Major revision needed

**Example Scoring:**

```text
CREATIVE: UGC video for sleep supplement

HOOK QUALITY: 22/25
- Pattern interrupt: 5 (relatable sleep struggle visual)
- Relevance: 5 (clearly for people with sleep issues)
- Curiosity: 5 (want to know what worked)
- Clarity: 4 (slightly unclear product name in first 3s)
- Specificity: 3 (could use specific stat)

VALUE PROPOSITION: 18/20
- Benefit clarity: 5 (better sleep, no grogginess)
- Differentiation: 4 (mentions natural ingredients but not unique mechanism)
- Proof: 5 (personal testimonial + visible results)
- Relevance: 4 (matches audience but could be more specific)

CREATIVE EXECUTION: 18/20
- Production quality: 5 (authentic UGC, well-lit)
- Native feel: 5 (perfect for platform)
- Mobile optimization: 5 (vertical, readable captions)
- Branding: 3 (product shown but could be clearer)

COPY QUALITY: 17/20
- Headline: 5 ("Fall Asleep in Under 20 Minutes")
- Primary text: 4 (good hook, could be punchier)
- CTA: 5 (clear "Try free for 30 days")
- Tone: 3 (good but could match testimonial energy more)

OFFER & CTA: 14/15
- Offer strength: 5 (30-day free trial)
- Urgency: 4 (could add limited-time element)
- Friction: 5 (no credit card required mentioned)

TOTAL: 89/100 - GOOD
Recommendation: Launch, but test variation with specific stat in hook and add urgency to offer
```

### Post-Launch Performance Scorecard

**After 7 days of live data:**

```text
PERFORMANCE METRICS SCORE (100 points possible)

CPA vs. Target: ___/30
□ 30%+ better than target (30)
□ 10-29% better (25)
□ 0-9% better (20)
□ 0-10% worse (15)
□ 10-25% worse (10)
□ 25%+ worse (0)

Volume: ___/20
□ >20 conversions/day (20)
□ 10-19 conversions/day (15)
□ 5-9 conversions/day (10)
□ 1-4 conversions/day (5)
□ <1 conversion/day (0)

CTR: ___/15
□ >3% (15)
□ 2-3% (12)
□ 1-2% (8)
□ 0.5-1% (4)
□ <0.5% (0)

Hook Rate (video only): ___/15
□ >60% (15)
□ 50-60% (12)
□ 40-49% (8)
□ 30-39% (4)
□ <30% (0)

Engagement Rate: ___/10
□ Above account average (10)
□ At average (7)
□ Below average (4)
□ Significantly below (0)

Longevity: ___/10
□ Performance improving (10)
□ Performance stable (8)
□ Slight decline (5)
□ Significant decline (0)

TOTAL: ___/100
```

**Action Based on Score:**
- 85-100: SCALE AGGRESSIVELY
- 70-84: SCALE MODERATELY
- 50-69: KEEP TESTING
- 30-49: OPTIMIZE OR PAUSE
- <30: KILL

### Video-Specific Scoring

**Video Creative Quality Rubric:**

```text
HOOK (First 3 Seconds): ___/30
□ Stops scroll visually (10)
□ Clear verbal/text hook (10)
□ Immediate relevance signal (10)

PACING: ___/15
□ Cut frequency (5)
□ Energy level (5)
□ Maintains interest (5)

STORYTELLING: ___/15
□ Clear narrative arc (5)
□ Emotional connection (5)
□ Satisfying resolution (5)

AUDIO: ___/10
□ Sound quality (5)
□ Music choice (if applicable) (3)
□ Voice clarity (2)

CAPTIONS: ___/10
□ Readable/visible (5)
□ Synced properly (3)
□ Styled appropriately (2)

CALL-TO-ACTION: ___/10
□ Verbally stated (3)
□ Visually shown (3)
□ Clear next step (4)

BRANDING: ___/5
□ Product/brand clear (5)
□ Somewhat clear (3)
□ Unclear (0)

TECHNICAL: ___/5
□ Proper aspect ratio (2)
□ Good lighting (2)
□ Stable footage (1)

TOTAL: ___/100
```

### Image Ad Scoring

**Static Image Quality Rubric:**

```text
VISUAL IMPACT: ___/25
□ Thumb-stopping visual (10)
□ Clear focal point (8)
□ Color contrast (7)

COMPOSITION: ___/20
□ Rule of thirds/balance (7)
□ Hierarchy (text readable first) (7)
□ Not cluttered (6)

TEXT OVERLAY: ___/15
□ Minimal text (5)
□ High contrast/readable (5)
□ Complements headline (5)

PRODUCT SHOWCASE: ___/15
□ Product visible/clear (10)
□ In context/lifestyle (5)

BRANDING: ___/10
□ Logo visible but not overwhelming (5)
□ Brand colors (3)
□ Consistent with brand (2)

MOBILE READINESS: ___/10
□ Works at small sizes (5)
□ Important elements in center (3)
□ No tiny text (2)

PLATFORM FIT: ___/5
□ Looks native to platform (5)
□ Somewhat native (3)
□ Looks out of place (0)

TOTAL: ___/100
```

### Scoring Process

**Pre-Launch:**
1. Score creative before launch
2. Only launch creatives scoring 75+
3. Iterate on those scoring 60-74
4. Scrap those below 60

**Post-Launch:**
1. Score after 7 days of data
2. Compare pre-launch score to performance
3. Build pattern recognition (what scores actually perform)
4. Adjust rubric based on learnings

**Pattern Analysis:**
```text
Track over time:
"Our ads scoring 85+ in pre-launch typically achieve CPA 20% below target"
"Hook quality score correlates most strongly with CTR"
"Offer strength score predicts conversion rate"

Use insights to focus improvement efforts
```

---

## Dynamic Creative Optimization

DCO uses machine learning to automatically test creative combinations and serve the best-performing version to each user.

**Platforms:** Facebook/Meta (Dynamic Creative) · Google Ads (RSA, RDA, Performance Max) · TikTok (Smart Creative) · Snapchat (Dynamic Ads)
- LinkedIn: Dynamic Ads

### Meta Dynamic Creative

**How It Works:**

```text
YOU PROVIDE:
- Up to 10 images or videos
- Up to 5 headlines
- Up to 5 primary text options
- Up to 5 descriptions

META'S SYSTEM:
- Tests all combinations
- Learns which combinations perform best
- Serves optimal combinations to each user
- Continuously optimizes

RESULT:
- Best creative for each viewer
- Automated testing at scale
- Improved performance vs. static ads
```

**Setup Process:**

1. **Turn on Dynamic Creative at ad level**
2. **Upload creative assets:**
   - Images: 10 (recommended)
   - Videos: 10 (if using video)
   - Primary text: 5 options
   - Headlines: 5 options
   - Descriptions: 5 options
   - CTAs: Choose primary CTA

3. **Let it run:**
   - Minimum 50-100 conversions for learning
   - Don't make changes for 7 days
   - Review asset performance report

**Asset Strategy:**

```text
IMAGES/VIDEOS (10):
- 3 product-focused
- 3 lifestyle/in-use
- 2 before/after or testimonial
- 2 promotional/offer-focused

PRIMARY TEXT (5):
- 2 benefit-focused hooks
- 1 problem-focused hook
- 1 question hook
- 1 social proof hook

HEADLINES (5):
- 2 benefit-driven
- 1 offer-focused
- 1 social proof
- 1 urgency-based

DESCRIPTIONS (5):
- Offer details
- Guarantee/risk reversal
- Social proof
- Urgency
- Feature highlight
```

**Performance Analysis:**

```text
After 7+ days, check asset performance report:

HIGH PERFORMERS (more impressions):
- Scale these concepts
- Create more variations
- Use learnings in other campaigns

LOW PERFORMERS (fewer impressions):
- Replace with new concepts
- Analyze why they failed
- Don't give up after one test
```

**When to Use Dynamic Creative:**

✅ **Use When:**
- Testing creative concepts quickly
- Need to scale creative production
- Want platform optimization
- Limited creative bandwidth
- Broad audiences

❌ **Don't Use When:**
- Need precise message control
- Very specific audience segments requiring tailored messaging
- Testing isolated variables (use manual A/B testing)
- Brand-sensitive content (less control over combinations)

### Google Responsive Search Ads (DCO)

**[See Google Ads Creative section for full RSA details]**

**Quick DCO Strategy:**

```text
PROVIDE:
- 15 headlines (maximize asset count)
- 4 descriptions
- Let Google test combinations
- Review asset performance
- Replace "Low" performing assets
- Continuously iterate
```

**Optimization Cycle:**

```text
WEEK 1-2: Launch with maximum assets
WEEK 3: Review performance (check for "Low" assets)
WEEK 4: Replace bottom 20% of assets
WEEK 5-6: Let new assets gather data
WEEK 7: Review and iterate again
Repeat indefinitely
```

### Google Performance Max (DCO)

**Asset Group Strategy:**

```text
ASSET GROUP STRUCTURE:
- 20 images (all 3 aspect ratios)
- 5 videos (multiple aspect ratios)
- 5 headlines
- 5 long headlines
- 5 descriptions
- 5 logos

GOOGLE'S OPTIMIZATION:
- Tests across all placements (Search, Display, YouTube, Discover, Gmail, Maps)
- Automatically adjusts creative for each placement
- Learns which assets work where
- Serves optimal combinations
```

**Performance Max Best Practices:**

1. **Provide Maximum Assets**
   - 20 images (not 10)
   - 5 videos (not 1)
   - All headline + description slots filled

2. **Audience Signals**
   - Provide audience hints (Google uses these as signals, not restrictions)
   - Custom audiences
   - Interest categories
   - Demographics

3. **Asset Groups by Theme**
   - Separate asset groups for different product categories
   - Different messaging for different audience segments
   - Don't mix unrelated products in one asset group

4. **Monitor Asset Performance**
   - Check asset performance report weekly
   - Identify top performers
   - Create more similar assets
   - Replace poor performers

**Example Asset Group:**

```text
PRODUCT: Running shoes

IMAGES (20):
Landscapes (8):
- 3 product-only on white background
- 3 person running in shoes
- 2 close-up shoe details

Squares (8):
- 3 product-only
- 3 lifestyle shots
- 2 before/after (worn vs. new)

Portraits (4):
- 2 product shots
- 2 person wearing shoes (full body)

VIDEOS (5):
- 1 horizontal product showcase (16:9)
- 2 vertical running demonstrations (9:16)
- 1 square customer testimonial (1:1)
- 1 horizontal "how it's made" (16:9)

SHORT HEADLINES (5):
- "Premium Running Shoes"
- "Run Faster, Recover Quicker"
- "Free Shipping + Returns"
- "4.8★ Rated by Runners"
- "Shop Best Sellers"

LONG HEADLINES (5):
- "Performance Running Shoes Engineered for Speed & Comfort"
- "Run Your Best With Award-Winning Cushioning Technology"
- "Get Free Shipping & 60-Day Returns on All Running Shoes"
- "Trusted by 50,000+ Runners - Join the Community"
- "Shop Top-Rated Running Shoes - All Sizes In Stock"

DESCRIPTIONS (5):
- "Advanced cushioning technology for maximum comfort. Lightweight design. Built for speed and endurance."
- "Trusted by 50,000+ runners worldwide. 4.8-star rating. Free shipping and easy 60-day returns."
- "Limited time: Free shipping on all orders. 60-day trial. Love them or return them - no questions asked."
- "Responsive foam midsole, breathable mesh upper, durable rubber outsole. Built to last 500+ miles."
- "Shop now and get free shipping, 60-day returns, and access to our exclusive runner community."
```

### TikTok Smart Creative

**How It Works:**

```text
YOU PROVIDE:
- Multiple video clips
- Multiple text options
- Multiple CTAs

TIKTOK:
- Assembles videos automatically
- Tests combinations
- Uses trending audio
- Optimizes for TikTok environment
```

**Best Practices:**

1. **Provide Variety**
   - Different hooks (first 3 seconds)
   - Different video bodies
   - Multiple CTAs

2. **TikTok-Native Content**
   - Vertical only (9:16)
   - Fast-paced
   - Trendy audio
   - Creator-style, not brand-style

3. **Let TikTok Optimize**
   - Don't overthink
   - Platform knows its audience
   - Trust the algorithm

### DCO vs. Manual Testing

**When to Use DCO:**

✅ **Advantages:**
- Faster testing (platform does the work)
- Tests at scale (thousands of combinations)
- Continuous optimization
- Cross-placement optimization
- Resource efficient

❌ **Disadvantages:**
- Less control over messaging
- Can't isolate variables precisely
- Platform dependency (trust algorithm)
- Reporting less granular

**When to Use Manual Testing:**

✅ **Advantages:**
- Complete control
- Isolate specific variables
- Precise audience-message matching
- Better for brand-sensitive content

❌ **Disadvantages:**
- Time-intensive
- Slower learning
- Requires more creative production
- Can't test all combinations

**Hybrid Approach (Recommended):**

```text
PHASE 1: DCO for Concept Discovery
- Use dynamic creative to find winning concepts quickly
- Let platform test broadly
- Identify top-performing assets

PHASE 2: Manual Testing for Refinement
- Take winning concepts from DCO
- Create focused manual A/B tests
- Refine messaging
- Optimize details

PHASE 3: Scale Winners with DCO
- Create asset variations of manual test winners
- Use DCO to scale at volume
- Continuous iteration
```

### DCO Optimization Checklist

```text
□ Provided maximum number of assets (don't leave slots empty)
□ Assets are diverse (not just minor variations)
□ Each asset can stand alone (no dependencies)
□ Headlines work in any combination with descriptions
□ Images/videos match all possible text combinations
□ Asset quality is high (don't include "filler" assets just to hit count)
□ Sufficient budget for learning (at least $50-100/day)
□ Ran for minimum learning period (7 days minimum)
□ Checked asset performance report
□ Replaced low performers
□ Created more variations of high performers
□ Documented learnings for future campaigns
```

---

## A/B Testing Creative Elements

### A/B Testing Fundamentals

**What is A/B Testing:**
Running two (or more) variations simultaneously to determine which performs better.

**Why It Matters:**
- Opinions don't matter (data does)
- Small changes can have huge impact
- Continuous improvement
- Build creative knowledge base

**A/B Test vs. Multivariate Test:**

```text
A/B TEST:
- Test ONE variable
- Two variations (A vs. B)
- Clear learnings (know what caused difference)

MULTIVARIATE TEST:
- Test multiple variables simultaneously
- Many variations
- Complex analysis (which combination works)
- Requires more traffic
```

### What to Test

**Priority Testing Order:**

**TIER 1 (Highest Impact):**
1. Hook (video ads: first 3 seconds)
2. Value proposition / Core message
3. Offer (discount, bonus, guarantee)
4. Creative format (image vs. video)

**TIER 2 (High Impact):**
5. Headline
6. Visual (which image/video)
7. Call-to-action
8. Social proof (which testimonial, what stat)

**TIER 3 (Medium Impact):**
9. Primary text (body copy)
10. Description
11. Button color/text
12. Length (video duration, copy length)

**TIER 4 (Lower Impact - but still worth testing):**
13. Emoji usage
14. Capitalization style
15. Pricing display ($99 vs. $99.00 vs. "ninety-nine dollars")
16. Urgency language

### A/B Testing Methodology

**Step 1: Hypothesis Formation**

```text
FORMAT:
"If we change [variable] from [A] to [B], we believe [metric] will [improve/worsen] because [reasoning]."

EXAMPLE:
"If we change the headline from 'Get Organized' to 'Never Miss a Deadline Again', we believe CTR will increase because it speaks to a specific pain point rather than a generic benefit."
```

**Step 2: Test Design**

**Isolation Rules:**
```text
✅ GOOD TEST:
Variable: Headline
A: "Get Organized"
B: "Never Miss a Deadline Again"
Everything else: Identical (same image, same body copy, same audience)

❌ BAD TEST:
Variable: Multiple
A: "Get Organized" + Image 1 + Copy 1
B: "Never Miss a Deadline Again" + Image 2 + Copy 2
Result: Can't determine what caused the difference
```

**Control vs. Variant:**
```text
CONTROL: Current champion (or baseline)
VARIANT: New test challenger

Always test against control
Winner becomes new control
Continuous improvement
```

**Step 3: Traffic Allocation**

**Equal Split:**
```text
50% traffic to A
50% traffic to B

Most common approach
Clear winner emerges
```

**Unequal Split (Advanced):**
```text
80% traffic to Control (safe bet)
20% traffic to Variant (testing)

Use when:
- Don't want to risk full traffic on untested variant
- Control is very strong performer
- Testing radical change
```

**Step 4: Sample Size & Duration**

**Minimum Thresholds:**

```text
FOR STATISTICAL SIGNIFICANCE:
- 100+ conversions per variant (minimum)
- 95% confidence level
- Run for at least 7 days (account for day-of-week variance)

RULE OF THUMB:
If you get 10 conversions/day:
- Need 10-20 days for valid test (100-200 conversions)

If you get 50 conversions/day:
- Need 2-4 days for valid test
```

**When to Stop Test:**

```text
STOP WHEN:
✅ Reached statistical significance (95%+ confidence)
✅ Hit minimum conversion threshold (100+)
✅ Run minimum duration (7 days)
✅ Clear winner emerged

DON'T STOP WHEN:
❌ Results "look good" after 1 day
❌ Boss wants answer early
❌ Impatient
❌ Variant is losing (must let test complete)
```

**Step 5: Analysis**

**Metrics to Compare:**

```text
PRIMARY METRIC:
The main goal (usually CPA or ROAS)

SECONDARY METRICS:
- CTR (click-through rate)
- CVR (conversion rate)
- CPC (cost per click)
- Video watch time (for video ads)
- Engagement rate

Example Analysis:
Variant A: 2.1% CTR, $45 CPA, 100 conversions
Variant B: 2.8% CTR, $38 CPA, 110 conversions

Winner: Variant B (16% lower CPA, higher CTR, more conversions)
Confidence: 96%
Action: B becomes new control, retire A
```

**Step 6: Implementation**

```text
WINNER:
- Scale budget
- Becomes new control
- Use learnings for future tests

LOSER:
- Pause
- Analyze why it failed
- Document learnings

NEXT TEST:
- Test new variant against winning control
- Continuous optimization
```

### Testing Frameworks

**Framework 1: Sequential Testing**

```text
WEEK 1: Test headlines (5 variations)
WEEK 2: Take winning headline, test images (5 variations)
WEEK 3: Take winning image+headline, test CTAs (3 variations)
WEEK 4: Take winning combination, test offers (3 variations)

RESULT:
Optimized creative with best:
- Headline
- Image
- CTA
- Offer

Then start over with new concepts.
```

**Framework 2: Champion vs. Challengers**

```text
STRUCTURE:
- 1 Champion (current best performer, 40% budget)
- 4-5 Challengers (new tests, 15% budget each)

WEEKLY:
- Analyze performance
- Best challenger beats champion? New champion.
- Worst challenger replaced with new test

BENEFIT:
- Always have safe bet (champion)
- Continuous testing (challengers)
- Automatic optimization
```

**Framework 3: Bracket Testing**

```text
ROUND 1:
Test 8 variations (equal budget)

ROUND 2:
Top 4 performers get more budget

ROUND 3:
Top 2 performers battle for champion

ROUND 4:
Winner gets full budget

BENEFIT:
- Fast elimination of losers
- Efficient budget allocation
- Clear winner emerges
```

### Test Examples

**Test 1: Headline Test**

```text
HYPOTHESIS:
Benefit-focused headlines will outperform question headlines

CONTROL:
"Want Better Project Management?"

VARIANTS:
B: "Manage Projects 50% Faster"
C: "Never Miss a Deadline Again"
D: "The PM Tool Your Team Will Actually Use"

EVERYTHING ELSE IDENTICAL:
- Same image
- Same body copy
- Same audience
- Same budget per variant

DURATION: 7 days
SAMPLE SIZE: 100+ conversions each

RESULTS:
A (Control): $48 CPA, 1.8% CTR
B: $52 CPA, 1.6% CTR (❌ Loser)
C: $39 CPA, 2.3% CTR (✅ Winner)
D: $44 CPA, 2.0% CTR

LEARNING:
Specific benefit ("Never Miss a Deadline") outperformed generic benefit and question

ACTION:
C becomes new control
Test more specific benefit angles
```

**Test 2: Image Test**

```text
HYPOTHESIS:
UGC-style images will outperform professional product photos

CONTROL:
Professional product photo on white background

VARIANTS:
B: Person using product (lifestyle shot)
C: UGC-style phone photo of product
D: Before/after split screen

EVERYTHING ELSE IDENTICAL:
- Same headline
- Same copy
- Same audience

DURATION: 10 days
SAMPLE SIZE: 150+ conversions each

RESULTS:
A (Control): $42 CPA, 2.1% CTR
B: $38 CPA, 2.4% CTR (✅ Winner)
C: $40 CPA, 2.3% CTR
D: $45 CPA, 1.9% CTR

LEARNING:
Lifestyle shot showing product in use outperformed all others

ACTION:
B becomes new control
Create more lifestyle imagery
```

**Test 3: Video Hook Test**

```text
HYPOTHESIS:
Question hooks will outperform statement hooks for cold traffic

CONTROL:
"This changed how I manage projects" (statement)

VARIANTS:
B: "Tired of project chaos?" (question)
C: "What if you never missed a deadline?" (hypothetical question)
D: "I cut project time in half. Here's how:" (result + promise)

EVERYTHING ELSE IDENTICAL:
- Same video body (seconds 3-45)
- Same headline/copy
- Same audience

DURATION: 7 days
SAMPLE SIZE: 80+ conversions each

RESULTS:
A (Control): $41 CPA, 52% hook rate
B: $38 CPA, 58% hook rate (✅ Winner)
C: $40 CPA, 55% hook rate
D: $36 CPA, 61% hook rate (✅ Best CPA & hook rate)

LEARNING:
Result + promise hook (D) performed best
Questions generally outperformed statements

ACTION:
D becomes new control
Test more result-driven hooks
```

**Test 4: Offer Test**

```text
HYPOTHESIS:
Free trial offer will outperform discount offer

CONTROL:
"40% off your first month"

VARIANTS:
B: "Try free for 30 days - no credit card"
C: "First month free, then $29/month"
D: "50% off for 3 months"

EVERYTHING ELSE IDENTICAL:
- Same creative
- Same headline
- Same audience

DURATION: 14 days (longer for offer tests)
SAMPLE SIZE: 120+ conversions each

RESULTS:
A (Control): $44 CPA, 3.2% CVR
B: $36 CPA, 4.1% CVR (✅ Winner - best CPA)
C: $38 CPA, 3.9% CVR
D: $42 CPA, 3.5% CVR

But check LTV:
A: $180 LTV (discount users)
B: $245 LTV (free trial users - higher retention)
C: $220 LTV
D: $165 LTV (heavy discounters, low LTV)

LEARNING:
Free trial had best CPA AND best LTV
No credit card requirement reduced friction

ACTION:
B becomes standard offer
Test variations of free trial (14 days vs. 30 days)
```

### Statistical Significance

**Why It Matters:**
- Prevents false positives (thinking something works when it doesn't)
- Gives confidence in results
- Required for valid conclusions

**How to Calculate:**
Use an A/B test significance calculator:
- VWO Calculator
- Optimizely Stats Engine
- AB Test Guide Calculator

**Input:**
- Visitors to A
- Conversions from A
- Visitors to B
- Conversions from B

**Output:**
- Confidence level (aim for 95%+)
- Which variant is better
- By how much

**Interpreting Results:**

```text
CONFIDENCE LEVEL: 95%
MEANING: 95% certain this result is real, not random chance
ACTION: Safe to declare winner and scale

CONFIDENCE LEVEL: 75%
MEANING: Not enough data, could be random
ACTION: Keep testing, don't make decisions yet

CONFIDENCE LEVEL: 50%
MEANING: Basically a coin flip
ACTION: Results are meaningless, keep testing
```

### Common Testing Mistakes

**Mistake 1: Testing Too Many Variables**
```text
PROBLEM: Changed headline, image, copy, and audience
RESULT: Can't determine what caused the difference

FIX: One variable at a time
```

**Mistake 2: Stopping Test Too Early**
```text
PROBLEM: "Variant B is winning after 1 day! Let's scale it!"
RESULT: Random noise, not real result. Variant B fails when scaled.

FIX: Wait for statistical significance + minimum sample size + minimum duration
```

**Mistake 3: Not Running Long Enough**
```text
PROBLEM: Tested Monday-Wednesday only
RESULT: Missed weekend behavior, incomplete data

FIX: Minimum 7 days to account for day-of-week variance
```

**Mistake 4: Unequal Sample Sizes**
```text
PROBLEM: Variant A got 1000 visitors, Variant B got 200
RESULT: Not a fair comparison

FIX: Equal traffic split (or adjust for unequal if intentional)
```

**Mistake 5: Looking at Wrong Metric**
```text
PROBLEM: "Variant B has higher CTR, so it wins!"
RESULT: But Variant B has worse CPA (what actually matters)

FIX: Always optimize for primary business metric (usually CPA or ROAS)
```

**Mistake 6: Not Documenting Results**
```text
PROBLEM: Ran test, forgot results, tested same thing again 3 months later
RESULT: Wasted time and money

FIX: Test documentation system (spreadsheet, tool, etc.)
```

### Test Documentation

**Testing Log Template:**

```text
TEST ID: [Unique identifier]
DATE: [Start - End]
CAMPAIGN: [Which campaign]

HYPOTHESIS:
[What you're testing and why]

CONTROL:
[Description + screenshot]

VARIANT(S):
[Description + screenshot for each]

VARIABLE TESTED:
[Headline / Image / Hook / Offer / etc.]

AUDIENCE:
[Who saw this test]

BUDGET:
[$ per variant]

DURATION:
[Days run]

RESULTS:
Control: [CPA, CTR, Conversions, Confidence]
Variant B: [CPA, CTR, Conversions, Confidence]
Variant C: [etc.]

WINNER:
[Which won and why]

CONFIDENCE LEVEL:
[%]

LEARNINGS:
[What did we learn from this test?]

NEXT STEPS:
[What to test next based on these results]

SCREENSHOTS:
[Attach images of creatives and results]
```

**Knowledge Base:**

```text
Build institutional knowledge:

WINNERS LIBRARY:
- All winning creatives
- Performance metrics
- Why they won
- When they were champions

LOSERS LIBRARY:
- Failed tests
- Why they failed
- Lessons learned
- Don't repeat mistakes

BEST PRACTICES LOG:
- Accumulated learnings
- "Headlines with numbers outperform generic"
- "UGC beats professional photography for our audience"
- "Question hooks > statement hooks for cold traffic"
```

---

## Creative Performance Metrics

### Primary Metrics

**1. CPA (Cost Per Acquisition)**

**Definition:** How much it costs to acquire one customer/conversion

**Formula:** Total Spend ÷ Total Conversions

**Example:**
```text
Spent: $5,000
Conversions: 100
CPA: $50
```

**What Good Looks Like:**
- CPA < Target CPA (business-dependent)
- Lower than competitor average
- Decreasing over time (with optimization)

**Optimization:**
- Lower CPA = better creative efficiency
- Compare across creatives to find winners
- Track trend (improving or worsening?)

**2. ROAS (Return On Ad Spend)**

**Definition:** Revenue generated per dollar spent on ads

**Formula:** Revenue ÷ Ad Spend

**Example:**
```text
Revenue: $25,000
Ad Spend: $5,000
ROAS: 5:1 (or 5x or 500%)
```

**What Good Looks Like:**
- ROAS > Target ROAS (typically 3-5x for e-commerce)
- Above breakeven
- Increasing over time

**Optimization:**
- Higher ROAS = more profitable campaigns
- Primary metric for e-commerce
- Balance with scale (sometimes lower ROAS acceptable for more volume)

**3. CTR (Click-Through Rate)**

**Definition:** Percentage of people who see ad and click

**Formula:** (Clicks ÷ Impressions) × 100

**Example:**
```text
Impressions: 100,000
Clicks: 2,500
CTR: 2.5%
```

**What Good Looks Like:**
| Platform | Good CTR | Great CTR |
|----------|----------|-----------|
| Facebook Feed | 1.5-2% | 3%+ |
| Facebook Stories | 0.8-1.2% | 2%+ |
| Instagram Feed | 1-1.5% | 2.5%+ |
| Instagram Stories | 0.5-1% | 1.5%+ |
| Google Search | 3-5% | 8%+ |
| Google Display | 0.3-0.5% | 1%+ |
| YouTube | 0.5-1% | 2%+ |
| TikTok | 1-2% | 3%+ |

**Optimization:**
- Higher CTR = more engaging creative
- Good indicator of thumb-stop power
- But watch conversion rate (high CTR + low CVR = bad targeting or misleading ad)

**4. CVR (Conversion Rate)**

**Definition:** Percentage of clickers who convert

**Formula:** (Conversions ÷ Clicks) × 100

**Example:**
```text
Clicks: 2,500
Conversions: 100
CVR: 4%
```

**What Good Looks Like:**
- E-commerce: 2-5%
- Lead gen: 5-15%
- SaaS trials: 3-10%

**Optimization:**
- Higher CVR = better audience targeting and message-offer-landing page alignment
- If CVR is low: problem is likely landing page or offer, not creative
- If CVR is high but CPA still high: traffic is expensive (improve CTR with better creative)

### Secondary Metrics (Video Specific)

**5. Hook Rate (ThruPlay Rate)**

**Definition:** Percentage of people who watch past the first 3 seconds

**Also Called:** 3-Second View Rate, Retention Rate

**What Good Looks Like:**
- 50%+ is good
- 60%+ is great
- 70%+ is excellent

**Optimization:**
- Low hook rate = weak hook (first 3 seconds)
- High hook rate = strong pattern interrupt
- Test hooks aggressively (highest leverage point)

**6. Hold Rate (Average Watch Time)**

**Definition:** How long viewers watch on average

**Formula:** Total Watch Time ÷ Total Views

**Example:**
```text
Video length: 45 seconds
Average watch time: 18 seconds
Hold rate: 40%
```

**What Good Looks Like:**
- 30-40% for feed videos
- 50-70% for Stories/Reels (shorter attention)
- Higher for YouTube (different viewing intent)

**Optimization:**
- Low hold rate = lost interest (pacing, content quality)
- High hold rate = engaging throughout
- Aim for 25%+ completion rate minimum

**7. ThruPlay (Facebook Specific)**

**Definition:** Video watched to completion (or 15+ seconds)

**Why It Matters:**
- Facebook optimization objective
- Lower cost per ThruPlay = more engaging video
- Correlates with lower-funnel performance

**What Good Looks Like:**
- Cost per ThruPlay < $0.05-0.10 (varies by industry)
- ThruPlay rate > 25%

**8. Video Views**

**Definitions Vary by Platform:**

```text
FACEBOOK/INSTAGRAM:
- 3-second view: Watched 3+ seconds
- 10-second view: Watched 10+ seconds
- ThruPlay: Watched to end or 15s

YOUTUBE:
- View: 30+ seconds or interaction

TIKTOK:
- View: Any watch time (even 1 second)
- Full view: 100% completion
```

**Use Case:**
- Awareness metric
- Costs: cost per 3s view, cost per 10s view
- Volume indicator

### Engagement Metrics

**9. Engagement Rate**

**Definition:** Total engagements ÷ Impressions

**Engagements Include:**
- Likes
- Comments
- Shares
- Saves
- Clicks

**What Good Looks Like:**
- 1-3%: Average
- 3-6%: Good
- 6%+: Excellent

**Optimization:**
- High engagement = resonating with audience
- Can improve organic reach
- Social proof (more engagement attracts more)

**10. Comment Sentiment**

**Qualitative Metric:**
Read comments for insights:
- Positive: "This is exactly what I needed!"
- Neutral: Questions about product
- Negative: "Sick of seeing this ad"

**Use:**
- Gauge creative fatigue (negative comments increasing)
- Find objections to address
- Uncover messaging opportunities
- Social listening

**11. Save Rate (Instagram Specific)**

**Definition:** How many people save your ad/post

**Why It Matters:**
- High-intent action (want to reference later)
- Strong signal of value
- Boosts organic reach

**12. Share Rate**

**Definition:** How many people share your ad

**Why It Matters:**
- Highest-intent engagement
- Extends reach organically
- Strong indicator of resonance

**What Drives Shares:**
- Highly relatable content
- Funny/entertaining
- Educational (worth passing along)
- Emotional (inspires sharing)

### Cost Metrics

**13. CPM (Cost Per 1,000 Impressions)**

**Definition:** How much to reach 1,000 people

**Formula:** (Total Spend ÷ Impressions) × 1,000

**Example:**
```text
Spent: $500
Impressions: 100,000
CPM: $5
```

**What It Indicates:**
- How competitive ad auction is
- Audience demand
- Creative quality (better creative = lower CPM)

**What Good Looks Like:**
- Varies widely by platform, audience, time of year
- Facebook: $5-15 typically
- Instagram: $5-10
- LinkedIn: $30-100 (higher for B2B)
- Google Display: $2-10

**14. CPC (Cost Per Click)**

**Definition:** Average cost per click

**Formula:** Total Spend ÷ Clicks

**Example:**
```text
Spent: $1,000
Clicks: 500
CPC: $2
```

**What It Indicates:**
- How expensive each website visit is
- Efficiency of driving traffic

**Relationship to Other Metrics:**
```text
CPA = CPC ÷ CVR

If CPC = $2 and CVR = 5%:
CPA = $2 ÷ 0.05 = $40
```

**15. CPL (Cost Per Lead)**

**Definition:** Cost to acquire one lead (email, form fill, etc.)

**Same as CPA for lead-gen campaigns**

**What Good Looks Like:**
- B2C: $5-20
- B2B: $50-200+ (depends on deal size)

### Quality Metrics

**16. Relevance Score (Facebook)**

**What It Is:**
Facebook's rating of ad quality (1-10 scale)
- Now replaced by: Quality Ranking, Engagement Ranking, Conversion Ranking

**Rankings:**
- Above Average
- Average
- Below Average (Bottom 35%)
- Below Average (Bottom 20%)
- Below Average (Bottom 10%)

**Why It Matters:**
- Higher relevance = lower costs
- Better ad delivery
- Indicator of creative-audience fit

**How to Improve:**
- Better creative (more engaging)
- Better targeting (right audience)
- Better offer
- Reduce negative feedback

**17. Quality Ranking**

**What It Is:** How your ad quality compares to ads competing for the same audience

**Optimization:**
- Low quality ranking = creative isn't resonating
- Improve visuals, messaging, or targeting

**18. Engagement Rate Ranking**

**What It Is:** How your expected engagement compares to competitors

**Optimization:**
- Low engagement ranking = ad is boring
- Improve thumb-stop power
- More compelling hook

**19. Conversion Rate Ranking**

**What It Is:** How your expected conversion rate compares to competitors

**Optimization:**
- Low CR ranking = misleading ad or bad landing page
- Ensure message match
- Improve offer or landing page

### Attribution Metrics

**20. View-Through Conversions**

**Definition:** Conversions from people who saw ad but didn't click, then converted later

**Why It Matters:**
- Measures awareness impact
- Not all conversions are click-attributed
- Video ads especially benefit from this

**21. Click-Through Conversions**

**Definition:** Conversions from people who clicked ad and converted

**Why It Matters:**
- Direct attribution
- More reliable than view-through

**Attribution Windows:**

```text
FACEBOOK:
- 1-day click, 1-day view
- 7-day click, 1-day view (default)
- 28-day click, 28-day view

GOOGLE:
- Last click (default)
- Data-driven (recommended)
- First click, linear, time decay, position-based (other options)

Different windows = different CPA reporting
```

### Metrics Dashboard

**Daily Monitoring (Quick Check):**
```text
□ Spend (on track?)
□ CPA / ROAS (hitting targets?)
□ Volume (enough conversions?)
□ CTR (any major drops?)
```

**Weekly Analysis (Deep Dive):**
```text
□ Creative performance (winners/losers)
□ Frequency (any fatigue?)
□ Audience performance (any changes?)
□ Trends (improving or worsening?)
□ Quality rankings (any below average?)
```

**Monthly Review (Strategic):**
```text
□ Overall account health
□ Creative library performance
□ Winning patterns (what works?)
□ Losing patterns (what doesn't?)
□ Competitive benchmarks
□ YoY / MoM trends
```

### Metrics by Objective

**Awareness Campaigns:**
Primary: CPM, Reach, Video Views, ThruPlay
Secondary: Engagement, Share rate

**Consideration Campaigns:**
Primary: CTR, Cost per Click, Video Views
Secondary: Engagement, Landing page views

**Conversion Campaigns:**
Primary: CPA, ROAS, CVR
Secondary: CTR, CPC

### Calculating ROI

**Formula:**
```text
ROI = (Revenue - Ad Spend) ÷ Ad Spend × 100

Example:
Revenue: $25,000
Ad Spend: $5,000
ROI = ($25,000 - $5,000) ÷ $5,000 × 100 = 400%
```

**Break-Even:**
```text
Break-even ROAS = 1 ÷ Profit Margin

If profit margin is 40%:
Break-even ROAS = 1 ÷ 0.40 = 2.5

Need 2.5:1 ROAS to break even
```

### Metrics Tracking Tools

**Native Platforms:**
- Facebook Ads Manager
- Google Ads interface
- TikTok Ads Manager
- etc.

**Third-Party Tracking:**
- Google Analytics (website behavior)
- Triple Whale (e-commerce, Shopify)
- Hyros (advanced attribution)
- Northbeam (attribution platform)

**Reporting Tools:**
- Google Data Studio (free dashboards)
- Supermetrics (automated reporting)
- Funnel.io (multi-platform aggregation)

**Spreadsheet Tracking:**
```text
Simple daily log:
Date | Campaign | Spend | Clicks | Conv | CPA | ROAS | Notes
[Track daily to spot trends quickly]
```

---

