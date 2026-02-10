---
description: Email design testing - local Playwright rendering and Email on Acid API integration
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Email Design Testing

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Visual email rendering tests — local Playwright screenshots + Email on Acid API for real-client previews
- **Local tool**: Playwright (headless Chromium/WebKit) for fast local rendering
- **Remote tool**: Email on Acid API v5 for 90+ real email client screenshots
- **Credentials**: `aidevops secret set EOA_API_KEY` + `aidevops secret set EOA_API_PASSWORD`
- **Related**: `email-testing.md` (HTML/CSS validation), `email-health-check.md` (DNS auth)

**Quick commands:**

```bash
# Local Playwright rendering (free, instant)
email-design-test-helper.sh render newsletter.html
email-design-test-helper.sh render newsletter.html --dark-mode
email-design-test-helper.sh render newsletter.html --viewports mobile,tablet,desktop

# Email on Acid API (paid, real clients)
email-design-test-helper.sh eoa-test newsletter.html
email-design-test-helper.sh eoa-results <test_id>
email-design-test-helper.sh eoa-clients
```

<!-- AI-CONTEXT-END -->

## Overview

Email design testing validates that HTML emails render correctly across email clients. This subagent provides two complementary approaches:

| Approach | Speed | Cost | Accuracy | Use Case |
|----------|-------|------|----------|----------|
| **Local Playwright** | ~2s per viewport | Free | Approximation (WebKit/Chromium only) | Rapid iteration, CI/CD gates, dark mode checks |
| **Email on Acid API** | 30-120s per test | Paid (per-test) | Real clients (Outlook, Gmail, Apple Mail, etc.) | Pre-send validation, client sign-off |

**Recommended workflow:**

1. Iterate locally with Playwright (fast feedback loop)
2. Run `email-testing.md` validation (HTML structure, CSS compatibility)
3. Submit to Email on Acid for final real-client verification

## Local Playwright Rendering

Use Playwright to render HTML emails locally and capture screenshots. This catches layout issues, dark mode problems, and responsive breakpoints without any external service.

### Basic Rendering

```bash
# Render email and save screenshot
email-design-test-helper.sh render newsletter.html

# Output: ./email-screenshots/newsletter-desktop.png
```

### Playwright Script (Direct Usage)

For maximum control, use Playwright directly:

```javascript
import { chromium, webkit } from 'playwright';
import { readFileSync } from 'fs';

const html = readFileSync('newsletter.html', 'utf-8');

// Desktop rendering (Chromium — approximates Gmail web)
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({
  viewport: { width: 800, height: 600 },
});
await page.setContent(html, { waitUntil: 'networkidle' });
await page.screenshot({ path: 'desktop-chromium.png', fullPage: true });

// Mobile rendering (WebKit — approximates Apple Mail/iOS)
const wkBrowser = await webkit.launch({ headless: true });
const mobilePage = await wkBrowser.newPage({
  viewport: { width: 375, height: 812 },
  deviceScaleFactor: 3,
  isMobile: true,
});
await mobilePage.setContent(html, { waitUntil: 'networkidle' });
await mobilePage.screenshot({ path: 'mobile-webkit.png', fullPage: true });

await browser.close();
await wkBrowser.close();
```

### Viewport Presets

Standard viewports that match common email reading contexts:

| Preset | Width | Height | Engine | Approximates |
|--------|-------|--------|--------|--------------|
| `mobile` | 375 | 812 | WebKit | iPhone / Apple Mail iOS |
| `mobile-android` | 412 | 915 | Chromium | Samsung / Gmail Android |
| `tablet` | 768 | 1024 | WebKit | iPad / Apple Mail |
| `desktop` | 800 | 600 | Chromium | Gmail web, Yahoo web |
| `outlook-preview` | 657 | 600 | Chromium | Outlook reading pane |
| `desktop-wide` | 1200 | 800 | Chromium | Full-width webmail |

