## Common Use Cases

1. **Performance monitoring** — inspect Core Web Vitals, then use Debug View to trace poor LCP elements back to a selector you can optimize.

   ```typescript
   // 1. Enable Web Analytics
   // 2. Dashboard → Core Web Vitals → LCP
   // 3. Debug View shows top 5 problematic elements
   document.querySelector('.hero-image') // Example selector from Debug View
   // 4. Optimize the element (lazy loading, compression, etc.)
   ```

2. **Bot traffic filtering** — exclude bots so dashboard metrics reflect human traffic only.

   ```text
   Dashboard filters:
   - Exclude Bots: Yes
   ```

3. **Multi-site analytics** — compare traffic across properties in one account.

   ```text
   Proxied sites: Unlimited
   Non-proxied: Up to 10 sites

   View by dimension:
   - Site: example.com
   - Site: blog.example.com
   ```

4. **Geographic analysis** — combine country and device filters to isolate audience segments.

   ```text
   Filter by:
   - Country: United States
   - Device type: Mobile
   ```
