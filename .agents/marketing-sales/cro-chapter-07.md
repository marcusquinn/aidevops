<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Chapter 7: Call-to-Action (CTA) Optimization

The CTA is where browsing becomes conversion. Small improvements yield outsized gains.

## Psychology of Action

`Action Likelihood = (Motivation x Ability) - Friction`

Reduce friction (fewer steps, remove obstacles). Increase perceived benefit (value, urgency, risk reduction). Use commitment gradient (small steps first, align with self-image, social accountability).

## CTA Button Design

**Size:** Desktop min 200x50px (ideal 240x60px). Mobile min 44x44px (48x48px+ better; full-width often wins). Must be the most prominent interactive element via size, color contrast, position, and white space.

**Color:** Contrast matters, not specific color. Red/Orange = urgency. Green = positive/financial. Blue = trust. Yellow = attention (hard to read). White/ghost = secondary (lower conversion). WCAG AA: text 4.5:1, large text/UI 3:1.

**Shape:** Rounded corners (4-8px) > pill (friendly, mobile) > sharp (formal). Primary = solid fill. Secondary = outline/ghost. Add `box-shadow` for depth.

**States:** Default, hover (lift + darken), active (press), focus (visible outline -- never bare `outline: none`), disabled (grey, `cursor: not-allowed`), loading (spinner, same size, disabled to prevent double-submit).

**Accessibility:** Focusable with Tab, activatable with Enter/Space. Logical tab order. Descriptive ARIA labels -- not "Click Here". Use `<a>` for navigation, `<button>` for actions. Min target 44x44px (48x48px recommended); adequate spacing.

**Edge states:** Form validation -- inline real-time feedback. Loading -- disable button, show spinner, maintain size (no layout shift). Success -- confirmation before redirect. Error -- re-enable with "Error - Try Again". Offline -- detect `navigator.onLine`, disable with message, re-enable on `online` event.

## CTA Copy

**Action verbs -- Avoid:** Submit, Click Here, Enter, Continue, Go. **Use:** Get, Start, Discover, Unlock, Claim, Download, Join, Reserve, Build, Access, Create.

**Person:** "Start **My** Free Trial" often outperforms "Start **Your** Free Trial" by 10-25%. Test both; first person usually wins.

**Formula:** `[Action Verb] + [Benefit/Outcome]` -- "Get Instant Access" not "Sign Up"; "Start Saving Time" not "Download"; "Join 50,000+ Marketers" not "Register". Be specific: "Start My 14-Day Free Trial", "Save 10 Hours Per Week".

**Microcopy** (below CTA, smaller font): Free trials -- "No credit card required" / "Cancel anytime". Purchases -- "30-day money-back guarantee" / "Secure checkout". Forms -- "We'll never share your email". Account creation -- "Takes less than 60 seconds".

## Placement

**Above fold:** Simple/familiar offers, warm traffic, known brands, low-cost/free. **Below fold can win:** Complex/unfamiliar offers, cold traffic, high-consideration purchases. **Best practice:** CTA above fold AND repeated after key benefits, social proof, and page bottom.

**Directional cues:** Arrows, gaze direction toward CTA, white space buffer, framing borders. Single primary CTA per section. Secondary CTAs visually de-emphasized (ghost). Remove nav on dedicated landing pages. Hierarchy: primary (large, colored) > secondary (outline) > tertiary (text link).

## Advanced Techniques

**Dynamic CTAs:** First visit -> "Start Free Trial" / Return -> "Continue Where You Left Off". Logged out -> "Sign Up Free" / Logged in -> "Upgrade to Pro". Empty cart -> "Shop Now" / Items in cart -> "Complete Your Order".

**Traffic-source copy:** Social -> "Join the Conversation". Email -> "Access Your Exclusive Offer". Paid search -> match keyword (e.g., "free CRM software" -> "Start Free CRM Trial"). Time/location -> "Free Shipping to [State]".

**Exit-intent:** Trigger on mouse toward close/back (desktop) or scroll-based (mobile). Offer discount, free resource, newsletter, or alternative. Show once per session; easy to close.

**Sticky CTAs:** Sticky header, sticky footer (effective on mobile), floating corner button. Don't obstruct content, make dismissible, don't stack multiple sticky elements.

## Testing

**High impact (test first):** Copy (verbs, person, specificity, benefit), button color, size, placement, supporting copy (anxiety reducers, urgency). **Medium:** Shape, visual style, icons, microcopy variations.

**Metrics -- Primary:** CTR, conversion rate, revenue per visitor. **Secondary:** Time to click, scroll depth, bounce rate. **Segment by:** Device, traffic source, new vs returning, geography. After 10-20 tests, aggregate into site-specific principles.

## Industry-Specific CTAs

| Industry | Primary CTA | Secondary CTA | Key Microcopy |
|----------|------------|---------------|---------------|
| E-commerce: Product | "Add to Cart" / "Buy Now" | -- | Price, stock, variant |
| E-commerce: Cart | "Proceed to Checkout" | "Continue Shopping" | Total, security badges |
| SaaS: Homepage | "Start Free Trial" / "Get Started Free" | "View Pricing" | Trial duration, no CC |
| SaaS: Pricing | "Choose [Plan]" / "Get Started" | -- | Post-trial info |
| B2B: Homepage | "Schedule a Demo" / "Get a Quote" | "View Case Studies" | "Free consultation" |
| Lead gen: Blog | "Download Free Guide" | "Subscribe for Updates" | "No spam" |

## Common Mistakes

| # | Mistake | Fix |
|---|---------|-----|
| 1 | Generic copy ("Submit", "Click Here") | Specific, benefit-driven copy |
| 2 | Too many equal-weight CTAs | One primary, de-emphasized secondaries |
| 3 | Low contrast / tiny buttons | High-contrast color, min 44x44px |
| 4 | No context or anxiety reduction | Value proposition + guarantees/trial info |
| 5 | Vague language ("Learn More") | "Download Free Guide", "Start My Trial" |
| 6 | Poor accessibility | ARIA labels, keyboard nav, focus indicators |
| 7 | No mobile optimization or click feedback | Full-width buttons, loading/success states |
