# Troubleshooting Common Issues

> When things go wrong, follow these diagnostic paths.

---

## Delivery Issues

### Ad Not Spending

**Check in Order:**

1. **Payment Method**
   - Valid card on file?
   - Recent payment failure?
   - Spending limit reached?

2. **Ad Status**
   - Is ad "Active"?
   - Any disapproval?
   - In review?

3. **Budget**
   - Is budget too low?
   - Daily budget exhausted?
   - Lifetime budget exhausted?

4. **Schedule**
   - Start date in future?
   - End date passed?
   - Dayparting excluding now?

5. **Audience**
   - Too small (<1,000)?
   - Overlapping with better performer?
   - All excluded?

6. **Bid**
   - Cost cap too low?
   - Bid cap too restrictive?

### Limited Delivery

**Causes:**
- Audience too narrow
- Budget too low for CPA
- High competition
- Low-quality ad

**Solutions:**

| Cause | Fix |
|-------|-----|
| Small audience | Broaden targeting |
| Low budget | Increase or consolidate |
| Competition | Adjust bid/budget |
| Low quality | Improve creative |

### Learning Limited

**Definition:**
Ad set not getting 50 conversions/week to optimize.

**Fixes:**
1. **Increase budget** — More spend = more conversions
2. **Broaden audience** — Larger pool to find converters
3. **Higher-funnel event** — Optimize for AddToCart instead of Purchase
4. **Consolidate** — Combine ad sets to aggregate conversions

---

## Performance Issues

### High CPA (Above Target)

**Diagnostic Flow:**
```
CPA too high?
├── Check CPM
│   ├── High CPM? → Competition/quality issue
│   └── Normal CPM? → Continue...
├── Check CTR
│   ├── Low CTR? → Creative not compelling
│   └── Normal CTR? → Continue...
├── Check CVR
│   ├── Low CVR? → Landing page issue
│   └── Normal CVR? → Wrong traffic/audience
```

**Common Causes & Fixes:**

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| High CPM + Low CTR | Poor creative | Improve hook/visuals |
| Normal CPM + Low CTR | Wrong audience | Adjust targeting |
| High CTR + Low CVR | LP doesn't match ad | Improve congruence |
| High CTR + Normal CVR + High CPA | CPM too high | Optimize delivery |

### High CPM

**Why CPMs Rise:**
- Q4/Holiday competition
- Audience too narrow
- Low ad quality score
- Poor engagement
- Industry competition

**Fixes:**
- Broaden audience
- Improve creative quality
- Test different placements
- Adjust timing (avoid peak)
- Improve engagement signals

### Low CTR

**Benchmark:** <0.8% is concerning, <0.5% needs action

**Causes:**
- Hook not compelling
- Wrong audience
- Creative fatigue
- Poor visual quality
- Unclear value proposition

**Fixes:**
- Test new hooks
- Review audience fit
- Refresh creative
- Improve visual quality
- Clarify message

### Low Conversion Rate

**Site-Side Issues:**
- Page load slow (>3 seconds)
- Mobile experience broken
- Form too long
- Price shock
- Trust signals missing

**Message Mismatch:**
- Ad promises X, page delivers Y
- Different visual style
- Different offer
- Confusing journey

**Audience Issues:**
- Wrong intent level
- Too early in funnel
- Wrong demographics

---

## Account Issues

### Account Disabled

**Immediate Steps:**
1. Check email for explanation
2. Request review in Business Settings
3. Don't create new accounts (makes it worse)

**Common Causes:**
- Policy violations
- Payment failures
- Suspicious activity
- Circumventing systems

**Prevention:**
- Stay within policies
- Keep payment current
- Avoid frequent major changes
- Don't use VPNs/proxies

### Ad Rejections

**Review Process:**
1. Read rejection reason carefully
2. Check ad against specific policy
3. Fix the issue
4. Request manual review

**Common Violations:**
| Violation | Fix |
|-----------|-----|
| Personal attributes | Remove "you" + attribute ("You're fat") |
| Misleading claims | Remove impossible promises |
| Adult content | Remove suggestive imagery |
| Restricted product | Ensure compliance/certification |
| Clickbait | Remove sensational language |
| Non-functional LP | Fix landing page |

