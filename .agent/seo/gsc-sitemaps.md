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
- **Screenshots**: `/tmp/gsc-screenshots/` (verification)

**Commands**:

```bash
# Submit sitemap for single domain
gsc-sitemap-helper.sh submit example.com

# Submit sitemaps for multiple domains
gsc-sitemap-helper.sh submit example.com example.net example.org

# Submit from file (one domain per line)
gsc-sitemap-helper.sh submit --file domains.txt

# Check sitemap status
gsc-sitemap-helper.sh status example.com

# List all sitemaps for a domain
gsc-sitemap-helper.sh list example.com
```

**Prerequisites**:
- Domain verified in Google Search Console
- Sitemap accessible at URL (test with `curl https://example.com/sitemap.xml`)
- User logged into Google in the Chrome profile
- Node.js and Playwright installed

<!-- AI-CONTEXT-END -->

## When to Use

- After deploying a new site
- After adding `sitemap.xml` to a domain
- When setting up multiple domains (like a portfolio of sites)
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

Uses `chromium.launchPersistentContext()` with a dedicated profile directory and stealth flags to avoid "browser isn't secure" warnings:

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
- **Sidebar conflict**: There's also a "Submit feedback" link - must avoid clicking that
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

Look for sitemap in table (not just page content, as "sitemap.xml" appears in input placeholder):

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
  "screenshot_dir": "/tmp/gsc-screenshots",
  "timeout_ms": 60000,
  "headless": false
}
```

## First-Time Setup

1. **Install dependencies**:

   ```bash
   gsc-sitemap-helper.sh setup
   ```

2. **Login to Google** (first run opens browser for manual login):

   ```bash
   gsc-sitemap-helper.sh login
   ```

3. **Verify access**:

   ```bash
   gsc-sitemap-helper.sh list example.com
   ```

## Usage Examples

### Single Domain

```bash
# Submit sitemap for one domain
gsc-sitemap-helper.sh submit example.com

# With custom sitemap path
gsc-sitemap-helper.sh submit example.com --sitemap news-sitemap.xml
```

### Multiple Domains

```bash
# Submit to multiple domains
gsc-sitemap-helper.sh submit example.com example.net example.org

# From file
echo -e "example.com\nexample.net\nexample.org" > domains.txt
gsc-sitemap-helper.sh submit --file domains.txt
```

### Status Checking

```bash
# Check if sitemap is submitted
gsc-sitemap-helper.sh status example.com

# List all sitemaps for a domain
gsc-sitemap-helper.sh list example.com
```

### Batch Operations

```bash
# Dry run (show what would be done)
gsc-sitemap-helper.sh submit --dry-run example.com example.net

# Skip already-submitted domains
gsc-sitemap-helper.sh submit --skip-existing example.com example.net
```

## Troubleshooting

### "Browser isn't secure" Warning

The script uses stealth flags to prevent this. If it still appears:

1. Close all Chrome instances
2. Delete the profile: `rm -rf ~/.aidevops/.agent-workspace/chrome-gsc-profile`
3. Run `gsc-sitemap-helper.sh login` to create fresh profile

### "No access" Error

- Domain not verified in GSC for this Google account
- Check GSC manually: https://search.google.com/search-console

### Submit Button Not Clicking

- Check screenshot in `/tmp/gsc-screenshots/`
- May be clicking feedback button instead of submit
- Script uses DOM traversal to find correct button

### Session Expired

```bash
# Re-login to refresh session
gsc-sitemap-helper.sh login
```

### Sitemap Not Accessible

Before submitting, verify sitemap is accessible:

```bash
curl -I https://www.example.com/sitemap.xml
# Should return 200 OK with Content-Type: application/xml
```

## Integration with Other Tools

### With Site Crawler

After crawling a site, submit its sitemap:

```bash
# Crawl site
site-crawler-helper.sh crawl https://example.com

# Submit sitemap
gsc-sitemap-helper.sh submit example.com
```

### With MainWP (WordPress Fleet)

Submit sitemaps for all managed WordPress sites:

```bash
# Get domains from MainWP
mainwp-helper.sh list-sites | awk '{print $2}' > wp-domains.txt

# Submit sitemaps
gsc-sitemap-helper.sh submit --file wp-domains.txt
```

### With Coolify Deployments

After deploying a new site:

```bash
# Deploy site
coolify-helper.sh deploy my-app

# Submit sitemap
gsc-sitemap-helper.sh submit my-app.example.com
```

## Related

- `seo/google-search-console.md` - GSC API integration (analytics, not sitemaps)
- `tools/browser/playwright.md` - Playwright automation patterns
- `seo/site-crawler.md` - Site auditing and crawling
