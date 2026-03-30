---
description: Google Rich Results Test via browser automation (API deprecated)
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

# Google Rich Results Test

- **URL**: `https://search.google.com/test/rich-results`
- **API**: Deprecated — use browser automation (Playwright) or manual testing
- **Alternative**: Schema.org Validator (`https://validator.schema.org/`) — faster, no CAPTCHA, no Google-specific eligibility

## Manual Testing

1. Go to `https://search.google.com/test/rich-results`
2. Enter URL or paste code snippet; select Smartphone or Desktop
3. Review critical errors, non-critical issues, and rich result preview

## Browser Automation (Playwright)

```javascript
// rich-results-test.js
import { chromium } from 'playwright';

const TEST_URL = process.argv[2];
if (!TEST_URL) { console.error('Usage: node rich-results-test.js <url>'); process.exit(1); }

async function main() {
  const browser = await chromium.launch({ headless: false });
  const page = await browser.newPage();
  await page.goto('https://search.google.com/test/rich-results');
  const input = await page.waitForSelector('input[type="url"], input[type="text"]', { timeout: 10000 });
  await input.fill(TEST_URL);
  await page.keyboard.press('Enter');
  console.log('Waiting for results (up to 60s). Complete CAPTCHA if prompted.');
  try {
    await page.waitForSelector('.result-card, .error-card, [data-result]', { timeout: 60000 });
    await page.screenshot({ path: 'rich-results.png', fullPage: true });
  } catch {
    await page.screenshot({ path: 'rich-results-timeout.png', fullPage: true });
  }
  // await browser.close(); // keep open for manual inspection
}
main().catch(console.error);
```

```bash
node rich-results-test.js https://example.com

# Batch test
for url in https://example.com https://example.com/article https://example.com/product; do
  node rich-results-test.js "$url"; sleep 5
done
```

## JSON-LD Extraction

```bash
curl -sL "https://example.com" \
  | grep -oE '<script type="application/ld\+json">[^<]+</script>' \
  | sed 's/<[^>]*>//g' \
  | jq . 2>/dev/null || echo "No valid JSON-LD found"
```

## Rich Result Types

| Type | Schema | Common Use |
|------|--------|------------|
| Article | `Article`, `NewsArticle` | Blog posts, news |
| Product | `Product` | E-commerce listings |
| FAQ | `FAQPage` | Question/answer pages |
| HowTo | `HowTo` | Step-by-step guides |
| Recipe | `Recipe` | Cooking instructions |
| Review | `Review` | Product/service reviews |
| Event | `Event` | Upcoming events |
| LocalBusiness | `LocalBusiness` | Business listings |
| BreadcrumbList | `BreadcrumbList` | Navigation breadcrumbs |
| VideoObject | `VideoObject` | Video content |
| JobPosting | `JobPosting` | Job listings |
| Course | `Course` | Educational content |

## Related

- `seo/debug-opengraph.md` - Open Graph meta tag validation
- `seo/site-crawler.md` - Bulk structured data auditing
- `tools/browser/playwright.md` - Browser automation for JS-rendered pages
