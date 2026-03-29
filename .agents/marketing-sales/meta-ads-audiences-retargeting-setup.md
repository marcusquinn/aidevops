# Retargeting Setup Guide

## Website Custom Audiences

**Create:** Ads Manager → Audiences → Create Audience → Custom Audience → Website → Choose pixel → Set events + retention window

| Audience Name | Configuration |
|---------------|--------------|
| All Visitors 7d | All website visitors, 7 days |
| All Visitors 14d | All website visitors, 14 days |
| All Visitors 30d | All website visitors, 30 days |
| Product Viewers 14d | ViewContent event, 14 days |
| Cart Abandoners 7d | AddToCart, exclude Purchase, 7 days |
| Checkout Started 3d | InitiateCheckout, exclude Purchase, 3 days |
| Purchasers 30d | Purchase event, 30 days |
| Purchasers 180d | Purchase event, 180 days |
| High-Intent Pages 7d | URL contains /pricing OR /demo, 7 days |

**URL examples:** `/pricing` → `RT_Pricing_14d` (14d) · `/blog` → `RT_Blog_30d` (30d)

**Cart abandoner config:** Include: AddToCart · Exclude: Purchase · Retention: 14d · Name: `RT_Cart_NoPurchase_14d`

**Standard events:** PageView, ViewContent, AddToCart, InitiateCheckout, Purchase, Lead, CompleteRegistration

---

## Engagement Audiences

### Video Viewers

**Create:** Custom Audience → Video

| Option | Meaning |
|--------|---------|
| 3 seconds | Viewed at least 3s |
| 10 seconds | Viewed at least 10s |
| 25% / 50% / 75% / 95% | Watched that % |
| ThruPlay | 15s+ or completed |

**Recommended:** Video_50%_30d (mid-funnel) · Video_75%_60d (high intent) · Video_95%_60d (highest intent)

### Page / Instagram Engagement

**Create:** Custom Audience → Facebook Page (or Instagram Account)

**Options:** Everyone who engaged · Anyone who visited · Engaged with any post or ad · Clicked CTA · Sent message · Saved page/post

**Recommended:** "Engaged with any post or ad" — 60 days

### Lead Form Engagement

**Create:** Custom Audience → Lead form → People who opened but didn't submit

---

## Customer List Setup

**CSV format:**
```csv
email,phone,fn,ln,ct,st,country,zip
john@example.com,+14155551234,John,Smith,San Francisco,CA,US,94102
```

**Upload:** Custom Audience → Customer list → Upload CSV → Map columns → Review match rate → Name: `Customers_All_[Date]`

**Expected match rates:**

| Data Quality | Match |
|--------------|-------|
| Email only | 40-60% |
| Email + Phone | 50-70% |
| Email + Phone + Name | 55-75% |
| All fields | 60-80% |

**Segments to upload:**

| Segment | Frequency |
|---------|-----------|
| All customers | Monthly |
| High-LTV customers | Monthly |
| Recent customers (90d) | Weekly |
| Churned customers | Monthly |
| Leads (not customers) | Weekly |

---

## Audience Combinations

```
# Warm But Not Hot
Include: All Visitors 30d
Exclude: Visitors 7d + Purchasers 30d
= Visited 8-30 days ago, didn't buy

# Engaged But Not Visited
Include: Page/IG Engagers 60d
Exclude: Website Visitors 30d
= Social engagers who haven't been to site

# Lapsed Customers
Include: Purchasers 365d
Exclude: Purchasers 90d
= Bought 4-12 months ago, not recently
```

---

## Pixel Event Configuration

**Event Setup Tool:** Data Sources → Select Pixel → Settings → Open Event Setup Tool → Navigate to website → Configure events via interface

**AEM event priority (rank 8 events by value):**

1. Purchase (highest)
2. InitiateCheckout
3. AddToCart
4. Lead
5. CompleteRegistration
6. ViewContent
7. Search
8. PageView (lowest)

**Test events:** Events Manager → Data Sources → Pixel → Test Events tab → Open website → Complete actions → Verify events fire

---

## Audience Maintenance

| Task | Frequency |
|------|-----------|
| Update customer lists | Weekly-Monthly |
| Check audience sizes | Monthly |
| Remove old audiences | Quarterly |
| Update segment definitions | Quarterly |

**Naming convention:** `[Type]_[Specifics]_[Window]`
- `RT_Web_AllVisitors_14d` · `RT_Web_CartAbandoners_7d` · `RT_Video_75pct_30d`
- `RT_Engage_PageLikes_60d` · `LAL_Customers_HighLTV_1pct`

**Archiving:** Add "ARCHIVE" prefix, move to Archive folder. Don't delete (breaks historical reports).

---

*Next: [First-Party Data](first-party-data.md)*
