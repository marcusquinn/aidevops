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
- **API Status**: **Deprecated** (standalone API no longer available)
- **Method**: Browser automation (Playwright) or manual testing
- **Alternatives**: Schema.org Validator (`https://validator.schema.org/`)

## Manual Testing

1. Go to [Google Rich Results Test](https://search.google.com/test/rich-results)
2. Enter the URL to test or paste the code snippet
3. Select "Smartphone" or "Desktop" user agent
4. Click "Test URL" or "Test Code"
5. Review critical errors, non-critical issues, and preview the result

## Browser Automation (Playwright)

Since the API is deprecated, use Playwright to automate the testing process.

### Test a URL

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

Run with:

```bash
node rich-results-test.js https://example.com
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

<!-- AI-CONTEXT-END -->

## Schema Validation (Alternative)

For pure syntax validation without Google's rendering context, use the Schema.org Validator.

- **URL**: `https://validator.schema.org/`
- **Advantage**: Faster, no CAPTCHA, API-friendly
- **Disadvantage**: Does not show Google-specific eligibility (e.g., Merchant Center requirements)

### Quick JSON-LD Extraction

```bash
# Extract JSON-LD from a page
curl -sL "https://example.com" \
  | grep -oE '<script type="application/ld\+json">[^<]+</script>' \
  | sed 's/<[^>]*>//g' \
  | jq . 2>/dev/null || echo "No valid JSON-LD found"
```

## Rich Result Types

Google supports rich results for these structured data types:

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
