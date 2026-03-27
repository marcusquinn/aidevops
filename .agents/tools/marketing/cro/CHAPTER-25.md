# Chapter 25: Advanced Revenue Optimization

## 25.1 Pricing Page Optimization

Highest-leverage conversion point. Treat as a living experiment. Use 3-tier structure with emphasized "recommended" plan (center-stage effect + anchoring).

| Variable | Options | Note |
|----------|---------|------|
| Plan count | 2 (simple), **3** (standard), 4 (enterprise) | Run ≥2 full billing cycles |
| Naming | Functional vs Aspirational vs Simple | B2B functional +8–15% (faster self-selection) |
| Feature diff | Capability tiers vs usage limits | Capability → "which features?"; limits → minimize spend |
| Billing toggle | Above cards; default annual | Show % AND absolute savings → +23% annual selection (n=47) |
| Price display | Remove currency symbols (Cornell: less pain); charm ($49) SMB / round ($50) enterprise | Per-user price + cost calculator; slash-through for discounts |
| Feature tables | Show only differentiators; group by use case (Analytics/Collaboration/Security) | Progressive disclosure 5–8 + "See all" → −12–18% bounce; replace checkmarks with specifics; tooltips for SSO/RBAC |

---

## 25.2 Bundling and Cross-Sell

Bundles increase AOV 15–35%. Psychology: one payment event, perceived value asymmetry, choice reduction.

| Bundle type | When to use | Risk |
|-------------|-------------|------|
| Pure (together only) | Highly complementary | Alienates single-item buyers |
| Mixed (individual + bundle) | Default highest-revenue | Discount 10–30%; <10% doesn't motivate, >30% cannibalizes |
| Leader (discount popular + less popular) | New product, slow inventory | Leader must be genuinely desirable |
| Tiered (buy more, save more) | Consumables | Easy to test incrementally |

| Cross-sell moment | Placement | Rule |
|-------------------|-----------|------|
| Pre-purchase | Product page | Max 2–3; carousel (desktop), list (mobile) |
| In-cart | Cart/checkout | Price <25% of cart total |
| Post-purchase | Order confirmation | One-click add; buyer receptive (cognitive dissonance) |
| Post-delivery | Email follow-up | Trigger on usage signals (limit hits, gated feature attempts) |

---

## 25.3 Checkout Flow

See Chapter 18 §18.3 for comprehensive checkout optimization.

---

## 25.4 Retention and Expansion Revenue

+5% retention = +25–95% profit (Bain). Expansion 3–5× cheaper than acquisition.

**Cancellation flow:** Required reason → friction + product data · Match save offer to reason ("Too expensive" → discount/downgrade; "Not using" → tips; "Missing feature" → roadmap) · Pause option (1–3 months) saves 15–25% of churners · Downgrade path: $10/mo >> $0

**Dunning** (involuntary churn = 20–40% of SaaS churn; recovers 30–50%):

| Step | Action |
|------|--------|
| −7 days | Pre-expiry notification |
| Soft decline | 24h wait, auto-retry |
| 1st failure | Email with one-click payment update |
| 2nd failure | SMS (if consented) + in-app persistent banner |
| Grace period | 7–14 days before service interruption |
| Post-pause | Win-back email with easy reactivation |

**Expansion triggers:** Upgrade prompts at 80% limit (test 70/80/90%), frame as growth not restriction · Gate scale-valuable features (analytics, automation, team); test tier placement · Annual conversion at 3 months active, milestones, renewal — annual churn ~half of monthly

---

## 25.5 Monetization Experimentation

Optimize for **RPV**, not CR alone: `LRPV = CR × Avg Transaction × (1 + Expansion Rate) × Avg Lifetime`

- Duration ≥1 full purchase cycle + 2 weeks
- Cohort analysis: higher initial CR + lower 6-mo LTV = net negative
- Revenue decomposition: CR × AOV × frequency × lifetime (lower CR can be net positive)
- Sensitivity: Van Westendorp PSM or Gabor-Granger before live tests
- Ethics: never show different prices simultaneously; test sequentially or across clearly different configs

**Report every test:** 30-day revenue impact · Projected 12-mo LTV · CAC impact · Qualitative signals (tickets, NPS)

