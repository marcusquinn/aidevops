<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

## Common Use Cases

1. **LCP triage** — open Core Web Vitals → LCP → Debug View, inspect the reported selector, then optimize that element.

   ```typescript
   document.querySelector('.hero-image') // Selector copied from Debug View
   ```

2. **Human-only reporting** — set `Exclude Bots: Yes` before comparing traffic or engagement trends.

3. **Multi-site comparisons** — use the `Site` dimension to compare proxied properties (unlimited) and up to 10 non-proxied sites.

   ```text
   Site:
   - example.com
   - blog.example.com
   ```

4. **Segment analysis** — combine filters such as `Country: United States` and `Device type: Mobile` before investigating behavior.
