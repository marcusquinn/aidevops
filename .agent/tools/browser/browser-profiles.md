---
description: Multi-profile browser management - persistent/clean profiles like AdsPower/GoLogin
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
---

# Browser Profiles (Multi-Account Management)

<!-- AI-CONTEXT-START -->

## Overview

Profile management system replicating commercial anti-detect browsers (AdsPower, GoLogin, OctoBrowser). Each profile maintains its own fingerprint, cookies, proxy, and browsing state.

## Profile Storage

```text
~/.aidevops/.agent-workspace/browser-profiles/
├── profiles.json                    # Profile index (metadata)
├── persistent/
│   ├── account-1/
│   │   ├── fingerprint.json         # Fixed fingerprint config
│   │   ├── proxy.json               # Assigned proxy
│   │   ├── cookies.json             # Saved cookies
│   │   ├── storage-state.json       # Playwright storageState
│   │   ├── user-data/               # Full browser profile dir
│   │   └── metadata.json            # Created, last-used, notes
│   └── account-2/
│       └── ...
├── clean/                           # Template profiles (no state)
│   ├── default/
│   │   └── fingerprint.json         # Random on each launch
│   └── custom-template/
│       └── fingerprint.json         # Fixed template fingerprint
└── warmup/                          # Pre-warmed profiles
    └── account-3/
        ├── history.json             # Browsing history to replay
        └── ...
```

## Profile Types

### Persistent Profiles

Maintain identity across sessions. Cookies, localStorage, fingerprint all preserved.

```bash
# Create persistent profile
anti-detect-helper.sh profile create "my-account" --type persistent

# Launch (loads saved state)
anti-detect-helper.sh launch --profile "my-account"

# After session, state is auto-saved on browser close
```

### Clean Profiles

Fresh identity each launch. No cookies, random fingerprint, optional proxy rotation.

```bash
# Create clean profile template
anti-detect-helper.sh profile create "scraper" --type clean

# Launch (random fingerprint, no cookies)
anti-detect-helper.sh launch --profile "scraper"

# Each launch is a completely new identity
```

### Warm Profiles

Pre-warmed with browsing history to appear as a real user. Used for new account creation.

```bash
# Create and warm a profile
anti-detect-helper.sh profile create "new-account" --type warm
anti-detect-helper.sh warmup "new-account" --duration 30m

# Warmup visits popular sites, scrolls, clicks, builds history
```

### Disposable Profiles

Single-use, auto-deleted after session. Maximum anonymity.

```bash
# Launch disposable (no profile saved)
anti-detect-helper.sh launch --disposable

# Or with specific proxy
anti-detect-helper.sh launch --disposable --proxy "socks5://proxy:1080"
```

## Profile Operations

### CRUD

```bash
# Create
anti-detect-helper.sh profile create "name" [--type persistent|clean|warm|disposable]
anti-detect-helper.sh profile create "name" --proxy "http://user:pass@host:port"
anti-detect-helper.sh profile create "name" --os windows --browser firefox

# List
anti-detect-helper.sh profile list
anti-detect-helper.sh profile list --format json

# Show details
anti-detect-helper.sh profile show "name"

# Update
anti-detect-helper.sh profile update "name" --proxy "new-proxy:8080"
anti-detect-helper.sh profile update "name" --notes "Main shopping account"

# Delete
anti-detect-helper.sh profile delete "name"
anti-detect-helper.sh profile delete "name" --keep-cookies  # Keep cookies, reset fingerprint

# Clone
anti-detect-helper.sh profile clone "source" "destination"
```

### Bulk Operations

```bash
# Create multiple profiles
anti-detect-helper.sh profile bulk-create --count 10 --prefix "worker" --type clean

# Delete all clean profiles
anti-detect-helper.sh profile bulk-delete --type clean

# Export all profiles
anti-detect-helper.sh profile export --output /tmp/profiles-backup.tar.gz

# Import profiles
anti-detect-helper.sh profile import --input /tmp/profiles-backup.tar.gz
```

### Cookie Management

```bash
# Export cookies (Netscape format, compatible with curl)
anti-detect-helper.sh cookies export "profile-name" --output cookies.txt

# Import cookies
anti-detect-helper.sh cookies import "profile-name" --input cookies.txt

# Import from browser (via sweet-cookie)
anti-detect-helper.sh cookies import-browser "profile-name" --browser chrome --domain example.com

# Clear cookies
anti-detect-helper.sh cookies clear "profile-name"
anti-detect-helper.sh cookies clear "profile-name" --domain example.com  # Domain-specific
```

## Python API

### Profile Manager

```python
from pathlib import Path
import json

PROFILES_DIR = Path.home() / ".aidevops/.agent-workspace/browser-profiles"

def load_profile(name: str) -> dict:
    """Load a profile's configuration."""
    profile_dir = PROFILES_DIR / "persistent" / name
    return {
        "fingerprint": json.loads((profile_dir / "fingerprint.json").read_text()),
        "proxy": json.loads((profile_dir / "proxy.json").read_text()) if (profile_dir / "proxy.json").exists() else None,
        "storage_state": str(profile_dir / "storage-state.json") if (profile_dir / "storage-state.json").exists() else None,
    }

def save_profile_state(name: str, context):
    """Save browser state after session."""
    profile_dir = PROFILES_DIR / "persistent" / name
    context.storage_state(path=str(profile_dir / "storage-state.json"))
```

