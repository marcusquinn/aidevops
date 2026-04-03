# Chapter 21: CRO Testing Masterclass

## 21.1 Hypothesis Development

Structure: **IF** [change], **THEN** [expected result], **BECAUSE** [reasoning]

**Data sources:** Analytics drop-off points, heatmap clicks/scrolls, session recordings, user surveys, support tickets, competitor benchmarking

**Prioritization matrix:**

| Factor | Weight |
|--------|--------|
| Potential Impact | 30% |
| Ease of Implementation | 25% |
| Resource Requirements | 25% |
| Confidence | 20% |

## 21.2 Advanced Test Design

### Factorial Experiments

Test multiple variables simultaneously to detect interaction effects. Example (2×2×2 = 8 variations): Headline A/B × Image X/Y × CTA Red/Blue

| | |
|---|---|
| **Benefits** | Interaction effects, sample-efficient when interactions matter |
| **Challenges** | Complex analysis, more traffic required, implementation complexity |

### Bandit Algorithms

Dynamic traffic allocation to winning variations during the test.

**Epsilon-Greedy:** 90% traffic to current best, 10% exploration, adapts in real-time. Use for continuous optimization, long-running campaigns, seasonal adjustments.

## 21.3 Statistical Rigor

### Error Types

| Error | Definition | Control |
|-------|-----------|---------|
| Type I (False Positive) | Declaring winner when no real difference | Significance level α = 0.05 |
| Type II (False Negative) | Missing a real improvement | Power 1-β = 0.8 |

### Sequential Testing

Stop tests early **only with pre-specified stopping rules** — ad-hoc stopping inflates false positive rates.

**Valid early-stopping methods:**
- O'Brien-Fleming boundaries (conservative early, lenient late)
- Pocock boundaries (equal spending at each interim look)
- Always Valid P-values (anytime-valid inference)
- Alpha-spending functions (flexible interim analysis scheduling)

## 21.4 Test Analysis Deep Dive

### Segment-Level Analysis

**Dimensions:** Device type, traffic source, new vs returning, geography, browser

```sql
SELECT
  device_type,
  variation,
  COUNT(*) as users,
  SUM(converted) as conversions,
  AVG(converted) as conversion_rate
FROM test_data
WHERE test_id = 'TEST_001'
GROUP BY device_type, variation
```

### Cohort Analysis

Track how test effects change over time.

**Dimensions:** Day of week, week of test, acquisition cohort

**Interpret for:** Novelty effects (initial excitement), seasonality impacts, sustained vs temporary lift