```javascript
const viewports = {
  mobile:          { width: 375,  height: 812,  engine: 'webkit',   scale: 3 },
  'mobile-android': { width: 412,  height: 915,  engine: 'chromium', scale: 2.625 },
  tablet:          { width: 768,  height: 1024, engine: 'webkit',   scale: 2 },
  desktop:         { width: 800,  height: 600,  engine: 'chromium', scale: 1 },
  'outlook-preview': { width: 657,  height: 600,  engine: 'chromium', scale: 1 },
  'desktop-wide':  { width: 1200, height: 800,  engine: 'chromium', scale: 1 },
};
```

### Dark Mode Testing

Simulate dark mode using Playwright's `colorScheme` emulation:

```javascript
import { webkit } from 'playwright';
import { readFileSync } from 'fs';

const html = readFileSync('newsletter.html', 'utf-8');

const browser = await webkit.launch({ headless: true });

// Light mode baseline
const lightPage = await browser.newPage({
  viewport: { width: 375, height: 812 },
  colorScheme: 'light',
});
await lightPage.setContent(html, { waitUntil: 'networkidle' });
await lightPage.screenshot({ path: 'mobile-light.png', fullPage: true });

// Dark mode
const darkPage = await browser.newPage({
  viewport: { width: 375, height: 812 },
  colorScheme: 'dark',
});
await darkPage.setContent(html, { waitUntil: 'networkidle' });
await darkPage.screenshot({ path: 'mobile-dark.png', fullPage: true });

await browser.close();
```

**What dark mode testing catches:**

- Missing `prefers-color-scheme` media queries
- Hardcoded white backgrounds that blind users in dark mode
- Logos/images with no dark-mode alternative
- Text that becomes invisible against inverted backgrounds

### Image Blocking Simulation

Simulate image-blocked rendering by stripping `<img>` tags:

```javascript
import { chromium } from 'playwright';
import { readFileSync } from 'fs';

const html = readFileSync('newsletter.html', 'utf-8');

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 800, height: 600 } });

// Block all image requests
await page.route('**/*.{png,jpg,jpeg,gif,svg,webp}', (route) => route.abort());
await page.setContent(html, { waitUntil: 'networkidle' });

// Also hide inline base64 images via CSS
await page.addStyleTag({ content: 'img { visibility: hidden !important; }' });

await page.screenshot({ path: 'images-blocked.png', fullPage: true });
await browser.close();
```

**What image blocking testing catches:**

- Missing `alt` text on images
- Layout collapse when images fail to load
- Critical content conveyed only through images

### Full Local Test Suite

Run all viewports, dark mode, and image blocking in parallel:

```javascript
import { chromium, webkit } from 'playwright';
import { readFileSync, mkdirSync } from 'fs';

const html = readFileSync(process.argv[2] || 'newsletter.html', 'utf-8');
const outDir = './email-screenshots';
mkdirSync(outDir, { recursive: true });

const tests = [
  { name: 'desktop',       engine: 'chromium', vp: { width: 800,  height: 600 },  scheme: 'light' },
  { name: 'desktop-dark',  engine: 'chromium', vp: { width: 800,  height: 600 },  scheme: 'dark' },
  { name: 'mobile',        engine: 'webkit',   vp: { width: 375,  height: 812 },  scheme: 'light', scale: 3 },
  { name: 'mobile-dark',   engine: 'webkit',   vp: { width: 375,  height: 812 },  scheme: 'dark',  scale: 3 },
  { name: 'tablet',        engine: 'webkit',   vp: { width: 768,  height: 1024 }, scheme: 'light', scale: 2 },
  { name: 'outlook-pane',  engine: 'chromium', vp: { width: 657,  height: 600 },  scheme: 'light' },
];

const engines = {
  chromium: await chromium.launch({ headless: true }),
  webkit:  await webkit.launch({ headless: true }),
};

await Promise.all(tests.map(async (t) => {
  const page = await engines[t.engine].newPage({
    viewport: t.vp,
    colorScheme: t.scheme,
    deviceScaleFactor: t.scale || 1,
  });
  await page.setContent(html, { waitUntil: 'networkidle' });
  await page.screenshot({ path: `${outDir}/${t.name}.png`, fullPage: true });
  await page.close();
}));

for (const b of Object.values(engines)) await b.close();
console.log(`Screenshots saved to ${outDir}/`);
```

### Limitations of Local Rendering

Local Playwright rendering does **not** replicate:

