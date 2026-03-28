# Chapter 16: Advanced CRO Analytics and Attribution

## 10.1 Multi-Touch Attribution Models

| Model | Credit Distribution | Best For | Limitation |
|-------|-------------------|----------|------------|
| First-Touch | 100% to first interaction | Top-of-funnel analysis | Ignores nurturing |
| Last-Touch | 100% to final interaction | Default in most platforms | Undervalues awareness |
| Linear | Equal across all touchpoints | Full journey recognition | No weighting |
| Time-Decay | More to recent touches (half-life ~7 days) | Recency-sensitive | Undervalues awareness |
| Position-Based (U-Shaped) | 40% first, 40% last, 20% middle | B2B sales cycles | Arbitrary weighting |
| Data-Driven | ML-calculated incremental impact | Mature (300+ conv/mo, 3K+ paths, 90d) | High data requirements |

### Data-Driven Attribution: GA4 + BigQuery

```javascript
gtag('config', 'GA_MEASUREMENT_ID', {
  'allow_ad_personalization_signals': true,
  'transport_type': 'beacon'
});
function trackConversion(eventName, value) {
  gtag('event', eventName, {
    'value': value, 'currency': 'USD',
    'transaction_id': generateTransactionId()
  });
}
```

```sql
-- BigQuery path analysis
WITH user_paths AS (
  SELECT user_pseudo_id,
    STRING_AGG(channel, ' > ' ORDER BY event_timestamp) AS path,
    MAX(CASE WHEN event_name = 'purchase' THEN 1 ELSE 0 END) AS converted
  FROM `project.dataset.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20240101' AND '20240131'
  GROUP BY user_pseudo_id
)
SELECT path, COUNT(*) AS users, SUM(converted) AS conversions,
  AVG(converted) AS conversion_rate
FROM user_paths
WHERE path IS NOT NULL
GROUP BY path HAVING COUNT(*) > 10
ORDER BY conversions DESC LIMIT 100;
```

## 10.2 Incrementality Testing

Incrementality measures causal impact — "What would have happened without this activity?" Attribution assigns credit; incrementality proves causation.

### Geo-Lift Testing

Select matched test/control markets (min 5/group), run campaign in test only, compare lift. Match on: demographics, historical sales, no cross-market contamination, sufficient sample size.

```python
import numpy as np
from scipy import stats

def calculate_geo_lift(test_sales, control_sales, test_baseline, control_baseline):
    """Difference-in-differences lift calculation."""
    test_change = np.array(test_sales) - np.array(test_baseline)
    control_change = np.array(control_sales) - np.array(control_baseline)
    lift = np.mean(test_change) - np.mean(control_change)
    se_test = np.std(test_change, ddof=1) / np.sqrt(len(test_change))
    se_control = np.std(control_change, ddof=1) / np.sqrt(len(control_change))
    pooled_se = np.sqrt(se_test**2 + se_control**2)
    t_stat = lift / pooled_se
    df = len(test_change) + len(control_change) - 2
    p_value = 2 * (1 - stats.t.cdf(abs(t_stat), df=df))
    return {'lift': lift, 'lift_percent': (lift / np.mean(test_baseline)) * 100,
            't_statistic': t_stat, 'p_value': p_value, 'significant': p_value < 0.05}
```

**Platform lift studies:** Facebook (Ads Manager → lift study → min 2 weeks), Google Ads (YouTube/Display/Discovery, min 4K users/group, 2-4 weeks).

**Holdout testing:** Random assignment, 80%+ power, 95% confidence, account for seasonality. Pitfalls: network effects, insufficient sample size, short duration, selection bias.

## 10.3 Marketing Mix Modeling (MMM)

**Use when:** Measuring offline channels, strategic budget allocation, limited user-level tracking. Requires 2+ years weekly/monthly data — sales, spend by channel, external factors.

**Model components:** (1) Adstock: A_t = S_t + λ × A_{t-1} (λ = 0.3-0.8), (2) Saturation: Response = Spend^α / (Spend^α + γ^α), (3) Seasonality + Trend.

```python
import numpy as np
import statsmodels.api as sm

