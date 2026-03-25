# Troubleshooting Common Issues

> When things go wrong, follow these diagnostic paths.

---

## Delivery Issues

### Ad Not Spending

Check in order: payment method (valid card, no failures, spending limit) → ad status (Active, no disapproval) → budget (not exhausted, above minimum) → schedule (start/end dates, dayparting) → audience (>1,000, no conflicts) → bid (cost cap not too restrictive).

### Limited Delivery

| Cause | Fix |
|-------|-----|
| Small audience | Broaden targeting |
| Low budget | Increase or consolidate ad sets |
| High competition | Adjust bid/budget |
| Low-quality ad | Improve creative |

### Learning Limited

Ad set not getting 50 conversions/week. Fixes: increase budget, broaden audience, optimize for higher-funnel event (AddToCart instead of Purchase), or consolidate ad sets to aggregate conversions.

---

## Performance Issues

### High CPA (Above Target)

```
CPA too high?
├── High CPM? → Competition/quality issue
├── Low CTR? → Creative not compelling
├── Low CVR? → Landing page issue
└── Normal all? → Wrong traffic/audience
```

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| High CPM + Low CTR | Poor creative | Improve hook/visuals |
| Normal CPM + Low CTR | Wrong audience | Adjust targeting |
| High CTR + Low CVR | LP doesn't match ad | Improve congruence |
| High CTR + Normal CVR + High CPA | CPM too high | Optimize delivery |

### High CPM

**Causes**: Q4/Holiday competition, narrow audience, low ad quality, poor engagement, industry competition.

**Fixes**: Broaden audience, improve creative quality, test different placements, adjust timing, improve engagement signals.

### Low CTR

**Benchmark**: <0.8% is concerning, <0.5% needs action.

**Causes**: Hook not compelling, wrong audience, creative fatigue, poor visual quality, unclear value proposition.

**Fixes**: Test new hooks, review audience fit, refresh creative, clarify message.

### Low Conversion Rate

**Site-side**: Page load >3s, broken mobile, long form, price shock, missing trust signals.

**Message mismatch**: Ad promises X, page delivers Y; different visual style, offer, or confusing journey.

**Audience**: Wrong intent level, too early in funnel, wrong demographics.

---

## Account Issues

### Account Disabled

1. Check email for explanation
2. Request review in Business Settings
3. Don't create new accounts (makes it worse)

**Prevention**: Stay within policies, keep payment current, avoid frequent major changes, don't use VPNs/proxies.

### Ad Rejections

| Violation | Fix |
|-----------|-----|
| Personal attributes | Remove "you" + attribute ("You're fat") |
| Misleading claims | Remove impossible promises |
| Adult content | Remove suggestive imagery |
| Restricted product | Ensure compliance/certification |
| Clickbait | Remove sensational language |
| Non-functional LP | Fix landing page |

**Appeals**: Account Quality → find rejected ad → Request Review → wait 24-72 hours. If denied, modify and resubmit (don't keep appealing same ad).

---

## Tracking Issues

### Pixel Not Firing

1. Use Facebook Pixel Helper extension
2. Check Events Manager → Test Events
3. Verify pixel code is on page (correct location, no script conflicts, test in incognito)

### Conversion Mismatch (Meta vs analytics)

**Causes**: Different attribution windows, duplicate events, CAPI not deduplicating, cross-domain issues, view-through attribution.

**Investigation**: Compare same date range → check attribution settings → test for duplicate events → verify CAPI setup → review cross-domain tracking.

### CAPI Issues

- **Events not matching**: Check `event_id` parameter — Pixel and CAPI must use same `event_id`
- **Low match rate**: Include more user data (email, phone, fbp, fbc), check data formatting and hashing algorithm

---

## Creative Issues

### Ad Fatigue

**Signs**: CTR declining >20% week-over-week, frequency >3.0 (prospecting) or >5.0 (retargeting), CPA rising while CPM stable, running 3+ weeks unchanged.

**Fixes**: Add new creative, create iterations of winner, pause fatigued ads, test new concepts.

### Quality Ranking Issues

| Ranking | Fixes |
|---------|-------|
| Below average quality | Check policy-edge content, improve visuals, remove clickbait, test authentic style |
| Below average engagement | Test new hooks, improve scroll-stopping elements, add call-to-engagement, test formats |
| Below average conversion | Improve landing page, check offer-audience fit, verify tracking, test CTAs |

---

## Seasonal Issues

| Period | Expectation | Strategy |
|--------|-------------|----------|
| Q4 (Oct-Dec) | CPMs +30-100%, intense competition | Increase CPA targets, lock in winning creative early, focus on retargeting |
| January | Lower CPMs, lower purchase intent | Test new creative cheaply, build audiences, prepare for spring |
| Summer | Lower engagement, industry-specific | Good for testing |

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

## Common Scenarios

### New Campaign Won't Spend

Check all levels Active (Campaign, Ad Set, Ad) → budget above minimum → audience >1,000, no conflicting exclusions → payment valid → all ads approved with correct landing page URLs.

If still not spending after 24 hours: duplicate the campaign, start with smaller proven audience, increase budget temporarily, contact support if persistent.

### CPA Was Great, Now Terrible

- **Gradual over days** = likely fatigue → add new creative, pause fatigued ads
- **Sudden overnight** = algorithm reset or external factor → check if you edited anything, check seasonal competition, check landing page for changes
- **Recovery**: revert edits if sudden, duplicate fresh ad set, adjust expectations for external factors

### High CTR But No Conversions

Check in order: landing page (doesn't match ad, loads slow, poor mobile, confusing CTA) → tracking (pixel not on thank you page, CAPI mismatch) → audience (curious clickers, wrong demographics) → offer (price shock, too much friction).

**Diagnostic test**: Check LP conversion rate in GA4 (benchmark: 5-15%). If LP CVR is fine but Meta shows no conversions → tracking issue.

### Winning Campaign Suddenly Stopped

**Causes**: Policy issue (ad flagged, LP changed) → audience exhaustion (frequency 5+, small audience burned through) → competition spike (seasonal, new competitor) → algorithm change.

**Recovery**: Check for policy issues first → review frequency and reach → duplicate ad set to new campaign → test broader audiences → create new creative variations.

---

## Platform-Specific

### Facebook vs Instagram

| Platform | Characteristics |
|----------|----------------|
| Facebook | Older audience, more text-tolerant, Marketplace/Groups placements |
| Instagram | Younger/visual, Stories/Reels heavy, less text tolerance, Explore/Shop |

If performing differently: check placement breakdown, create placement-specific creative.

### Audience Network Issues

Common problems: low-quality clicks, high volume but low conversion, accidental clicks.

Solutions: exclude Audience Network entirely, or create separate AN-only campaign and monitor conversion rate separately.

### Reels-Specific

- **Underperforms**: Check format (must be 9:16), content too "ad-like", hook not working — need native-feeling content
- **Over-delivers**: May be cheaper but lower intent — check conversion quality, consider restricting placements

---

## When to Contact Meta Support

**Contact when**: Account disabled with no clear reason, repeated rejections for compliant ads, pixel/tracking issues after exhausting docs, payment issues not resolved through help center, suspected platform bug.

**How**: Business Help Center → Contact → Chat (usually fastest). Provide: Ad Account ID, Campaign ID, specific issue.

**Support can help with**: Account access, policy clarifications, technical bugs, payment problems.

**Support cannot help with**: CPA optimization questions, strategy advice, creative feedback, competitor issues.

---

*Next: [Automation Rules](automation-rules.md)*