| Limitation | Why | Mitigation |
|-----------|-----|------------|
| Outlook Word engine | Outlook uses Microsoft Word for HTML rendering — no browser replicates this | Use Email on Acid for Outlook testing |
| Gmail `<style>` stripping | Gmail strips `<style>` blocks and rewrites class names | Inline all CSS before testing; use `email-testing.md` CSS check |
| Yahoo/AOL quirks | Custom rendering engines with partial CSS support | Use Email on Acid for Yahoo testing |
| Real mobile rendering | iOS Mail and Gmail app have subtle differences from WebKit/Chromium | Use Email on Acid for final mobile verification |

## Email on Acid API Integration

Email on Acid (EoA) provides real-client screenshots across 90+ email clients and devices. The API v5 enables programmatic testing.

### Authentication

EoA uses HTTP Basic Authentication. Store credentials securely:

```bash
# Store credentials (NEVER pass in conversation)
aidevops secret set EOA_API_KEY
aidevops secret set EOA_API_PASSWORD

# Test authentication
curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" \
  https://api.emailonacid.com/v5/auth
# Expected: {"success": true}
```

**Sandbox mode** (free, no credits consumed):

```bash
# Use sandbox credentials for testing the integration
curl -s -u "sandbox:sandbox" \
  https://api.emailonacid.com/v5/auth
```

### API Endpoints

Base URL: `https://api.emailonacid.com/v5`

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/auth` | GET | Test authentication |
| `/email/clients` | GET | List available email clients |
| `/email/clients/default` | GET | Get default client list |
| `/email/clients/default` | PUT | Set default client list |
| `/email/tests` | POST | Create a new email test |
| `/email/tests` | GET | List all tests |
| `/email/tests/<id>` | GET | Get test status (completed/processing/bounced) |
| `/email/tests/<id>` | DELETE | Delete a test |
| `/email/tests/<id>/results` | GET | Get screenshot URLs for all clients |
| `/email/tests/<id>/results/<client>` | GET | Get screenshot for specific client |
| `/email/tests/<id>/results/reprocess` | PUT | Retake failed screenshots |
| `/email/tests/<id>/content` | GET | Get submitted HTML |
| `/email/tests/<id>/content/inlinecss` | GET | Get HTML with inlined CSS |
| `/email/tests/<id>/spam/results` | GET | Get spam test results |

### Create a Test

```bash
# Submit HTML email for testing
curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" \
  -H "Content-Type: application/json" \
  -X POST https://api.emailonacid.com/v5/email/tests \
  -d '{
    "subject": "Newsletter - February 2026",
    "html": "'"$(cat newsletter.html | jq -Rs .)"'",
    "clients": ["outlook16", "gmail_chr26_win", "iphone6p_9", "appmail14"],
    "image_blocking": true
  }'
# Returns: {"id": "<test_id>"}
```

**Or test from a URL:**

```bash
curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" \
  -H "Content-Type: application/json" \
  -X POST https://api.emailonacid.com/v5/email/tests \
  -d '{
    "subject": "Newsletter Preview",
    "url": "https://example.com/email-preview.html",
    "image_blocking": true
  }'
```

### Poll for Results

Tests take 30-120 seconds. Poll the test info endpoint until all clients show `completed`:

```bash
# Check test status
curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" \
  https://api.emailonacid.com/v5/email/tests/<test_id>

# Response includes:
# "completed": ["outlook16", "iphone6p_9"]
# "processing": ["gmail_chr26_win"]
# "bounced": []
```

**Polling script:**

```bash
#!/usr/bin/env bash
set -euo pipefail

local test_id="$1"
local max_attempts=30
local attempt=0

