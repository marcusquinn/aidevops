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
├── profiles.json          # Profile index (metadata)
├── persistent/
│   └── account-1/
│       ├── fingerprint.json    # Fixed fingerprint config
│       ├── proxy.json          # Assigned proxy
│       ├── cookies.json        # Saved cookies
│       ├── storage-state.json  # Playwright storageState
│       ├── user-data/          # Full browser profile dir
│       └── metadata.json       # Created, last-used, notes
├── clean/                 # Template profiles (no state)
│   └── default/
│       └── fingerprint.json    # Random on each launch
└── warmup/                # Pre-warmed profiles
    └── account-3/
        └── history.json        # Browsing history to replay
```

## Profile Types

| Type | State | Use case |
|------|-------|----------|
| `persistent` | Cookies + fingerprint preserved | Managed accounts |
| `clean` | Fresh identity each launch | Scraping |
| `warm` | Pre-warmed with browsing history | New account creation |
| `disposable` | Single-use, auto-deleted | Maximum anonymity |

```bash
# Create
anti-detect-helper.sh profile create "name" --type persistent|clean|warm|disposable
anti-detect-helper.sh profile create "name" --proxy "http://user:pass@host:port"
anti-detect-helper.sh profile create "name" --os windows --browser firefox

# Launch (loads saved state for persistent; random identity for clean)
anti-detect-helper.sh launch --profile "name"

# Disposable (no profile saved)
anti-detect-helper.sh launch --disposable [--proxy "socks5://proxy:1080"]

# Warm a profile (visits popular sites, scrolls, builds history)
anti-detect-helper.sh warmup "name" --duration 30m
```

## Profile Operations

### CRUD

```bash
anti-detect-helper.sh profile list [--format json]
anti-detect-helper.sh profile show "name"
anti-detect-helper.sh profile update "name" --proxy "new-proxy:8080" [--notes "text"]
anti-detect-helper.sh profile delete "name" [--keep-cookies]
anti-detect-helper.sh profile clone "source" "destination"
```

### Bulk Operations

```bash
anti-detect-helper.sh profile bulk-create --count 10 --prefix "worker" --type clean
anti-detect-helper.sh profile bulk-delete --type clean
anti-detect-helper.sh profile export --output /tmp/profiles-backup.tar.gz
anti-detect-helper.sh profile import --input /tmp/profiles-backup.tar.gz
```

### Cookie Management

```bash
anti-detect-helper.sh cookies export "profile" --output cookies.txt   # Netscape format
anti-detect-helper.sh cookies import "profile" --input cookies.txt
anti-detect-helper.sh cookies import-browser "profile" --browser chrome --domain example.com
anti-detect-helper.sh cookies clear "profile" [--domain example.com]
```

## Python API

### Profile Helpers

```python
from pathlib import Path
import json

PROFILES_DIR = Path.home() / ".aidevops/.agent-workspace/browser-profiles"

def load_profile(name: str) -> dict:
    profile_dir = PROFILES_DIR / "persistent" / name
    return {
        "fingerprint": json.loads((profile_dir / "fingerprint.json").read_text()),
        "proxy": json.loads((profile_dir / "proxy.json").read_text()) if (profile_dir / "proxy.json").exists() else None,
        "storage_state": str(profile_dir / "storage-state.json") if (profile_dir / "storage-state.json").exists() else None,
    }

def save_profile_state(name: str, context):
    profile_dir = PROFILES_DIR / "persistent" / name
    context.storage_state(path=str(profile_dir / "storage-state.json"))
```

### Launch with Profile (Camoufox)

```python
from camoufox.sync_api import Camoufox
import json
from pathlib import Path

def launch_with_profile(profile_name: str, headless: bool = True):
    profile = load_profile(profile_name)
    kwargs = {"headless": headless, "config": profile["fingerprint"]}
    if profile["proxy"]:
        kwargs["proxy"] = profile["proxy"]
    if profile.get("geoip"):
        kwargs["geoip"] = True

    with Camoufox(**kwargs) as browser:
        context = browser.contexts[0]
        # Camoufox doesn't support storageState directly — load cookies manually
        if profile["storage_state"]:
            storage = json.loads(Path(profile["storage_state"]).read_text())
            if storage.get("cookies"):
                context.add_cookies(storage["cookies"])
        page = context.pages[0] if context.pages else context.new_page()
        yield page, context
        save_profile_state(profile_name, context)
```

### Launch with Profile (Playwright + rebrowser-patches)

```python
from playwright.sync_api import sync_playwright

def launch_chromium_stealth(profile_name: str, headless: bool = True):
    profile = load_profile(profile_name)
    profile_dir = PROFILES_DIR / "persistent" / profile_name / "user-data"

    with sync_playwright() as p:
        browser = p.chromium.launch_persistent_context(
            user_data_dir=str(profile_dir),
            headless=headless,
            args=["--disable-blink-features=AutomationControlled", "--no-first-run"],
            viewport={"width": profile["fingerprint"].get("screen_width", 1920),
                      "height": profile["fingerprint"].get("screen_height", 1080)},
            user_agent=profile["fingerprint"].get("user_agent"),
            proxy=profile["proxy"] if profile["proxy"] else None,
        )
        page = browser.pages[0] if browser.pages else browser.new_page()
        yield page, browser
        browser.close()  # Persistent context auto-saves state
```

## Profile Warming

```python
import asyncio, random
from camoufox.async_api import AsyncCamoufox

WARMUP_SITES = [
    "https://www.google.com", "https://www.youtube.com", "https://www.wikipedia.org",
    "https://www.reddit.com", "https://www.amazon.com", "https://news.ycombinator.com",
    "https://www.github.com", "https://stackoverflow.com",
]

async def warmup_profile(profile_name: str, duration_minutes: int = 30):
    profile = load_profile(profile_name)
    async with AsyncCamoufox(headless=True, config=profile["fingerprint"],
                              humanize=True, proxy=profile.get("proxy")) as browser:
        page = await browser.new_page()
        end_time = asyncio.get_event_loop().time() + (duration_minutes * 60)
        while asyncio.get_event_loop().time() < end_time:
            url = random.choice(WARMUP_SITES)
            try:
                await page.goto(url, timeout=15000)
                await asyncio.sleep(random.uniform(3, 15))
                await page.evaluate("window.scrollBy(0, window.innerHeight * Math.random())")
                await asyncio.sleep(random.uniform(1, 5))
                if random.random() > 0.6:
                    links = await page.query_selector_all("a[href^='http']")
                    if links:
                        await random.choice(links[:10]).click()
                        await asyncio.sleep(random.uniform(2, 8))
                        await page.go_back()
            except Exception:
                pass
            await asyncio.sleep(random.uniform(2, 10))
        save_profile_state(profile_name, browser.contexts[0])
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
