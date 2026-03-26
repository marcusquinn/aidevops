# Chapter 11: Mobile CRO

Mobile is the majority of traffic for most businesses, yet mobile conversion rates lag desktop by 40-60%. The gap is the opportunity.

**Key stats (2024):** 60%+ of web traffic is mobile. Mobile conversion: 1-3% vs desktop: 3-5%. Improving mobile conversion from 1.5% to 2.5% on 60% mobile traffic increases overall conversions by ~60%.

## Thumb Zone Design

Mobile interaction is thumb-driven. Place elements by interaction frequency:

- **Bottom third (natural thumb rest):** Primary CTAs — Buy Now, Add to Cart, Submit
- **Middle third (easy reach):** Navigation, filters, secondary actions
- **Top third (hard to reach):** Headings, images, informational content

Center bottom-aligned buttons work for both right-handed (80-90%) and left-handed users.

**Sticky CTA pattern** — the highest-impact mobile CRO change:

```text
┌─────────────────┐
│ Product Image   │
│ Description...  │ ← Scrollable content
├─────────────────┤
│ [Buy Now]       │ ← Sticky, always visible
└─────────────────┘
```

CTA stays accessible regardless of scroll position. Test sticky vs non-sticky — typical impact: 10-30% increase in clicks.

## Mobile Form Optimization

Forms are the highest-friction point on mobile.

**Core principles:**

1. **Minimize fields** — target <5. Every field feels 3x harder on mobile than desktop
2. **Single-column layout** — always. Never side-by-side fields on mobile
3. **48px minimum height** on inputs with 16px+ font size (prevents iOS Safari auto-zoom)
4. **Correct input types** — triggers appropriate keyboard:

```html
<input type="email">  <!-- @ and .com keys -->
<input type="tel">    <!-- Number pad -->
<input type="url">    <!-- .com and / keys -->
<input type="number"> <!-- Number pad -->
<input type="date">   <!-- Native date picker -->
```

5. **Autofill attributes** — enables one-tap fill from saved data:

```html
<input type="email" autocomplete="email">
<input type="text" autocomplete="name">
<input type="tel" autocomplete="tel">
<input type="text" autocomplete="street-address">
```

6. **Labels above fields** (not placeholder-only) — persist after user starts typing
7. **Inline validation** — show errors below the field immediately, don't wait for submit
8. **Input masks** for formatted fields (phone, credit card). Libraries: Cleave.js, react-input-mask

**CSS baseline:**

```css
input, select, textarea {
  min-height: 48px;
  padding: 12px;
  font-size: 16px; /* Prevents iOS auto-zoom */
}
```

## Mobile Navigation

**Patterns (choose one):**

| Pattern | Best for | Trade-off |
|---------|----------|-----------|
| Hamburger menu (☰) | Content-heavy sites | Saves space but reduces discoverability |
| Bottom tab bar | App-like experiences, e-commerce | Thumb-friendly, always visible; takes vertical space |
| Priority+ | Sites with 3-5 key pages | Shows top items, hides rest in overflow |

**Best practices:**
- Limit top-level items to 5-7
- Make search prominent — mobile users search more than browse
- Use sticky header for persistent access
- Simplify mega menus to accordion/drill-down on mobile
- Simplify breadcrumbs: `← Running Shoes` instead of full path

**Search must have autocomplete** — reduces typing and speeds discovery.

## Click-to-Call

Mobile enables instant calls. High-impact for: high-ticket items, complex products, local services, urgent needs.

```html
<a href="tel:+18005551234">📞 Call Now: 1-800-555-1234</a>
```

**Placement options:** sticky header icon, floating action button (bottom-right), or inline on product/service pages alongside chat.

**Test:** Click-to-call vs form submission. Calls = higher intent, faster close (requires sales team). Forms = scalable, trackable.

## Mobile CTA Design

**Size requirements:**
- Minimum: 44x44px (Apple) / 48x48px (Google)
- Recommended: 56px+ height, full-width

```css
.mobile-cta {
  min-height: 56px;
  width: 100%;
  font-size: 18px;
  font-weight: bold;
  border-radius: 8px;
  margin: 16px 0;
}
```

**Copy principle:** Mobile = brevity.
- Desktop: "Request a Free Consultation with Our Experts" → Mobile: "Get Free Consultation"
- Desktop: "Add to Cart and Continue Shopping" → Mobile: "Add to Cart"

**Patterns:** Full-width buttons, sticky bottom CTA (see Thumb Zone), primary + secondary (primary larger/bolder, secondary outlined).

## App Install Banners

If you have a mobile app, prompt engaged users to install.

**iOS Smart Banner:**

```html
<meta name="apple-itunes-app" content="app-id=123456789">
```

**When to show:** Engaged users (3+ pages, 2+ minutes), repeat visitors, users with cart items.
**When NOT to show:** First-time visitors, users who dismissed before, on checkout pages.

**Deep linking:** If app is installed, open content in app; otherwise fall back to web. Use Universal Links (iOS) / App Links (Android) rather than custom URI schemes.

