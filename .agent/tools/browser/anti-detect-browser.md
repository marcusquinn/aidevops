---
description: Anti-detect browser automation - stealth, fingerprinting, multi-profile management
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

# Anti-Detect Browser Automation

<!-- AI-CONTEXT-START -->

## Overview

Anti-detect browser capabilities for multi-account automation, bot detection evasion, and fingerprint management. Replicates features of commercial tools (AdsPower, GoLogin, OctoBrowser) using open-source components.

## Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│                    Anti-Detect Stack                         │
├─────────────────────────────────────────────────────────────┤
│  Layer 4: CAPTCHA Solving    → CapSolver (existing)         │
│  Layer 3: Network Identity   → Proxies (residential/SOCKS5) │
│  Layer 2: Browser Identity   → Camoufox (fingerprint)       │
│  Layer 1: Automation Stealth → rebrowser-patches (CDP leak) │
│  Layer 0: Browser Engine     → Playwright (existing)        │
└─────────────────────────────────────────────────────────────┘
```

## Decision Tree

```text
Need anti-detection?
    |
    +-> Quick stealth (hide automation signals only)?
    |       |
    |       +-> Chromium (existing Playwright)? --> stealth-patches.md (rebrowser-patches)
    |       +-> Firefox? --> Camoufox (fingerprint-profiles.md)
    |
    +-> Full anti-detect (fingerprint rotation, multi-account)?
    |       |
    |       +-> Need unique fingerprints per profile? --> fingerprint-profiles.md (Camoufox)
    |       +-> Need persistent profiles (cookies, history)? --> browser-profiles.md
    |       +-> Need proxy per profile? --> proxy-integration.md
    |       +-> Need all of the above? --> anti-detect-helper.sh launch --profile <name>
    |
    +-> Which browser engine?
    |       |
    |       +-> Maximum stealth (C++ level spoofing)? --> Camoufox (Firefox)
    |       +-> Speed + existing Playwright code? --> rebrowser-patches (Chromium)
    |       +-> Both (rotate engines)? --> anti-detect-helper.sh --engine random
    |
    +-> Headless or headed?
            |
            +-> Headless (server/CI)? --> Camoufox virtual display OR rebrowser headless
            +-> Headed (local dev)? --> Either engine, visible window
            +-> Headless that looks headed? --> Camoufox (patches headless detection)
```

## Tool Comparison

| Feature | rebrowser-patches | Camoufox | AdsPower/GoLogin |
|---------|------------------|----------|------------------|
| **Engine** | Chromium (Playwright) | Firefox (Playwright) | Chromium |
| **Stealth level** | Medium (CDP patches) | High (C++ level) | High (proprietary) |
| **Fingerprint rotation** | No (add manually) | Yes (BrowserForge) | Yes |
| **WebRTC spoofing** | No | Yes (protocol level) | Yes |
| **Canvas/WebGL** | No | Yes (C++ intercept) | Yes |
| **Font spoofing** | No | Yes (bundled fonts) | Yes |
| **Human mouse** | No | Yes (C++ algorithm) | Yes |
| **Profile management** | Manual | Python API | GUI |
| **Proxy integration** | Playwright native | Python API | Built-in |
| **Headless stealth** | Partial | Full (patched) | N/A |
| **Cost** | Free (MIT) | Free (MPL-2.0) | $9-$299/mo |
| **Setup** | `npx rebrowser-patches patch` | `pip install camoufox` | Download app |

## Quick Start

```bash
# Setup all anti-detect tools
~/.aidevops/agents/scripts/anti-detect-helper.sh setup

# Create a profile with auto-generated fingerprint
~/.aidevops/agents/scripts/anti-detect-helper.sh profile create "my-account"

# Launch with full anti-detect (Camoufox + proxy + fingerprint)
~/.aidevops/agents/scripts/anti-detect-helper.sh launch --profile "my-account"