while [ "$attempt" -lt "$max_attempts" ]; do
  local status
  status=$(curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" \
    "https://api.emailonacid.com/v5/email/tests/${test_id}")

  local processing
  processing=$(echo "$status" | jq -r '.processing | length')

  if [ "$processing" -eq 0 ]; then
    echo "All screenshots complete"
    echo "$status" | jq .
    return 0
  fi

  echo "Still processing $processing clients... (attempt $((attempt + 1))/$max_attempts)"
  sleep 5
  attempt=$((attempt + 1))
done

echo "Timed out waiting for results"
return 1
```

### Get Screenshot URLs

```bash
# Get all results with screenshot URLs
curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" \
  https://api.emailonacid.com/v5/email/tests/<test_id>/results

# Get specific client result
curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" \
  https://api.emailonacid.com/v5/email/tests/<test_id>/results/outlook16
```

**Response structure per client:**

```json
{
  "outlook16": {
    "id": "outlook16",
    "display_name": "Outlook 2016",
    "client": "Outlook 2016",
    "os": "Windows",
    "category": "Application",
    "screenshots": {
      "default": "<url>",
      "no_images": "<url>"
    },
    "thumbnail": "<url>",
    "full_thumbnail": "<url>",
    "status": "Complete",
    "status_details": {
      "submitted": 1739180000,
      "completed": 1739180045,
      "attempts": 1
    }
  }
}
```

**Screenshot URL authentication:** URLs support either Basic Auth (persistent, valid for 90 days) or presigned URLs (valid for 24 hours, no auth needed). Always call Get Results for fresh URLs rather than caching them.

### Download Screenshots

```bash
# Download all screenshots for a test
local test_id="$1"
local out_dir="./eoa-screenshots/${test_id}"
mkdir -p "$out_dir"

curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" \
  "https://api.emailonacid.com/v5/email/tests/${test_id}/results" \
  | jq -r 'to_entries[] | "\(.key) \(.value.screenshots.default)"' \
  | while read -r client url; do
    curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" \
      -o "${out_dir}/${client}.png" "$url"
    echo "Downloaded: ${client}.png"
  done
```

### List Available Clients

```bash
# Get all available email clients
curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" \
  https://api.emailonacid.com/v5/email/clients \
  | jq '.clients | to_entries[] | {id: .key, name: .value.client, os: .value.os, category: .value.category}'
```

**Common client IDs:**

| Client ID | Display Name | Category |
|-----------|-------------|----------|
| `outlook16` | Outlook 2016 | Application |
| `outlook19` | Outlook 2019 | Application |
| `ol365_win` | Outlook 365 (Windows) | Application |
| `gmail_chr26_win` | Gmail (Chrome/Windows) | Web |
| `gmail_and11` | Gmail (Android 11) | Mobile |
| `iphone6p_9` | iPhone 6+ (iOS 9) | Mobile |
| `appmail14` | Apple Mail (macOS 14) | Application |
| `yahoo_chr26_win` | Yahoo (Chrome/Windows) | Web |
| `thunderbird_win` | Thunderbird (Windows) | Application |

### Reprocess Failed Screenshots

```bash
# Reprocess specific clients that returned bad results
curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" \
  -H "Content-Type: application/json" \
  -X PUT "https://api.emailonacid.com/v5/email/tests/<test_id>/results/reprocess" \
  -d '{"clients": ["outlook16", "gmail_chr26_win"]}'
```

### Combined Spam + Rendering Test

```bash
curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" \
  -H "Content-Type: application/json" \
  -X POST https://api.emailonacid.com/v5/email/tests \
  -d '{
    "subject": "Newsletter - February 2026",
    "html": "'"$(cat newsletter.html | jq -Rs .)"'",
    "clients": ["outlook16", "gmail_chr26_win", "iphone6p_9"],
    "spam": {
      "test_method": "eoa",
      "from_address": "newsletter@example.com"
    }
  }'
```

## CI/CD Integration

### Local Playwright Gate (Pre-Commit / PR Check)

Add to your CI pipeline to catch rendering regressions before merge:

```yaml
# .github/workflows/email-test.yml
name: Email Design Test
on:
  pull_request:
    paths: ['emails/**', 'templates/**']

