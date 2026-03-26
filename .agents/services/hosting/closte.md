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
 */
if (
    isset($_SERVER['HTTP_X_FORWARDED_PROTO'])
    && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https'
) {
    $_SERVER['HTTPS'] = 'on';
}
```

**For multisite:** This goes in the shared `wp-config.php` — it applies to all sites in the network.

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

# Verify TLS 1.1 is rejected at the edge
curl --tlsv1.1 --tls-max 1.1 https://example.com 2>&1 | head -3
# Expected: SSL handshake failure or protocol error
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