# Launch with stealth patches only (faster, Chromium)
~/.aidevops/agents/scripts/anti-detect-helper.sh launch --profile "my-account" --engine chromium

# Test detection status
~/.aidevops/agents/scripts/anti-detect-helper.sh test --profile "my-account"

# Clean profile (fresh fingerprint, no cookies)
~/.aidevops/agents/scripts/anti-detect-helper.sh profile clean "my-account"
```

## Subagent Index

| Subagent | Purpose | When to Read |
|----------|---------|--------------|
| `stealth-patches.md` | Chromium automation signal removal | Quick stealth, existing Playwright code |
| `fingerprint-profiles.md` | Camoufox fingerprint rotation & spoofing | Full anti-detect, unique identities |
| `browser-profiles.md` | Multi-profile management (persistent/clean) | Account management, session persistence |
| `proxy-integration.md` | Proxy routing per profile | IP rotation, geo-targeting, multi-account |

## Profile Types

| Type | Cookies | Fingerprint | Proxy | Use Case |
|------|---------|-------------|-------|----------|
| **Persistent** | Saved | Fixed per profile | Fixed | Account management, stay logged in |
| **Clean** | None | Random each launch | Rotating | Scraping, one-off tasks |
| **Warm** | Saved | Fixed | Fixed | Pre-warmed accounts (browsing history) |
| **Disposable** | None | Random | Random | Single-use, maximum anonymity |

## Ethical Guidelines

- Only use for legitimate automation (your own accounts, authorized testing)
- Respect website Terms of Service
- Do not use for fraud, spam, or unauthorized access
- Rate limit requests (2-5s delays minimum)
- Do not create fake accounts or impersonate others

<!-- AI-CONTEXT-END -->

## Detailed Subagent Usage

### Layer 1: Stealth Patches (Chromium)

For quick stealth on existing Playwright code. Read `stealth-patches.md` for:
- rebrowser-patches installation and usage
- CDP leak prevention
- `navigator.webdriver` removal
- Runtime.enable leak fix
- Headless detection bypass

### Layer 2: Fingerprint Profiles (Camoufox)

For full anti-detect with unique identities. Read `fingerprint-profiles.md` for:
- Camoufox installation and Python API
- BrowserForge fingerprint generation
- WebRTC, Canvas, WebGL, Font spoofing
- Screen/viewport/timezone spoofing
- Human-like mouse movement
- Headless mode that appears headed

### Layer 3: Profile Management

For multi-account workflows. Read `browser-profiles.md` for:
- Profile CRUD operations
- Cookie/localStorage persistence
- Fingerprint assignment per profile
- Profile warming (browsing history generation)
- Import/export profiles
- Bulk profile operations

### Layer 4: Proxy Integration

For network identity. Read `proxy-integration.md` for:
- Residential proxy providers (DataImpulse, WebShare, BrightData)
- SOCKS5/HTTP proxy configuration
- Sticky sessions (same IP per profile)
- Geo-targeting by country/city
- Proxy health checking and rotation
- VPN integration (IVPN, Mullvad)

## Integration with Existing Tools

The anti-detect stack integrates with existing browser tools:

| Existing Tool | Integration |
|---------------|-------------|
| **Playwright** | rebrowser-patches applied, stealth context creation |
| **dev-browser** | Profile directory shared, stealth launch args |
| **Crawl4AI** | Camoufox as browser backend, proxy config |
| **CapSolver** | CAPTCHA solving after anti-detect fails |
| **Chrome DevTools** | Debugging stealth issues, leak detection |

## Future Extensions

Services to be added (see `proxy-integration.md` for proxy roadmap):
- Additional proxy providers (Oxylabs, SmartProxy, PacketStream)
- VPN services (NordVPN, ExpressVPN SOCKS5)
- SMS verification services (for account creation)
- Email verification services
- Browser fingerprint marketplace integration
- Cloud browser farms (for scale)
