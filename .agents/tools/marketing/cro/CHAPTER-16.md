# Chapter 16: Advanced CRO Analytics and Attribution

## 10.1 Multi-Touch Attribution Models

Understanding how different marketing touchpoints contribute to conversions is essential for accurate CRO analysis. While last-click attribution dominated early digital marketing, sophisticated businesses now recognize that customer journeys are complex and non-linear.

### The Attribution Challenge

Consider a typical B2B software purchase journey:
1. Discovers product through LinkedIn sponsored content
2. Reads blog post from organic search
3. Downloads whitepaper after email nurture
4. Attends webinar from retargeting ad
5. Visits pricing page directly
6. Requests demo after sales outreach
7. Converts after personalized email sequence

Last-click attribution gives 100% credit to the final email. First-touch gives 100% credit to LinkedIn. Both miss the complex reality.

### Attribution Model Types

**First-Touch Attribution**
Credits the initial discovery channel. Useful for understanding top-of-funnel effectiveness and brand awareness campaigns. Formula: 100% credit to first interaction.

Limitations: Ignores nurturing and conversion optimization efforts. Overvalues awareness channels.

**Last-Touch Attribution**  
Credits the final interaction before conversion. Default in most analytics platforms.

Limitations: Overvalues bottom-funnel tactics. Undervalues awareness and consideration efforts.

**Linear Attribution**
Distributes credit equally across all touchpoints. Recognizes the full customer journey.

Formula: Credit = 100% / Number of touchpoints

Example: 5 touchpoints = 20% credit each

**Time-Decay Attribution**
Gives more credit to recent touchpoints. Acknowledges recency bias in decision-making.

Formula: Credit = Base^(Days from conversion / Half-life)

Common half-life: 7 days

**Position-Based (U-Shaped)**
40% credit to first touch, 40% to last touch, 20% distributed among middle touches.

Best for: B2B with defined sales cycles, considered purchases.

**Data-Driven Attribution**
Uses machine learning to calculate actual incremental impact based on path analysis.

Requirements: Minimum 300 conversions per month, 3,000+ path interactions, 90 days historical data.

### Implementing Data-Driven Attribution

**Google Analytics 4 Setup:**
```javascript
// Enable data-driven attribution in GA4
gtag('config', 'GA_MEASUREMENT_ID', {
  'allow_ad_personalization_signals': true,
  'transport_type': 'beacon'
});

// Track custom events with attribution
function trackConversion(eventName, value) {
  gtag('event', eventName, {
    'value': value,
    'currency': 'USD',
    'transaction_id': generateTransactionId()
  });
}
```

**Attribution Path Analysis:**
```sql
-- BigQuery path analysis query
WITH user_paths AS (
  SELECT
    user_pseudo_id,
    STRING_AGG(channel, ' > ' ORDER BY event_timestamp) AS path,
    MAX(CASE WHEN event_name = 'purchase' THEN 1 ELSE 0 END) AS converted
  FROM `project.dataset.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20240101' AND '20240131'
  GROUP BY user_pseudo_id
)
SELECT
  path,
  COUNT(*) AS users,
  SUM(converted) AS conversions,
  AVG(converted) AS conversion_rate
FROM user_paths
WHERE path IS NOT NULL
GROUP BY path
HAVING COUNT(*) > 10
ORDER BY conversions DESC
LIMIT 100;
```

## 10.2 Incrementality Testing

Attribution assigns credit. Incrementality measures causal impact. Both are necessary for complete CRO analysis.

### What Is Incrementality?

Incrementality answers: "What would have happened without this marketing activity?"

**Example:**
- Attribution: User clicked Facebook ad, then bought
- Incrementality: User exposed to Facebook ad bought vs. similar user not exposed didn't buy

### Geo-Lift Testing

**Methodology:**
1. Select geographically isolated test and control markets
2. Ensure markets match on key characteristics
3. Run campaign in test markets only
4. Compare conversion lift

**Market Selection Criteria:**
- Population demographics match
- Historical sales patterns similar
- No cross-market contamination
- Sufficient sample size (minimum 5 markets per group)

**Statistical Design:**
```python
import numpy as np
from scipy import stats

