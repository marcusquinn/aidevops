---
description: Google Search Console sitemap submission via Playwright browser automation
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Google Search Console Sitemap Submission

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Automate sitemap submissions to Google Search Console
- **Method**: Playwright browser automation with persistent Chrome profile
- **Script**: `~/.aidevops/agents/scripts/gsc-sitemap-helper.sh`
- **Config**: `~/.config/aidevops/gsc-config.json`
- **Profile**: `~/.aidevops/.agent-workspace/chrome-gsc-profile/`
- **Screenshots**: `~/.aidevops/.agent-workspace/gsc-screenshots/` (verification)

**Commands**:

```bash
# Submit sitemap (single or multiple domains)
gsc-sitemap-helper.sh submit example.com
gsc-sitemap-helper.sh submit example.com example.net example.org
gsc-sitemap-helper.sh submit --file domains.txt

# Custom sitemap path
gsc-sitemap-helper.sh submit example.com --sitemap news-sitemap.xml

# Status and listing
gsc-sitemap-helper.sh status example.com
gsc-sitemap-helper.sh list example.com

# Batch options
gsc-sitemap-helper.sh submit --dry-run example.com example.net
gsc-sitemap-helper.sh submit --skip-existing example.com example.net
```

> All commands use full path `~/.aidevops/agents/scripts/gsc-sitemap-helper.sh`, or add `~/.aidevops/agents/scripts` to PATH.

**Prerequisites**:

- Domain verified in Google Search Console
- Sitemap accessible at URL (test with `curl https://example.com/sitemap.xml`)
- User logged into Google in the Chrome profile
- Node.js and Playwright installed

<!-- AI-CONTEXT-END -->

## When to Use

- After deploying a new site or adding `sitemap.xml`
- When setting up multiple domains (portfolio of sites)
- After major site restructuring that changes sitemap content

## How It Works

1. Opens Chrome with persistent profile (preserves Google login)
2. Navigates to GSC sitemaps page for each domain
3. Fills sitemap URL in "Add a new sitemap" input
4. Clicks SUBMIT button (finds it relative to input, not sidebar feedback button)
5. Verifies success via screenshot
6. Handles domains that already have sitemaps submitted

## Technical Details

### Chrome Profile Setup

Uses `chromium.launchPersistentContext()` with stealth flags to avoid "browser isn't secure" warnings:

```javascript
{
    ignoreDefaultArgs: ['--enable-automation'],
    args: [
        '--disable-blink-features=AutomationControlled',
        '--disable-infobars',
        '--no-first-run',
        '--no-default-browser-check'
    ]
}
```

### GSC UI Specifics

- **SUBMIT button**: A `div[role="button"]` not a `<button>` element
- **Sidebar conflict**: "Submit feedback" link exists — must avoid clicking it
- **Button location**: Found relative to input field (walk up DOM to find container)
- **Input format**: Requires FULL URL: `https://www.domain.com/sitemap.xml` not just `sitemap.xml`
- **Button state**: Disabled until input has valid content

### Finding the Correct Submit Button

```javascript
const submitBtn = await input.evaluateHandle(el => {
    let parent = el.parentElement;
    for (let i = 0; i < 10; i++) {
        if (!parent) break;
        const btn = parent.querySelector('[role="button"]');
        if (btn && btn.textContent.trim().toUpperCase() === 'SUBMIT') {
            return btn;
        }
        parent = parent.parentElement;
    }
    return null;
});
```

### Detecting Already Submitted

Look for sitemap in table (not page content — "sitemap.xml" appears in input placeholder):

```javascript
const sitemapInTable = await page.$('table:has-text("sitemap.xml")') ||
                       await page.$('tr:has-text("sitemap.xml")') ||
                       await page.$('[role="row"]:has-text("sitemap.xml")');
```

## Configuration

Store in `~/.config/aidevops/gsc-config.json`:

```json
{
  "chrome_profile_dir": "~/.aidevops/.agent-workspace/chrome-gsc-profile",
  "default_sitemap_path": "sitemap.xml",
  "screenshot_dir": "~/.aidevops/.agent-workspace/gsc-screenshots",
  "timeout_ms": 60000,
  "headless": false
}
```

## First-Time Setup

```bash
# 1. Install dependencies
gsc-sitemap-helper.sh setup

# 2. Login to Google (opens browser for manual login)
gsc-sitemap-helper.sh login

# 3. Verify access
gsc-sitemap-helper.sh list example.com
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Browser isn't secure" warning | Close all Chrome, delete profile (`rm -rf ~/.aidevops/.agent-workspace/chrome-gsc-profile`), re-run `gsc-sitemap-helper.sh login` |
| "No access" error | Domain not verified in GSC — check https://search.google.com/search-console |
| Submit button not clicking | Check screenshot in `~/.aidevops/.agent-workspace/gsc-screenshots/`; script uses DOM traversal to find correct button (not feedback link) |
| Session expired | Re-login: `gsc-sitemap-helper.sh login` |
| Sitemap not accessible | Verify: `curl -I https://www.example.com/sitemap.xml` (expect 200 OK, Content-Type: application/xml) |

## Integration Examples

```bash
# After crawling a site
site-crawler-helper.sh crawl https://example.com
gsc-sitemap-helper.sh submit example.com

# WordPress fleet via MainWP
mainwp-helper.sh list-sites | awk '{print $2}' > wp-domains.txt
gsc-sitemap-helper.sh submit --file wp-domains.txt

# After Coolify deployment
coolify-helper.sh deploy my-app
gsc-sitemap-helper.sh submit my-app.example.com
```

## Related

- `seo/google-search-console.md` - GSC API integration (analytics, not sitemaps)
- `tools/browser/playwright.md` - Playwright automation patterns
- `seo/site-crawler.md` - Site auditing and crawling
