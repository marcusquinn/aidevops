<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Thumb Zone Design

- **Bottom third (natural rest):** Primary CTAs — Buy Now, Add to Cart, Submit
- **Middle third (easy reach):** Navigation, filters, secondary actions
- **Top third (hard to reach):** Headings, images, informational content

**Sticky CTA** — highest-impact mobile CRO change (10-30% click increase). CTA stays visible regardless of scroll position.

**CTA sizing:** Min 44x44px (Apple) / 48x48px (Google), recommended 56px+ height full-width. Mobile copy = brevity ("Get Free Consultation" not "Request a Free Consultation with Our Experts").

```css
.mobile-cta { min-height: 56px; width: 100%; font-size: 18px; font-weight: bold; border-radius: 8px; margin: 16px 0; }
```
