<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Mobile Page Speed

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
