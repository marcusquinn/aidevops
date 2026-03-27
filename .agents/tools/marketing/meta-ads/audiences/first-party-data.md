# First-Party Data Strategies

> In a privacy-first world, your own data is your competitive advantage.

## Why First-Party Data Matters

| Change | Impact |
|--------|--------|
| iOS 14+ ATT | 80%+ users opt out of tracking |
| Cookie deprecation | Third-party tracking dying |
| GDPR/Privacy laws | Consent requirements |
| Browser tracking prevention | Safari, Firefox block trackers |

**Result:** Third-party data is unreliable. Your data is gold.

---

## Customer List Strategies

### Data to Collect

- Email (mandatory), Phone (highly recommended), Name (improves matching)
- Purchase history (segmentation), Engagement data (targeting)

**Collection points:** Purchase/checkout, account creation, newsletter signup, lead magnets, webinars, support interactions.

### Unified Segmentation Model

Combine value, behaviour, and lifecycle into one framework. Segments overlap — assign each customer to their highest-priority segment.

```
Champions (high frequency + high LTV, recent)
  Use for: Best lookalike source, advocacy
  Message: VIP/exclusive offers, early access
  Exclude from: Discount campaigns

Loyal / Repeat (recent, high frequency, medium value)
  Use for: Upsell, loyalty, referral campaigns
  Message: Product education, cross-sell

Recent / First-Time Buyers (very recent, low frequency)
  Use for: Exclude from acquisition
  Message: Onboarding, second-purchase incentive

At-Risk / Lapsed (not recent, was high value)
  Use for: Win-back, retention campaigns
  Message: "We miss you" + incentive, value reminder

Leads (no purchase yet, engaged)
  Use for: Conversion campaigns
  Message: First-purchase incentive

Low-Value / Lost (old, low frequency, low spend)
  Use for: Lookalike exclusion
  Consider: May not be worth retargeting cost
```

---

## Email List Segmentation for Ads

**Don't upload your entire list.** Upload targeted segments for specific purposes:

| Segment | Size | Purpose |
|---------|------|---------|
| Customers - High LTV | 500-2000 | Best lookalike source |
| Customers - All | All | Exclusion, retention |
| Leads - Engaged | Recent openers/clickers | Conversion campaigns |
| Leads - Cold | No engagement 90d | Re-engagement |
| Trial Users | Active trials | Conversion campaigns |

### Match Rate Optimization

1. **Include phone numbers** (+10-20% match rate)
2. **Add name + location** (+5-10% match)
3. **Use business emails** (higher match than personal)
4. **Clean your list** (remove bounces, invalid, deduplicate)

### Update Frequency

| Segment Type | Frequency |
|--------------|-----------|
| Dynamic (recent activity) | Weekly |
| Exclusions | Weekly |
| Static (all customers) | Monthly |
| Lookalike source | Monthly |

---

## Purchase Behaviour Targeting

### RFM Analysis (Recency, Frequency, Monetary)

| Segment | Recency | Frequency | Monetary | Action |
|---------|---------|-----------|----------|--------|
| Champions | Recent | High | High | Lookalike, advocacy |
| Loyal | Recent | High | Medium | Upsell |
| Recent | Very recent | Low | Low | Convert to repeat |
| At Risk | Not recent | High | High | Win-back |
| Lost | Old | Low | Low | Consider excluding |

### Product-Based Targeting

**Cross-sell:** Create custom audience of Product A buyers, exclude Product B buyers, target with Product B ads.

**Category-based:** Bought from Category X → target related categories ("You might also like...").

### Value-Based Lookalikes

1. Export customers with LTV values
2. Create Customer List with Value column
3. Create Value-Based Lookalike — Meta weights by customer value
4. Result: Finds people similar to your *best* customers, not just any customers

---

## CRM Integration

| Method | Complexity | Real-Time |
|--------|------------|-----------|
| Manual CSV Upload | Easy | No |
| Zapier/Make | Medium | Near |
| Native Integration | Varies | Yes/Near |
| Custom API | Hard | Yes |

**Popular integrations:** HubSpot (contact lists, events, conversions), Salesforce (lead status, opportunities, closed-won), Klaviyo (segments, purchase events), Segment (all events, audiences).

### Offline Conversion Tracking

Send offline conversions (phone calls, in-store) to Meta: collect customer email/phone at conversion, match to Facebook user, send offline conversion event.

**Benefits:** Algorithm optimizes for real conversions, better lookalike audiences, true ROAS measurement.

---

## Privacy Compliance

### Consent Requirements

- **GDPR (EU):** Explicit consent, right to be forgotten, data portability
- **CCPA (California):** Opt-out right, disclosure of data collection, non-discrimination
- **Best practice:** Get clear consent at collection, document it, honour opt-out requests, update suppression lists

### Suppression Lists

Suppress: unsubscribed, requested deletion, opted out of advertising, compliance/legal requirements.

**Implementation:** Maintain suppression list in CRM, upload as Custom Audience, apply as exclusion to ALL campaigns, update weekly.

---

## Data Quality

### List Hygiene & Formatting

- Remove bounced emails, verify phone formats, deduplicate, standardize formatting
- **Formats:** Email lowercase trimmed, Phone `+1XXXXXXXXXX`, Name title case, Country ISO 2-letter

### Data Enrichment

| Tool | Use Case |
|------|----------|
| Clearbit | B2B company data |
| ZoomInfo | B2B contacts |
| FullContact | Consumer profiles |

**Enrich:** Company size, industry, job title, social profiles.

---

*Back to: [SKILL.md](../SKILL.md)*
