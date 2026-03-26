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

Closte is a managed cloud hosting provider optimized for WordPress, offering automatic scaling and a pay-as-you-go model.

## Provider Overview

### **Closte Characteristics:**

- **Infrastructure Type**: Managed WordPress Cloud (Google Cloud Platform / Litespeed)
- **Locations**: Global (GCP network)
- **SSH Access**: Restricted shell access with password authentication (keys not supported)
- **Control Panel**: Custom Closte Dashboard
- **Caching**: Integrated Litespeed Cache + CDN + Object Cache (Redis)
- **Pricing**: Pay-as-you-go based on resource usage
- **Performance**: High-performance Litespeed stack

## ⚠️ **Critical: Caching & AI Content Editing**

**Issue:** Closte uses aggressive caching (Litespeed Page Cache + Object Cache/Redis + CDN). When updating content via WP-CLI or SSH, the Admin Dashboard and Frontend may show stale data even after flushing standard caches.

**Solution:** You must enable **Development Mode** before performing bulk edits or debugging via CLI/SSH.

### **Enabling Development Mode**

Development Mode disables all caching layers (Page, Object, CDN) to ensure you see the real-time state of the database.

**Via WP-CLI (Recommended):**

```bash
# Enable Dev Mode
wp closte devmode enable

# Disable Dev Mode (Restore Caching)
wp closte devmode disable
```

**Via Dashboard:**

1. Go to Closte Dashboard > Sites > [Your Site].
2. Navigate to **Settings**.
3. Toggle **Development Mode** to ON.

**Manual Object Cache Flush:**
If changes are still stuck in the Admin Panel (e.g., "Last edited 7 days ago"), flush the object cache specifically:

```bash
wp cache flush
# If using multisite, specify URL:
wp cache flush --url=https://example.com
```

## 🔧 **Configuration**

### **Setup Configuration:**

```bash
# Copy template
cp configs/closte-config.json.txt configs/closte-config.json
```

### **Configuration Structure:**

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

**Note:** Hostname often resolves to `mysql.cluster` or specific IP. Use the IP/Host provided in the Closte Dashboard under "Access".

### **Password Authentication:**

Closte **does not support SSH keys**. You must use `sshpass` with a stored password file.

```bash
# Install sshpass
brew install sshpass  # macOS
sudo apt-get install sshpass  # Linux

# Store password
echo 'your-closte-password' > ~/.ssh/closte_password
chmod 600 ~/.ssh/closte_password

# Connect
sshpass -f ~/.ssh/closte_password ssh user@host
```

## 🚀 **Usage Examples**

### **WP-CLI Operations (Multisite):**

Closte often hosts Multisite networks. Always specify `--url` to target the correct site.

```bash
# List sites
wp site list --fields=blog_id,url

# Update Post on Specific Site
wp post update 123 content.txt --url=https://subsite.example.com

# Flush Cache for Specific Site
wp cache flush --url=https://subsite.example.com
```

### **File Operations:**

```bash
# Upload file
sshpass -f ~/.ssh/closte_pass scp local.txt user@host:public_html/remote.txt

# Recursive Download
sshpass -f ~/.ssh/closte_pass scp -r user@host:public_html/wp-content/themes/my-theme ./local-theme
```

## Cloudflare Proxy (SSL A+ Grade)

Closte runs on Google Cloud with LiteSpeed and supports TLS 1.1, which caps the SSL Labs grade at B. Closte has declined to disable TLS 1.0/1.1 (GCloud platform limitation). The workaround is to place Cloudflare in front of the site with Full (strict) SSL and minimum TLS 1.2, which achieves an A+ grade on SSL Labs.

### Step 1: WordPress `wp-config.php` Fix (Required First)

Without this fix, WordPress enters an infinite redirect loop behind Cloudflare proxy because it cannot detect HTTPS from the forwarded headers.

Add this snippet **before** `/* That's all, stop editing! */` in `wp-config.php`:

```php
/**
 * Cloudflare proxy: trust X-Forwarded-Proto so WordPress detects HTTPS correctly.
 * Without this, WordPress redirect-loops when Cloudflare proxies the request
 * because is_ssl() returns false (Cloudflare terminates TLS, origin sees HTTP).
 *
 * Security: only trust the header when the request originates from a Cloudflare
 * IP. Ranges sourced from https://www.cloudflare.com/ips/ (update periodically).
 * On Closte the managed firewall already restricts origin access to Cloudflare,
 * so this check is defence-in-depth. On self-managed hosts it is the primary
 * guard against header spoofing by direct-to-origin attackers.
 */
function _cf_ip_in_cidr( string $ip, string $cidr ): bool {
    [ $subnet, $bits ] = explode( '/', $cidr );
    if ( strpos( $ip, ':' ) !== false ) {
        // IPv6: compare the first $bits bits of the packed addresses.
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
    // IPv4
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

$remote_addr    = $_SERVER['REMOTE_ADDR'] ?? '';
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

**Security note:** The snippet verifies `REMOTE_ADDR` against Cloudflare's published IP ranges before trusting `X-Forwarded-Proto`. This prevents a direct-to-origin attacker from spoofing the header. Keep the IP list current with [https://www.cloudflare.com/ips/](https://www.cloudflare.com/ips/) — Cloudflare publishes changes there. On Closte, the managed platform firewall already restricts origin access to Cloudflare IPs, so this check is defence-in-depth.

**For multisite:** This goes in the shared `wp-config.php` — it applies to all sites in the network.

### Server-Level Header Trust (Defence-in-Depth)

The `wp-config.php` snippet above handles header verification at the application layer. For stronger security, also restrict header trust at the web server level. This ensures **all** applications on the server — not just WordPress — only trust forwarded headers from Cloudflare.

**On Closte (managed hosting):** Closte's platform firewall already restricts origin access to Cloudflare IPs, so server-level config is not required. The `wp-config.php` snippet is sufficient. The guidance below is for self-managed hosts or environments where you control the web server config.

**Apache / LiteSpeed (`mod_remoteip`):**

```apache
# /etc/apache2/conf-available/cloudflare.conf (or .htaccess if AllowOverride permits)
# Requires: mod_remoteip enabled (a2enmod remoteip)

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