def calculate_geo_lift(test_sales, control_sales, test_baseline, control_baseline):
    """
    Calculate lift using difference-in-differences with proper variance estimation.
    
    Args:
        test_sales: Array of per-market sales in treatment group during test period
        control_sales: Array of per-market sales in control group during test period
        test_baseline: Array of per-market sales in treatment group during baseline period
        control_baseline: Array of per-market sales in control group during baseline period
    """
    # Calculate per-market change scores (DiD approach)
    test_change = np.array(test_sales) - np.array(test_baseline)
    control_change = np.array(control_sales) - np.array(control_baseline)
    
    # True lift is difference in differences
    lift = np.mean(test_change) - np.mean(control_change)
    
    # Standard error of the difference in differences
    se_test = np.std(test_change, ddof=1) / np.sqrt(len(test_change))
    se_control = np.std(control_change, ddof=1) / np.sqrt(len(control_change))
    pooled_se = np.sqrt(se_test**2 + se_control**2)
    
    t_stat = lift / pooled_se
    df = len(test_change) + len(control_change) - 2
    p_value = 2 * (1 - stats.t.cdf(abs(t_stat), df=df))
    
    return {
        'lift': lift,
        'lift_percent': (lift / np.mean(test_baseline)) * 100,
        't_statistic': t_stat,
        'p_value': p_value,
        'significant': p_value < 0.05
    }
```

### Conversion Lift Studies

**Facebook Conversion Lift:**
1. Create lift study in Ads Manager
2. Select campaign and conversion event
3. Facebook creates holdout group (not shown ads)
4. Run for minimum 2 weeks
5. Measure incremental conversions

**Google Ads Lift Studies:**
- Available for YouTube, Display, Discovery campaigns
- Requires minimum 4,000 eligible users per group
- 2-4 week test duration recommended

### Holdout Testing Best Practices

**Test Design:**
- Random assignment to test/control
- Minimum 80% statistical power
- 95% confidence level
- Account for seasonality

**Common Pitfalls:**
- Network effects between groups
- Insufficient sample size
- Short test duration
- Selection bias in assignment

## 10.3 Marketing Mix Modeling (MMM)

MMM analyzes aggregate data to understand marketing impact on business outcomes.

### When to Use MMM

- Offline marketing measurement (TV, radio, print)
- Strategic budget allocation
- Long-term planning
- When user-level tracking is limited

### Data Requirements

**Minimum 2 years of historical data:**
- Weekly or monthly sales/conversions
- Marketing spend by channel
- External factors (promotions, seasonality)
- Economic indicators

### Model Structure

**Key Components:**

1. **Adstock (Carryover Effects)**
   Marketing impact persists beyond the spend period.
   
   Formula: A_t = S_t + λ × A_{t-1}
   
   Where λ = decay rate (typically 0.3-0.8)

2. **Saturation (Diminishing Returns)**
   Additional spend yields decreasing returns.
   
   Formula: Response = Spend^α / (Spend^α + γ^α)

3. **Seasonality**
   Regular patterns in consumer behavior.

4. **Trend**
   Long-term growth or decline.

**Python Implementation:**
```python
import pandas as pd
import numpy as np
import statsmodels.api as sm

def apply_adstock(spend, decay_rate=0.5):
    """Apply adstock transformation"""
    adstocked = np.zeros(len(spend))
    adstocked[0] = spend[0]
    
    for t in range(1, len(spend)):
        adstocked[t] = spend[t] + decay_rate * adstocked[t-1]
    
    return adstocked

def hill_function(x, alpha=2, gamma=0.5):
    """Apply saturation curve"""
    return x**alpha / (x**alpha + gamma**alpha)

# Build MMM
df['tv_adstock'] = apply_adstock(df['tv_spend'], 0.3)
df['digital_adstock'] = apply_adstock(df['digital_spend'], 0.1)

X = df[['tv_adstock', 'digital_adstock', 'price', 'promo']]
X = sm.add_constant(X)
y = df['sales']

model = sm.OLS(y, X).fit()
print(model.summary())
```

### MMM Output Interpretation

**Response Curves:**
Show how sales respond to spend at different levels.

**ROAS by Channel:**
Return on ad spend calculated from model coefficients.

**Optimal Budget Allocation:**
Mathematical optimization to maximize revenue or conversions.

### Modern Bayesian MMM

**Robyn (Meta's Open Source MMM):**
```python
from robyn import Robyn

