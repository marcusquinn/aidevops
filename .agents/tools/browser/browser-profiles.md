---
description: Multi-profile browser management - persistent/clean profiles like AdsPower/GoLogin
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Browser Profiles (Multi-Account Management)

<!-- AI-CONTEXT-START -->

## Profile Storage

```text
~/.aidevops/.agent-workspace/browser-profiles/
├── profiles.json              # Profile index
├── persistent/{name}/         # Cookies + fingerprint preserved
│   ├── fingerprint.json       # Fixed fingerprint config
│   ├── proxy.json             # Assigned proxy
│   ├── cookies.json / storage-state.json  # Session state
│   ├── user-data/             # Full browser profile dir
│   └── metadata.json          # Created, last-used, notes
├── clean/default/             # Fresh identity each launch
└── warmup/{name}/history.json # Pre-warmed browsing history
```

## Profile Types

| Type | State | Use case |
|------|-------|----------|
| `persistent` | Cookies + fingerprint preserved | Managed accounts |
| `clean` | Fresh identity each launch | Scraping |
| `warm` | Pre-warmed with browsing history | New account creation |
| `disposable` | Single-use, auto-deleted | Maximum anonymity |

```bash
# Create / Launch / Warmup
anti-detect-helper.sh profile create "name" --type persistent|clean|warm|disposable
anti-detect-helper.sh profile create "name" --proxy "http://user:pass@host:port" [--os windows --browser firefox]
anti-detect-helper.sh launch --profile "name"                    # Loads saved state (persistent) or random identity (clean)
anti-detect-helper.sh launch --disposable [--proxy "socks5://proxy:1080"]
anti-detect-helper.sh warmup "name" --duration 30m               # Visits popular sites, scrolls, builds history

# CRUD
anti-detect-helper.sh profile list [--format json]
anti-detect-helper.sh profile show "name" [--format json]
anti-detect-helper.sh profile delete "name"
anti-detect-helper.sh profile clone "source-name" "target-name"
anti-detect-helper.sh profile update "name" --proxy "new-proxy:8080" [--notes "text"]

# Cookies
anti-detect-helper.sh cookies export "profile" --output cookies.txt  # Netscape format
anti-detect-helper.sh cookies clear "profile"
```

## Python API

```python
from pathlib import Path
from camoufox.sync_api import Camoufox
from camoufox.async_api import AsyncCamoufox
from playwright.sync_api import sync_playwright
import asyncio, json, random

PROFILES_DIR = Path.home() / ".aidevops/.agent-workspace/browser-profiles"

def load_profile(name: str) -> dict:
    profile_dir = PROFILES_DIR / "persistent" / name
    return {
        "fingerprint": json.loads((profile_dir / "fingerprint.json").read_text()),
        "proxy": json.loads((profile_dir / "proxy.json").read_text()) if (profile_dir / "proxy.json").exists() else None,
        "storage_state": str(profile_dir / "storage-state.json") if (profile_dir / "storage-state.json").exists() else None,
    }

def save_profile_state(name: str, context):
    context.storage_state(path=str(PROFILES_DIR / "persistent" / name / "storage-state.json"))
```

### Launch with Profile (Camoufox)

```python
def launch_with_profile(profile_name: str, headless: bool = True):
    profile = load_profile(profile_name)
    kwargs = {"headless": headless, "config": profile["fingerprint"]}
    if profile["proxy"]:  kwargs["proxy"] = profile["proxy"]
    if profile.get("geoip"):  kwargs["geoip"] = True
    with Camoufox(**kwargs) as browser:
        context = browser.contexts[0]
        if profile["storage_state"]:  # Camoufox: load cookies manually (no storageState support)
            storage = json.loads(Path(profile["storage_state"]).read_text())
            if storage.get("cookies"):  context.add_cookies(storage["cookies"])
        page = context.pages[0] if context.pages else context.new_page()
        yield page, context
        save_profile_state(profile_name, context)
```

### Launch with Profile (Playwright + rebrowser-patches)

```python
def launch_chromium_stealth(profile_name: str, headless: bool = True):
    profile = load_profile(profile_name)
    fp = profile["fingerprint"]
    with sync_playwright() as p:
        browser = p.chromium.launch_persistent_context(
            user_data_dir=str(PROFILES_DIR / "persistent" / profile_name / "user-data"),
            headless=headless,
            args=["--disable-blink-features=AutomationControlled", "--no-first-run"],
            viewport={"width": fp.get("screen_width", 1920), "height": fp.get("screen_height", 1080)},
            user_agent=fp.get("user_agent"),
            proxy=profile["proxy"] or None,
        )
        page = browser.pages[0] if browser.pages else browser.new_page()
        yield page, browser
        browser.close()  # Persistent context auto-saves state
```

## Profile Warming

```python
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
            try:
                await page.goto(random.choice(WARMUP_SITES), timeout=15000)
                await asyncio.sleep(random.uniform(3, 15))
                await page.evaluate("window.scrollBy(0, window.innerHeight * Math.random())")
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

## vs Commercial Tools

**This system:** free, open-source, local JSON/dir storage, Camoufox/BrowserForge fingerprints, Git-based sharing, CLI bulk ops, Python/Bash API, script-based warming.

**Commercial (AdsPower/GoLogin/OctoBrowser):** cloud storage, proprietary fingerprints, GUI-only bulk ops, REST API, manual warming; $9-329/mo.

## Integration Points

- **Proxy**: [proxy-integration.md](proxy-integration.md) — per-profile proxy routing
- **Fingerprints**: [fingerprint-profiles.md](fingerprint-profiles.md) — Camoufox/BrowserForge generation
- **Cookies**: [sweet-cookie.md](sweet-cookie.md) — importing from real browsers
- **CAPTCHA**: [capsolver.md](capsolver.md) — when anti-detect isn't enough

<!-- AI-CONTEXT-END -->