def apply_adstock(spend, decay_rate=0.5):
    adstocked = np.zeros(len(spend))
    adstocked[0] = spend[0]
    for t in range(1, len(spend)):
        adstocked[t] = spend[t] + decay_rate * adstocked[t-1]
    return adstocked

def hill_function(x, alpha=2, gamma=0.5):
    return x**alpha / (x**alpha + gamma**alpha)

df['tv_adstock'] = apply_adstock(df['tv_spend'], 0.3)
df['digital_adstock'] = apply_adstock(df['digital_spend'], 0.1)
X = sm.add_constant(df[['tv_adstock', 'digital_adstock', 'price', 'promo']])
model = sm.OLS(df['sales'], X).fit()
```

**Bayesian MMM (Robyn):**

```python
from robyn import Robyn
robyn = Robyn(country='US', date_var='date', dep_var='revenue', dep_var_type='revenue')
robyn.set_media(var_name='facebook_spend', spend_name='facebook_spend', media_type='paid')
robyn.set_media(var_name='google_spend', spend_name='google_spend', media_type='paid')
robyn.set_prophet(country='US', seasonality=True, holiday=True)
robyn.fit(df)
```

**Key outputs:** Response curves (spend vs. sales), ROAS by channel, optimal budget allocation.

## 10.4 Advanced Segmentation for CRO

### RFM Analysis

```python
def calculate_rfm_scores(df):
    snapshot_date = pd.Timestamp(df['purchase_date'].max()) + pd.Timedelta(days=1)
    rfm = df.groupby('customer_id').agg({
        'purchase_date': lambda x: (snapshot_date - x.max()).days,
        'order_id': 'count', 'amount': 'sum'
    }).reset_index()
    rfm.columns = ['customer_id', 'recency', 'frequency', 'monetary']
    rfm['r_score'] = pd.qcut(rfm['recency'], 5, labels=[5,4,3,2,1])
    rfm['f_score'] = pd.qcut(rfm['frequency'].rank(method='first'), 5, labels=[1,2,3,4,5])
    rfm['m_score'] = pd.qcut(rfm['monetary'], 5, labels=[1,2,3,4,5])
    rfm['rfm_score'] = rfm['r_score'].astype(str) + rfm['f_score'].astype(str) + rfm['m_score'].astype(str)
    return rfm
```

| Segment | RFM Scores | Strategy |
|---------|-----------|----------|
| Champions | 555, 554, 544 | Reward, early access |
| Loyal | 543, 444, 435 | Upsell, referral |
| Potential Loyalists | 512, 511, 412 | Nurture, membership |
| New | 511, 411 | Onboard, welcome series |
| At Risk | 155, 144, 214 | Re-engage, win-back |
| Lost | 111, 112, 121 | Revive or remove |

### Intent-Based Segmentation

Score user actions to classify intent, then route to engagement:

| Signal | Score | Segment (threshold) | Action |
|--------|-------|---------------------|--------|
| Demo request | 50 | Hot (≥75) | Sales alert |
| Free trial start | 45 | Warm (40-74) | Nurture sequence |
| Pricing calculator | 25 | Cold (<40) | Education content |
| Comparison page | 20 | | |
| Case study download | 15 | | |
| Pricing page view | 10 | | |
| Pricing email open | 8 | | |
| Multiple/long sessions | 5 | | |
| Email click | 3 | | |

### Cohort Retention Analysis

```python
def create_cohort_table(df, period='M'):
    df['first_purchase'] = df.groupby('customer_id')['purchase_date'].transform('min')
    df['cohort'] = df['first_purchase'].dt.to_period(period)
    df['period'] = df['purchase_date'].dt.to_period(period)
    df['period_number'] = (df['period'] - df['cohort']).apply(lambda x: x.n)
    cohort_data = df.groupby(['cohort', 'period_number'])['customer_id'].nunique().reset_index()
    cohort_sizes = df.groupby('cohort')['customer_id'].nunique()
    cohort_table = cohort_data.pivot(index='cohort', columns='period_number', values='customer_id')
    return cohort_table.divide(cohort_sizes, axis=0)