### Appeals Process

1. Go to Account Quality
2. Find rejected ad
3. Click "Request Review"
4. Provide context if asked
5. Wait (usually 24-72 hours)

**If Appeal Denied:**
- Modify ad and resubmit
- Don't keep appealing same ad
- Contact support for clarification

---

## Tracking Issues

### Pixel Not Firing

**Debug Steps:**
1. Use Facebook Pixel Helper extension
2. Check Events Manager → Test Events
3. Browse your site and check events
4. Verify pixel code is on page

**Common Causes:**
- Pixel code missing
- Code in wrong location
- Conflicts with other scripts
- Ad blocker (test in incognito)

### Conversion Mismatch

**When Meta reports differ from your analytics:**

**Causes:**
- Attribution windows different
- Duplicate events firing
- CAPI not deduplicating
- Cross-domain issues
- View-through attribution

**Investigation:**
1. Compare same date range
2. Check attribution settings
3. Test for duplicate events
4. Verify CAPI setup
5. Review cross-domain tracking

### CAPI Issues

**Events Not Matching:**
- Check event_id parameter
- Ensure Pixel and CAPI use same event_id
- Verify user data hashing

**Low Match Rate:**
- Include more user data (email, phone, fbp, fbc)
- Check data formatting
- Verify hashing algorithm

---

## Creative Issues

### Ad Fatigue

**Signs:**
- CTR declining >20% week-over-week
- Frequency >3.0 (prospecting) or >5.0 (retargeting)
- CPA rising while CPM stable
- Running 3+ weeks unchanged

**Fixes:**
1. Add new creative to ad set
2. Create iterations of winner
3. Pause fatigued ads
4. Test new concepts

### Quality Ranking Issues

**Below Average Quality:**
1. Check for policy-edge content
2. Improve visual quality
3. Remove clickbait elements
4. Test more authentic style

**Below Average Engagement:**
1. Test new hooks
2. Improve scroll-stopping elements
3. Add call-to-engagement
4. Test different formats

**Below Average Conversion:**
1. Improve landing page
2. Check offer-audience fit
3. Verify tracking accurate
4. Test different CTAs

---

## Seasonal Issues

### Q4 (Oct-Dec) Challenges

**What to Expect:**
- CPMs increase 30-100%+
- Competition intense
- Inventory premium

**How to Handle:**
- Increase CPA targets
- Lock in winning creative early
- Consider pausing low-margin offers
- Focus on retargeting

### Post-Holiday Slump (January)

**What to Expect:**
- Lower CPMs
- Lower purchase intent
- Budget hangovers for consumers

**Opportunity:**
- Test new creative cheaply
- Build audiences
- Prepare for spring

### Summer Variations

**General:**
- Lower engagement (people outside)
- Good for testing
- Industry-specific variations

---

## Quick Fixes Reference

| Problem | Quick Fix |
|---------|-----------|
| No spend | Check payment, budget, approval |
| High CPA | Check CTR → CVR → CPM in order |
| Low CTR | New hooks, test creative |
| Low CVR | Fix landing page, message match |
| High frequency | Expand audience, add creative |
| Learning limited | More budget or higher-funnel event |
| Account disabled | Appeal, don't create new account |
| Ad rejected | Fix policy issue, request review |

---

## Deep Dive: Common Scenarios

### Scenario 1: New Campaign Won't Spend

**Step-by-Step Diagnosis:**

1. **Check Campaign Status**
   - Campaign, Ad Set, and Ad all "Active"?
   - Any "Errors" or "Warnings" badges?

2. **Check Budget**
   - Is budget set correctly?
   - Is it higher than minimum bid?
   - For CBO, are all ad sets receiving allocation?

3. **Check Audience**
   - Audience size >1,000?
   - No conflicting exclusions?
   - Location set correctly?

4. **Check Payment**
   - Payment method valid?
   - Spending limit not hit?
   - Account in good standing?

5. **Check Ads**
   - All approved?
   - No policy holds?
   - Correct landing page URLs?

