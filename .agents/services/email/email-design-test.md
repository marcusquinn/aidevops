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

- **Local tool**: Playwright (headless Chromium/WebKit) -- free, ~2s per viewport, approximation only
- **Remote tool**: Email on Acid API v5 -- paid, 30-120s, 90+ real email clients
- **Credentials**: `aidevops secret set EOA_API_KEY` + `aidevops secret set EOA_API_PASSWORD`
- **Related**: `email-testing.md` (HTML/CSS validation), `email-health-check.md` (DNS auth), `ses.md` (SES sending), `tools/browser/playwright.md`

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

**Workflow:** Playwright locally -> `email-testing.md` validation -> Email on Acid for real-client verification.

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

Full test suite (all viewports + dark mode + image blocking): `email-design-test-helper.sh render --all`.

### Rendering Modes

- **Dark mode** (`colorScheme: 'dark'`): catches missing `prefers-color-scheme`, hardcoded white backgrounds, invisible text
- **Image blocking** (route to `abort()` + `img { visibility: hidden !important; }`): catches missing `alt` text, layout collapse
- **Limitations**: does **not** replicate Outlook Word engine, Gmail `<style>` stripping, Yahoo/AOL quirks, or real mobile rendering -- use Email on Acid for these

## Email on Acid API

Base URL: `https://api.emailonacid.com/v5` -- HTTP Basic Auth (`EOA_API_KEY:EOA_API_PASSWORD`). Sandbox (free, no credits): `sandbox:sandbox`.

### Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/auth` | GET | Test authentication |
| `/email/clients` | GET | List available clients |
| `/email/tests` | POST | Create test (`subject`, `html`, `clients[]`, `image_blocking`) |
| `/email/tests/<id>` | GET | Poll status (~30-120s, every 5s until `processing` empty) |
| `/email/tests/<id>/results` | GET | Screenshot URLs (Basic Auth: 90d; presigned: 24h) |
| `/email/tests/<id>/results/reprocess` | PUT | Retake failed screenshots |
| `/email/tests/<id>/spam/results` | GET | Spam test results |

### Common Client IDs

| Client ID | Approximates |
|-----------|-------------|
| `outlook16` | Outlook 2016 |
| `ol365_win` | Outlook 365 (Windows) |
| `gmail_chr26_win` | Gmail (Chrome/Windows) |
| `gmail_and11` | Gmail (Android 11) |
| `iphone6p_9` | iPhone 6+ (iOS 9) |
| `appmail14` | Apple Mail (macOS 14) |
| `yahoo_chr26_win` | Yahoo (Chrome/Windows) |

Live list: `email-design-test-helper.sh eoa-clients`.

## CI/CD Integration

Playwright rendering gate -- triggers on `emails/**`, `templates/**`:

```yaml
# .github/workflows/email-test.yml
name: Email Design Test
on: { pull_request: { paths: ['emails/**', 'templates/**'] } }
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

| Issue | Fix |
|-------|-----|
| Fonts look different | Use web-safe fonts or embed via `@font-face` |
| Images not loading | Use absolute URLs or `file://` protocol |
| Media queries ignored | Set `isMobile: true` for mobile viewports |
| Dark mode not triggering | Set `colorScheme: 'dark'` in page context |
| `AccessDenied` from EoA | Verify credentials with `/v5/auth` |
| `InvalidClient` from EoA | Fetch valid IDs from `/v5/email/clients` |
| Screenshots stuck processing | Wait 3 min, then call `/results/reprocess` |
| Encoding issues | Use `transfer_encoding: base64` with base64-encoded HTML |
