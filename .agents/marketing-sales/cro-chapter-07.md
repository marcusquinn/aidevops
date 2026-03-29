# Chapter 7: Call-to-Action (CTA) Optimization

The CTA is where browsing becomes conversion. Small CTA improvements yield outsized conversion gains.

## Psychology of Action

`Action Likelihood = (Motivation x Ability) - Friction`

- **Reduce friction** -- make it easy, break into steps, remove obstacles
- **Increase perceived benefit** -- emphasize value, show immediate benefit, reduce risk, create urgency
- **Commitment gradient** -- people act after smaller steps, when action aligns with self-image, or under social accountability

## CTA Button Design

**Size:** Desktop min 200x50px (ideal 240x60px). Mobile min 44x44px (48x48px+ better; full-width often wins). CTA must be the most prominent interactive element via size, color contrast, position, and white space.

**Color:** The rule is **contrast**, not a specific color. Red/Orange = urgency/sales. Green = positive/financial. Blue = trust/payments. Yellow = attention (hard to read). White/ghost = secondary (lower conversion). WCAG AA: normal text 4.5:1, large text/UI 3:1.

**Shape:** Rounded corners (4-8px) > pill (friendly, mobile) > sharp (formal, legal/finance). Primary = solid fill (highest conversion). Secondary = outline/ghost. Add `box-shadow` for depth/clickability.

**States:** Design all: default, hover (lift + darken), active (press), focus (visible outline -- never bare `outline: none`), disabled (grey, `cursor: not-allowed`), loading (spinner, same size, disabled to prevent double-submit).

## CTA Copy Optimization

**Action verbs -- Avoid:** Submit, Click Here, Enter, Continue, Go. **Use:** Get, Start, Discover, Unlock, Claim, Download, Join, Reserve, Build, Access, Create.

**First vs second person:** "Start **My** Free Trial" often outperforms "Start **Your** Free Trial" by 10-25%. Test both; first person usually wins.

**Formula:** `[Action Verb] + [Benefit/Outcome]` -- "Get Instant Access" not "Sign Up"; "Start Saving Time" not "Download"; "Join 50,000+ Marketers" not "Register". Be specific and quantify: "Start My 14-Day Free Trial", "Save 10 Hours Per Week".

**Anxiety-reducing microcopy** (below CTA, smaller/lighter font): Free trials -- "No credit card required" / "Cancel anytime". Purchases -- "30-day money-back guarantee" / "Secure checkout". Forms -- "We'll never share your email". Account creation -- "Takes less than 60 seconds".

## CTA Placement Strategy

**Above fold:** Simple/familiar offers, warm traffic, known brands, low-cost/free. **Below fold can win:** Complex/unfamiliar offers, cold traffic, high-consideration purchases needing education. **Best practice:** CTA above fold AND repeated after key benefits, social proof, and page bottom.

**Directional cues:** Arrows, photos of people gazing toward CTA, white space buffer, framing borders. **Competing elements:** Single primary CTA per section. Secondary CTAs visually de-emphasized (ghost). Remove nav on dedicated landing pages. Hierarchy: primary (large, colored) > secondary (outline) > tertiary (text link).

## Advanced CTA Techniques

**Dynamic/personalized CTAs** -- adapt by context: First visit -> "Start Free Trial" / Return -> "Continue Where You Left Off". Logged out -> "Sign Up Free" / Logged in -> "Upgrade to Pro". Empty cart -> "Shop Now" / Items in cart -> "Complete Your Order".

**Traffic-source adapted copy:** Social -> "Join the Conversation". Email -> "Access Your Exclusive Offer". Paid search -> match keyword (e.g., "free CRM software" -> "Start Free CRM Trial"). Time/location-based -> "Free Shipping to [State]".

**Exit-intent CTAs:** Trigger on mouse toward close/back (desktop) or scroll-based (mobile). Offer discount, free resource, newsletter, or alternative. Show once per session; make easy to close.

**Sticky/fixed CTAs:** Sticky header, sticky footer (effective on mobile), floating corner button. Don't obstruct content, make dismissible, don't stack multiple sticky elements.

## CTA Testing Framework

**High impact (test first):** CTA copy (verbs, person, specificity, benefit), button color (brand vs high-contrast), button size, placement (above/below fold), supporting copy (anxiety reducers, urgency). **Medium impact:** Shape, visual style, icons, microcopy variations.

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

## Accessibility and Edge States

**Keyboard/ARIA:** Focusable with Tab, activatable with Enter/Space. Clear focus indicator. Logical tab order. Descriptive ARIA labels -- not "Click Here". Use `<a>` for navigation, `<button>` for actions. Min target 44x44px (48x48px recommended); adequate spacing.

**Error/edge states:** Form validation -- inline real-time feedback. Loading -- disable button, show spinner, maintain size (no layout shift). Success -- confirmation state before redirect. Error -- re-enable with "Error - Try Again". Offline -- detect `navigator.onLine`, disable with message, re-enable on `online` event.

## CTA Launch Checklist

**Design:** High contrast (3:1 min, 4.5:1 text) . Min 44x44px . Most prominent element . All states designed
**Copy:** Action verb . Benefit-focused . First person tested . Anxiety-reducing microcopy
**Placement:** Above fold . Repeated after value sections . Single primary per section
**Technical:** Correct semantics (`<button>` vs `<a>`) . Accessible (ARIA, keyboard, focus) . Loading/error/success states . Analytics tracking . Cross-browser/device tested
**Context:** Matches funnel stage . Appropriate for traffic source . Privacy/security addressed

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