robyn = Robyn(country='US', date_var='date', 
              dep_var='revenue', dep_var_type='revenue')

robyn.set_media(var_name='facebook_spend', 
                spend_name='facebook_spend', media_type='paid')
robyn.set_media(var_name='google_spend', 
                spend_name='google_spend', media_type='paid')

robyn.set_prophet(country='US', seasonality=True, holiday=True)

robyn.fit(df)
```

## 10.4 Advanced Segmentation for CRO

### Behavioral Segmentation

Segment users based on actions, not demographics.

**RFM Analysis:**
- Recency: How recently did they purchase?
- Frequency: How often do they purchase?
- Monetary: How much do they spend?

**Implementation:**
```python
def calculate_rfm_scores(df):
    """
    Calculate RFM scores (1-5 scale)
    """
    from datetime import datetime, timedelta
    
    # Calculate metrics
    snapshot_date = df['purchase_date'].max() + timedelta(days=1)
    
    rfm = df.groupby('customer_id').agg({
        'purchase_date': lambda x: (snapshot_date - x.max()).days,
        'order_id': 'count',
        'amount': 'sum'
    }).reset_index()
    
    rfm.columns = ['customer_id', 'recency', 'frequency', 'monetary']
    
    # Calculate quintiles (1-5 scores)
    rfm['r_score'] = pd.qcut(rfm['recency'], 5, labels=[5,4,3,2,1])
    rfm['f_score'] = pd.qcut(rfm['frequency'].rank(method='first'), 5, labels=[1,2,3,4,5])
    rfm['m_score'] = pd.qcut(rfm['monetary'], 5, labels=[1,2,3,4,5])
    
    # Combined RFM score
    rfm['rfm_score'] = (rfm['r_score'].astype(str) + 
                        rfm['f_score'].astype(str) + 
                        rfm['m_score'].astype(str))
    
    return rfm
```

**Segment Strategies:**

| Segment | RFM Score | Strategy |
|---------|-----------|----------|
| Champions | 555, 554, 544 | Reward, early access |
| Loyal Customers | 543, 444, 435 | Upsell, referral |
| Potential Loyalists | 512, 511, 412 | Nurture, membership |
| New Customers | 511, 411 | Onboard, welcome series |
| At Risk | 155, 144, 214 | Re-engage, win-back |
| Lost | 111, 112, 121 | Revive or remove |

### Intent-Based Segmentation

Segment based on where users are in the buying journey.

**Intent Signals:**
- Page views (pricing, features, case studies)
- Content downloads (topical interest)
- Engagement depth (scroll, time on site)
- Return frequency
- Email engagement

**Implementation:**
```javascript
// Intent scoring system
const intentSignals = {
  pricingPageView: 10,
  demoRequest: 50,
  caseStudyDownload: 15,
  comparisonPage: 20,
  pricingCalculator: 25,
  freeTrialStart: 45,
  multipleSessions: 5,
  longSession: 5,
  emailClick: 3,
  pricingEmailOpen: 8
};

function calculateIntentScore(userActions) {
  return userActions.reduce((score, action) => {
    return score + (intentSignals[action] || 0);
  }, 0);
}

// Segment thresholds
const segments = {
  hot: { min: 75, action: 'sales_alert' },
  warm: { min: 40, action: 'nurture_sequence' },
  cold: { min: 0, action: 'education_content' }
};
```

### Cohort Analysis

Analyze behavior of users acquired in the same time period.

**Cohort Metrics:**
- Retention rate by cohort
- Revenue per cohort
- Conversion rate progression
- Time to first purchase

**Cohort Table:**
```
        Month 0   Month 1   Month 2   Month 3
