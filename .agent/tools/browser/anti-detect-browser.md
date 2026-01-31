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
    |       +-> Privacy-first (Tor Browser patches)? --> Mullvad Browser (--engine mullvad)
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

| Feature | rebrowser-patches | Camoufox | Mullvad Browser | AdsPower/GoLogin |
|---------|------------------|----------|-----------------|------------------|
| **Engine** | Chromium (Playwright) | Firefox (Playwright) | Firefox (Playwright) | Chromium |
| **Stealth level** | Medium (CDP patches) | High (C++ level) | High (Tor patches) | High (proprietary) |
| **Fingerprint rotation** | No (add manually) | Yes (BrowserForge) | No (fixed uniform) | Yes |
| **WebRTC spoofing** | No | Yes (protocol level) | Yes (disabled) | Yes |
| **Canvas/WebGL** | No | Yes (C++ intercept) | Yes (randomized) | Yes |
| **Font spoofing** | No | Yes (bundled fonts) | Yes (limited set) | Yes |
| **Human mouse** | No | Yes (C++ algorithm) | No | Yes |
| **Profile management** | Manual | Python API | Manual | GUI |
| **Proxy integration** | Playwright native | Python API | Manual/system | Built-in |
| **Headless stealth** | Partial | Full (patched) | Partial | N/A |
| **Cost** | Free (MIT) | Free (MPL-2.0) | Free (GPL) | $9-$299/mo |
| **Setup** | `npx rebrowser-patches patch` | `pip install camoufox` | Download app | Download app |

**Mullvad Browser vs Camoufox**:
- **Mullvad Browser**: Best for manual browsing with privacy. Uses Tor Browser's uniform fingerprint approach (all users look identical). Limited automation support.
- **Camoufox**: Best for automation. Generates unique, realistic fingerprints per profile. Full Playwright API support with C++ level spoofing.

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

# Launch with Mullvad Browser (Tor-based privacy, no fingerprint rotation)
~/.aidevops/agents/scripts/anti-detect-helper.sh launch --profile "my-account" --engine mullvad

# Test detection status
~/.aidevops/agents/scripts/anti-detect-helper.sh test --profile "my-account"

# Clean profile (fresh fingerprint, no cookies)
~/.aidevops/agents/scripts/anti-detect-helper.sh profile clean "my-account"
```

## Integration with playwright-cli

playwright-cli uses Playwright's Chromium under the hood. For stealth:

| Stealth Level | Setup | Use Case |
|---------------|-------|----------|
| **None** | `playwright-cli open <url>` | Dev testing, trusted sites |
| **Medium** | Apply rebrowser-patches, then use playwright-cli | Hide automation signals |
| **High** | Use Camoufox + Playwright API directly | Bot detection evasion |

**Medium stealth with playwright-cli**:

```bash
# 1. Patch Playwright's Chromium (one-time)
npx rebrowser-patches@latest patch

# 2. Use playwright-cli normally - it uses patched browser
playwright-cli open https://bot-detection-test.com
playwright-cli snapshot
```

**High stealth** requires Camoufox with Playwright API (not playwright-cli) for fingerprint rotation. See `fingerprint-profiles.md`.

## Subagent Index

| Subagent | Purpose | When to Read |
|----------|---------|--------------|
| `playwright-cli.md` | CLI automation (works with rebrowser-patches) | AI agent automation |
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
