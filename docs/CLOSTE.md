# Closte Provider Guide

Closte is a managed cloud hosting provider optimized for WordPress, offering automatic scaling and a pay-as-you-go model.

## 🏢 **Provider Overview**

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

## 🔍 **Troubleshooting**

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