Jan     100%      45%       38%       32%
Feb     100%      42%       35%       29%
Mar     100%      48%       41%       -
Apr     100%      44%       -         -
```

**Python Implementation:**
```python
def create_cohort_table(df, period='M'):
    """
    Create cohort retention table
    """
    from operator import attrgetter
    # Get first purchase date for each customer
    df['first_purchase'] = df.groupby('customer_id')['purchase_date'].transform('min')
    
    # Create period columns
    df['cohort'] = df['first_purchase'].dt.to_period(period)
    df['period'] = df['purchase_date'].dt.to_period(period)
    
    # Calculate period number
    df['period_number'] = (df['period'] - df['cohort']).apply(attrgetter('n'))
    
    # Create cohort table
    cohort_data = df.groupby(['cohort', 'period_number'])['customer_id'].nunique().reset_index()
    cohort_sizes = df.groupby('cohort')['customer_id'].nunique()
    
    cohort_table = cohort_data.pivot(index='cohort', 
                                     columns='period_number', 
                                     values='customer_id')
    
    # Calculate retention percentages
    retention = cohort_table.divide(cohort_sizes, axis=0)
    
    return retention
```

## 10.5 Predictive Analytics for CRO

### Conversion Probability Scoring

Predict likelihood of conversion using machine learning.

**Features to Include:**
- Behavioral: pages viewed, time on site, scroll depth
- Demographic: location, device, referrer
- Historical: previous visits, email engagement
- Contextual: time of day, day of week, seasonality

**Model Implementation:**
```python
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report

# Prepare features
features = [
    'pages_viewed', 'time_on_site', 'scroll_depth',
    'return_visitor', 'email_engagement_score',
    'pricing_page_viewed', 'demo_requested',
    'device_type', 'traffic_source'
]

X = df[features]
y = df['converted']

# Split data
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2)

# Train model
model = RandomForestClassifier(n_estimators=100, max_depth=10)
model.fit(X_train, y_train)

# Predict probabilities
probabilities = model.predict_proba(X_test)[:, 1]

# Feature importance
importance = pd.DataFrame({
    'feature': features,
    'importance': model.feature_importances_
}).sort_values('importance', ascending=False)
```

### Churn Prediction

Identify users at risk of churning before they leave.

**Churn Signals:**
- Decreased engagement
- Support ticket frequency
- Failed payment attempts
- Feature usage decline
- Competitor research activity

**Intervention Strategies:**
- Proactive outreach
- Special offers
- Product education
- Win-back campaigns

### Lifetime Value Prediction

Predict customer LTV for better acquisition decisions.

**Simple LTV Formula:**
```
LTV = Average Order Value × Purchase Frequency × Customer Lifespan
```

**Predictive LTV:**
```python
def predict_ltv(customer_data, model):
    """
    Predict lifetime value using trained model
    """
    # Features: acquisition channel, first purchase amount,
    # first purchase category, demographic data
    
    predicted_ltv = model.predict(customer_data)
    
    return predicted_ltv

# Use for acquisition optimization
channels = ['paid_social', 'paid_search', 'organic', 'referral']

for channel in channels:
    customers = get_customers_by_channel(channel)
    avg_ltv = predict_ltv(customers, model).mean()
    cac = get_customer_acquisition_cost(channel)
    
    roi = (avg_ltv - cac) / cac
    print(f"{channel}: LTV=${avg_ltv:.0f}, CAC=${cac:.0f}, ROI={roi:.1f}x")
```

## 10.6 Statistical Methods for CRO

### A/B Test Sample Size Calculation

**Required Parameters:**
- Baseline conversion rate
- Minimum detectable effect (MDE)
- Statistical significance (alpha)
- Statistical power (1-beta)

**Formula:**
```python
import scipy.stats as stats
import math

def sample_size_per_variant(baseline_rate, mde, alpha=0.05, power=0.8):
    """
    Calculate required sample size per variant.
    
    Args:
        baseline_rate: Current conversion rate (e.g., 0.02 for 2%)
        mde: Minimum detectable effect as relative lift (e.g., 0.15 for 15%
             relative increase, yielding p2 = baseline_rate * (1 + mde))
        alpha: Significance level (default 0.05)
        power: Statistical power (default 0.8)
    """
    p1 = baseline_rate
    p2 = baseline_rate * (1 + mde)
    
    z_alpha = stats.norm.ppf(1 - alpha/2)
    z_beta = stats.norm.ppf(power)
    
    pooled_p = (p1 + p2) / 2
    
    n = ((z_alpha * math.sqrt(2 * pooled_p * (1 - pooled_p)) +
          z_beta * math.sqrt(p1 * (1 - p1) + p2 * (1 - p2))) ** 2) / (p1 - p2) ** 2
    
    return math.ceil(n)

