# Campaign Launch Checklist

> Don't launch until every box is checked.

## Pre-Launch

### Tracking

**Pixel & events**
- [ ] Meta Pixel installed on all pages and verified in Events Manager
- [ ] Test events firing correctly (use Test Events tool)
- [ ] Standard events set up (PageView, ViewContent, AddToCart, Purchase/Lead)
- [ ] Custom events configured if needed
- [ ] Event parameters passing correctly (value, currency, content_id)

**CAPI**
- [ ] CAPI implemented (server-side tracking)
- [ ] Event deduplication set up (matching event_id)
- [ ] Match rate >50%

**Domain**
- [ ] Domain verified in Business Settings
- [ ] Events Manager > Data Sources > Domain verification complete

### Business Manager

- [ ] Ad account in good standing, no policy violations pending
- [ ] Payment method valid and current
- [ ] Spending limit sufficient
- [ ] Proper access levels assigned, 2FA enabled
- [ ] Business Manager ownership clear

### Landing Page

**Technical**
- [ ] Page loads in <3 seconds
- [ ] Mobile responsive (test on actual phone)
- [ ] No broken links or images
- [ ] Form submits correctly, thank you page works

**Message match**
- [ ] Headline aligns with ad message
- [ ] Offer matches ad promise
- [ ] Visual style consistent with ad, no confusing redirects

**Conversion optimization**
- [ ] Clear CTA above the fold
- [ ] Social proof present (logos, testimonials, reviews)
- [ ] Trust signals (security badges, guarantees)
- [ ] Minimal form fields
- [ ] Privacy policy linked

### Audiences

**Custom and lookalike audiences**
- [ ] Website visitors (by timeframe)
- [ ] High-intent page visitors (pricing, cart, checkout)
- [ ] Engagement audiences (video viewers, page engagers)
- [ ] Customer lists uploaded (if applicable)
- [ ] 1% lookalike from best source (source audience 500+)

**Exclusions**
- [ ] Exclude recent purchasers/converters
- [ ] Exclude employees if significant
- [ ] Higher-intent audiences excluded from lower-intent ad sets

### Creative

**Assets**
- [ ] Minimum 3-5 creative variations
- [ ] Mix of formats (video, static, carousel as appropriate)
- [ ] Correct aspect ratios (9:16, 1:1, 4:5)

**Quality**
- [ ] Video has captions
- [ ] Text readable on mobile
- [ ] Images high resolution
- [ ] No policy-violating content

**Copy**
- [ ] Primary text compelling and clear
- [ ] Headline under character limit
- [ ] CTA appropriate for objective
- [ ] UTM parameters in URLs

### Campaign Settings

**Campaign level**
- [ ] Correct objective selected
- [ ] Budget type (CBO/ABO) intentional
- [ ] Campaign spending limit set (optional)
- [ ] A/B test configured if testing

**Ad set level**
- [ ] Audiences configured correctly
- [ ] Budget appropriate for goal
- [ ] Schedule set (start/end if needed)
- [ ] Placements: Advantage+ or intentionally restricted
- [ ] Optimization event is correct
- [ ] Bid strategy appropriate

**Ad level**
- [ ] All creative uploaded, copy entered correctly
- [ ] Destination URL correct, UTM parameters working
- [ ] Preview checked on mobile

## Launch Day

- [ ] Preview all ads one more time
- [ ] Confirm tracking is working (one more test)
- [ ] Set calendar reminders for check-ins
- [ ] Document launch in tracking sheet
- [ ] Campaign set to active
- [ ] Confirm ads move to "In Review" or "Active"
- [ ] Note any immediate disapprovals

## Post-Launch (First 24-48 Hours)

- [ ] Ads are spending (delivery confirmed)
- [ ] No ad disapprovals
- [ ] Early metrics look reasonable (CPM, CTR)
- [ ] Events firing in Events Manager
- [ ] Record initial metrics, note any adjustments made
- [ ] Set up automated rules if using

## Red Flags — Stop and Investigate

- No spend after 24 hours
- Ad disapproved
- CPM >2x expected
- CTR below 0.3% after 1,000+ impressions
- No conversions after significant spend
