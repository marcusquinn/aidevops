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

## Credentials

Store in `~/.config/aidevops/credentials.sh` (600 perms):

```bash
export DATAIMPULSE_USER="user"   # ~$1/GB residential
export DATAIMPULSE_PASS="pass"
export WEBSHARE_API_KEY="key"    # ~$6/GB residential
export BRIGHTDATA_ZONE="zone"    # enterprise
export BRIGHTDATA_PASS="pass"
export IVPN_SOCKS_HOST="socks5://10.0.0.1:1080"
export MULLVAD_SOCKS_HOST="socks5://10.0.0.1:1080"
```

## Provider URL Formats

**DataImpulse** — append modifiers to password with `_`:

```
http://user:pass@gw.dataimpulse.com:823                          # rotating
http://user:pass_session-abc123@gw.dataimpulse.com:823           # sticky
http://user:pass_country-us_city-newyork@gw.dataimpulse.com:823  # geo-targeted
```

**WebShare:**

```
http://user:pass@p.webshare.io:80           # rotating
http://user-country-us:pass@p.webshare.io:80  # country targeting
```

**BrightData:**

```
http://user-zone-residential:pass@brd.superproxy.io:22225                  # rotating
http://user-zone-residential-session-abc:pass@brd.superproxy.io:22225      # sticky
http://user-zone-residential-country-us:pass@brd.superproxy.io:22225       # country
```

**SOCKS5 VPN** (IVPN/Mullvad — requires active subscription + WireGuard):

```
socks5://10.0.0.1:1080              # provider local (same format for both)
socks5://user:pass@host:1080        # generic with auth
```

## Per-Profile Assignment

```bash
# Sticky session + geo-targeting
anti-detect-helper.sh profile update "my-account" \
  --proxy "http://user:pass_country-us_city-newyork@gw.dataimpulse.com:823"

# Rotating (new IP each launch) — scrapers
anti-detect-helper.sh profile update "scraper" \
  --proxy "http://user:pass@gw.dataimpulse.com:823" \
  --proxy-mode rotating
```

## Health Checking

```bash
anti-detect-helper.sh proxy check "http://user:pass@host:port"  # single
anti-detect-helper.sh proxy check-all  # all profiles; outputs IP/country/city/ISP/speed/anonymity
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

`anti-detect-helper.sh profile update --proxy-mode [rotating|sticky|round-robin|failover]`. Sticky sessions default to 30m; override with `--session-duration`.

## Browser Engine Integration

Proxy config structure is identical across engines — only the wrapper differs:

**Playwright (Chromium):**

```javascript
const browser = await chromium.launch({
  proxy: { server: 'http://gw.dataimpulse.com:823', username: 'user', password: 'pass_country-us_session-abc123' }
});
```

**Camoufox (Firefox):**

```python
with Camoufox(headless=True, proxy={"server": "...", "username": "user", "password": "pass_country-us"}, geoip=True) as browser:
    ...  # geoip=True auto-matches timezone/locale to proxy region
```

**Crawl4AI:**

```python
browser_config = BrowserConfig(proxy_config={"server": "...", "username": "user", "password": "pass_country-us"})
```

## Security

- Never commit proxy credentials — use `credentials.sh` (600 perms)
- Use sticky sessions for login flows (avoid IP changes mid-session)
- Match proxy geo to profile fingerprint (timezone, locale, geolocation)
- Rotate proxies if blocked — don't retry same IP

<!-- AI-CONTEXT-END -->
