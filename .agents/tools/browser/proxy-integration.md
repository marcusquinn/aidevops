---
description: Proxy integration for anti-detect browsers - residential, SOCKS5, VPN, rotation
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
---

# Proxy Integration

<!-- AI-CONTEXT-START -->

Network identity layer for anti-detect browser profiles. Supports residential, datacenter, SOCKS5, and VPN proxies with per-profile assignment, rotation, and health checking.

## Proxy Types

| Type | Detection Risk | Speed | Cost | Best For |
|------|---------------|-------|------|----------|
| **Residential** | Very low | Medium | $1-10/GB | Multi-account, social media |
| **ISP/Static** | Low | Fast | $2-5/IP/mo | Persistent accounts |
| **Datacenter** | High | Very fast | $0.5-2/IP/mo | Scraping, non-sensitive |
| **Mobile** | Very low | Slow | $3-20/GB | Highest trust, mobile apps |
| **SOCKS5 VPN** | Low | Fast | $5-10/mo | Privacy, geo-unblocking |

## Provider Configuration

Credentials stored in `~/.config/aidevops/credentials.sh` (600 perms):

```bash
# Residential providers
export DATAIMPULSE_USER="user"
export DATAIMPULSE_PASS="pass"
export WEBSHARE_API_KEY="key"
export BRIGHTDATA_ZONE="zone"
export BRIGHTDATA_PASS="pass"

# VPN SOCKS5
export IVPN_SOCKS_HOST="socks5://10.0.0.1:1080"
export MULLVAD_SOCKS_HOST="socks5://10.0.0.1:1080"
```

## Provider Formats

### DataImpulse (~$1/GB residential, rotating or sticky)

```bash
# Rotating (new IP each request)
http://user:pass@gw.dataimpulse.com:823

# Sticky session (same IP for duration)
http://user:pass_session-abc123@gw.dataimpulse.com:823

# Country targeting
http://user:pass_country-us@gw.dataimpulse.com:823

# City targeting
http://user:pass_country-us_city-newyork@gw.dataimpulse.com:823
```

### WebShare (~$6/GB residential)

```bash
# Direct proxy list (from API)
http://user:pass@proxy1.webshare.io:80

# Rotating endpoint
http://user:pass@p.webshare.io:80

# Country targeting
http://user-country-us:pass@p.webshare.io:80
```

### BrightData (enterprise)

```bash
# Residential rotating
http://user-zone-residential:pass@brd.superproxy.io:22225

# Sticky session
http://user-zone-residential-session-abc:pass@brd.superproxy.io:22225

# Country
http://user-zone-residential-country-us:pass@brd.superproxy.io:22225
```

### SOCKS5 VPN (IVPN/Mullvad — requires active subscription + WireGuard)

```bash
# Provider local SOCKS5 (same format for IVPN and Mullvad)
socks5://10.0.0.1:1080

# Generic SOCKS5 with auth
socks5://user:pass@host:1080
```

## Per-Profile Proxy Assignment

```bash
# Assign proxy with sticky session + geo-targeting
anti-detect-helper.sh profile update "my-account" \
  --proxy "http://user:pass_country-us_city-newyork@gw.dataimpulse.com:823"

# Rotating proxy (new IP each launch) — use for scrapers
anti-detect-helper.sh profile update "scraper" \
  --proxy "http://user:pass@gw.dataimpulse.com:823" \
  --proxy-mode rotating
```

## Proxy Health Checking

```bash
# Check single proxy
anti-detect-helper.sh proxy check "http://user:pass@host:port"

# Check all profile proxies
anti-detect-helper.sh proxy check-all
# Output: IP, country, city, ISP, speed, anonymity level
```

DNS leak prevention: Playwright handles automatically; Camoufox uses `network.proxy.socks_remote_dns = true` (default).

## Rotation Strategies

| Strategy | Use Case |
|----------|----------|
| **Fixed** | Persistent accounts |
| **Rotating** | Scraping (new IP each request) |
| **Sticky session** | Login flows (same IP for N minutes) |
| **Round-robin** | Load distribution across proxy list |
| **Geo-targeted** | Match profile's target region |
| **Failover** | Switch on error/block |

Pass `--proxy-mode [rotating|sticky|round-robin|failover]` to `anti-detect-helper.sh profile update`. Sticky sessions default to 30m; override with `--session-duration`.

## Browser Engine Integration

### Playwright (Chromium)

```javascript
const browser = await chromium.launch({
  proxy: {
    server: 'http://gw.dataimpulse.com:823',
    username: 'user',
    password: 'pass_country-us_session-abc123',
  }
});
```

### Camoufox (Firefox)

```python
with Camoufox(
    headless=True,
    proxy={
        "server": "http://gw.dataimpulse.com:823",
        "username": "user",
        "password": "pass_country-us",
    },
    geoip=True,  # Auto-match timezone/locale to proxy region
) as browser:
    ...
```

### Crawl4AI

```python
browser_config = BrowserConfig(
    proxy_config={
        "server": "http://gw.dataimpulse.com:823",
        "username": "user",
        "password": "pass_country-us",
    }
)
```

## Security

- Never commit proxy credentials — use `credentials.sh` (600 perms)
- Use sticky sessions for login flows (avoid IP changes mid-session)
- Match proxy geo to profile fingerprint (timezone, locale, geolocation)
- Rotate proxies if blocked — don't retry same IP

<!-- AI-CONTEXT-END -->
