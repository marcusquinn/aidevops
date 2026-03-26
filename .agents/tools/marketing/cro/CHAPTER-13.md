# Chapter 13: Heatmap and Session Recording Analysis

Heatmaps and session recordings reveal how users actually interact with your site—where they click, how far they scroll, what confuses them, and where they get stuck.

### Types of Heatmaps

**1. Click Heatmaps (Click Maps)**

Shows where users click (or tap on mobile).

**What It Reveals**:
- Are users clicking on non-clickable elements? (Indicates they expect it to be a link/button)
- Are they ignoring important CTAs?
- Are they clicking on the wrong things?

**Example Insights**:

**Product Image Clicks**:

```text
Heatmap shows 1,000 clicks on product image (not clickable)
0 clicks on "View Details" link
```

**Action**: Make product image clickable, or add "Click to enlarge" text.

**Non-Button Text Clicked**:

```text
Heatmap shows 500 clicks on "Free Shipping" text (looks like button but isn't)
```

**Action**: Either make it a button or visually differentiate it so users don't think it's clickable.

**2. Scroll Heatmaps (Scroll Maps)**

Shows how far down the page users scroll before leaving.

**What It Reveals**:
- Do users see your CTA? (Is it below the fold where only 20% scroll?)
- Are long pages losing engagement halfway through?
- Where do users drop off?

**Example Insights**:

**CTA Below the Fold**:

```text
Scroll map shows 60% of users never scroll past hero section
CTA is at 70% page depth
```

**Action**: Add CTA above the fold OR create sticky CTA.

**Content Drop-Off**:

```text
Scroll map shows 90% engagement at top, 40% at middle, 10% at bottom
```

**Action**: Move important content higher, cut fluff at bottom, or add visual breaks to encourage scrolling.

**3. Move Heatmaps (Mouse Tracking / Hover Maps)**

Shows where users move their mouse cursor (desktop only).

**What It Reveals**:
- Mouse movement often correlates with eye tracking
- Where users are reading/paying attention
- Hesitation points (cursor hovering without clicking)

**Example Insights**:

**Pricing Hesitation**:

```text
Move map shows cursors hovering over price for 10+ seconds
Then leaving without clicking CTA
```

**Action**: Price may be too high, or value not clear. Add guarantees, testimonials near pricing.

**Reading Patterns**:

```text
Move map shows users reading first 3 bullet points, skipping rest
```

**Action**: Limit to 3-5 bullets, or restructure for scannability.

**4. Attention Heatmaps (Based on Time Spent)**

Shows which areas of the page get the most visual attention based on time spent.

**What It Reveals**:
- What content actually gets read
- What gets ignored
- Where users spend time before converting (or leaving)

**Example Insights**:

**Ignored Value Proposition**:

```text
Attention map shows users spend 2 seconds on headline, 30 seconds on image, 0 seconds on benefits section
```

**Action**: Make benefits section more visual, scannable, or reposition.

**Confused Navigation**:

```text
Attention map shows users spending 20+ seconds on navigation menu (indicating confusion)
```

**Action**: Simplify navigation labels or structure.

### Reading Heatmaps: What to Look For

**Red = High Activity** (clicks, scrolls, attention)
**Yellow/Orange = Medium Activity**
**Blue/Green = Low Activity**
**White/Gray = No Activity**

#### Good Heatmap Patterns

**Hero Section**:
- Red around headline (high attention)
- Red around CTA button (high clicks)
- Some attention on value prop

**Product Page**:
- High clicks on "Add to Cart"
- High attention on product images
- Moderate attention on product description
- Low clicks on unrelated elements

**Landing Page**:
- High scroll depth (80%+ reach CTA)
- High clicks on CTA
- Even distribution of attention across benefits

#### Bad Heatmap Patterns

**Rage Clicks**:
Multiple rapid clicks in same spot = frustration.

**Causes**:
- Element looks clickable but isn't
- Button isn't working (broken JS)
- Slow page response (user impatiently clicking)

**Action**: Fix the issue causing frustration.

**Dead Clicks**:
Clicks on non-clickable elements.