## Mobile Page Speed

Speed impact is exponential on mobile. Google study: bounce probability goes from 32% (1-3s load) to 90% (1-5s load).

**Mobile-specific optimizations:**

1. **Responsive images** with `srcset` and `loading="lazy"` — serve device-appropriate sizes
2. **WebP/AVIF format** — 25-35% smaller than JPEG at same quality
3. **Inline critical CSS** — instant above-fold render; load full CSS async
4. **Minimize/defer JS** — code-split per page, `defer` non-critical scripts
5. **SSR over CSR** — faster initial render (server sends complete HTML)
6. **CDN** for static assets, **Brotli/Gzip** compression (70-90% text reduction)
7. **Preconnect** to third-party domains: `<link rel="preconnect" href="https://cdn.example.com">`
8. **Eliminate redirect chains** — each redirect adds a full round-trip

**Target Core Web Vitals (mobile):**

| Metric | Target |
|--------|--------|
| First Contentful Paint | <1.8s |
| Largest Contentful Paint | <2.5s |
| Time to Interactive | <3.8s |
| Cumulative Layout Shift | <0.1 |
| First Input Delay | <100ms |

**Tools:** Google PageSpeed Insights, Lighthouse mobile audit, WebPageTest, Chrome DevTools (throttle to 3G).

## AMP Considerations

AMP (Accelerated Mobile Pages) delivers near-instant loads (<1s) via stripped-down HTML, no custom JS, and Google caching. However, Google has reduced AMP's ranking advantage and the ecosystem has matured alternatives (SSR, edge rendering).

**Use AMP for:** Content pages, simple product pages, lead-gen landing pages with basic forms.
**Skip AMP for:** Checkout, interactive tools, rich media. The functionality constraints outweigh speed gains.

**Hybrid approach:** AMP landing page (fast acquisition from search) → non-AMP site for conversion (full functionality).

## Mobile Checkout Optimization

Mobile checkout has the highest drop-off rate. Key principles:

1. **Guest checkout default** — forced account creation kills mobile conversions
2. **Digital wallets front and center** — Apple Pay / Google Pay reduce checkout from 2-3 minutes to ~10 seconds

```text
[Apple Pay]  [Google Pay]
─── or enter info ───
[Guest Checkout Form]
```

3. **Minimize steps** — 2 maximum (ideally 1). Desktop tolerates 3-4; mobile doesn't
4. **Autofill everything** — especially `cc-number`, `cc-exp`, `cc-csc`
5. **Sticky progress indicator** and **sticky "Complete Order" CTA** with price shown
6. **Remove distractions** — hide main nav, no promos, no related products during checkout
7. **Real-time validation** — errors on blur, not on submit
8. **Progress saving** — if user abandons, save cart state and email recovery link with pre-filled info
9. **Click-to-call support** visible during checkout

**Case study:** E-commerce brand went from desktop-style checkout (7 steps, account required, small fields, no autofill) to mobile-optimized (2 steps, guest default, large fields, Apple/Google Pay). Result: mobile conversion 0.8% → 2.4% (200% increase).

## Mobile A/B Testing

**Critical rule:** Test mobile separately from desktop — behaviour differs too much for combined tests.

**High-value mobile test ideas:**

| Test | Expected Impact |
|------|----------------|
| Sticky vs non-sticky CTA | 10-30% click increase |
| Hamburger vs bottom tab nav | Audience-dependent |
| Click-to-call vs form | Measure leads, not just clicks |
| One-page vs multi-step checkout | Multi-step often wins on mobile |
| Accordion vs expanded content | Accordion reduces scroll fatigue |

**Mobile testing challenges:**
- **Smaller segments** — traffic splits across devices/OS/screen sizes. Run tests longer or segment by OS (iOS vs Android), not device model
- **Cross-device journeys** — users start mobile, finish desktop. Use user ID-based tracking, not cookies
- **OS differences** — iOS and Android users behave differently. Segment by OS

## Mobile CRO Checklist

**Performance:** Page load <3s on 3G | Images optimized (WebP, lazy) | Critical CSS inlined | JS deferred | CDN enabled

**Forms:** Single-column | 48px+ height | 16px+ font | Correct input types | Autofill attributes | Inline validation | Labels above fields

**Navigation:** Mobile-appropriate pattern | Search prominent | Breadcrumbs simplified | Sticky header

**CTAs:** 44px+ minimum (56px+ recommended) | Full-width | High contrast | Concise copy | Sticky on long pages

**Checkout:** Guest default | 1-2 steps | Digital wallets | Autofill | Progress indicator | Minimal distractions | Click-to-call support

**Content:** Short paragraphs (2-3 lines) | 16px+ font | Ample whitespace | Videos load on tap

**Usability:** No hover-only elements | Adequate tap spacing | No content-blocking popups | Landscape supported

**Testing:** iOS Safari + Android Chrome | Multiple screen sizes | 3G throttled | Touch gestures verified

---
