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
- **Rich result types**: [Google's structured data gallery](https://developers.google.com/search/docs/appearance/structured-data/search-gallery)

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

  // Keep browser open for manual inspection
  // await browser.close();
}

main().catch(console.error);
```

### Batch Testing

```bash
for url in https://example.com https://example.com/article https://example.com/product; do
  echo "--- Testing: $url ---"
  node rich-results-test.js "$url"
  sleep 5
done
```

## JSON-LD Extraction

```bash
curl -sL "https://example.com" \
  | grep -oE '<script type="application/ld\+json">[^<]+</script>' \
  | sed 's/<[^>]*>//g' \
  | jq . 2>/dev/null || echo "No valid JSON-LD found"
```

<!-- AI-CONTEXT-END -->

## Related

- `seo/debug-opengraph.md` - Open Graph meta tag validation
- `seo/site-crawler.md` - Bulk structured data auditing
- `tools/browser/playwright.md` - Browser automation for JS-rendered pages