**Example**: Users clicking product image expecting it to enlarge.

**Action**: Make element functional or remove visual cue that suggests it's clickable.

**Scroll Abandonment**:
90% of users never scroll past 30% of page.

**Causes**:
- Boring content
- No visual breaks
- CTA too low
- Above-fold content doesn't compel scrolling

**Action**: Add engaging content, visual hierarchy, CTA higher.

**Ignored CTAs**:
CTA button has almost zero clicks despite high traffic.

**Causes**:
- Poor placement
- Weak copy
- Not visually distinct
- Low value proposition
- Wrong audience

**Action**: Redesign, reposition, or rewrite CTA.

### Heatmap Tools

**Hotjar**:
- Click, scroll, and move heatmaps
- Session recordings
- Surveys and feedback
- Free plan available

**Crazy Egg**:
- Click heatmaps (desktop and mobile)
- Scroll maps
- Confetti tool (segment clicks by traffic source)
- A/B testing built-in

**Microsoft Clarity**:
- 100% free
- Heatmaps
- Session recordings
- Rage clicks and dead clicks
- Integrates with Google Analytics

**Mouseflow**:
- Heatmaps
- Session recordings
- Form analytics
- Funnel analysis

**FullStory**:
- Session recordings
- Retroactive funnels
- Heatmaps
- Error tracking
- Premium tool (higher cost)

### Session Recordings: What to Watch For

Session recordings show actual user sessions—you watch them navigate your site in real-time.

**What to Look For**:

**1. Hesitation**:
User hovers over a button for 10+ seconds without clicking.

**Indicates**: Uncertainty, fear, lack of trust, or unclear value prop.

**Action**: Add reassurance (guarantees, testimonials, clearer benefits).

**2. Confusion**:
User clicks multiple navigation items, backtracks, re-reads content.

**Indicates**: Poor navigation, unclear information hierarchy, confusing copy.

**Action**: Simplify navigation, improve content clarity.

**3. Frustration (Rage Clicks)**:
User clicks same spot rapidly 5-10 times.

**Indicates**: Broken element, slow load, or misleading design.

**Action**: Fix technical issue or redesign element.

**4. Form Abandonment**:
User starts filling form, then leaves.

**Where They Abandon**:
- Email field: Privacy concerns or not ready to commit
- Phone field: Don't want to be called
- Credit card field: Not ready to pay or security concerns
- Complex field: Confused about what to enter

**Action**: Simplify form, reduce required fields, add reassurance.

**5. Scroll Patterns**:

**Fast Scrolling**: User scrolls quickly to bottom, then leaves.
**Indicates**: Not finding what they need, impatient, wrong audience.

**Slow Scrolling**: User reads carefully, spends time on each section.
**Indicates**: High intent, engaged, likely to convert.

**Back-and-Forth Scrolling**: User scrolls down, then back up repeatedly.
**Indicates**: Seeking specific information that's hard to find, or comparing options.

**6. Mobile Struggles**:
User zooming in to read text, struggling to tap small buttons, horizontal scrolling (bad!).

**Indicates**: Poor mobile optimization.

**Action**: Larger fonts, bigger buttons, fix responsive design.

**7. Exit Points**:
Where do users leave?

**Common Exit Points**:
- Pricing page (too expensive or unclear value)
- Checkout page (surprise fees, friction, trust issues)
- Form page (too long, too invasive)
- Product page (not enough info, poor images)

**Action**: Analyze why they're leaving at that specific point and optimize.

### Session Recording Methodology

**Don't Watch Randomly**: That's inefficient and biased.

**Systematic Approach**:

**1. Segment Recordings**:
- **Converters**: Watch users who converted (see what worked)
- **Abandoners**: Watch users who almost converted but didn't (see what broke)
- **Bounces**: Watch users who left immediately (see what turned them off)

**2. Filter by Traffic Source**:
- Paid traffic behaves differently than organic
- Email traffic is warmer than cold social traffic

**3. Filter by Device**:
- Mobile vs desktop (different friction points)

