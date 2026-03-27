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

Anti-detect browser capabilities for multi-account automation, bot detection evasion, and fingerprint management. Replicates commercial tools (AdsPower, GoLogin, OctoBrowser) using open-source components.

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
    |       +-> Chromium? --> stealth-patches.md (rebrowser-patches)
    |       +-> Firefox?  --> fingerprint-profiles.md (Camoufox)
    |
    +-> Full anti-detect (fingerprint rotation, multi-account)?
    |       +-> Unique fingerprints per profile? --> fingerprint-profiles.md
    |       +-> Persistent profiles (cookies, history)? --> browser-profiles.md
    |       +-> Proxy per profile? --> proxy-integration.md
    |       +-> All of the above? --> anti-detect-helper.sh launch --profile <name>
    |
    +-> Which engine?
    |       +-> Max stealth (C++ spoofing)?       --> Camoufox (Firefox)
    |       +-> Privacy-first (Tor patches)?      --> Mullvad Browser (--engine mullvad)
    |       +-> Speed + existing Playwright code? --> rebrowser-patches (Chromium)
    |       +-> Rotate engines?                   --> anti-detect-helper.sh --engine random
    |
    +-> Headless or headed?
            +-> Headless (server/CI)?        --> Camoufox virtual display OR rebrowser
            +-> Headed (local dev)?          --> Either engine, visible window
            +-> Headless that looks headed?  --> Camoufox (patches headless detection)
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
| **Profile mgmt** | Manual | Python API | Manual | GUI |
| **Proxy integration** | Playwright native | Python API | Manual/system | Built-in |
| **Headless stealth** | Partial | Full (patched) | Partial | N/A |
| **Cost** | Free (MIT) | Free (MPL-2.0) | Free (GPL) | $9-$299/mo |
| **Setup** | `npx rebrowser-patches patch` | `pip install camoufox` | Download app | Download app |

**Mullvad** = manual browsing with uniform fingerprint (all users identical). **Camoufox** = automation with unique realistic fingerprints per profile + full Playwright API.

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

## playwright-cli Integration

| Stealth Level | Setup | Use Case |
|---------------|-------|----------|
| **None** | `playwright-cli open <url>` | Dev testing, trusted sites |
| **Medium** | `npx rebrowser-patches@latest patch` then use playwright-cli normally | Hide automation signals |
| **High** | Camoufox + Playwright API directly (not playwright-cli) | Bot detection evasion, fingerprint rotation → `fingerprint-profiles.md` |

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
