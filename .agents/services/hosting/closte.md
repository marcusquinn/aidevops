---
description: Closte managed WordPress hosting
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

# Closte Provider Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Managed WordPress cloud (GCP/Litespeed), pay-as-you-go
- **SSH**: Password auth only (no SSH keys), use `sshpass`
- **Config**: `configs/closte-config.json`
- **DB host**: `mysql.cluster`
- **Caching**: Litespeed Page Cache + Object Cache (Redis) + CDN
- **CRITICAL**: Enable Dev Mode before CLI edits: `wp closte devmode enable`
- **Cache flush**: `wp cache flush --url=https://site.com`
- **Multisite**: Always use `--url=` flag with WP-CLI
- **File perms**: 755 dirs, 644 files, owner u12345678
- **Disable Dev Mode when done**: `wp closte devmode disable`

<!-- AI-CONTEXT-END -->

## Caching & Dev Mode

Closte uses aggressive caching (Litespeed Page Cache + Object Cache/Redis + CDN). Enable Dev Mode before any CLI/SSH edits — otherwise Admin Dashboard and Frontend show stale data even after flushing.

```bash
wp closte devmode enable   # before edits
wp closte devmode disable  # after edits

# Flush object cache (multisite: always specify --url)
wp cache flush --url=https://example.com
```

Via Dashboard: Sites > [Your Site] > Settings > Development Mode toggle.

## Configuration

```bash
cp configs/closte-config.json.txt configs/closte-config.json
```

```json
{
  "servers": {
    "web-server": {
      "ip": "mysql.cluster",
      "port": 22,
      "username": "u12345678",
      "password_file": "~/.ssh/closte_password",
      "description": "Closte Site Container"
    }
  },
  "default_settings": {
    "username": "u12345678",
    "port": 22,
    "password_file": "~/.ssh/closte_password"
  }
}
```

Hostname resolves to `mysql.cluster` or the IP shown in Closte Dashboard > Access.

### SSH / sshpass

Closte does not support SSH keys. Use `sshpass` with a stored password file.

```bash
brew install sshpass          # macOS
sudo apt-get install sshpass  # Linux

echo 'your-closte-password' > ~/.ssh/closte_password
chmod 600 ~/.ssh/closte_password

sshpass -f ~/.ssh/closte_password ssh user@host
sshpass -f ~/.ssh/closte_password scp local.txt user@host:public_html/remote.txt
sshpass -f ~/.ssh/closte_password scp -r user@host:public_html/wp-content/themes/my-theme ./local-theme
```

## WP-CLI (Multisite)

Always specify `--url` to target the correct site.

```bash
wp site list --fields=blog_id,url
wp post update 123 content.txt --url=https://subsite.example.com
wp cache flush --url=https://subsite.example.com
```

## Cloudflare Proxy (SSL A+)

Closte supports TLS 1.1 (SSL Labs grade B). Workaround: proxy through Cloudflare with Full (strict) SSL + min TLS 1.2 → A+ grade.

### Step 1: wp-config.php Fix

Without this, WordPress redirect-loops behind Cloudflare because `is_ssl()` returns false (Cloudflare terminates TLS, origin sees HTTP).

Add **before** `/* That's all, stop editing! */`:

```php
/**
 * Cloudflare proxy: trust X-Forwarded-Proto so WordPress detects HTTPS correctly.
 * Verifies REMOTE_ADDR against Cloudflare IP ranges before trusting the header.
 * Update ranges periodically from https://www.cloudflare.com/ips/
 * On Closte, the managed firewall already restricts origin to Cloudflare IPs (defence-in-depth).
 */
function _cf_ip_in_cidr( string $ip, string $cidr ): bool {
    [ $subnet, $bits ] = explode( '/', $cidr );
    if ( strpos( $ip, ':' ) !== false ) {
        $ip_bin     = inet_pton( $ip );
        $subnet_bin = inet_pton( $subnet );
        if ( $ip_bin === false || $subnet_bin === false ) {
            return false;
        }
        $bytes = (int) ceil( (int) $bits / 8 );
        $mask  = (int) $bits % 8;
        if ( substr( $ip_bin, 0, $bytes - ( $mask ? 1 : 0 ) )
             !== substr( $subnet_bin, 0, $bytes - ( $mask ? 1 : 0 ) ) ) {
            return false;
        }
        if ( $mask ) {
            $last_byte_mask = 0xFF & ( 0xFF << ( 8 - $mask ) );
            return ( ord( $ip_bin[ $bytes - 1 ] ) & $last_byte_mask )
                === ( ord( $subnet_bin[ $bytes - 1 ] ) & $last_byte_mask );
        }
        return true;
    }
    $mask_long = -1 << ( 32 - (int) $bits );
    return ( ip2long( $ip ) & $mask_long ) === ( ip2long( $subnet ) & $mask_long );
}

$cloudflare_ip_ranges = [
    // IPv4 — https://www.cloudflare.com/ips-v4
    '173.245.48.0/20', '103.21.244.0/22', '103.22.200.0/22', '103.31.4.0/22',
    '141.101.64.0/18', '108.162.192.0/18', '190.93.240.0/20', '188.114.96.0/20',
    '197.234.240.0/22', '198.41.128.0/17', '162.158.0.0/15', '104.16.0.0/13',
    '104.24.0.0/14', '172.64.0.0/13', '131.0.72.0/22',
    // IPv6 — https://www.cloudflare.com/ips-v6
    '2400:cb00::/32', '2606:4700::/32', '2803:f800::/32', '2405:b500::/32',
    '2405:8100::/32', '2a06:98c0::/29', '2c0f:f248::/32',
];

$remote_addr     = $_SERVER['REMOTE_ADDR'] ?? '';
$from_cloudflare = false;
foreach ( $cloudflare_ip_ranges as $range ) {
    if ( _cf_ip_in_cidr( $remote_addr, $range ) ) {
        $from_cloudflare = true;
        break;
    }
}

if (
    $from_cloudflare
    && isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] )
    && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https'
) {
    $_SERVER['HTTPS'] = 'on';
}
```

