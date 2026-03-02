# First-Party Data Strategies

> In a privacy-first world, your own data is your competitive advantage.

---

## Why First-Party Data Matters More Than Ever

### The Privacy Landscape

| Change | Impact |
|--------|--------|
| iOS 14+ ATT | 80%+ users opt out of tracking |
| Cookie deprecation | Third-party tracking dying |
| GDPR/Privacy laws | Consent requirements |
| Browser tracking prevention | Safari, Firefox block trackers |

**Result:** Third-party data is unreliable. Your data is gold.

---

## Customer List Strategies

### Building Your Customer Database

**Data to Collect:**
- Email (mandatory)
- Phone (highly recommended)
- Name (improves matching)
- Purchase history (for segmentation)
- Engagement data (for targeting)

**Collection Points:**
- Purchase/checkout
- Account creation
- Newsletter signup
- Lead magnets
- Webinars
- Support interactions

### Segmentation for Targeting

**Value-Based Segments:**
```
VIP Customers: Top 20% by LTV
├── Use for: Lookalike source
├── Message: Exclusive offers, early access
└── Exclude from: Discount campaigns

Regular Customers: 60-80 percentile
├── Use for: Upsell campaigns
├── Message: Product education
└── Include in: Retention campaigns

Low-Value Customers: Bottom 20%
├── Use for: Lookalike exclusion
├── Message: Activation campaigns
└── Consider: May not be worth retargeting cost
```

**Behavioral Segments:**
```
Recent Buyers (0-30 days)
├── Action: Exclude from acquisition
├── Target for: Upsell, review request

Active Customers (bought 2+ times)
├── Action: Loyalty campaigns
├── Use for: Best lookalike source

Lapsed Customers (no purchase 90+ days)
├── Action: Win-back campaigns
├── Message: "We miss you" + incentive

At-Risk (showing churn signals)
├── Action: Retention campaigns
├── Message: Value reminder, support offer
```

**Lifecycle Segments:**
```
Leads (no purchase yet)
├── Message: Conversion-focused
├── Offer: First-purchase incentive

First-Time Buyers
├── Message: Onboarding, education
├── Goal: Second purchase

Repeat Customers
├── Message: Loyalty, referral
├── Goal: Increase frequency

Champions (high frequency + value)
├── Message: VIP treatment
├── Goal: Advocacy, referrals
```

---

## Email List Segmentation for Ads

### Creating Effective Upload Segments

**Don't Upload Your Entire List**

Upload targeted segments for specific purposes:

| Segment | Size | Purpose |
|---------|------|---------|
| Customers - High LTV | 500-2000 | Best lookalike source |
| Customers - All | All | Exclusion, retention |
| Leads - Engaged | Recent openers/clickers | Conversion campaigns |
| Leads - Cold | No engagement 90d | Re-engagement |
| Trial Users | Active trials | Conversion campaigns |

### Match Rate Optimization

**To Improve Match Rates:**

1. **Use Business Emails** (higher match than personal)
2. **Include Phone Numbers** (+10-20% match)
3. **Add Name + Location** (+5-10% match)
4. **Hash Before Upload** (Meta does this, but you can too)
5. **Clean Your List** (remove bounces, invalid)

### Update Frequency

| Segment Type | Update Frequency |
|--------------|------------------|
| Dynamic (recent activity) | Weekly |
| Static (all customers) | Monthly |
| Looklalike source | Monthly |
| Exclusions | Weekly |

---

## Purchase Behavior Targeting

### RFM Analysis for Ads

**RFM = Recency, Frequency, Monetary**

```
Segment customers by:
- Recency: When did they last buy?
- Frequency: How often do they buy?
- Monetary: How much do they spend?
```

**Creating RFM Segments:**

| Segment | Recency | Frequency | Monetary | Action |
|---------|---------|-----------|----------|--------|
| Champions | Recent | High | High | Lookalike, advocacy |
| Loyal | Recent | High | Medium | Upsell |
| Recent | Very recent | Low | Low | Convert to repeat |
| At Risk | Not recent | High | High | Win-back |
| Lost | Old | Low | Low | Consider excluding |

### Product-Based Targeting

**Cross-Sell Audiences:**
```
Bought Product A → Show Product B
├── Create: Custom audience of Product A buyers
├── Exclude: Product B buyers
└── Target: Product B ads
```

**Category-Based:**
```
Bought from Category X
├── Target: Related categories
├── Message: "You might also like..."
```

### LTV-Based Audiences

**Value-Based Lookalikes:**
```
1. Export customers with LTV values
2. Create Customer List with Value column
3. Create Value-Based Lookalike
4. Meta weights by customer value
```

**Benefits:**
- Finds people similar to BEST customers
- Not just any customers
- Higher predicted LTV

---

## CRM Integration

### Syncing Data to Meta

**Integration Options:**
| Method | Complexity | Real-Time |
|--------|------------|-----------|
| Manual CSV Upload | Easy | No |
| Zapier/Make | Medium | Near |
| Native Integration | Varies | Yes/Near |
| Custom API | Hard | Yes |

### Popular Integrations

**HubSpot:**
```
HubSpot → Meta Integration
└── Sync: Contact lists, events, conversions
```

**Salesforce:**
```
Salesforce → Meta via API or third-party
└── Sync: Lead status, opportunities, closed-won
```

**Klaviyo:**
```
Klaviyo → Meta Native Integration
└── Sync: Segments, purchase events
```

**Segment:**
```
Segment → Meta Destination
└── Sync: All events, audiences
```

### Offline Conversion Tracking

**Sending Offline Events:**
When someone converts offline (phone call, in-store), send to Meta:

```
1. Collect: Customer email/phone at conversion
2. Match: To Facebook user
3. Send: Offline conversion event
4. Result: Meta learns what converts
```

**Benefits:**
- Algorithm optimizes for real conversions
- Better lookalike audiences
- True ROAS measurement

---

## Privacy Compliance

### Consent Requirements

**GDPR (EU):**
- Explicit consent for marketing
- Right to be forgotten
- Data portability

**CCPA (California):**
- Opt-out right
- Disclosure of data collection
- Non-discrimination

**Best Practice:**
- Get clear consent at collection
- Document consent
- Honor opt-out requests
- Update suppression lists

### Suppression Lists

**Who to Suppress:**
- Unsubscribed from marketing
- Requested deletion
- Opted out of advertising
- Compliance/legal requirements

**Implementation:**
```
1. Maintain suppression list in CRM
2. Upload as Custom Audience
3. Apply as exclusion to ALL campaigns
4. Update weekly
```

---

## Data Quality Best Practices

### List Hygiene

**Regular Cleaning:**
- Remove bounced emails
- Verify phone formats
- Deduplicate
- Standardize formatting

**Formatting Standards:**
```
Email: lowercase, trim whitespace
Phone: +1XXXXXXXXXX format
Name: Title case
Country: ISO 2-letter code
```

### Data Enrichment

**Tools to Enrich First-Party Data:**
- Clearbit (B2B company data)
- ZoomInfo (B2B contacts)
- FullContact (consumer profiles)

**What to Enrich:**
- Company size (B2B)
- Industry
- Job title
- Social profiles

---

*Back to: [SKILL.md](../SKILL.md)*