**4. Set a Sample Size**:
- Don't watch 1,000 recordings
- Watch 20-30 per segment (enough to identify patterns)

**5. Take Notes**:
Track patterns:

```text
Issue: Users confused by navigation
Frequency: 8/20 recordings
Action: Simplify nav labels
Priority: High
```

### Heatmap Analysis Checklist

Before running tests, analyze heatmaps to identify optimization opportunities:

**Click Heatmap Analysis**:
- [ ] Are CTAs getting clicked? (If not, why?)
- [ ] Are users clicking non-clickable elements?
- [ ] Are users clicking the "wrong" elements (not the ones you want)?
- [ ] Are there unexpected click patterns?
- [ ] Mobile: Are tap targets large enough?

**Scroll Heatmap Analysis**:
- [ ] What % of users reach the CTA?
- [ ] Where do most users drop off?
- [ ] Is important content below average scroll depth?
- [ ] Are there visual barriers preventing scrolling?
- [ ] How does scroll depth compare to conversion rate?

**Move Heatmap Analysis**:
- [ ] Where are users' cursors spending the most time?
- [ ] Are they reading the content you want them to read?
- [ ] Are there hesitation patterns (hovering without clicking)?
- [ ] Do move patterns align with click patterns?

**Attention Heatmap Analysis**:
- [ ] What gets the most attention? (Is it what you want?)
- [ ] What gets ignored? (Should it be more prominent?)
- [ ] How long do users spend on key sections?
- [ ] Is attention distributed logically?

### Sample Size for Heatmaps

**Question**: How much data do I need before heatmap insights are reliable?

**General Guideline**:

**Minimum**:
- 100-200 sessions for initial patterns
- 500-1,000 sessions for reliable insights
- 2,000+ sessions for statistically confident insights

**But It Depends**:

**High-Traffic Pages** (10,000+ sessions/month):
- 1-2 weeks of data

**Medium-Traffic Pages** (1,000-10,000 sessions/month):
- 2-4 weeks of data

**Low-Traffic Pages** (<1,000 sessions/month):
- 1-3 months of data

**Conversion-Focused Pages** (landing pages, checkout):
- Need enough conversions AND non-conversions to compare
- Minimum: 50 conversions + 500 non-conversions

**Segment Analysis** (mobile vs desktop, traffic source):
- Minimum 200-500 sessions per segment

**Too Little Data = Noise**:
With only 20 sessions, one odd user behavior skews the entire heatmap.

**Too Much Data = Diminishing Returns**:
After 5,000 sessions, patterns stabilize. More data doesn't reveal much new.

### Combining Heatmaps with Analytics

Heatmaps answer "what happened."
Analytics answer "how much."

**Powerful Combination**:

**Example 1: Low CTA Clicks**

**Analytics**: CTA click rate is 2% (low)

**Heatmap**: CTA is getting almost no clicks

**Session Recordings**: Users are clicking above the CTA on a non-clickable image that looks like a button

**Insight**: Users think the image is the CTA

**Action**: Make image clickable OR redesign to visually differentiate actual CTA

**Result**: CTA click rate increases to 8%

**Example 2: High Bounce Rate**

**Analytics**: Landing page has 70% bounce rate

**Scroll Heatmap**: 90% of users never scroll past hero section

**Session Recordings**: Users land on page, read headline, immediately leave

**Insight**: Headline doesn't match ad promise (traffic source analysis shows users coming from ad about "free trial" but headline says "request demo")

**Action**: Align headline with ad message

**Result**: Bounce rate drops to 45%

**Example 3: Form Abandonment**

**Analytics**: 60% of users abandon form at phone number field

**Heatmap**: High attention on phone number field, zero clicks on submit

**Session Recordings**: Users fill email and name, hesitate at phone, then leave

**Insight**: Phone number field creates friction (privacy concerns)

**Action**: Make phone number optional

**Result**: Form completion rate increases 35%

---

*This deep dive continues in [Chapter 14: Landing Page Teardowns](./CHAPTER-14.md) and [Chapter 15: Personalization](./CHAPTER-15.md).*
