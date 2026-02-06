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

## Overview

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

Proxy credentials stored in `~/.config/aidevops/credentials.sh`:

```bash
# Residential providers
export DATAIMPULSE_USER="user"
export DATAIMPULSE_PASS="pass"
export WEBSHARE_API_KEY="key"
export BRIGHTDATA_ZONE="zone"
export BRIGHTDATA_PASS="pass"
export OXYLABS_USER="user"
export OXYLABS_PASS="pass"
export SMARTPROXY_USER="user"
export SMARTPROXY_PASS="pass"

# VPN SOCKS5
export IVPN_SOCKS_HOST="socks5://10.0.0.1:1080"
export MULLVAD_SOCKS_HOST="socks5://10.0.0.1:1080"
```

## Provider Formats

### DataImpulse (~$1/GB residential)

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

### SOCKS5 VPN (IVPN/Mullvad)

```bash
# IVPN (requires active subscription + WireGuard)
socks5://10.0.0.1:1080

# Mullvad (requires active subscription + WireGuard)
socks5://10.0.0.1:1080

# Generic SOCKS5
socks5://user:pass@host:1080
```

## Per-Profile Proxy Assignment

```bash
# Assign proxy to profile
anti-detect-helper.sh profile update "my-account" \
  --proxy "http://user:pass_session-fixed123@gw.dataimpulse.com:823"

# Assign with geo-targeting
anti-detect-helper.sh profile update "my-account" \
  --proxy "http://user:pass_country-us_city-newyork@gw.dataimpulse.com:823"

# Use rotating proxy (new IP each launch)
anti-detect-helper.sh profile update "scraper" \
  --proxy "http://user:pass@gw.dataimpulse.com:823" \
  --proxy-mode rotating

# Use sticky session (same IP for session duration)
anti-detect-helper.sh profile update "my-account" \
  --proxy "http://user:pass@gw.dataimpulse.com:823" \
  --proxy-mode sticky
```

## Proxy Health Checking

```bash
# Check single proxy
anti-detect-helper.sh proxy check "http://user:pass@host:port"

# Check all profile proxies
anti-detect-helper.sh proxy check-all

# Output: IP, country, city, ISP, speed, anonymity level
```

### Health Check Script

```bash
check_proxy() {
    local proxy="$1"
    local result
    result=$(curl -s --proxy "$proxy" --max-time 10 "https://httpbin.org/ip" 2>/dev/null)
    if [ $? -eq 0 ]; then
        local ip
        ip=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['origin'])" 2>/dev/null)
        echo "OK: $ip"
        return 0
    else
        echo "FAIL: Connection timeout"
        return 1
    fi
}
```

## Proxy Rotation Strategies

| Strategy | Description | Use Case |
|----------|-------------|----------|
| **Fixed** | Same proxy always | Persistent accounts |
| **Rotating** | New IP each request | Scraping |
| **Sticky session** | Same IP for N minutes | Login flows |
| **Round-robin** | Cycle through proxy list | Load distribution |
| **Geo-targeted** | Match profile's target region | Regional accounts |
| **Failover** | Switch on error/block | Reliability |

### Rotation Configuration

```json
{
  "strategy": "sticky",
  "provider": "dataimpulse",
  "session_duration": "30m",
  "country": "us",
  "city": "new-york",
  "fallback_provider": "webshare",
  "max_retries": 3,
  "health_check_interval": "5m"
}
```

## Integration with Browser Engines

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

## DNS Leak Prevention

```bash
# Verify no DNS leaks through proxy
anti-detect-helper.sh proxy dns-check "profile-name"

# Forces DNS through proxy (not system resolver)
# Playwright: handled automatically with proxy config
# Camoufox: network.proxy.socks_remote_dns = true (default)
```

## Future Providers (Roadmap)

Services to be added as subagents when needed:

| Provider | Type | Pricing | Notes |
|----------|------|---------|-------|
| Oxylabs | Residential | ~$8/GB | Enterprise, large pools |
| SmartProxy | Residential | ~$7/GB | Good geo coverage |
| PacketStream | Residential | ~$1/GB | Budget option |
| NordVPN | SOCKS5 | $4/mo | 5000+ servers |
| ExpressVPN | SOCKS5 | $8/mo | Fast, many locations |
| IPRoyal | Residential | ~$1.75/GB | Static residential available |

## Security Notes

- Never commit proxy credentials (stored in `credentials.sh` with 600 permissions)
- Use sticky sessions for login flows (avoid IP changes mid-session)
- Match proxy geo to profile fingerprint (timezone, locale, geolocation)
- Monitor proxy usage/costs via provider dashboards
- Rotate proxies if blocked (don't retry same IP)

<!-- AI-CONTEXT-END -->
