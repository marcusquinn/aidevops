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

- **Local**: Playwright (headless Chromium/WebKit) — fast, free, approximate
- **Remote**: Email on Acid API v5 — 90+ real clients, paid per-test
- **Credentials**: `aidevops secret set EOA_API_KEY` + `aidevops secret set EOA_API_PASSWORD`
- **Related**: `email-testing.md` (HTML/CSS validation), `email-health-check.md` (DNS auth)

```bash
email-design-test-helper.sh render newsletter.html [--dark-mode] [--viewports mobile,tablet,desktop]
email-design-test-helper.sh eoa-test newsletter.html
email-design-test-helper.sh eoa-results <test_id>
email-design-test-helper.sh eoa-clients
```

**Workflow:** Iterate locally → `email-testing.md` validation → Email on Acid for final real-client verification.

| Approach | Speed | Cost | Use Case |
|----------|-------|------|----------|
| Local Playwright | ~2s/viewport | Free | Rapid iteration, CI/CD, dark mode |
| Email on Acid | 30-120s/test | Paid | Pre-send validation, client sign-off |

<!-- AI-CONTEXT-END -->

## Local Playwright Rendering

### Viewport Presets

| Preset | Width | Height | Engine | Approximates |
|--------|-------|--------|--------|--------------|
| `mobile` | 375 | 812 | WebKit | iPhone / Apple Mail iOS |
| `mobile-android` | 412 | 915 | Chromium | Samsung / Gmail Android |
| `tablet` | 768 | 1024 | WebKit | iPad / Apple Mail |
| `desktop` | 800 | 600 | Chromium | Gmail web, Yahoo web |
| `outlook-preview` | 657 | 600 | Chromium | Outlook reading pane |
| `desktop-wide` | 1200 | 800 | Chromium | Full-width webmail |

### Full Local Test Suite

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

const engines = { chromium: await chromium.launch({ headless: true }), webkit: await webkit.launch({ headless: true }) };

await Promise.all(tests.map(async (t) => {
  const page = await engines[t.engine].newPage({ viewport: t.vp, colorScheme: t.scheme, deviceScaleFactor: t.scale || 1 });
  await page.setContent(html, { waitUntil: 'networkidle' });
  await page.screenshot({ path: `${outDir}/${t.name}.png`, fullPage: true });
  await page.close();
}));

for (const b of Object.values(engines)) await b.close();
console.log(`Screenshots saved to ${outDir}/`);
```

- **Dark mode**: `colorScheme: 'dark'` — catches missing `prefers-color-scheme` queries and hardcoded white backgrounds.
- **Image blocking**: route `**/*.{png,jpg,jpeg,gif,svg,webp}` to `route.abort()` + `addStyleTag('img{visibility:hidden!important}')` — catches missing `alt` text and layout collapse.
- **Limitations**: does not replicate Outlook Word engine, Gmail `<style>` stripping, Yahoo/AOL quirks, or real mobile differences.

## Email on Acid API

Base URL: `https://api.emailonacid.com/v5` — HTTP Basic Auth (`EOA_API_KEY:EOA_API_PASSWORD`). Sandbox (free): `sandbox:sandbox`.

### Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/auth` | GET | Test authentication |
| `/email/clients` | GET | List available clients |
| `/email/tests` | POST | Create test |
| `/email/tests/<id>` | GET | Get status |
| `/email/tests/<id>/results` | GET | Get screenshot URLs |
| `/email/tests/<id>/results/reprocess` | PUT | Retake failed screenshots |
| `/email/tests/<id>/spam/results` | GET | Spam test results |

### Create, Poll, Download

```bash
# Submit — returns {"id": "<test_id>"}
curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" -H "Content-Type: application/json" \
  -X POST https://api.emailonacid.com/v5/email/tests \
  -d '{"subject":"Newsletter","html":"'"$(cat newsletter.html | jq -Rs .)"'","clients":["outlook16","gmail_chr26_win","iphone6p_9","appmail14"],"image_blocking":true}'

# Poll every 5s until `processing` array is empty (30-120s)
curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" https://api.emailonacid.com/v5/email/tests/<test_id>

# Download all screenshots (URLs valid 90 days Basic Auth / 24h presigned)
curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" \
  "https://api.emailonacid.com/v5/email/tests/${test_id}/results" \
  | jq -r 'to_entries[] | "\(.key) \(.value.screenshots.default)"' \
  | while read -r client url; do
    curl -s -u "$EOA_API_KEY:$EOA_API_PASSWORD" -o "${out_dir}/${client}.png" "$url"
  done
```

### Common Client IDs

| Client ID | Display Name |
|-----------|-------------|
| `outlook16` | Outlook 2016 |
| `ol365_win` | Outlook 365 (Windows) |
| `gmail_chr26_win` | Gmail (Chrome/Windows) |
| `gmail_and11` | Gmail (Android 11) |
| `iphone6p_9` | iPhone 6+ (iOS 9) |
| `appmail14` | Apple Mail (macOS 14) |
| `yahoo_chr26_win` | Yahoo (Chrome/Windows) |

## CI/CD Integration

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
        with: { node-version: '22' }
      - run: npx playwright install --with-deps chromium webkit
      - run: node scripts/email-render-test.js emails/*.html
      - uses: actions/upload-artifact@v4
        with: { name: email-screenshots, path: email-screenshots/ }
```

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| Fonts look different | System fonts vary by OS | Use web-safe fonts or embed via `@font-face` |
| Images not loading | Relative paths in HTML | Use absolute URLs or `file://` protocol |
| Media queries ignored | Viewport not set | Ensure `isMobile: true` for mobile viewports |
| Dark mode not triggering | Missing `colorScheme` | Set `colorScheme: 'dark'` in page context |
| `AccessDenied` | Invalid EoA credentials | Verify with `/v5/auth` |
| `InvalidClient` | Bad client ID | Fetch valid IDs from `/v5/email/clients` |
| Screenshots stuck on `Processing` | Server delay | Wait 3 min, then call reprocess endpoint |
| Encoding issues | Special characters | Use `transfer_encoding: base64` with base64-encoded HTML |

## Related

- `services/email/email-testing.md` - HTML/CSS validation, dark mode checks, responsive checks
- `services/email/email-health-check.md` - DNS authentication (SPF, DKIM, DMARC)
- `services/email/ses.md` - Amazon SES sending integration
- `tools/browser/playwright.md` - Playwright automation reference
- `tools/browser/playwright-cli.md` - Playwright CLI for AI agents
