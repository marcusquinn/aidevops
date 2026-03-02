# Automated Rules

> Set it and forget it (sort of). Use rules to automate common optimizations.

---

## What Are Automated Rules?

Rules that automatically take action based on conditions you define:
- Turn ads on/off
- Adjust budgets
- Send notifications

**Access:** Ads Manager → Rules → Create Rule

---

## Essential Rules to Set Up

### Rule 1: Kill High-CPA Ads

**Purpose:** Stop losing money on underperformers

**Settings:**
```
Apply rule to: All active ads
Action: Turn off ads
Condition:
  - Cost per result > [2x your target CPA]
  - AND Impressions > 1000
Time range: Last 7 days
Schedule: Run continuously
```

**Example:**
```
If CPA > $60 (target is $30)
AND Impressions > 1000
→ Turn off ad
```

### Rule 2: Kill Zero-Conversion Spenders

**Purpose:** Stop ads that spend but don't convert

**Settings:**
```
Apply rule to: All active ads
Action: Turn off ads
Condition:
  - Results < 1
  - AND Amount spent > [2x target CPA]
Time range: Last 3 days
Schedule: Daily at 8 AM
```

**Example:**
```
If Purchases = 0
AND Spend > $60
→ Turn off ad
```

### Rule 3: Scale Winners Automatically

**Purpose:** Increase budget on high performers

**Settings:**
```
Apply rule to: All active ad sets
Action: Increase daily budget by 20%
Condition:
  - Cost per result < [80% of target CPA]
  - AND Results > 10
Time range: Last 3 days
Schedule: Daily at 12 AM
Maximum daily budget: [Your max]
```

**Example:**
```
If CPA < $24 (target is $30)
AND Purchases > 10
→ Increase budget 20%
→ Cap at $500/day
```

### Rule 4: Pause Fatigued Creatives

**Purpose:** Stop ads showing signs of fatigue

**Settings:**
```
Apply rule to: All active ads
Action: Turn off ads
Condition:
  - Frequency > 3.5
  - AND CTR (link) < 0.8%
Time range: Last 7 days
Schedule: Run continuously
```

### Rule 5: Budget Decrease for Rising CPA

**Purpose:** Protect against spend at bad CPA

**Settings:**
```
Apply rule to: All active ad sets
Action: Decrease daily budget by 25%
Condition:
  - Cost per result > [1.5x target CPA]
  - AND Results > 5
Time range: Last 3 days
Schedule: Daily at 12 AM
Minimum daily budget: $20
```

### Rule 6: Notification for Low Performance

**Purpose:** Get alerted when things go wrong

**Settings:**
```
Apply rule to: All active campaigns
Action: Send notification only
Condition:
  - Cost per result > [target CPA]
  - AND Results > 20
Time range: Last 3 days
Schedule: Daily at 9 AM
```

---

## Rule Templates by Campaign Type

### For Testing Campaigns (ABO)

**Kill Losers Fast:**
```
Turn off ads where:
- CPA > 1.5x target
- AND Impressions > 2000
Time: Last 3 days
```

**Identify Winners:**
```
Notify me when:
- CPA < target
- AND Results > 10
Time: Last 3 days
```

### For Scaling Campaigns (CBO)

**Auto-Scale Winners:**
```
Increase budget 15% when:
- CPA < 80% of target
- AND ROAS > target
- AND Results > 20
Time: Last 7 days
Cap: $1000/day
```

**Protect Against CPA Spikes:**
```
Decrease budget 20% when:
- CPA > 1.3x target
- AND Results > 10
Time: Last 3 days
Floor: $100/day
```

### For Retargeting Campaigns

**Frequency Control:**
```
Turn off ad sets where:
- Frequency > 5
- AND CTR declining >20%
Time: Last 7 days
```

**Keep Performers Running:**
```
Notify when ad set:
- ROAS > 3x
- AND Results > 15
Time: Last 7 days
```

---

## Advanced Rule Strategies

### Tiered Budget Rules

**Create multiple rules with increasing thresholds:**

**Tier 1 - Aggressive Scale:**
```
CPA < 50% of target → +30% budget
Requires: >20 conversions
```

**Tier 2 - Moderate Scale:**
```
CPA < 80% of target → +15% budget
Requires: >10 conversions
```

**Tier 3 - Maintenance:**
```
CPA 80-100% of target → No change
```

**Tier 4 - Defensive:**
```
CPA 100-130% of target → -15% budget
```

**Tier 5 - Kill:**
```
CPA > 130% of target → Turn off
```

### Dayparting Rules

**Pause During Low-Performance Hours:**
```
Turn off campaigns:
- Daily at 11 PM
Turn on campaigns:
- Daily at 6 AM
```

**Note:** Only useful if you have data showing specific hours underperform.

### Weekly Reset Rules

**Sunday Night Evaluation:**
```
Turn off any ad where:
- CTR < 0.5%
- AND Impressions > 5000
Time: Last 14 days
Schedule: Every Sunday at 11 PM
```

---

## Rule Best Practices

### Do's

✅ **Start conservative** — Small actions, verify they work
✅ **Use notifications first** — Understand patterns before automating
✅ **Set minimum thresholds** — Require enough data before action
✅ **Add caps and floors** — Prevent runaway budget changes
✅ **Review rule history** — Check what actions were taken
✅ **Combine with manual review** — Rules assist, don't replace judgment

### Don'ts

❌ **Don't over-automate** — Too many rules create conflicts
❌ **Don't use too short time ranges** — 1-day data is noisy
❌ **Don't forget about rules** — Review monthly
❌ **Don't set and forget scaling rules** — Can overspend
❌ **Don't use with learning phase** — Wait until stable

---

## Rule Monitoring

### Checking Rule History

```
1. Ads Manager → Rules
2. Select rule
3. View "Activity" tab
4. See all actions taken
```

### Monthly Rule Audit

**Questions to Ask:**
- Are rules firing appropriately?
- Any false positives (good ads killed)?
- Any false negatives (bad ads not killed)?
- Do thresholds need adjustment?

---

## Rule Configuration Reference

### Available Conditions

**Performance:**
- Results, Cost per result, ROAS
- Impressions, Reach, Frequency
- Clicks, CTR, CPC
- Amount spent

**Time Ranges:**
- Today
- Yesterday
- Last 3 days
- Last 7 days
- Last 14 days
- Last 30 days
- Lifetime

### Available Actions

**Ad Level:**
- Turn on/off
- Send notification

**Ad Set Level:**
- Turn on/off
- Increase/decrease daily budget
- Increase/decrease lifetime budget
- Send notification

**Campaign Level:**
- Turn on/off
- Increase/decrease daily budget
- Send notification

---

## Sample Rule Set for New Advertisers

**Start with these 4 rules:**

1. **Kill Zero Converters**
   - Turn off ads with 0 results AND $50+ spend (last 3 days)

2. **Alert High CPA**
   - Notify when CPA > target AND results > 5 (last 3 days)

3. **Alert Winners**
   - Notify when CPA < 70% of target AND results > 10 (last 7 days)

4. **Frequency Warning**
   - Notify when frequency > 3 AND CTR declining (last 7 days)

**Then add scaling rules once you're comfortable.**

---

*Back to: [SKILL.md](../SKILL.md)*
