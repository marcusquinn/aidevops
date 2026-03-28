# First-Party Data Strategies

Third-party data is unreliable (iOS 14+ ATT 80%+ opt-out, cookie deprecation, GDPR consent, browser tracking prevention). Your own data is the competitive advantage.

---

## Customer List Strategies

### Data to Collect

| Field | Priority | Why |
|-------|----------|-----|
| Email | Mandatory | Primary match key |
| Phone | Highly recommended | +10-20% match rate |
| Name | Recommended | Improves matching |
| Purchase history | Recommended | Segmentation |
| Engagement data | Recommended | Targeting |

**Collection points:** Purchase/checkout, account creation, newsletter signup, lead magnets, webinars, support interactions.

### Segmentation for Targeting

#### Value-Based Segments

| Segment | Definition | Use for | Message | Notes |
|---------|-----------|---------|---------|-------|
| VIP | Top 20% by LTV | Lookalike source | Exclusive offers, early access | Exclude from discount campaigns |
| Regular | 60-80th percentile | Upsell campaigns | Product education | Include in retention campaigns |
| Low-Value | Bottom 20% | Lookalike exclusion | Activation campaigns | May not be worth retargeting cost |

#### Behavioral Segments

| Segment | Definition | Action | Message |
|---------|-----------|--------|---------|
| Recent Buyers | 0-30 days | Exclude from acquisition | Upsell, review request |
| Active Customers | Bought 2+ times | Loyalty campaigns, best lookalike source | Loyalty offers |
| Lapsed | No purchase 90+ days | Win-back campaigns | "We miss you" + incentive |
| At-Risk | Showing churn signals | Retention campaigns | Value reminder, support offer |

#### Lifecycle Segments

| Segment | Message | Goal |
|---------|---------|------|
| Leads (no purchase) | Conversion-focused, first-purchase incentive | Convert |
| First-Time Buyers | Onboarding, education | Second purchase |
| Repeat Customers | Loyalty, referral | Increase frequency |
| Champions (high frequency + value) | VIP treatment | Advocacy, referrals |

---

## Email List Segmentation for Ads

### Upload Targeted Segments, Not Your Entire List

| Segment | Size | Purpose |
|---------|------|---------|
| Customers - High LTV | 500-2000 | Best lookalike source |
| Customers - All | All | Exclusion, retention |
| Leads - Engaged | Recent openers/clickers | Conversion campaigns |
| Leads - Cold | No engagement 90d | Re-engagement |
| Trial Users | Active trials | Conversion campaigns |

### Match Rate Optimization

1. **Use Business Emails** — higher match than personal
2. **Include Phone Numbers** — +10-20% match
3. **Add Name + Location** — +5-10% match
4. **Hash Before Upload** — Meta does this, but you can pre-hash
5. **Clean Your List** — remove bounces, invalid addresses

### Update Frequency

| Segment Type | Frequency |
|--------------|-----------|
| Dynamic (recent activity) | Weekly |
| Static (all customers) | Monthly |
| Lookalike source | Monthly |
| Exclusions | Weekly |

---

## Purchase Behavior Targeting

### RFM Analysis (Recency, Frequency, Monetary)

| Segment | Recency | Frequency | Monetary | Action |
|---------|---------|-----------|----------|--------|
| Champions | Recent | High | High | Lookalike, advocacy |
| Loyal | Recent | High | Medium | Upsell |
| Recent | Very recent | Low | Low | Convert to repeat |
| At Risk | Not recent | High | High | Win-back |
| Lost | Old | Low | Low | Consider excluding |

### Product-Based Targeting

**Cross-sell:** Create custom audience of Product A buyers → exclude Product B buyers → target with Product B ads.

**Category-based:** Bought from Category X → target related categories ("You might also like...").

### LTV-Based Lookalike Audiences

1. Export customers with LTV values
2. Create Customer List with Value column
3. Create Value-Based Lookalike
4. Meta weights by customer value → finds people similar to **best** customers, not just any customers → higher predicted LTV

---

## CRM Integration

### Syncing Data to Meta

| Method | Complexity | Real-Time |
|--------|------------|-----------|
| Manual CSV Upload | Easy | No |
| Zapier/Make | Medium | Near |
| Native Integration | Varies | Yes/Near |
| Custom API | Hard | Yes |

### Popular Integrations

| Platform | Integration | Syncs |
|----------|-------------|-------|
| HubSpot | Native Meta integration | Contact lists, events, conversions |
| Salesforce | API or third-party | Lead status, opportunities, closed-won |
| Klaviyo | Native Meta integration | Segments, purchase events |
| Segment | Meta Destination | All events, audiences |

### Offline Conversion Tracking

Send offline conversions (phone calls, in-store) to Meta:

1. Collect customer email/phone at conversion
2. Match to Facebook user
3. Send offline conversion event
4. Meta learns what converts → optimizes for real conversions, better lookalikes, true ROAS measurement

---

## Privacy Compliance

### Consent Requirements

**GDPR (EU):** Explicit consent for marketing, right to be forgotten, data portability.

**CCPA (California):** Opt-out right, disclosure of data collection, non-discrimination.

**Best practice:** Get clear consent at collection, document consent, honor opt-out requests, update suppression lists.

### Suppression Lists

**Who to suppress:** Unsubscribed from marketing, requested deletion, opted out of advertising, compliance/legal requirements.

**Implementation:**

1. Maintain suppression list in CRM
2. Upload as Custom Audience
3. Apply as exclusion to ALL campaigns
4. Update weekly

---

## Data Quality

### List Hygiene

**Regular cleaning:** Remove bounced emails, verify phone formats, deduplicate, standardize formatting.

**Formatting standards:**

| Field | Format |
|-------|--------|
| Email | lowercase, trim whitespace |
| Phone | +1XXXXXXXXXX |
| Name | Title case |
| Country | ISO 2-letter code |

### Data Enrichment

**B2B enrichment tools:** Clearbit (company data), ZoomInfo (contacts), FullContact (consumer profiles).

**What to enrich:** Company size, industry, job title, social profiles.

---

*Back to: [meta-ads.md](meta-ads.md)*
