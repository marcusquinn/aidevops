---
description: Detect exposed origin server IPs behind CDN/WAF (Cloudflare, Sucuri, Incapsula)
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
---

# CDN Origin IP Leak Detection

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Find origin server IPs that bypass CDN/WAF protection
- **Risk**: Exposed origin IPs allow attackers to bypass DDoS protection, WAF rules, and rate limiting
- **Techniques**: DNS history, SSL cert search, Shodan favicon hash, email headers, subdomain enumeration

<!-- AI-CONTEXT-END -->

## Detection Techniques

### 1. DNS History Lookup

Historical DNS records often reveal the origin IP before CDN was configured.

```bash
# SecurityTrails API (requires key)
curl -s "https://api.securitytrails.com/v1/history/$DOMAIN/dns/a" \
  -H "APIKEY: $SECURITYTRAILS_KEY" | jq '.records[].values[].ip'

# Free alternatives
# - viewdns.info/iphistory/?domain=example.com
# - completedns.com/dns-history/
# - dnshistory.org
```

### 2. SSL Certificate Search

Origin servers often share the same SSL cert, searchable via CT logs.

```bash
# Censys (requires API key)
curl -s "https://search.censys.io/api/v2/hosts/search" \
  -H "Authorization: Basic $CENSYS_AUTH" \
  -d '{"q": "services.tls.certificates.leaf.names: example.com"}' \
  | jq '.result.hits[].ip'

# crt.sh (free, no auth)
curl -s "https://crt.sh/?q=%25.example.com&output=json" | jq '.[].common_name' | sort -u
```

### 3. Shodan Favicon Hash

Match the site's favicon hash against Shodan to find servers hosting the same icon.

```bash
# Calculate favicon hash (mmh3)
python3 -c "
import mmh3, requests, codecs
response = requests.get('https://example.com/favicon.ico')
favicon = codecs.encode(response.content, 'base64')
print(f'http.favicon.hash:{mmh3.hash(favicon)}')
"

# Search Shodan with the hash
shodan search "http.favicon.hash:HASH_VALUE"
```

### 4. Email Header Analysis

Outbound emails from the domain may contain the origin IP in headers.

```bash
# Sign up for newsletter or trigger password reset
# Check Received: headers for internal IPs
# Look for X-Originating-IP or X-Mailer-IP headers
```

### 5. Subdomain Enumeration

Non-proxied subdomains (mail, ftp, cpanel, direct) often point to the origin.

```bash
# Check common subdomains
for sub in mail ftp cpanel webmail direct origin www2 staging dev; do
  ip=$(dig +short "$sub.example.com" 2>/dev/null)
  [[ -n "$ip" ]] && echo "$sub.example.com -> $ip"
done

# Subfinder (comprehensive)
subfinder -d example.com -silent | while read -r sub; do
  ip=$(dig +short "$sub" 2>/dev/null | head -1)
  [[ -n "$ip" ]] && echo "$sub -> $ip"
done
```

## Verification

After finding a candidate IP, verify it serves the target site:

```bash
# Direct request with Host header
curl -sk "https://CANDIDATE_IP" -H "Host: example.com" | head -20

# Compare response to CDN-proxied version
diff <(curl -sk "https://CANDIDATE_IP" -H "Host: example.com" | md5) \
     <(curl -sk "https://example.com" | md5)
```

## Remediation

If origin IP is exposed:

1. **Firewall**: Only allow CDN IP ranges (e.g., [Cloudflare IPs](https://www.cloudflare.com/ips/))
2. **Change IP**: Migrate to a new origin IP, update CDN config
3. **Authenticated origin pulls**: Enable CDN-to-origin authentication
4. **Review DNS**: Remove A records for non-proxied subdomains
5. **Email**: Use separate IP/service for outbound email

## Tools Reference

| Tool | Type | Notes |
|------|------|-------|
| SecurityTrails | API | DNS history, subdomains |
| Censys | API | SSL cert + host search |
| Shodan | API/CLI | Favicon hash, banner search |
| crt.sh | Free | Certificate transparency logs |
| subfinder | CLI | Subdomain enumeration |
| Cloudmare | Archived | Python, was 1.7k stars, archived 2023 |
| IP.X | CLI | Python, active, combines multiple techniques |

## Related

- `seo/domain-research.md` - DNS reconnaissance
- `tools/security/privacy-filter.md` - Content privacy filtering
- `tools/browser/anti-detect-browser.md` - Stealth browsing
