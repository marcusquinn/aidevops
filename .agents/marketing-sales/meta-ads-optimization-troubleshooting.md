# Troubleshooting Common Issues

> Diagnostic paths for Meta Ads problems.

## Delivery Issues

**Ad Not Spending** — Check in order: payment method (valid card, no failures, spending limit) → ad status (Active, no disapproval) → budget (not exhausted, above minimum) → schedule (start/end dates, dayparting) → audience (>1,000, no conflicts) → bid (cost cap not too restrictive). Verify all levels Active (Campaign, Ad Set, Ad) and LP URLs correct. If still not spending after 24h: duplicate campaign, start with smaller proven audience, increase budget temporarily, contact support.

**Limited Delivery**:

| Cause | Fix |
|-------|-----|
| Small audience | Broaden targeting |
| Low budget | Increase or consolidate ad sets |
| High competition | Adjust bid/budget |
| Low-quality ad | Improve creative |

**Learning Limited** — Ad set not getting 50 conversions/week. Fixes: increase budget, broaden audience, optimize for higher-funnel event (AddToCart instead of Purchase), consolidate ad sets.

---

## Performance Issues

**High CPA** — Diagnose by isolating the bottleneck:

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| High CPM + Low CTR | Poor creative | Improve hook/visuals |
| Normal CPM + Low CTR | Wrong audience | Adjust targeting |
| High CTR + Low CVR | LP doesn't match ad | Improve congruence |
| High CTR + Normal CVR + High CPA | CPM too high | Optimize delivery |
| Normal all metrics | Wrong traffic/audience | Revisit targeting |

**Was great, now terrible**: Gradual decline = fatigue (add new creative, pause fatigued ads). Sudden overnight = algorithm reset or external factor (check edits, seasonal competition, LP changes). Recovery: revert edits if sudden, duplicate fresh ad set, adjust expectations.

**Algorithm Reset Triggers**: Budget change >20% (sometimes), targeting change (always), all creative changed at once (always), pause >7 days (always). Recovery: wait 3-5 days, don't make more changes, let algorithm re-learn.

**Diminishing Returns at Scale**: Each budget increase yields smaller CPA improvement, eventually CPA starts rising, frequency increasing despite larger audience. Response: (1) stop vertical scaling, (2) try horizontal scaling (duplicates), (3) look for new winning creative, (4) accept current scale as efficient maximum.

**High CPM** — Causes: Q4/holiday competition, narrow audience, low ad quality, poor engagement. Fixes: broaden audience, improve creative, test placements, adjust timing.

**Low CTR** — Benchmark: <0.8% concerning, <0.5% needs action. Causes: hook not compelling, wrong audience, creative fatigue, poor visuals, unclear value prop. Fixes: test new hooks, review audience fit, refresh creative, clarify message.

**Low Conversion Rate** — Site-side: page load >3s, broken mobile, long form, price shock, missing trust signals. Message mismatch: ad promises X, page delivers Y. Audience: wrong intent level, too early in funnel. High CTR but no conversions? Check LP CVR in GA4 (benchmark: 5-15%) — if LP CVR is fine but Meta shows zero → tracking issue.

**Winning Campaign Suddenly Stopped** — Check: policy issue (ad flagged, LP changed) → audience exhaustion (frequency 5+) → competition spike (seasonal, new competitor) → algorithm change. Recovery: check policy first → review frequency/reach → duplicate ad set → broader audiences → new creative.

---

## Account Issues

**Account Disabled**: (1) Check email for explanation, (2) Request review in Business Settings, (3) Don't create new accounts (makes it worse). Prevention: stay within policies, keep payment current, avoid frequent major changes, don't use VPNs/proxies.

**Ad Rejections**:

| Violation | Fix |
|-----------|-----|
| Personal attributes | Remove "you" + attribute |
| Misleading claims | Remove impossible promises |
| Adult content | Remove suggestive imagery |
| Restricted product | Ensure compliance/certification |
| Clickbait | Remove sensational language |
| Non-functional LP | Fix landing page |

Appeals: Account Quality → find rejected ad → Request Review → wait 24-72h. If denied, modify and resubmit (don't keep appealing same ad).

---

## Tracking Issues

**Pixel Not Firing**: (1) Use Facebook Pixel Helper extension, (2) Check Events Manager → Test Events, (3) Verify pixel code on page (correct location, no script conflicts, test in incognito).

**Conversion Mismatch (Meta vs Analytics)** — Causes: different attribution windows, duplicate events, CAPI not deduplicating, cross-domain issues, view-through attribution. Investigation: compare same date range → check attribution settings → test for duplicate events → verify CAPI setup.

**CAPI Issues** — Events not matching: check `event_id` — Pixel and CAPI must use same `event_id`. Low match rate: include more user data (email, phone, fbp, fbc), check data formatting and hashing.

---

## Creative Issues

**Ad Fatigue** — Signs: CTR declining >20% week-over-week, frequency >3.0 (prospecting) or >5.0 (retargeting), CPA rising while CPM stable, running 3+ weeks unchanged. Fixes: add new creative, create iterations of winner, pause fatigued ads, test new concepts.

**Quality Ranking**:

| Ranking | Fixes |
|---------|-------|
| Below average quality | Improve visuals, remove clickbait, test authentic style |
| Below average engagement | Test new hooks, improve scroll-stopping elements, test formats |
| Below average conversion | Improve LP, check offer-audience fit, verify tracking, test CTAs |

---

## Seasonal & Platform Notes

| Period | Expectation | Strategy |
|--------|-------------|----------|
| Q4 (Oct-Dec) | CPMs +30-100% | Increase CPA targets, lock in winning creative early, focus retargeting |
| January | Lower CPMs/intent | Test new creative cheaply, build audiences |
| Summer | Lower engagement | Good for testing |

**Facebook**: Older audience, more text-tolerant, Marketplace/Groups placements. **Instagram**: Younger/visual, Stories/Reels heavy, less text tolerance, Explore/Shop. If platforms perform differently: check placement breakdown, create placement-specific creative.

**Audience Network**: Low-quality/accidental clicks common, high volume but low conversion. Exclude entirely, or create separate AN-only campaign and monitor CVR separately.

**Reels**: Must be 9:16, needs native-feeling content. May over-deliver cheaply but with lower intent — check conversion quality.

---

## When to Contact Meta Support

**Contact when**: account disabled with no clear reason, repeated rejections for compliant ads, pixel/tracking issues after exhausting docs, unresolved payment issues, suspected platform bug. **How**: Business Help Center → Contact → Chat (fastest). Provide: Ad Account ID, Campaign ID, specific issue. Support can help with account access, policy clarifications, technical bugs, payment. Cannot help with CPA optimization, strategy, creative feedback, competitor issues.

---

*Next: [Automation Rules](automation-rules.md)*
