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

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Validate structured data and preview rich snippets
- **URL**: `https://search.google.com/test/rich-results`
- **API Status**: **Deprecated** (standalone API removed) -- browser automation required
- **Alternative**: Schema.org Validator (`https://validator.schema.org/`) -- faster, no CAPTCHA, no Google-specific eligibility

## Browser Automation (Playwright)

Primary method. Run `node rich-results-test.js <url>`:

```javascript
// rich-results-test.js
import { chromium } from 'playwright';

const TEST_URL = process.argv[2];

if (!TEST_URL) {
  console.error('Usage: node rich-results-test.js <url>');
  process.exit(1);
}

async function main() {
  const browser = await chromium.launch({ headless: false });
  const page = await browser.newPage();

  console.log(`Testing: ${TEST_URL}`);

  await page.goto('https://search.google.com/test/rich-results');

  // Wait for input field and enter URL
  const input = await page.waitForSelector(
    'input[type="url"], input[type="text"]',
    { timeout: 10000 }
  );
  await input.fill(TEST_URL);
  await page.keyboard.press('Enter');

  console.log('Test started... waiting for results (up to 60s)');
  console.log('Complete CAPTCHA if prompted.');

  try {
    await page.waitForSelector('.result-card, .error-card, [data-result]', {
      timeout: 60000,
    });
    console.log('Results loaded.');

    await page.screenshot({ path: 'rich-results.png', fullPage: true });
    console.log('Screenshot saved to rich-results.png');
  } catch {
    console.log('Timed out waiting for results or CAPTCHA encountered.');
    await page.screenshot({ path: 'rich-results-timeout.png', fullPage: true });
  }

  // Keep open for manual inspection
  // await browser.close();
}

main().catch(console.error);
```

### Batch Testing

```bash
# Test multiple URLs
for url in https://example.com https://example.com/article https://example.com/product; do
  echo "--- Testing: $url ---"
  node rich-results-test.js "$url"
  sleep 5
done
```

## JSON-LD Extraction

```bash
# Extract JSON-LD from a page
curl -sL "https://example.com" \
  | grep -oE '<script type="application/ld\+json">[^<]+</script>' \
  | sed 's/<[^>]*>//g' \
  | jq . 2>/dev/null || echo "No valid JSON-LD found"
```

## Manual Testing

1. Open [Rich Results Test](https://search.google.com/test/rich-results)
2. Enter URL or paste code snippet, select user agent (Smartphone/Desktop)
3. Click "Test URL" / "Test Code", review errors and rich snippet preview

## Common Rich Result Types

Full list: [Google's structured data gallery](https://developers.google.com/search/docs/appearance/structured-data/search-gallery).

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

<!-- AI-CONTEXT-END -->

## Related

- `seo/debug-opengraph.md` - Open Graph meta tag validation
- `seo/site-crawler.md` - Bulk structured data auditing
- `tools/browser/playwright.md` - Browser automation for JS-rendered pages