```

## 10.5 Predictive Analytics for CRO

### Conversion Probability Scoring

```python
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import train_test_split

features = ['pages_viewed', 'time_on_site', 'scroll_depth', 'return_visitor',
            'email_engagement_score', 'pricing_page_viewed', 'demo_requested',
            'device_type', 'traffic_source']
X_train, X_test, y_train, y_test = train_test_split(df[features], df['converted'], test_size=0.2)
model = RandomForestClassifier(n_estimators=100, max_depth=10)
model.fit(X_train, y_train)
probabilities = model.predict_proba(X_test)[:, 1]
importance = pd.DataFrame({'feature': features, 'importance': model.feature_importances_}).sort_values('importance', ascending=False)
```

### Churn Prediction and LTV

**Churn signals:** Decreased engagement, support tickets, failed payments, feature usage decline, competitor research. **Interventions:** Proactive outreach, special offers, product education, win-back campaigns.

**LTV:** Average Order Value × Purchase Frequency × Customer Lifespan. Channel ROI comparison:

```python
for channel in ['paid_social', 'paid_search', 'organic', 'referral']:
    customers = get_customers_by_channel(channel)
    avg_ltv = model.predict(customers).mean()
    cac = get_customer_acquisition_cost(channel)
    print(f"{channel}: LTV=${avg_ltv:.0f}, CAC=${cac:.0f}, ROI={(avg_ltv - cac) / cac:.1f}x")
```

## 10.6 Statistical Methods for CRO

### A/B Test Sample Size

```python
import scipy.stats as stats
import math

def sample_size_per_variant(baseline_rate, mde, alpha=0.05, power=0.8):
    """baseline_rate: e.g. 0.02 for 2%. mde: relative lift e.g. 0.15 for 15%."""
    p1, p2 = baseline_rate, baseline_rate * (1 + mde)
    z_alpha, z_beta = stats.norm.ppf(1 - alpha/2), stats.norm.ppf(power)
    pooled_p = (p1 + p2) / 2
    n = ((z_alpha * math.sqrt(2 * pooled_p * (1 - pooled_p)) +
          z_beta * math.sqrt(p1 * (1 - p1) + p2 * (1 - p2))) ** 2) / (p1 - p2) ** 2
    return math.ceil(n)
```

### Sequential Testing (O'Brien-Fleming)

Stops tests early when significance is reached without inflating false positive rate:

```python
def sequential_test_boundary(alpha=0.05, max_samples=10000):
    return [(n, stats.norm.ppf(1 - alpha/2) * math.sqrt(max_samples / n))
            for n in range(100, max_samples + 1, 100)]
```

### Bayesian A/B Testing

Direct probability statements ("B beats A with 95% probability") with prior knowledge support.

```python
import numpy as np
from scipy import stats

def bayesian_ab_test(a_conv, a_vis, b_conv, b_vis, prior_a=1, prior_b=1):
    a_post = stats.beta(prior_a + a_conv, prior_b + a_vis - a_conv)
    b_post = stats.beta(prior_a + b_conv, prior_b + b_vis - b_conv)
    a_samples = a_post.rvs(100000)
    b_samples = b_post.rvs(100000)
    lift = (b_samples - a_samples) / a_samples
    return {'prob_b_better': np.mean(b_samples > a_samples),
            'expected_lift': np.mean(lift), 'lift_ci': np.percentile(lift, [2.5, 97.5])}
```

## 10.7 Dashboards and Reporting

| Category | Key Metrics |
|----------|------------|
| Conversion | Overall rate, funnel step rates, revenue/visitor, AOV |
| Testing | Active tests, completed, win rate, revenue impact |
| Behavior | Bounce rate, pages/session, session duration, exit rate by page |

**Automated weekly report components:** Revenue impact, active/completed tests, funnel metrics, top opportunities. Distribute to CRO team and leadership.
