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

## Stack (bottom-up)

Layer 0: Playwright (browser engine) → Layer 1: rebrowser-patches (CDP leak) → Layer 2: Camoufox (fingerprint) → Layer 3: Proxies (network identity) → Layer 4: CapSolver (CAPTCHA)

## Decision Tree

| Goal | Engine | Doc |
|------|--------|-----|
| Quick stealth, existing Playwright (Chromium) | rebrowser-patches | `stealth-patches.md` |
| Quick stealth, Firefox | Camoufox | `fingerprint-profiles.md` |
| Unique fingerprints per profile | Camoufox | `fingerprint-profiles.md` |
| Persistent profiles (cookies, history) | Any | `browser-profiles.md` |
| Proxy per profile | Any | `proxy-integration.md` |
| Full stack (fingerprint + profile + proxy) | Camoufox | `anti-detect-helper.sh launch --profile <name>` |
| Maximum stealth (C++ spoofing) | Camoufox (Firefox) | `fingerprint-profiles.md` |
| Privacy-first (Tor patches, uniform fingerprint) | Mullvad (`--engine mullvad`) | `proxy-integration.md` |
| Headless that looks headed | Camoufox | `fingerprint-profiles.md` |
| Rotate engines randomly | Any | `anti-detect-helper.sh --engine random` |

## Tool Comparison

| Feature | rebrowser-patches | Camoufox | Mullvad Browser | AdsPower/GoLogin |
|---------|------------------|----------|-----------------|------------------|
| **Engine** | Chromium (Playwright) | Firefox (Playwright) | Firefox (Playwright) | Chromium |
| **Stealth level** | Medium (CDP patches) | High (C++ level) | High (Tor patches) | High (proprietary) |
| **Fingerprint rotation** | No | Yes (BrowserForge) | No (fixed uniform) | Yes |
| **WebRTC spoofing** | No | Yes (protocol level) | Yes (disabled) | Yes |
| **Canvas/WebGL** | No | Yes (C++ intercept) | Yes (randomized) | Yes |
| **Human mouse** | No | Yes (C++ algorithm) | No | Yes |
| **Profile management** | Manual | Python API | Manual | GUI |
| **Proxy integration** | Playwright native | Python API | Manual/system | Built-in |
| **Headless stealth** | Partial | Full (patched) | Partial | N/A |
| **Cost** | Free (MIT) | Free (MPL-2.0) | Free (GPL) | $9-$299/mo |
| **Setup** | `npx rebrowser-patches patch` | `pip install camoufox` | Download app | Download app |

**Mullvad vs Camoufox**: Mullvad uses Tor Browser's uniform fingerprint (all users look identical) — best for manual privacy browsing, limited automation. Camoufox generates unique realistic fingerprints per profile with full Playwright API — best for automation.

## Quick Start

```bash
~/.aidevops/agents/scripts/anti-detect-helper.sh setup
~/.aidevops/agents/scripts/anti-detect-helper.sh profile create "my-account"
~/.aidevops/agents/scripts/anti-detect-helper.sh launch --profile "my-account"                    # Camoufox (full anti-detect)
~/.aidevops/agents/scripts/anti-detect-helper.sh launch --profile "my-account" --engine chromium  # rebrowser-patches (faster)
~/.aidevops/agents/scripts/anti-detect-helper.sh launch --profile "my-account" --engine mullvad   # Mullvad Browser
~/.aidevops/agents/scripts/anti-detect-helper.sh test --profile "my-account"
~/.aidevops/agents/scripts/anti-detect-helper.sh profile clean "my-account"
```

## Integration with playwright-cli

| Stealth Level | Setup | Use Case |
|---------------|-------|----------|
| **None** | `playwright-cli open <url>` | Dev testing, trusted sites |
| **Medium** | Apply rebrowser-patches, then use playwright-cli | Hide automation signals |
| **High** | Camoufox + Playwright API directly | Bot detection evasion |

High stealth requires Camoufox with Playwright API (not playwright-cli) for fingerprint rotation. See `fingerprint-profiles.md`.

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

## Integration with Existing Tools

- **Playwright**: rebrowser-patches applied, stealth context creation
- **dev-browser**: Profile directory shared, stealth launch args
- **Crawl4AI**: Camoufox as browser backend, proxy config
- **CapSolver**: CAPTCHA solving after anti-detect fails
- **Chrome DevTools**: Debugging stealth issues, leak detection

## Ethical Guidelines

Only use for legitimate automation (your own accounts, authorized testing). Respect ToS. Rate limit requests (2-5s minimum). Do not create fake accounts or impersonate others.

<!-- AI-CONTEXT-END -->