jobs:
  render-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
      - run: npx playwright install --with-deps chromium webkit
      - run: node scripts/email-render-test.js emails/*.html
      - uses: actions/upload-artifact@v4
        with:
          name: email-screenshots
          path: email-screenshots/
```

### Email on Acid Gate (Pre-Deploy)

For critical sends, gate deployment on EoA results:

```bash
#!/usr/bin/env bash
set -euo pipefail

local html_file="$1"
local subject="$2"

# Submit test
local response
response=$(curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" \
  -H "Content-Type: application/json" \
  -X POST https://api.emailonacid.com/v5/email/tests \
  -d "{
    \"subject\": \"${subject}\",
    \"html\": $(jq -Rs . < "$html_file"),
    \"clients\": [\"outlook16\", \"gmail_chr26_win\", \"iphone6p_9\", \"appmail14\"]
  }")

local test_id
test_id=$(echo "$response" | jq -r '.id')
echo "EoA test created: $test_id"

# Poll until complete (max 3 minutes)
local attempt=0
while [ "$attempt" -lt 36 ]; do
  local info
  info=$(curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" \
    "https://api.emailonacid.com/v5/email/tests/${test_id}")

  local processing
  processing=$(echo "$info" | jq -r '.processing | length')
  local bounced
  bounced=$(echo "$info" | jq -r '.bounced | length')

  if [ "$processing" -eq 0 ]; then
    if [ "$bounced" -gt 0 ]; then
      echo "WARNING: $bounced clients bounced"
      echo "$info" | jq '.bounced'
    fi
    echo "Test complete. View results at: https://app.emailonacid.com/app/email-testing/$test_id"
    return 0
  fi

  sleep 5
  attempt=$((attempt + 1))
done

echo "ERROR: EoA test timed out after 3 minutes"
return 1
```

## Recommended Testing Workflow

```text
1. Edit HTML email
   |
2. Local Playwright render (2s)
   ├── Desktop + mobile viewports
   ├── Dark mode light/dark
   └── Image blocking simulation
   |
3. HTML/CSS validation (email-testing.md)
   ├── CSS compatibility check
   ├── Dark mode meta tags
   └── Gmail 102KB clip limit
   |
4. Email on Acid API test (60-120s)
   ├── Outlook 2016/2019/365
   ├── Gmail web + mobile
   ├── Apple Mail desktop + iOS
   └── Yahoo, Thunderbird
   |
5. Review EoA screenshots
   ├── Fix rendering issues
   └── Reprocess if needed
   |
6. DNS health check (email-health-check.md)
   └── SPF, DKIM, DMARC, MX
   |
7. Send
```

## Troubleshooting

### Local Playwright Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| Fonts look different | System fonts vary by OS | Use web-safe fonts or embed via `@font-face` |
| Images not loading | Relative paths in HTML | Use absolute URLs or `file://` protocol |
| Media queries ignored | Viewport not set correctly | Ensure `isMobile: true` for mobile viewports |
| Dark mode not triggering | Missing `colorScheme` option | Set `colorScheme: 'dark'` in page context |

### Email on Acid API Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `AccessDenied` | Invalid credentials | Verify API key and password with `/v5/auth` |
| `RateLimited` | Too many requests | Reduce request frequency; check plan limits |
| `NoSource` | Missing `html` or `url` | Provide either `html` (string) or `url` (string) |
| `InvalidClient` | Bad client ID | Fetch valid IDs from `/v5/email/clients` |
| Screenshots stuck on `Processing` | Server delay | Wait 3 minutes, then call reprocess endpoint |
| `TestLimitReached` | Monthly quota exceeded | Contact EoA support or upgrade plan |

### Encoding Issues

EoA expects HTML encoded per the `transfer_encoding` field (default: `8bit`). For HTML with special characters:

```bash
# Base64 encoding for complex HTML
local encoded
encoded=$(base64 < newsletter.html)

curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" \
  -H "Content-Type: application/json" \
  -X POST https://api.emailonacid.com/v5/email/tests \
  -d "{
    \"subject\": \"Newsletter\",
    \"html\": \"${encoded}\",
    \"transfer_encoding\": \"base64\"
  }"
```

## Related

- `services/email/email-testing.md` - HTML/CSS validation, dark mode checks, responsive checks
- `services/email/email-health-check.md` - DNS authentication (SPF, DKIM, DMARC)
- `services/email/ses.md` - Amazon SES sending integration
- `tools/browser/playwright.md` - Playwright automation reference
- `tools/browser/playwright-cli.md` - Playwright CLI for AI agents