### Launch with Profile (Camoufox)

```python
from camoufox.sync_api import Camoufox
import json
from pathlib import Path

def launch_with_profile(profile_name: str, headless: bool = True):
    """Launch Camoufox with a saved profile."""
    profile = load_profile(profile_name)

    kwargs = {
        "headless": headless,
        "config": profile["fingerprint"],
    }

    if profile["proxy"]:
        kwargs["proxy"] = profile["proxy"]

    if profile.get("geoip"):
        kwargs["geoip"] = True

    with Camoufox(**kwargs) as browser:
        context = browser.contexts[0]

        # Restore cookies/storage if persistent
        if profile["storage_state"]:
            # Note: Camoufox doesn't support storageState directly
            # Load cookies manually
            storage = json.loads(Path(profile["storage_state"]).read_text())
            if storage.get("cookies"):
                context.add_cookies(storage["cookies"])

        page = context.pages[0] if context.pages else context.new_page()
        yield page, context

        # Save state on exit
        save_profile_state(profile_name, context)
```

### Launch with Profile (Playwright + rebrowser-patches)

```python
from playwright.sync_api import sync_playwright
import json
from pathlib import Path

def launch_chromium_stealth(profile_name: str, headless: bool = True):
    """Launch patched Chromium with a saved profile."""
    profile = load_profile(profile_name)
    profile_dir = PROFILES_DIR / "persistent" / profile_name / "user-data"

    with sync_playwright() as p:
        browser = p.chromium.launch_persistent_context(
            user_data_dir=str(profile_dir),
            headless=headless,
            args=[
                '--disable-blink-features=AutomationControlled',
                '--no-first-run',
            ],
            viewport={"width": profile["fingerprint"].get("screen_width", 1920),
                      "height": profile["fingerprint"].get("screen_height", 1080)},
            user_agent=profile["fingerprint"].get("user_agent"),
            proxy=profile["proxy"] if profile["proxy"] else None,
        )

        page = browser.pages[0] if browser.pages else browser.new_page()
        yield page, browser

        # Persistent context auto-saves state
        browser.close()
```

## Profile Warming

Simulate real user behavior to build browsing history and cookies:

```python
import asyncio
import random
from camoufox.async_api import AsyncCamoufox

WARMUP_SITES = [
    "https://www.google.com",
    "https://www.youtube.com",
    "https://www.wikipedia.org",
    "https://www.reddit.com",
    "https://www.amazon.com",
    "https://news.ycombinator.com",
    "https://www.github.com",
    "https://stackoverflow.com",
]

async def warmup_profile(profile_name: str, duration_minutes: int = 30):
    """Warm up a profile with realistic browsing behavior."""
    profile = load_profile(profile_name)

    async with AsyncCamoufox(
        headless=True,
        config=profile["fingerprint"],
        humanize=True,
        proxy=profile.get("proxy"),
    ) as browser:
        page = await browser.new_page()

        end_time = asyncio.get_event_loop().time() + (duration_minutes * 60)

        while asyncio.get_event_loop().time() < end_time:
            url = random.choice(WARMUP_SITES)
            try:
                await page.goto(url, timeout=15000)
                # Simulate reading
                await asyncio.sleep(random.uniform(3, 15))
                # Scroll
                await page.evaluate("window.scrollBy(0, window.innerHeight * Math.random())")
                await asyncio.sleep(random.uniform(1, 5))
                # Maybe click a link
                if random.random() > 0.6:
                    links = await page.query_selector_all("a[href^='http']")
                    if links:
                        link = random.choice(links[:10])
                        await link.click()
                        await asyncio.sleep(random.uniform(2, 8))
                        await page.go_back()
            except Exception:
                pass  # Skip failed navigations

            await asyncio.sleep(random.uniform(2, 10))

        # Save warmed state
        context = browser.contexts[0]
        save_profile_state(profile_name, context)
```

## Comparison with Commercial Tools

| Feature | This System | AdsPower | GoLogin | OctoBrowser |
|---------|-------------|----------|---------|-------------|
| **Profile storage** | Local (JSON/dirs) | Cloud | Cloud | Cloud |
| **Fingerprint gen** | BrowserForge | Proprietary | Proprietary | Proprietary |
| **Proxy per profile** | Yes | Yes | Yes | Yes |
| **Cookie management** | Yes | Yes | Yes | Yes |
| **Profile warming** | Script-based | Manual | Manual | Manual |
| **Team sharing** | Git/export | Cloud sync | Cloud sync | Cloud sync |
| **Bulk operations** | CLI | GUI | GUI | GUI |
| **API access** | Python/Bash | REST API | REST API | REST API |
| **Cost** | Free | $9-299/mo | $24-199/mo | $21-329/mo |
| **Browser engine** | Firefox (Camoufox) | Chromium | Chromium | Chromium |
| **Open source** | Yes | No | No | No |

## Integration Points

- **Proxy assignment**: See `proxy-integration.md` for per-profile proxy routing
- **Fingerprint generation**: See `fingerprint-profiles.md` for Camoufox/BrowserForge
- **Cookie extraction**: See `sweet-cookie.md` for importing from real browsers
- **CAPTCHA solving**: See `capsolver.md` for when anti-detect isn't enough

<!-- AI-CONTEXT-END -->
