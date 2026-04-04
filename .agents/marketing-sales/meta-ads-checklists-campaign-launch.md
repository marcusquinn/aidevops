<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Meta Ads Campaign Launch Checklist

> Don't launch until every box is checked.

## Pre-Launch

### Tracking

- [ ] **Pixel & events**: Meta Pixel installed on all pages; test events firing (PageView, ViewContent, AddToCart, Purchase/Lead); parameters passing (value, currency, content_id).
- [ ] **CAPI**: Server-side tracking implemented; event deduplication set up (matching event_id); match rate >50%.
- [ ] **Domain**: Domain verified in Business Settings and Events Manager.

### Business Manager

- [ ] Ad account in good standing; payment method valid; spending limit sufficient.
- [ ] Proper access levels assigned; 2FA enabled; ownership clear.

### Landing Page

- [ ] **Technical**: Loads in <3s; mobile responsive; no broken links; form submits correctly.
- [ ] **Message match**: Headline, offer, and visual style align with ad message/promise; no confusing redirects.
- [ ] **Conversion optimization**: Clear CTA above the fold; social proof (logos, reviews) and trust signals (badges) present; minimal form fields; privacy policy linked.

### Audiences

- [ ] **Custom & Lookalike**: Website visitors, high-intent page visitors (pricing, cart, checkout), and engagers (video, page) configured; customer lists uploaded; 1% lookalike from source 500+.
- [ ] **Exclusions**: Exclude recent purchasers, employees, and higher-intent audiences from lower-intent ad sets.

### Creative

- [ ] **Assets**: 3-5 variations; mix of formats (video, static, carousel); correct aspect ratios (9:16, 1:1, 4:5).
- [ ] **Quality**: Video has captions; text readable on mobile; images high resolution; no policy violations.
- [ ] **Copy**: Primary text clear; headline under limit; CTA appropriate; UTM parameters in URLs.

### Campaign Settings

- [ ] **Campaign**: Correct objective; budget type (CBO/ABO) intentional; spending limit set; A/B test configured.
- [ ] **Ad set**: Audiences, budget, and schedule set; placements (Advantage+ or restricted); optimization event and bid strategy correct.
- [ ] **Ad**: Assets uploaded; destination URL and UTMs correct; mobile preview checked.

## Launch Day

- [ ] Preview all ads; confirm tracking; set check-in reminders; document launch.
- [ ] Set campaign to active; confirm "In Review" or "Active" status; note immediate disapprovals.

## Post-Launch (24-48 Hours)

- [ ] Confirm spending and delivery; no ad disapprovals.
- [ ] Monitor early metrics (CPM, CTR); verify events in Events Manager.
- [ ] Record initial metrics; set up automated rules.

## Red Flags — Stop and Investigate

- No spend after 24 hours or ad disapproved.
- CPM >2x expected or CTR <0.3% after 1,000+ impressions.
- No conversions after significant spend.