---

## 25.6 Case Studies

### B2B SaaS: Usage-Based Pricing ($5M ARR)

Flat $99/mo → tiered by contact list (Starter $49/≤1K · Growth $99/≤10K · Scale $199/≤50K · Enterprise custom). Grandfathered 6 months; 80% usage alerts; contact-cleaning tool; 20% annual discount.

**Results (6 mo):** ARPU +28% ($99→$127) · LTV +34% · Churn 4.5→3.2% · Expansion 0→23% of new MRR · NRR 102→118% — customer growth drives natural upgrades.

---

### Subscription Box: Strategic Bundling (Coffee)

$25/mo flat (CAC $35, 40% GM, 45% 6-mo retention) → Explorer $29 / **Enthusiast $49** *(flagship: micro-lot, virtual cupping, 15% add-on discount)* / Connoisseur $79 *(equipment, private Slack)*.

**Results (9 mo):** Mix 15/62/23% · ARPU +116% ($25→$54) · GM 40→52% · LTV +200% ($67→$201) · CAC payback 3.5→0.7 mo · Retention 45→68% — equipment inclusion created switching costs.

---

### Online Course Platform: Checkout Optimization

74% of "Buy Now" clicks abandoned. Fixes by cause:

| Cause (drop%) | Fix |
|----------------|-----|
| Forced account (28%) | Email-only capture; silent account post-purchase |
| Tax sticker shock (22%) | Order summary sidebar; "$3.30/day"; ROI calculator; payment plan upfront |
| Payment friction (15%) | PayPal/Apple Pay/Google Pay (12→3 fields); BNPL >$300; B2B invoice |
| No payment plan (9%) | "$499 or 4×$125" shown upfront |

Recovery sequence: 1h pre-filled cart → 24h FAQ+testimonials → 72h 10% discount → 7d personal outreach (>$400)

**Results (90 days):** Completion 26→47% · Mobile 19→44% · High-value 18→39% · Recovery $127K/mo · AOV +19% · BNPL 23% high-ticket · B2B invoice $45K/mo · **+$312K/mo (+47%)**

---

## 25.7 Monetization CRO Checklist

**Pre-launch:** Define primary metric (RPV/ARPU/LTV) + guardrails (CR, churn, NPS) · Calculate MDE + sample size · Document full journey impact · Set up cohort-level revenue tracking · Confirm legal compliance in all markets · Brief support · Establish rollback criteria

**During:** Monitor daily revenue + conversion · Track pricing-related tickets · Watch segment effects (new/returning, mobile/desktop, geo) · Verify allocation balance

**Post-test:** Statistical significance on revenue (not just CR) · Project 12-month LTV using cohort curves · Analyze qualitative signals · Document learnings · Update roadmap · Archive results

**Ongoing cadence:** Monthly: RPV vs benchmarks · Quarterly: competitive analysis + ≥1 experiment · Semi-annually: WTP survey · Annually: pricing update · Seasonally (e-com): recalibrate bundles

### Revenue Optimization Maturity Model

| Level | Name | Description | Threshold |
|-------|------|-------------|-----------|
| 1 | Reactive | Pricing set once; changes only when competitors force | — |
| 2 | Periodic | Quarterly reviews; occasional discount/plan tests | — |
| 3 | Systematic | Dedicated monetization function; continuous experiments; documented roadmap + revenue attribution | ≥10K mo transactions |
| 4 | Predictive | ML-driven dynamic pricing, bundle optimization, real-time cross-sell | ≥$10M ARR + data science |

Most companies at Level 1–2. Level 3 requires executive sponsorship + cross-functional alignment.

**Key principles across all case studies:** Price structure drives behavior (usage-based → natural upgrades; tiered bundles → optimal value perception) · Payment flexibility expands market (BNPL, wallets, invoice) · Value communication beats price reduction (ROI calculators, usage alerts, equipment inclusion) · Optimize for RPV not CR · Grandfather when changing pricing · Cohort analysis is mandatory · Qualitative validates quantitative

**Highest-impact action at any level**: measure RPV as north star + run ≥1 experiment per quarter → 5–10% quarterly improvements compound to 20–45% annual revenue growth without additional traffic.