For multisite: add once to the shared `wp-config.php` — applies to all sites.

### Step 2: Server-Level Header Trust (Self-Managed Hosts Only)

On Closte, the managed firewall already restricts origin to Cloudflare IPs — the `wp-config.php` snippet is sufficient. The configs below are for self-managed hosts.

**Apache / LiteSpeed (`mod_remoteip`):**

```apache
RemoteIPHeader X-Forwarded-For
# Cloudflare IPv4 — https://www.cloudflare.com/ips-v4
RemoteIPTrustedProxy 173.245.48.0/20
RemoteIPTrustedProxy 103.21.244.0/22
RemoteIPTrustedProxy 103.22.200.0/22
RemoteIPTrustedProxy 103.31.4.0/22
RemoteIPTrustedProxy 141.101.64.0/18
RemoteIPTrustedProxy 108.162.192.0/18
RemoteIPTrustedProxy 190.93.240.0/20
RemoteIPTrustedProxy 188.114.96.0/20
RemoteIPTrustedProxy 197.234.240.0/22
RemoteIPTrustedProxy 198.41.128.0/17
RemoteIPTrustedProxy 162.158.0.0/15
RemoteIPTrustedProxy 104.16.0.0/13
RemoteIPTrustedProxy 104.24.0.0/14
RemoteIPTrustedProxy 172.64.0.0/13
RemoteIPTrustedProxy 131.0.72.0/22
# Cloudflare IPv6 — https://www.cloudflare.com/ips-v6
RemoteIPTrustedProxy 2400:cb00::/32
RemoteIPTrustedProxy 2606:4700::/32
RemoteIPTrustedProxy 2803:f800::/32
RemoteIPTrustedProxy 2405:b500::/32
RemoteIPTrustedProxy 2405:8100::/32
RemoteIPTrustedProxy 2a06:98c0::/29
RemoteIPTrustedProxy 2c0f:f248::/32
```

**Nginx (`set_real_ip_from`):**

```nginx
# Cloudflare IPv4
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 103.31.4.0/22;
set_real_ip_from 141.101.64.0/18;
set_real_ip_from 108.162.192.0/18;
set_real_ip_from 190.93.240.0/20;
set_real_ip_from 188.114.96.0/20;
set_real_ip_from 197.234.240.0/22;
set_real_ip_from 198.41.128.0/17;
set_real_ip_from 162.158.0.0/15;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 104.24.0.0/14;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 131.0.72.0/22;
# Cloudflare IPv6
set_real_ip_from 2400:cb00::/32;
set_real_ip_from 2606:4700::/32;
set_real_ip_from 2803:f800::/32;
set_real_ip_from 2405:b500::/32;
set_real_ip_from 2405:8100::/32;
set_real_ip_from 2a06:98c0::/29;
set_real_ip_from 2c0f:f248::/32;
real_ip_header X-Forwarded-For;
real_ip_recursive on;
```

IP ranges change periodically — update from <https://www.cloudflare.com/ips/> (machine-readable: `https://api.cloudflare.com/client/v4/ips`).

### Step 3: Cloudflare Zone Settings

1. Add domain to Cloudflare; update registrar nameservers.
2. DNS: proxy (orange cloud) on `A @` → Closte IP and `CNAME www`.
3. SSL/TLS mode: **Full (strict)**. Never use Flexible (sends plaintext to origin).
4. Minimum TLS Version: **TLS 1.2** (SSL/TLS > Edge Certificates).
5. Always Use HTTPS: enable.
6. HSTS: enable, `max-age` ≥ 6 months, `includeSubDomains`.

For multisite with domain mapping: each mapped domain needs its own Cloudflare zone with the same settings. `wp-config.php` snippet is shared.

### Step 4: Verification

```bash
# Verify Cloudflare is proxying
curl -sI https://example.com | grep -i cf-ray

# Verify no redirect loop
curl -sI https://example.com | head -5

# Verify TLS 1.1 rejected at edge
curl --tlsv1.1 --tls-max 1.1 https://example.com 2>&1 | head -3
# Expected: SSL handshake failure
# Alternative: openssl s_client -connect example.com:443 -tls1_1 < /dev/null 2>&1 | head -5
```

### Known Interactions

| Component | Behaviour | Action |
|-----------|-----------|--------|
| Let's Encrypt renewal | HTTP-01 challenge may be blocked/cached by Cloudflare | Page Rule: bypass cache on `/.well-known/acme-challenge/*` |
| Closte Dashboard warnings | Shows "DNS not pointing to us" (detects Cloudflare IPs) | Safe to ignore |
| RSSSL `.htaccess` test | Test request goes through Cloudflare, may fail | Ignore — RSSSL works correctly with `wp-config.php` snippet |
| Closte CDN + Cloudflare | Double-caching / stale content | Disable Closte CDN; keep Litespeed Page Cache + Object Cache |
| Cloudflare APO | Conflicts with Litespeed Cache | If using APO, disable Litespeed Page Cache |

## Troubleshooting

**Changes not visible:**
1. `wp closte devmode enable`
2. `wp cache flush --url=https://example.com`
3. Purge CDN via Closte Dashboard (static assets)
4. Test in Incognito (browser cache)

**DB connection:** Use `mysql.cluster` as `DB_HOST`.

**Permissions:** Owner `u12345678`, dirs `755`, files `644`.
