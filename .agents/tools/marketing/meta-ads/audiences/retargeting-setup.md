# Retargeting Setup Guide

> Step-by-step guide to setting up retargeting audiences.

---

## Website Custom Audiences

### Creating Website Audiences

**Step 1: Go to Audiences**
```
Ads Manager → Audiences → Create Audience → Custom Audience → Website
```

**Step 2: Select Pixel**
```
Choose your pixel from dropdown
```

**Step 3: Define Audience**
```
Events: Website visitors who...
Retention: [1-180 days]
```

### Essential Website Audiences to Create

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

### URL-Based Audiences

**For Specific Page Visitors:**
```
Website visitors who:
└── URL contains: /pricing

Retention: 14 days
Name: RT_Pricing_14d
```

**For Blog Readers:**
```
Website visitors who:
└── URL contains: /blog

Retention: 30 days
Name: RT_Blog_30d
```

### Event-Based Audiences

**Standard Events to Track:**
- PageView (all visitors)
- ViewContent (product/key page views)
- AddToCart (cart additions)
- InitiateCheckout (checkout started)
- Purchase (completed orders)
- Lead (form submissions)
- CompleteRegistration (signups)

**Creating Event-Based Audience:**
```
All website visitors who:
└── Events: AddToCart

Refine by:
└── And also: Did NOT complete: Purchase

Retention: 14 days
Name: RT_Cart_NoPurchase_14d
```

---

## Engagement Audiences

### Video Viewer Audiences

**Creating Video Audiences:**
```
Create Audience → Custom Audience → Video
```

**Video Engagement Options:**
| Option | Meaning |
|--------|---------|
| 3 seconds | Viewed at least 3s |
| 10 seconds | Viewed at least 10s |
| 25% | Watched 25% of video |
| 50% | Watched 50% of video |
| 75% | Watched 75% of video |
| 95% | Watched 95% of video |
| ThruPlay | Watched 15s+ or completed |

**Recommended Video Audiences:**
| Audience | Config | Use Case |
|----------|--------|----------|
| Video_50%_30d | 50% viewers, 30 days | Mid-funnel |
| Video_75%_60d | 75% viewers, 60 days | High intent |
| Video_95%_60d | 95% viewers, 60 days | Highest intent |

### Page Engagement Audiences

**Creating Page Audiences:**
```
Create Audience → Custom Audience → Facebook Page
```

**Options:**
- Everyone who engaged with your Page
- Anyone who visited your Page
- People who engaged with any post or ad
- People who clicked any call-to-action button
- People who sent a message to your Page
- People who saved your Page or any post

**Recommended:** "People who engaged with any post or ad" - 60 days

### Instagram Engagement Audiences

**Creating IG Audiences:**
```
Create Audience → Custom Audience → Instagram Account
```

**Options:**
- Everyone who engaged with your professional account
- Anyone who visited your professional account's profile
- People who engaged with any post or ad
- People who sent a message to your professional account
- People who saved any post or ad

### Ad Engagement Audiences

**People Who Engaged with Ads:**
```
Create Audience → Custom Audience → Lead form
→ People who opened but didn't submit
```

This captures high-intent users who considered converting.

---

## Customer List Setup

### Preparing Your List

**Required Fields:**
- Email (most important)

**Recommended Fields:**
- Phone
- First Name
- Last Name
- City
- State
- Country
- Zip

**Format:**
```csv
email,phone,fn,ln,ct,st,country,zip
john@example.com,+14155551234,John,Smith,San Francisco,CA,US,94102
```

### Uploading Customer List

```
1. Create Audience → Custom Audience → Customer list
2. Select "Use a file that doesn't include LTV"
3. Upload CSV
4. Map columns to Meta fields
5. Review match rate
6. Name audience: "Customers_All_[Date]"
```

### Expected Match Rates

| Data Quality | Expected Match |
|--------------|----------------|
| Email only | 40-60% |
| Email + Phone | 50-70% |
| Email + Phone + Name | 55-75% |
| All fields | 60-80% |

### Customer Segments to Upload

| Segment | Update Frequency |
|---------|------------------|
| All customers | Monthly |
| High-LTV customers | Monthly |
| Recent customers (90d) | Weekly |
| Churned customers | Monthly |
| Leads (not customers) | Weekly |

---

## Audience Combinations

### Creating Combined Audiences

**Using AND/OR Logic:**

```
Website visitors who meet these conditions:
├── Include people who:
│   ├── Visited [any page] in the last 30 days
│   └── OR Engaged with Page in the last 60 days
│
└── Exclude people who:
    └── Purchased in the last 30 days
```

### Recommended Combinations

**Warm But Not Hot:**
```
Include: All Visitors 30d
Exclude: Visitors 7d
Exclude: Purchasers 30d

= People who visited 8-30 days ago, didn't buy
```

**Engaged But Not Visited:**
```
Include: Page/IG Engagers 60d
Exclude: Website Visitors 30d

= Social engagers who haven't been to site
```

**Lapsed Customers:**
```
Include: Purchasers 365d
Exclude: Purchasers 90d

= Bought 4-12 months ago, not recently
```

---

## Pixel Event Configuration

### Setting Up Events

**In Events Manager:**
```
1. Data Sources → Select Pixel
2. Settings → Open Event Setup Tool
3. Navigate to your website
4. Use interface to configure events
```

### Event Priority (AEM)

**Rank Your 8 Events by Value:**
```
1. Purchase (highest)
2. InitiateCheckout
3. AddToCart
4. Lead
5. CompleteRegistration
6. ViewContent
7. Search
8. PageView (lowest)
```

### Testing Events

**Using Test Events Tool:**
```
1. Events Manager → Data Sources → Pixel
2. Test Events tab
3. Open your website
4. Complete actions
5. Verify events fire correctly
```

---

## Audience Maintenance

### Regular Tasks

| Task | Frequency |
|------|-----------|
| Update customer lists | Weekly-Monthly |
| Check audience sizes | Monthly |
| Remove old audiences | Quarterly |
| Update segment definitions | Quarterly |

### Audience Naming Convention

```
[Type]_[Specifics]_[Window]

Examples:
RT_Web_AllVisitors_14d
RT_Web_CartAbandoners_7d
RT_Video_75pct_30d
RT_Engage_PageLikes_60d
LAL_Customers_HighLTV_1pct
```

### Archiving Audiences

**When to Archive:**
- No longer used in campaigns
- Data too old to be useful
- Replaced by newer version

**How to Archive:**
- Add "ARCHIVE" prefix to name
- Move to Archive folder
- Don't delete (may break historical reports)

---

*Next: [First-Party Data](first-party-data.md)*