This replaces `REMOTE_ADDR` with the real client IP from `X-Forwarded-For` only when the request comes from a Cloudflare IP. Requests from non-Cloudflare IPs keep their original `REMOTE_ADDR` and forwarded headers are ignored.

**Nginx (`set_real_ip_from`):**

```nginx
# /etc/nginx/conf.d/cloudflare.conf

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

**Maintenance:** Cloudflare publishes IP range changes at [https://www.cloudflare.com/ips/](https://www.cloudflare.com/ips/). Review periodically and update both the server config and the `wp-config.php` snippet. Cloudflare also provides a machine-readable endpoint: `https://api.cloudflare.com/client/v4/ips`.

### Step 2: Cloudflare Zone Settings

1. **Add the domain** to Cloudflare (free plan is sufficient).
2. **Update nameservers** at the registrar to point to Cloudflare's assigned nameservers.
3. **DNS records** — set proxy status (orange cloud) on:
   - `A` record for `@` (root domain) pointing to Closte's IP
   - `CNAME` record for `www` pointing to the root domain (or Closte's hostname)
4. **SSL/TLS mode** — set to **Full (strict)**. This encrypts traffic between Cloudflare and Closte using Closte's Let's Encrypt certificate. Never use "Flexible" — it sends plaintext to origin.
5. **Minimum TLS Version** — set to **TLS 1.2** (under SSL/TLS > Edge Certificates). This is what eliminates the B grade.
6. **Always Use HTTPS** — enable (under SSL/TLS > Edge Certificates).
7. **HSTS** — enable with `max-age` of at least 6 months and `includeSubDomains` (under SSL/TLS > Edge Certificates).

### Step 3: Verification

```bash
# Check SSL Labs grade (should be A or A+)
# Visit: https://www.ssllabs.com/ssltest/analyze.html?d=example.com

# Verify Cloudflare is proxying (response headers should include cf-ray)
curl -sI https://example.com | grep -i cf-ray

# Verify no redirect loop
curl -sI https://example.com | head -5

# Verify TLS 1.1 is rejected at the edge (requires curl 7.54.0+ with OpenSSL)
curl --tlsv1.1 --tls-max 1.1 https://example.com 2>&1 | head -3
# Expected: SSL handshake failure or protocol error
# Alternative for older curl or restricted environments:
# openssl s_client -connect example.com:443 -tls1_1 < /dev/null 2>&1 | head -5
```

### Multisite with Domain Mapping

For WordPress multisite with domain-mapped sites (each subsite has its own domain):

- **Each mapped domain needs its own Cloudflare zone** (free plan, one zone per domain).
- **Apply the same settings** (Full strict, min TLS 1.2, HSTS) to each zone.
- The `wp-config.php` snippet is shared — it only needs to be added once since all sites share the same WordPress installation.
- **DNS for each domain** must point to Closte's IP with proxy enabled (orange cloud).

### Known Interactions

| Component | Behaviour | Action |
|-----------|-----------|--------|
| Let's Encrypt renewal | Closte auto-renews via HTTP-01 challenge. Cloudflare proxy can interfere if it caches or blocks `/.well-known/acme-challenge/`. | Create a Cloudflare Page Rule or Cache Rule to bypass cache on `/.well-known/acme-challenge/*`. Closte support may also need to whitelist Cloudflare IPs. |
| Closte Dashboard warnings | Dashboard may show "DNS not pointing to us" because it detects Cloudflare's IPs instead of a direct connection. | Safe to ignore — the site works correctly. Closte is aware of this pattern. |
| RSSSL `.htaccess` test | Really Simple SSL plugin's server test may fail because the test request goes through Cloudflare. The plugin still works correctly. | Ignore the test failure. RSSSL functions normally with the `wp-config.php` snippet above. |
| Litespeed Cache CDN | Closte's built-in CDN and Cloudflare CDN can conflict, causing double-caching or stale content. | Disable Closte's CDN (in Closte Dashboard > CDN) when using Cloudflare proxy. Keep Litespeed Page Cache and Object Cache enabled — those are server-side and don't conflict. |
| Cloudflare APO (WordPress) | Cloudflare's Automatic Platform Optimization for WordPress can conflict with Litespeed Cache. | If using APO, disable Litespeed Page Cache to avoid double-caching. Generally, Litespeed Cache alone is sufficient — APO adds marginal benefit when the origin is already fast. |

## Troubleshooting

### **Changes Not Visible:**

1. **Check Dev Mode:** Ensure `wp closte devmode enable` is run.
2. **Flush Object Cache:** Run `wp cache flush`.
3. **Check CDN:** Purge CDN via Closte Dashboard if static assets are stale.
4. **Browser Cache:** Use Incognito mode.

### **Database Connection:**

Closte uses `mysql.cluster` as DB_HOST. Ensure your scripts/WP-CLI config respect this.

### **Permissions:**

Files should generally be owned by the user (e.g., `u12345678`) and group `u12345678`.
Standard permissions: `755` for directories, `644` for files.

---

**Closte is powerful but requires strict cache management for development workflows.** 🚀
