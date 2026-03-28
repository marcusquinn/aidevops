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

Camoufox (MPL-2.0) is a custom Firefox build for anti-detect automation. Fingerprints are injected at the C++ level — undetectable via JavaScript inspection. Uses BrowserForge for statistically realistic, cross-validated fingerprint generation (Windows ~75%, macOS ~16%, Linux ~5%; recent browser versions only).

**Spoofed at C++ level**: Navigator, Screen, Window, WebGL, WebRTC (protocol-level), Canvas, Audio, Fonts (OS-correct), Geolocation/timezone/locale (auto from proxy), Media devices, Battery, Speech, Network headers, Mouse movement.

## Installation

```bash
pip install camoufox[geoip]
python -m camoufox fetch  # Download Firefox binary (~500MB, first run)

# Or via helper
~/.aidevops/agents/scripts/anti-detect-helper.sh setup --engine firefox
```

**Requirements**: Python 3.9+, ~500MB disk.

## Usage

### Basic (auto-generated fingerprint)

```python
from camoufox.sync_api import Camoufox

with Camoufox(headless=True) as browser:
    page = browser.new_page()
    page.goto("https://www.browserscan.net/bot-detection")
```

### Async API

```python
from camoufox.async_api import AsyncCamoufox

async with AsyncCamoufox(headless=True) as browser:
    page = await browser.new_page()
    await page.goto("https://example.com")
```

### With Proxy (auto geo-location)

```python
with Camoufox(
    headless=True,
    proxy={"server": "http://proxy.example.com:8080", "username": "user", "password": "pass"},
    geoip=True,  # Auto-sets timezone/locale/geolocation from proxy IP
) as browser:
    page = browser.new_page()
```

### Fixed Fingerprint (persistent profile)

```python
config = {
    "window.navigator.userAgent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:131.0) Gecko/20100101 Firefox/131.0",
    "window.navigator.platform": "Win32",
    "window.navigator.hardwareConcurrency": 8,
    "window.screen.width": 1920,
    "window.screen.height": 1080,
}
with Camoufox(headless=True, config=config) as browser:
    ...
```

### Multiple Profiles (parallel)

```python
async def run_profile(name: str, proxy: dict):
    async with AsyncCamoufox(headless=True, proxy=proxy, geoip=True) as browser:
        page = await browser.new_page()
        await page.goto("https://example.com")

await asyncio.gather(*[run_profile(n, p) for n, p in profiles])
```

### Other options

```python
Camoufox(headless=True, humanize=True)          # Human-like mouse movement
Camoufox(headless=False, virtual_display=True)  # Headed in Xvfb (avoids headless detection)
Camoufox(headless=True, addons=["/path/to/ublock.xpi"])  # Firefox addons
```

`virtual_display=True` requires `apt install xvfb` on Linux.

## Headless Mode Decision

| Mode | Detection Risk | Notes |
|------|---------------|-------|
| `headless=True` | Low — Camoufox patches headless indicators | Default; use for most cases |
| `virtual_display=True` | Very low — appears fully headed | Use if headless detection is an issue |
| `headless=False` | None | Desktop only; needs real display |

## Limitations

- **Firefox only** — cannot spoof Chromium fingerprints
- **Python only** — no Node.js API (use subprocess or rebrowser-patches)
- **macOS only** (current FF146 build) — Linux coming soon, Windows later
- **~500MB binary** — Firefox + bundled fonts
- **Not perfect** — sophisticated anti-bots can still find inconsistencies

## Integration with Profile Manager

See `browser-profiles.md` for fingerprint storage and reuse per profile:

```python
profile = load_profile("my-account")
with Camoufox(headless=True, config=profile["fingerprint"]) as browser:
    ...  # Consistent identity across sessions
```

<!-- AI-CONTEXT-END -->