# Example
sample_size = sample_size_per_variant(
    baseline_rate=0.02,  # 2%
    mde=0.15,            # 15% relative lift
    alpha=0.05,
    power=0.8
)

print(f"Required sample size per variant: {sample_size:,}")
```

### Sequential Testing

Stop tests early when significance is reached, without inflating false positive rate.

**Benefits:**
- Faster decisions
- Reduced opportunity cost
- Lower traffic requirements

**Implementation:**
```python
from scipy import stats

def sequential_test_boundary(alpha=0.05, max_samples=10000):
    """
    Calculate stopping boundaries for sequential test
    """
    # Simple O'Brien-Fleming boundary approximation
    z_values = []
    
    for n in range(100, max_samples + 1, 100):
        # Boundary becomes less strict as sample grows
        boundary = stats.norm.ppf(1 - alpha/2) * math.sqrt(max_samples / n)
        z_values.append((n, boundary))
    
    return z_values
```

### Bayesian A/B Testing

Use Bayesian methods for more intuitive test interpretation.

**Advantages:**
- Direct probability statements ("B beats A with 95% probability")
- Incorporate prior knowledge
- Smaller sample sizes often needed

**Implementation:**
```python
import numpy as np
from scipy import stats

def bayesian_ab_test(a_conversions, a_visitors, b_conversions, b_visitors, 
                     prior_alpha=1, prior_beta=1):
    """
    Bayesian A/B test with Beta priors
    """
    # Posterior distributions
    a_posterior = stats.beta(prior_alpha + a_conversions, 
                             prior_beta + a_visitors - a_conversions)
    b_posterior = stats.beta(prior_alpha + b_conversions, 
                             prior_beta + b_visitors - b_conversions)
    
    # Monte Carlo simulation
    n_samples = 100000
    a_samples = a_posterior.rvs(n_samples)
    b_samples = b_posterior.rvs(n_samples)
    
    # Probability B beats A
    prob_b_better = np.mean(b_samples > a_samples)
    
    # Expected lift
    lift = (b_samples - a_samples) / a_samples
    expected_lift = np.mean(lift)
    lift_ci = np.percentile(lift, [2.5, 97.5])
    
    return {
        'prob_b_better': prob_b_better,
        'expected_lift': expected_lift,
        'lift_ci': lift_ci
    }
```

## 10.7 Dashboards and Reporting

### CRO Dashboard Design

**Key Metrics to Track:**

1. **Conversion Metrics**
   - Overall conversion rate
   - Funnel step conversion rates
   - Revenue per visitor
   - Average order value

2. **Test Metrics**
   - Tests running
   - Tests completed
   - Win rate
   - Revenue impact

3. **User Behavior**
   - Bounce rate
   - Pages per session
   - Average session duration
   - Exit rate by page

**Dashboard Tools:**
- Google Data Studio (free)
- Tableau (enterprise)
- Looker (enterprise)
- Power BI (Microsoft ecosystem)
- Custom dashboards (React + D3.js)

### Automated Reporting

**Weekly CRO Report:**
```
1. Executive Summary
   - Revenue impact from CRO this week
   - Active tests and their status
   - Key insights and recommendations

2. Test Results
   - Completed tests with results
   - Statistical significance
   - Revenue impact calculations

3. Funnel Analysis
   - Conversion rates by step
   - Week-over-week changes
   - Identified friction points

4. Next Week's Plan
   - Tests launching
   - Priorities
   - Resource needs
```

**Automated Email Report:**
```python
def generate_weekly_report():
    """
    Generate and send automated CRO report
    """
    report_data = {
        'revenue_impact': calculate_revenue_impact(),
        'active_tests': get_active_tests(),
        'completed_tests': get_completed_tests_this_week(),
        'funnel_metrics': get_funnel_metrics(),
        'top_opportunities': get_top_opportunities()
    }
    
    # Generate visualizations
    charts = create_report_charts(report_data)
    
    # Send email
    send_report_email(
        to=['cro-team@company.com', 'leadership@company.com'],
        subject='Weekly CRO Report',
        body=render_email_template(report_data),
        attachments=charts
    )
```

This chapter covers the advanced analytics and attribution methodologies essential for sophisticated CRO programs. Mastering these techniques enables data-driven decision-making and accurate measurement of optimization impact.
