# Automated Rules

Rules that automatically take action based on conditions you define (turn ads on/off, adjust budgets, send notifications).

**Access:** Ads Manager → Rules → Create Rule

---

## Essential Rules

### Rule 1: Kill High-CPA Ads

```
Apply to: All active ads | Action: Turn off
Condition: Cost per result > 2x target CPA AND Impressions > 1000
Time: Last 7 days | Schedule: Continuously
```

### Rule 2: Kill Zero-Conversion Spenders

```
Apply to: All active ads | Action: Turn off
Condition: Results < 1 AND Amount spent > 2x target CPA
Time: Last 3 days | Schedule: Daily 8 AM
```

### Rule 3: Scale Winners

```
Apply to: All active ad sets | Action: Increase daily budget 20%
Condition: Cost per result < 80% of target CPA AND Results > 10
Time: Last 3 days | Schedule: Daily 12 AM | Cap: your max budget
```

### Rule 4: Pause Fatigued Creatives

```
Apply to: All active ads | Action: Turn off
Condition: Frequency > 3.5 AND CTR (link) < 0.8%
Time: Last 7 days | Schedule: Continuously
```

### Rule 5: Decrease Budget for Rising CPA

```
Apply to: All active ad sets | Action: Decrease daily budget 25%
Condition: Cost per result > 1.5x target CPA AND Results > 5
Time: Last 3 days | Schedule: Daily 12 AM | Floor: $20/day
```

### Rule 6: Notify on Low Performance

```
Apply to: All active campaigns | Action: Send notification
Condition: Cost per result > target CPA AND Results > 20
Time: Last 3 days | Schedule: Daily 9 AM
```

---

## Rule Templates by Campaign Type

### Testing Campaigns (ABO)

```
Kill losers: Turn off ads where CPA > 1.5x target AND Impressions > 2000 (last 3 days)
Identify winners: Notify when CPA < target AND Results > 10 (last 3 days)
```

### Scaling Campaigns (CBO)

```
Auto-scale: Increase budget 15% when CPA < 80% of target AND ROAS > target AND Results > 20
            (last 7 days, cap $1000/day)
Protect:    Decrease budget 20% when CPA > 1.3x target AND Results > 10 (last 3 days, floor $100/day)
```

### Retargeting Campaigns

```
Frequency control: Turn off ad sets where Frequency > 5 AND CTR declining >20% (last 7 days)
Keep performers:   Notify when ROAS > 3x AND Results > 15 (last 7 days)
```

---

## Advanced Strategies

### Tiered Budget Rules

| Tier | Condition | Action |
|------|-----------|--------|
| Aggressive scale | CPA < 50% of target AND >20 conversions | +30% budget |
| Moderate scale | CPA < 80% of target AND >10 conversions | +15% budget |
| Maintenance | CPA 80–100% of target | No change |
| Defensive | CPA 100–130% of target | −15% budget |
| Kill | CPA > 130% of target | Turn off |

### Dayparting

```
Turn off: Daily at 11 PM | Turn on: Daily at 6 AM
```
Only useful if data confirms specific hours underperform.

### Weekly Reset

```
Turn off ads where CTR < 0.5% AND Impressions > 5000 (last 14 days)
Schedule: Every Sunday 11 PM
```

---

## Best Practices

**Do:** Start conservative. Use notifications before automating. Require minimum data thresholds. Set budget caps and floors. Review rule history monthly. Combine with manual judgment.

**Don't:** Over-automate (rules conflict). Use 1-day time ranges (too noisy). Set and forget scaling rules (overspend risk). Apply rules during learning phase.

---

## Monitoring

**Check rule history:** Ads Manager → Rules → select rule → Activity tab.

**Monthly audit questions:** Are rules firing appropriately? Any false positives (good ads killed)? False negatives (bad ads surviving)? Do thresholds need adjustment?

---

## Configuration Reference

**Conditions:** Results, Cost per result, ROAS, Impressions, Reach, Frequency, Clicks, CTR, CPC, Amount spent

**Time ranges:** Today, Yesterday, Last 3/7/14/30 days, Lifetime

**Actions by level:**
- Ad: Turn on/off, Send notification
- Ad set: Turn on/off, Increase/decrease daily or lifetime budget, Send notification
- Campaign: Turn on/off, Increase/decrease daily budget, Send notification

---

## Starter Set for New Advertisers

Begin with notifications only — understand patterns before automating actions:

1. **Kill zero converters** — Turn off ads: 0 results AND $50+ spend (last 3 days)
2. **Alert high CPA** — Notify: CPA > target AND results > 5 (last 3 days)
3. **Alert winners** — Notify: CPA < 70% of target AND results > 10 (last 7 days)
4. **Frequency warning** — Notify: frequency > 3 AND CTR declining (last 7 days)

Add scaling rules once you're comfortable with how rules behave.

---

*Back to: [meta-ads.md](meta-ads.md)*
