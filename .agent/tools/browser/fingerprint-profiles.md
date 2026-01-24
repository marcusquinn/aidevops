---
description: Camoufox fingerprint rotation and anti-detect browser profiles
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
---

# Fingerprint Profiles (Camoufox)

<!-- AI-CONTEXT-START -->

## Overview

Camoufox (4.9k stars, MPL-2.0) is a custom Firefox build for anti-detect automation. Fingerprints are injected at the C++ level (undetectable via JavaScript inspection). Uses BrowserForge for statistically realistic fingerprint generation.

## What Camoufox Spoofs (C++ Level)

| Category | Properties Spoofed |
|----------|-------------------|
| **Navigator** | userAgent, platform, oscpu, appVersion, vendor, hardwareConcurrency, deviceMemory |
| **Screen** | width, height, availWidth, availHeight, colorDepth, pixelDepth, orientation |
| **Window** | innerWidth, innerHeight, outerWidth, outerHeight, screenX, screenY |
| **WebGL** | vendor, renderer, extensions, shader precision, context attributes |
| **WebRTC** | Local IP spoofing at protocol level (not JS injection) |
| **Canvas** | Font metrics randomization, letter spacing offsets |
| **Audio** | sampleRate, outputLatency, maxChannelCount |
| **Fonts** | OS-correct system fonts bundled (Win/Mac/Linux) |
| **Geolocation** | Coordinates, timezone, locale (auto from proxy region) |
| **Media** | Microphones, webcams, speakers count |
| **Battery** | Charging state, level, charging/discharging time |
| **Speech** | Voices, playback rates |
| **Network** | Accept-Language, User-Agent headers match navigator |
| **Mouse** | Human-like cursor movement (C++ algorithm) |

## Installation

```bash
# Python package (recommended)
pip install camoufox

# With playwright dependency
pip install camoufox[geoip]

# Fetch browser binary (first run)
python -m camoufox fetch

# Or via anti-detect-helper.sh
~/.aidevops/agents/scripts/anti-detect-helper.sh setup --engine firefox
```

**Requirements**: Python 3.9+, ~500MB disk for Firefox binary + fonts.

## Usage

### Basic (Auto-Generated Fingerprint)

```python
from camoufox.sync_api import Camoufox

# Each launch gets a unique, realistic fingerprint
with Camoufox(headless=True) as browser:
    page = browser.new_page()
    page.goto("https://www.browserscan.net/bot-detection")
    page.screenshot(path="/tmp/camoufox-test.png")
```

### Async API

```python
import asyncio
from camoufox.async_api import AsyncCamoufox

async def main():
    async with AsyncCamoufox(headless=True) as browser:
        page = await browser.new_page()
        await page.goto("https://example.com")
        await page.screenshot(path="/tmp/test.png")

asyncio.run(main())
```

### Fixed Fingerprint (Persistent Profile)

```python
from camoufox.sync_api import Camoufox

# Same fingerprint every launch (for account persistence)
config = {
    "window.navigator.userAgent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:131.0) Gecko/20100101 Firefox/131.0",
    "window.navigator.platform": "Win32",
    "window.navigator.oscpu": "Windows NT 10.0; Win64; x64",
    "window.navigator.hardwareConcurrency": 8,
    "window.screen.width": 1920,
    "window.screen.height": 1080,
}

with Camoufox(headless=True, config=config) as browser:
    page = browser.new_page()
    page.goto("https://example.com")
```

### With Proxy (Auto Geo-Location)

```python
from camoufox.sync_api import Camoufox

# Proxy with automatic timezone/locale/geolocation from IP region
with Camoufox(
    headless=True,
    proxy={
        "server": "http://proxy.example.com:8080",
        "username": "user",
        "password": "pass",
    },
    geoip=True,  # Auto-detect geo from proxy IP
) as browser:
    page = browser.new_page()
    page.goto("https://example.com")
```

### Multiple Profiles (Parallel)

