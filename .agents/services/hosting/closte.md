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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

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

Closte uses aggressive caching (Litespeed Page Cache + Object Cache/Redis + CDN). Enable Dev Mode before any CLI/SSH edits — disables all caching layers so you see real-time state.

```bash
wp closte devmode enable   # before edits
wp closte devmode disable  # after edits — restores caching
```

**Via Dashboard:** Sites > [Your Site] > Settings > Development Mode toggle.

If Admin Panel still shows stale data after Dev Mode: `wp cache flush` (add `--url=https://example.com` for multisite).

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

Hostname: use value from Closte Dashboard > Access (`mysql.cluster` or a specific IP).

**SSH setup (password auth only — no keys):**

```bash
brew install sshpass          # macOS
sudo apt-get install sshpass  # Linux

echo 'your-closte-password' > ~/.ssh/closte_password
chmod 600 ~/.ssh/closte_password

sshpass -f ~/.ssh/closte_password ssh user@host
```

## WP-CLI Operations

Closte often hosts Multisite networks. Always specify `--url` to target the correct site.

```bash
wp site list --fields=blog_id,url
wp post update 123 content.txt --url=https://subsite.example.com
wp cache flush --url=https://subsite.example.com
```

**File transfer:**

```bash
sshpass -f ~/.ssh/closte_pass scp local.txt user@host:public_html/remote.txt
sshpass -f ~/.ssh/closte_pass scp -r user@host:public_html/wp-content/themes/my-theme ./local-theme
```

## Cloudflare Proxy (SSL A+ Grade)

Closte supports TLS 1.1 (GCloud limitation), capping SSL Labs at B. Fix: proxy through Cloudflare with Full (strict) SSL and minimum TLS 1.2.

### Step 1: wp-config.php Fix

Without this, WordPress redirect-loops behind Cloudflare because `is_ssl()` returns false (Cloudflare terminates TLS, origin sees HTTP). Add **before** `/* That's all, stop editing! */`:

```php
// Trust X-Forwarded-Proto only from Cloudflare IPs (defence-in-depth;
// Closte's managed firewall already restricts origin access to CF IPs).
// Keep IP list current: https://www.cloudflare.com/ips/
function _cf_ip_in_cidr( string $ip, string $cidr ): bool {
    [ $subnet, $bits ] = explode( '/', $cidr );
    if ( strpos( $ip, ':' ) !== false ) {
        $ip_bin     = inet_pton( $ip );
        $subnet_bin = inet_pton( $subnet );
        if ( $ip_bin === false || $subnet_bin === false ) { return false; }
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
    if ( _cf_ip_in_cidr( $remote_addr, $range ) ) { $from_cloudflare = true; break; }
}

if ( $from_cloudflare
     && isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] )
     && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https' ) {
    $_SERVER['HTTPS'] = 'on';
}
```

For multisite: add once to the shared `wp-config.php` — all sites inherit it.

### Step 2: Cloudflare Zone Settings

1. Add domain to Cloudflare (free plan sufficient); update registrar nameservers.
2. DNS: enable proxy (orange cloud) on `A` record for `@` and `CNAME` for `www`.
3. **SSL/TLS mode** → **Full (strict)**. Never use "Flexible" — sends plaintext to origin.
4. **Minimum TLS Version** → **TLS 1.2** (SSL/TLS > Edge Certificates). Eliminates the B grade.
5. **Always Use HTTPS** → enable.
6. **HSTS** → enable, `max-age` ≥ 6 months, `includeSubDomains`.

### Step 3: Verification

```bash
curl -sI https://example.com | grep -i cf-ray          # Cloudflare proxying
curl -sI https://example.com | head -5                  # no redirect loop
curl --tlsv1.1 --tls-max 1.1 https://example.com 2>&1 | head -3  # TLS 1.1 rejected (expect SSL handshake failure)
```

### Multisite with Domain Mapping

Each mapped domain needs its own Cloudflare zone (free plan). Apply the same settings (Full strict, min TLS 1.2, HSTS) to each zone. DNS for each domain must point to Closte's IP with proxy enabled.

### Known Interactions

| Component | Behaviour | Action |
|-----------|-----------|--------|
| Let's Encrypt renewal | HTTP-01 challenge blocked by Cloudflare cache. | Cache Rule: bypass on `/.well-known/acme-challenge/*`. |
| Closte Dashboard warnings | Shows "DNS not pointing to us" (detects CF IPs). | Safe to ignore. |
| RSSSL `.htaccess` test | Test request via Cloudflare may fail. | Ignore — RSSSL works with the `wp-config.php` snippet. |
| Litespeed Cache CDN | Conflicts with Cloudflare CDN (double-caching). | Disable Closte CDN (Dashboard > CDN); keep Page Cache and Object Cache. |
| Cloudflare APO | Conflicts with Litespeed Cache. | If using APO, disable Litespeed Page Cache. Litespeed alone is usually sufficient. |

## Troubleshooting

**Changes not visible:**

1. Confirm `wp closte devmode enable` was run.
2. `wp cache flush` (add `--url=` for multisite).
3. Purge CDN via Closte Dashboard if static assets are stale.
4. Test in Incognito to rule out browser cache.

**Database connection:** Closte uses `mysql.cluster` as `DB_HOST`. Ensure WP-CLI config and scripts use this value.

**Permissions:** Files owned by `u12345678:u12345678`. Standard: `755` dirs, `644` files.
