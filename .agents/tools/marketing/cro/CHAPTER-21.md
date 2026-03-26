# Chapter 21: CRO Testing Masterclass

## 21.1 Hypothesis Development

### The Hypothesis Framework

Every test should start with a clear hypothesis following this structure:

**IF** [change], **THEN** [expected result], **BECAUSE** [reasoning]

**Example:**
"IF we simplify the checkout form from 12 fields to 6 fields, THEN we will see a 15% increase in checkout completion, BECAUSE reducing friction removes barriers to purchase"

### Research-Driven Hypotheses

**Data Sources for Hypotheses:**
- Analytics data showing drop-off points
- Heatmap clicks and scrolls
- Session recording analysis
- User survey feedback
- Support ticket themes
- Competitor benchmarking

**Prioritization Matrix:**

| Factor | Weight | Score | Weighted |
|--------|--------|-------|----------|
| Potential Impact | 30% | 8 | 2.4 |
| Confidence | 20% | 7 | 1.4 |
| Ease of Implementation | 25% | 9 | 2.25 |
| Resource Requirements | 25% | 6 | 1.5 |
| **Total** | | | **7.55** |

## 21.2 Advanced Test Design

### Factorial Experiments

Test multiple variables simultaneously to understand interactions.

**Example: Landing Page Test**
Variables:
- Headline: A vs B
- Image: X vs Y
- CTA: Red vs Blue

Full factorial: 2 × 2 × 2 = 8 variations

**Benefits:**
- Detect interaction effects between variables
- Can be more sample-efficient than running many separate tests when interactions matter
- Comprehensive understanding of variable combinations

**Challenges:**
- Complex analysis
- More traffic required
- Implementation complexity

### Bandit Algorithms

Dynamic allocation of traffic to winning variations during the test.

**Epsilon-Greedy Algorithm:**
- 90% of traffic to current best
- 10% explores other options
- Adapts in real-time

**Use Cases:**
- Continuous optimization
- Long-running campaigns
- Seasonal adjustments

## 21.3 Statistical Rigor

### Type I and Type II Errors

**Type I Error (False Positive):**
- Declaring a winner when there is no real difference
- Controlled by significance level (α = 0.05)

**Type II Error (False Negative):**
- Missing a real improvement
- Controlled by power (1-β = 0.8)

### Sequential Testing

Stop tests early when significance is reached, but **only when using pre-specified stopping rules**. Ad-hoc stopping without proper error-control methods inflates false positive rates.

**Benefits:**
- Faster decisions when using valid stopping boundaries
- Lower opportunity cost
- Reduced sample size while maintaining statistical validity

**Methods (required for valid early stopping):**
- O'Brien-Fleming boundaries (conservative early, lenient late)
- Pocock boundaries (equal spending at each interim look)
- Always Valid P-values (anytime-valid inference)
- Alpha-spending functions (flexible interim analysis scheduling)

## 21.4 Test Analysis Deep Dive

### Segment-Level Analysis

**Dimensions to Analyze:**
- Device type (mobile vs desktop)
- Traffic source
- New vs returning
- Geographic location
- Browser type

**Implementation:**

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

Understand how test effects change over time.

**Cohort Dimensions:**
- Day of week
- Week of test
- Acquisition cohort

**Interpretation:**
- Novelty effects (initial excitement)
- Seasonality impacts
- Sustained vs temporary lift

This masterclass provides the advanced testing knowledge needed for enterprise CRO programs.
