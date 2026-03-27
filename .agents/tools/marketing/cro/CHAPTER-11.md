# Chapter 11: Mobile CRO

60%+ of web traffic is mobile, yet mobile converts 1-3% vs desktop 3-5%. Improving mobile from 1.5% to 2.5% on 60% mobile traffic increases overall conversions ~60%.

## Thumb Zone Design

Place elements by thumb reachability:

- **Bottom third (natural rest):** Primary CTAs — Buy Now, Add to Cart, Submit
- **Middle third (easy reach):** Navigation, filters, secondary actions
- **Top third (hard to reach):** Headings, images, informational content

**Sticky CTA** — highest-impact mobile CRO change (10-30% click increase). CTA stays visible regardless of scroll position.

**CTA sizing:** Min 44x44px (Apple) / 48x48px (Google), recommended 56px+ height full-width. Mobile copy = brevity ("Get Free Consultation" not "Request a Free Consultation with Our Experts").

```css
.mobile-cta { min-height: 56px; width: 100%; font-size: 18px; font-weight: bold; border-radius: 8px; margin: 16px 0; }
```

## Mobile Form Optimization

1. **Minimize fields** — target <5 (each feels 3x harder on mobile)
2. **Single-column layout** — always
3. **48px min height**, 16px+ font (prevents iOS Safari auto-zoom)
4. **Correct input types + autofill** — triggers appropriate keyboard and one-tap fill:

```html
<input type="email" autocomplete="email">   <!-- @ and .com keys -->
<input type="tel" autocomplete="tel">       <!-- Number pad -->
<input type="url">                          <!-- .com and / keys -->
<input type="number">                       <!-- Number pad -->
<input type="date">                         <!-- Native date picker -->
<input type="text" autocomplete="name">
<input type="text" autocomplete="street-address">
```

5. **Labels above fields** (not placeholder-only)
6. **Inline validation** — errors on blur, not on submit
7. **Input masks** for formatted fields (Cleave.js, react-input-mask)

```css
input, select, textarea { min-height: 48px; padding: 12px; font-size: 16px; /* Prevents iOS auto-zoom */ }
```

## Mobile Navigation

| Pattern | Best for | Trade-off |
|---------|----------|-----------|
| Hamburger (☰) | Content-heavy sites | Saves space, reduces discoverability |
| Bottom tab bar | App-like / e-commerce | Thumb-friendly, takes vertical space |
| Priority+ | 3-5 key pages | Shows top items, overflow for rest |

Limit top-level items to 5-7. Search prominent with autocomplete. Sticky header. Mega menus → accordion/drill-down. Breadcrumbs: `← Running Shoes` not full path.

## Click-to-Call and App Banners

**Click-to-call** — high-impact for high-ticket, complex, local, or urgent needs:

```html
<a href="tel:+18005551234">📞 Call Now: 1-800-555-1234</a>
```

Place in sticky header, FAB (bottom-right), or inline on product pages. Test vs form — calls = higher intent/faster close; forms = scalable/trackable.

**iOS Smart Banner:** `<meta name="apple-itunes-app" content="app-id=123456789">`

Show for engaged users (3+ pages, 2+ min), repeat visitors, cart holders. Never on first visit, after dismissal, or during checkout. Use Universal Links (iOS) / App Links (Android) — not custom URI schemes.

## Mobile Page Speed

Bounce probability: 32% at 1-3s → 90% at 1-5s.

1. Responsive images: `srcset` + `loading="lazy"`
2. WebP/AVIF (25-35% smaller than JPEG)
3. Inline critical CSS, async load rest
4. Code-split JS per page, `defer` non-critical
5. SSR over CSR for faster initial render
6. CDN + Brotli/Gzip (70-90% text reduction)
7. `<link rel="preconnect" href="https://cdn.example.com">`
8. Eliminate redirect chains (each = full round-trip)

**Core Web Vitals (mobile):** FCP <1.8s | LCP <2.5s | TTI <3.8s | CLS <0.1 | FID <100ms

**Tools:** PageSpeed Insights, Lighthouse, WebPageTest, Chrome DevTools (3G throttle).

## AMP Considerations

Near-instant loads (<1s) but Google has reduced ranking advantage; SSR/edge rendering are mature alternatives. **Use for:** content pages, simple product pages, basic lead-gen. **Skip for:** checkout, interactive tools, rich media. **Hybrid:** AMP landing (fast acquisition) → full site for conversion.

## Mobile Checkout

Highest drop-off rate:

1. **Guest checkout default** — forced account creation kills conversions
2. **Digital wallets front and center** — Apple Pay / Google Pay reduce checkout to ~10s
3. **Max 2 steps** (ideally 1)
4. **Autofill everything** — especially `cc-number`, `cc-exp`, `cc-csc`
5. **Sticky progress indicator** + "Complete Order" CTA with price
6. **Remove distractions** — hide nav, no promos during checkout
7. **Real-time validation** — errors on blur
8. **Progress saving** — save cart on abandon, email recovery with pre-filled info
9. **Click-to-call support** visible during checkout

**Case study:** 7-step desktop checkout → 2-step mobile-optimized (guest default, large fields, Apple/Google Pay). Result: 0.8% → 2.4% conversion (200% increase).

## Mobile A/B Testing

Test mobile separately from desktop — behaviour differs too much for combined tests.

| Test | Expected Impact |
|------|----------------|
| Sticky vs non-sticky CTA | 10-30% click increase |
| Hamburger vs bottom tab nav | Audience-dependent |
| Click-to-call vs form | Measure leads, not just clicks |
| One-page vs multi-step checkout | Multi-step often wins on mobile |
| Accordion vs expanded content | Reduces scroll fatigue |

**Challenges:** Smaller segments (run longer, segment by OS not device), cross-device journeys (user ID tracking not cookies), iOS vs Android behavioural differences.

## Mobile CRO Checklist

**Performance:** Load <3s on 3G | Images optimized (WebP, lazy) | Critical CSS inlined | JS deferred | CDN enabled

**Forms:** Single-column | 48px+ height | 16px+ font | Correct input types | Autofill | Inline validation | Labels above

**Navigation:** Mobile-appropriate pattern | Search prominent | Breadcrumbs simplified | Sticky header

**CTAs:** 44px+ min (56px+ recommended) | Full-width | High contrast | Concise copy | Sticky on long pages

**Checkout:** Guest default | 1-2 steps | Digital wallets | Autofill | Progress indicator | Minimal distractions | Click-to-call

**Content:** Short paragraphs (2-3 lines) | 16px+ font | Ample whitespace | Videos load on tap

**Usability:** No hover-only elements | Adequate tap spacing | No content-blocking popups | Landscape supported

**Testing:** iOS Safari + Android Chrome | Multiple screen sizes | 3G throttled | Touch gestures verified

---
