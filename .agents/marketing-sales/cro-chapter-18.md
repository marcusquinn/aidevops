# Chapter 18: CRO Case Studies and Implementation Playbook

Real-world implementations across e-commerce, SaaS, and B2B. Builds on [Chapter 1](./cro-chapter-01.md)–[Chapter 12](./cro-chapter-12.md).

## 18.1 E-commerce: Fashion Retailer ($50M Revenue)

| Category | Details |
|----------|---------|
| Challenge | 1.2% conversion, 72% cart abandonment, 0.8% mobile conversion |
| Baseline | 500K monthly visitors, 6K orders, $85 AOV |
| Product pages | Size guide with visual fitting, 360-degree views, customer photos in reviews, upfront shipping calculator |
| Checkout | Fields reduced 12→6, guest checkout, progress indicator, trust badges |
| Mobile | Redesigned nav, sticky "Add to Cart", simplified checkout, Apple/Google Pay |
| Cart recovery | Email sequence at 1h/24h/72h, 10% discount in final email, cart images, urgency messaging |

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| Conversion Rate | 1.2% | 2.1% | +75% |
| Cart Abandonment | 72% | 58% | -14pp |
| Mobile Conversion | 0.8% | 1.6% | +100% |
| AOV | $85 | $92 | +8% |
| Monthly Revenue | $510K | $966K | +89% |

| Summary | Value |
|---------|-------|
| Annual Impact | $5.5M additional revenue |

## 18.2 SaaS: B2B Project Management (Freemium)

| Category | Details |
|----------|---------|
| Challenge | 8% trial-to-paid, 15% monthly churn, average LTV $1,200 |
| Baseline | 10K monthly signups, 800 conversions |
| Root cause | 55% said "didn't see value", 40% of support tickets were basic setup — users not reaching "aha moment" |
| Onboarding | Progressive onboarding, interactive tour, use-case templates, in-app checklists |
| Value demonstration | "Quick Wins" dashboard, time-saved metrics, usage-based tips, early collaboration features |
| Pricing | Simplified tiers 4→3, ROI calculator, highlighted popular plan, enterprise CTA |
| Trial nurture | Day 3 value email → Day 7 case study → Day 10 limited discount → Day 14 CSM outreach |

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| Trial Conversion | 8% | 14% | +75% |
| Time to Value | 5 days | 2 days | -60% |
| Feature Adoption | 35% | 62% | +77% |
| Monthly Churn | 15% | 10% | -33% |
| Monthly Revenue | $96K | $168K | +75% |

| Summary | Value |
|---------|-------|
| Annual Impact | $864K additional revenue + improved retention |

## 18.3 Lead Gen: B2B Consulting ($20M Revenue)

| Category | Details |
|----------|---------|
| Challenge | $150 CPL, 5% lead-to-opportunity, 60% of leads unqualified (wrong size, no budget/authority, early research) |
| Landing pages | Qualification questions in form, use-case-specific pages, progressive profiling, social proof |
| Content | Gated research reports, industry content hubs, content-based lead scoring, segment-specific nurture |
| Qualification | BANT scoring, automated workflows, fast-track for high scores, SDR playbook |
| ABM | 500-account target list, personalized site experience, account-specific content, engagement alerts |

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| Cost Per Lead | $150 | $95 | -37% |
| Lead Quality | 45/100 | 72/100 | +60% |
| Lead-to-Opp Rate | 5% | 12% | +140% |
| Cost Per Opportunity | $3,000 | $792 | -74% |
| Pipeline/Month | $2M | $4.8M | +140% |

| Summary | Value |
|---------|-------|
| Annual Impact | $33.6M additional pipeline |

## 18.4 Implementation Playbook

### Phase 1: Foundation (Weeks 1–4)

| Week | Focus | Actions |
|------|-------|---------|
| 1 | Setup/Audit | Install GA4, heatmaps (Hotjar/FullStory), event tracking. Conduct CRO audit. Identify quick wins. |
| 2 | Research | Analyze GA data, heatmaps, recordings. Survey customers, interview recent converters, analyze competitors. |
| 3 | Prioritize | PIE framework scoring, test roadmap, stakeholder alignment, testing tool setup (Optimizely/VWO), document baselines. |
| 4 | Quick Wins | Resolve critical UX issues, add trust signals, optimize page speed, fix mobile issues, improve above-fold content. |

### Phase 2: Testing (Months 2–3)

| Period | Focus |
|--------|-------|
| Month 2 | First A/B tests — headlines, CTAs, forms, social proof placement |
| Month 3 | Test pricing presentation, product page layouts, checkout flow, email sequences. Implement winners. |

**Cadence:** Mon=review results, Tue=launch tests, Wed=deep analysis, Thu=creative dev, Fri=planning/docs.

### Phase 3: Advanced Optimization (Months 4–6)

| Track | Actions |
|-------|---------|
| Testing | Multivariate tests, personalization, segmentation analysis, funnel optimization, cross-channel testing |
| Operations | Document results, build test library, create design system, train team, establish reporting cadence |

### Team Structure

| Model | Team |
|-------|------|
| Minimum viable | CRO Manager + part-time Frontend Dev, Designer, Analyst |
| Enterprise | CRO Director, CRO Manager, 2–3 Specialists, Frontend Dev, UX Researcher, Data Analyst |

### Tools

| Category | Tools |
|----------|-------|
| Analytics | GA4 (free), Mixpanel/Amplitude (product), Tableau/Looker (BI) |
| Testing | Optimizely (enterprise), VWO (mid-market) |
| Research | Hotjar (heatmaps), UserTesting, SurveyMonkey/Typeform, FullStory |
| Project Mgmt | Jira/Asana, Confluence/Notion, Slack |

### Success Metrics

- **Primary:** Conversion rate (overall + segment), revenue per visitor, AOV (e-commerce), trial-to-paid (SaaS), CPA
- **Secondary:** Test velocity (tests/month), win rate, revenue impact from CRO, time to significance, implementation rate

### Common Pitfalls

1. **Testing too many variables** — one element at a time; multivariate only with sufficient traffic
2. **Insufficient sample size** — calculate before testing, wait for significance, don't peek early
3. **Ignoring segments** — mobile vs desktop, new vs returning, traffic source, geography often show different winners
4. **Skipping qualitative data** — analytics shows what, not why; combine with user research
5. **Poor documentation** — document every test including losses; build institutional knowledge