```python
import asyncio
from camoufox.async_api import AsyncCamoufox

async def run_profile(profile_name: str, proxy: dict):
    async with AsyncCamoufox(
        headless=True,
        proxy=proxy,
        geoip=True,
    ) as browser:
        page = await browser.new_page()
        await page.goto("https://example.com")
        print(f"{profile_name}: {await page.title()}")

async def main():
    profiles = [
        ("account-1", {"server": "http://proxy1:8080"}),
        ("account-2", {"server": "http://proxy2:8080"}),
        ("account-3", {"server": "http://proxy3:8080"}),
    ]
    await asyncio.gather(*[run_profile(name, proxy) for name, proxy in profiles])

asyncio.run(main())
```

### With Firefox Addons

```python
from camoufox.sync_api import Camoufox

with Camoufox(
    headless=True,
    addons=[
        "/path/to/ublock-origin.xpi",
        "/path/to/privacy-badger.xpi",
    ],
) as browser:
    page = browser.new_page()
    page.goto("https://example.com")
```

### Virtual Display (Headless Server)

```python
from camoufox.sync_api import Camoufox

# Run headed browser on headless server (Xvfb)
# Avoids headless detection entirely
with Camoufox(
    headless=False,  # Headed mode
    virtual_display=True,  # But in virtual display (no real screen needed)
) as browser:
    page = browser.new_page()
    page.goto("https://example.com")
```

**Requires**: `pip install camoufox[geoip]` and Xvfb on Linux (`apt install xvfb`).

### Human-Like Mouse Movement

```python
from camoufox.sync_api import Camoufox

with Camoufox(headless=True, humanize=True) as browser:
    page = browser.new_page()
    page.goto("https://example.com")
    # Mouse movements use natural C++ algorithm automatically
    # Clicks include realistic approach curves
    page.click("button#submit")
```

## BrowserForge Fingerprints

Camoufox uses [BrowserForge](https://github.com/daijro/browserforge) to generate fingerprints matching real-world traffic distribution:

- **OS distribution**: Windows ~75%, macOS ~16%, Linux ~5%
- **Screen resolutions**: Weighted by actual usage statistics
- **GPU models**: Matched to OS (no Intel HD on macOS M-series)
- **Browser versions**: Recent versions only (last 3-4 releases)
- **Internal consistency**: All properties cross-validated

### Generating Fingerprints Manually

```python
from browserforge.fingerprints import FingerprintGenerator

fg = FingerprintGenerator(
    browser="firefox",
    os=("windows", "macos"),  # Target OS distribution
    min_version=130,  # Minimum Firefox version
)

# Generate a consistent fingerprint
fingerprint = fg.generate()
print(fingerprint.navigator)
print(fingerprint.screen)
print(fingerprint.webgl)
```

## Headless vs Headed

| Mode | Detection Risk | Performance | Setup |
|------|---------------|-------------|-------|
| **Headless (patched)** | Low - Camoufox patches headless indicators | Fast | Default |
| **Virtual display** | Very low - appears fully headed | Medium | Xvfb required |
| **Headed** | None - real window | Slow (needs display) | Desktop only |

**Recommendation**: Use `headless=True` for most cases. Use `virtual_display=True` on servers if headless detection is an issue.

## Limitations

- **Firefox only** - Cannot spoof Chromium fingerprints (SpiderMonkey engine behavior differs)
- **Python only** - No Node.js API (use via subprocess or rebrowser-patches for Node.js)
- **Binary size** - ~500MB for Firefox + bundled fonts
- **macOS only** (current FF146 build) - Linux coming soon, Windows later
- **Not perfect** - Sophisticated anti-bots can still find inconsistencies in fingerprint rotation

## Integration with Profile Manager

See `browser-profiles.md` for how fingerprints are stored and reused per profile:

```python
# Profile manager generates and stores fingerprint config
profile = load_profile("my-account")
with Camoufox(headless=True, config=profile["fingerprint"]) as browser:
    # Consistent identity across sessions
    ...
```

<!-- AI-CONTEXT-END -->