**If Still Not Spending After 24 Hours:**
- Duplicate the campaign entirely
- Start with smaller, proven audience
- Increase budget temporarily
- Contact support if persistent

### Scenario 2: CPA Was Great, Now Terrible

**Step-by-Step Diagnosis:**

1. **When Did It Change?**
   - Gradual over days = likely fatigue
   - Sudden overnight = algorithm reset or external factor

2. **Check What Changed**
   - Did you edit anything?
   - Did you add new ads?
   - Did frequency spike?

3. **Check External Factors**
   - Seasonal competition (Q4, holidays)?
   - Competitor activity?
   - News/current events?

4. **Check Landing Page**
   - Did it change?
   - Is it still loading fast?
   - Any new errors?

**Recovery Actions:**
- If gradual: Add new creative, pause fatigued
- If sudden edit: Revert change, duplicate fresh
- If external: Adjust expectations or pause
- If landing page: Fix immediately

### Scenario 3: High CTR But No Conversions

**Likely Causes:**

1. **Landing Page Issues**
   - Page doesn't match ad promise
   - Page loads slow/broken
   - Poor mobile experience
   - Confusing layout/CTA

2. **Tracking Issues**
   - Pixel not on thank you page
   - Event not firing correctly
   - CAPI mismatch

3. **Audience Mismatch**
   - Curious clickers, not buyers
   - Wrong demographics finding ad
   - Interests don't align with intent

4. **Offer Issues**
   - Price shock when they arrive
   - Offer not compelling enough
   - Too much friction to convert

**Diagnostic Test:**
- Check landing page conversion rate directly (GA4)
- Compare to benchmark (5-15% for good LP)
- If LP CVR low, problem is post-click
- If LP CVR fine but Meta shows no conv, tracking issue

### Scenario 4: Winning Campaign Suddenly Stopped

**Common Causes:**

1. **Policy Issue**
   - Ad flagged after running
   - Landing page changed and now violates
   - New policy enforcement

2. **Audience Exhaustion**
   - Small audience + high spend = burned through
   - Frequency spiked to 5+
   - Everyone who would convert has converted

3. **Competition Spike**
   - Seasonal increase
   - Competitor entered market
   - Category CPMs rose

4. **Algorithm Change**
   - Meta updated delivery
   - Your ad no longer favored
   - Signal changed

**Recovery Actions:**
- Check for policy issues first
- Review frequency and reach
- Duplicate ad set to new campaign
- Test broader audiences
- Create new creative variations

---

## Platform-Specific Troubleshooting

### Facebook vs Instagram Differences

**Facebook:**
- Generally older audience
- Feed engagement different than IG
- More text-tolerant
- Marketplace, Groups placement

**Instagram:**
- Younger, more visual
- Stories/Reels heavy
- Less text tolerance
- Explore, Shop placements

**If Performing Differently:**
- Check placement breakdown
- Create placement-specific creative
- Adjust audience if needed

### Audience Network Issues

**Common Problems:**
- Low-quality clicks
- High volume, low conversion
- Accidental clicks

**Solutions:**
- Exclude Audience Network entirely
- Or create separate AN-only campaign
- Monitor conversion rate separately

### Reels-Specific Issues

**If Reels Underperforms:**
- Format wrong (not 9:16)?
- Content too "ad-like"?
- Hook not working for Reels audience?
- Need native-feeling content

**If Reels Over-Delivers:**
- May be cheaper but lower intent
- Check conversion quality
- May need to restrict placements

---

## When to Contact Meta Support

**Contact Support When:**
- Account disabled with no clear reason
- Repeated ad rejections for compliant ads
- Pixel/tracking issues after exhausting docs
- Payment issues not resolved through help center
- Suspected bug or platform issue

**How to Contact:**
1. Business Help Center → Contact
2. Chat is usually fastest
3. Provide: Ad Account ID, Campaign ID, specific issue
4. Be polite but persistent

**What Support CAN Help With:**
- Account access issues
- Policy clarifications
- Technical bugs
- Payment problems

**What Support CAN'T Help With:**
- "Why is my CPA high?" (optimization questions)
- Strategy advice
- Creative feedback
- Competitor issues

---

*Next: [Automation Rules](automation-rules.md)*
