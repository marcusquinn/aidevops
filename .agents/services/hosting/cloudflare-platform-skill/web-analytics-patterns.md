## Common Use Cases

1. **Core Web Vitals triage** — use the LCP debug view to map slow pages back to the element that needs optimization.

   ```typescript
   // 1. Enable Web Analytics
   // 2. Dashboard → Core Web Vitals → LCP
   // 3. Debug View lists the top 5 problematic elements
   document.querySelector('.hero-image') // Example selector from Debug View
   // 4. Optimize the element (lazy loading, compression, preloading)
   ```

2. **Human-only reporting** — enable bot exclusion before comparing traffic or engagement so the dashboard reflects real visitors.

   ```text
   Dashboard filters:
   - Exclude Bots: Yes
   ```

3. **Multi-site comparisons** — track several properties in one account, then pivot on the `Site` dimension to compare them.

   ```text
   Proxied sites: Unlimited
   Non-proxied sites: Up to 10

   Site dimension:
   - example.com
   - blog.example.com
   ```

4. **Audience segmentation** — combine geography and device filters to isolate a cohort before investigating trends.

   ```text
   Filter by:
   - Country: United States
   - Device type: Mobile
   ```
