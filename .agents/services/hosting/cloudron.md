---
description: Cloudron self-hosted app platform
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

# Cloudron App Platform Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Self-hosted app platform (100+ apps), auto-updates/backups/SSL
- **Auth**: API token from Dashboard > Settings > API Access
- **Config**: `configs/cloudron-config.json`
- **Commands**: `cloudron-helper.sh [servers|connect|status|apps|install-app|update-app|restart-app|logs|backup-app|domains|add-domain|users|add-user] [server] [args]`
- **API test**: `curl -H "Authorization: Bearer TOKEN" https://cloudron.domain.com/api/v1/cloudron/status`
- **App ops**: `install-app [server] [app] [subdomain]`, `update-app`, `restart-app`, `logs`
- **Backup**: `backup-system`, `backup-app`, `list-backups`, `restore-backup`
- **User mgmt**: `users`, `add-user`, `update-user`, `reset-password`
- **SSH access**: `ssh root@cloudron.domain.com` for direct server diagnosis
- **Forum**: [forum.cloudron.io](https://forum.cloudron.io) for known issues and solutions
- **Docker**: `docker ps -a` (states), `docker logs <container>`, `docker exec -it mysql mysql`
- **DB creds**: `docker inspect <container> | grep CLOUDRON_MYSQL`
<!-- AI-CONTEXT-END -->

Cloudron is a complete solution for running apps on your server, providing easy app installation, automatic updates, backups, and domain management.

## Provider Overview

### **Cloudron Characteristics:**

- **Service Type**: Self-hosted app platform and server management
- **App Ecosystem**: 100+ pre-configured apps available
- **Management**: Web-based dashboard for complete server management
- **Automation**: Automatic updates, backups, and SSL certificates
- **Multi-tenancy**: Support for multiple users and domains
- **API Support**: REST API for automation and integration
- **Security**: Built-in firewall, automatic security updates

### **Best Use Cases:**

- **Small to medium businesses** needing multiple web applications
- **Self-hosted alternatives** to SaaS applications
- **Development teams** needing staging and production environments
- **Organizations** requiring data sovereignty and privacy
- **Rapid application deployment** without complex configuration
- **Centralized management** of multiple applications and domains

## 🔧 **Configuration**

### **Setup Configuration:**

```bash
# Copy template
cp configs/cloudron-config.json.txt configs/cloudron-config.json

# Edit with your actual Cloudron server details
```

### **Configuration Structure:**

```json
{
  "servers": {
    "production": {
      "hostname": "cloudron.yourdomain.com",
      "ip": "192.168.1.100",
      "api_token": "YOUR_CLOUDRON_API_TOKEN_HERE",
      "description": "Production Cloudron server",
      "version": "7.5.0",
      "apps_count": 15
    },
    "staging": {
      "hostname": "staging-cloudron.yourdomain.com",
      "ip": "192.168.1.101",
      "api_token": "YOUR_STAGING_CLOUDRON_API_TOKEN_HERE",
      "description": "Staging Cloudron server",
      "version": "7.5.0",
      "apps_count": 5
    }
  }
}
```

### **API Token Setup:**

1. **Login to Cloudron Dashboard**
2. **Navigate to Settings** → API Access
3. **Generate API Token** with required permissions
4. **Copy token** to your configuration file
5. **Test access** with the helper script

## 🚀 **Usage Examples**

### **Basic Commands:**

```bash
# List all Cloudron servers
./.agents/scripts/cloudron-helper.sh servers

# Connect to Cloudron server
./.agents/scripts/cloudron-helper.sh connect production

# Get server status
./.agents/scripts/cloudron-helper.sh status production

# List installed apps
./.agents/scripts/cloudron-helper.sh apps production
```

### **App Management:**

```bash
# Install new app
./.agents/scripts/cloudron-helper.sh install-app production wordpress blog.yourdomain.com

# Update app
./.agents/scripts/cloudron-helper.sh update-app production app-id

# Restart app
./.agents/scripts/cloudron-helper.sh restart-app production app-id

# Get app logs
./.agents/scripts/cloudron-helper.sh logs production app-id

# Backup app
./.agents/scripts/cloudron-helper.sh backup-app production app-id
```

### **Domain Management:**

```bash
# List domains
./.agents/scripts/cloudron-helper.sh domains production

# Add domain
./.agents/scripts/cloudron-helper.sh add-domain production newdomain.com

# Configure DNS
./.agents/scripts/cloudron-helper.sh configure-dns production newdomain.com

# Get SSL certificate status
./.agents/scripts/cloudron-helper.sh ssl-status production newdomain.com
```

### **User Management:**

```bash
# List users
./.agents/scripts/cloudron-helper.sh users production

# Add user
./.agents/scripts/cloudron-helper.sh add-user production newuser@domain.com

# Update user permissions
./.agents/scripts/cloudron-helper.sh update-user production user-id admin

# Reset user password
./.agents/scripts/cloudron-helper.sh reset-password production user-id
```

## 🛡️ **Security Best Practices**

### **Server Security:**

- **Regular updates**: Keep Cloudron platform updated
- **Firewall configuration**: Use Cloudron's built-in firewall
- **SSL certificates**: Ensure all apps have valid SSL certificates
- **Access control**: Implement proper user access controls
- **Backup encryption**: Enable backup encryption

### **API Security:**

- **Token rotation**: Rotate API tokens regularly
- **Minimal permissions**: Use tokens with minimal required permissions
- **Secure storage**: Store API tokens securely
- **Access monitoring**: Monitor API access and usage
- **HTTPS only**: Always use HTTPS for API access

### **App Security:**

```bash
# Check app security status
./.agents/scripts/cloudron-helper.sh security-status production

# Update all apps
./.agents/scripts/cloudron-helper.sh update-all-apps production

# Check SSL certificates
./.agents/scripts/cloudron-helper.sh ssl-check production

# Review user access
./.agents/scripts/cloudron-helper.sh audit-users production
```

## 🔍 **Troubleshooting**

### **Troubleshooting Resources**

**Cloudron Forum**: Always check [forum.cloudron.io](https://forum.cloudron.io) for known issues:

- Search for error messages from app logs
- Check app-specific categories for recent issues
- Look for official workarounds from Cloudron staff
- Common post-update issues often have forum threads with solutions

### **SSH Diagnostic Access**

For deep troubleshooting, SSH directly into the Cloudron server:

```bash
# SSH into Cloudron server (use hostname from config)
ssh root@my.cloudron.domain.com

# Check all container states
docker ps -a

# Look for containers in "Restarting" state (indicates problems)
docker ps -a --filter "status=restarting"

# View container logs (last 100 lines)
docker logs --tail 100 <container_name>

# Follow logs in real-time
docker logs -f <container_name>

# Inspect container for environment variables and config
docker inspect <container_name>

# Execute commands inside a running container
docker exec -it <container_name> /bin/bash
```

### **Container State Diagnosis**

| State | Meaning | Action |
|-------|---------|--------|
| `Up` | Healthy | Normal operation |
| `Restarting` | Crash loop | Check logs, likely app/db issue |
| `Exited` | Stopped | May need manual restart or fix |
| `Created` | Never started | Check for startup errors |

### **Database Troubleshooting (MySQL)**

Cloudron apps use MySQL with randomly-generated database names. To troubleshoot:

```bash
# Find MySQL credentials from app container
docker inspect <app_container> | grep CLOUDRON_MYSQL

# This reveals:
# - CLOUDRON_MYSQL_HOST (usually "mysql")
# - CLOUDRON_MYSQL_PORT (usually 3306)
# - CLOUDRON_MYSQL_USERNAME
# - CLOUDRON_MYSQL_PASSWORD
# - CLOUDRON_MYSQL_DATABASE (hex string like "9ce6a923b53c880e")

# Connect to MySQL via the mysql container
docker exec -it mysql mysql -u<username> -p<password> <database>

# Or use root access
docker exec -it mysql mysql -uroot -p$(cat /home/yellowtent/platformdata/mysql/root_password)
```

#### **Common Database Fixes**

**Charset/Collation Issues** (common after updates):

```sql
-- Check current charset
SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME 
FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'your_db_hex';

-- Fix table charset (example for Vaultwarden SSO issue)
ALTER TABLE sso_nonce CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE sso_users CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Check all tables in database
SELECT TABLE_NAME, TABLE_COLLATION 
FROM information_schema.TABLES 
WHERE TABLE_SCHEMA = 'your_db_hex';
```

**Database Migration Errors**:

- Check forum for app-specific migration issues
- Often caused by charset mismatches after Cloudron/MySQL updates
- Solution usually involves ALTER TABLE commands before restarting app

### **App Recovery Mode**

When an app won't start, use Cloudron's recovery mode:

1. **Via Dashboard**: Apps → Select App → Advanced → Enable Recovery Mode
2. **Effect**: App starts with minimal config, bypasses startup scripts
3. **Use for**: Database repairs, config fixes, manual migrations

```bash
# After enabling recovery mode, access app container
docker exec -it <app_container> /bin/bash

# Make fixes, then disable recovery mode via dashboard
```

### **Common Issues:**

#### **API Connection Issues:**

```bash
# Test API connectivity
curl -H "Authorization: Bearer YOUR_TOKEN" https://cloudron.yourdomain.com/api/v1/cloudron/status

# Check server accessibility
ping cloudron.yourdomain.com

# Verify SSL certificate
openssl s_client -connect cloudron.yourdomain.com:443
```

#### **App Installation Issues:**

```bash
# Check available disk space
./.agents/scripts/cloudron-helper.sh exec production 'df -h'

# Check system resources
./.agents/scripts/cloudron-helper.sh exec production 'free -h'

# Review installation logs
./.agents/scripts/cloudron-helper.sh logs production app-id
```

#### **App Startup Failures (Post-Update)**

When apps fail after updates (common pattern):

1. **Check container state**: `docker ps -a | grep <app>`
2. **Review logs**: `docker logs --tail 200 <container>`
3. **Search forum**: Copy error message to forum.cloudron.io search
4. **Check database**: Often charset/migration issues
5. **Enable recovery mode**: If database fix needed
6. **Apply fix**: Usually SQL commands from forum solution
7. **Restart app**: Via dashboard or `docker restart <container>`

#### **Domain Configuration Issues:**

```bash
# Check DNS configuration
dig cloudron.yourdomain.com
nslookup cloudron.yourdomain.com

# Verify domain ownership
./.agents/scripts/cloudron-helper.sh verify-domain production yourdomain.com

# Check SSL certificate status
./.agents/scripts/cloudron-helper.sh ssl-status production yourdomain.com
```

### **App-Specific Troubleshooting**

For app-specific issues, check these subagents:

- **Vaultwarden**: `tools/credentials/vaultwarden.md` - Password manager troubleshooting
- **WordPress**: `tools/wordpress/` - WordPress-specific issues

## 📊 **Monitoring & Management**

### **System Monitoring:**

```bash
# Get system status
./.agents/scripts/cloudron-helper.sh status production

# Check resource usage
./.agents/scripts/cloudron-helper.sh resources production

# Monitor app health
./.agents/scripts/cloudron-helper.sh health-check production

# Review system logs
./.agents/scripts/cloudron-helper.sh system-logs production
```

### **App Monitoring:**

```bash
# Monitor all apps
for app_id in $(./.agents/scripts/cloudron-helper.sh apps production | awk '{print $1}'); do
    echo "App $app_id status:"
    ./.agents/scripts/cloudron-helper.sh app-status production $app_id
done
```

## 🔄 **Backup & Recovery**

### **Backup Management:**

```bash
# Create system backup
./.agents/scripts/cloudron-helper.sh backup-system production

# List backups
./.agents/scripts/cloudron-helper.sh list-backups production

# Restore from backup
./.agents/scripts/cloudron-helper.sh restore-backup production backup-id

# Configure backup schedule
./.agents/scripts/cloudron-helper.sh configure-backups production daily
```

### **App-Specific Backups:**

```bash
# Backup specific app
./.agents/scripts/cloudron-helper.sh backup-app production app-id

# Restore app from backup
./.agents/scripts/cloudron-helper.sh restore-app production app-id backup-id

# Export app data
./.agents/scripts/cloudron-helper.sh export-app production app-id
```

## 📚 **Best Practices**

### **Server Management:**

1. **Regular maintenance**: Schedule regular maintenance windows
2. **Resource monitoring**: Monitor CPU, memory, and disk usage
3. **Update management**: Keep platform and apps updated
4. **Backup verification**: Regularly test backup and restore procedures
5. **Security audits**: Perform regular security audits

### **App Lifecycle:**

- **Staging first**: Test app installations and updates on staging
- **Gradual rollout**: Deploy changes gradually to production
- **Health monitoring**: Monitor app health and performance
- **Log management**: Regularly review and archive logs
- **Resource allocation**: Properly allocate resources per app

### **Domain Management:**

- **DNS automation**: Automate DNS configuration where possible
- **SSL monitoring**: Monitor SSL certificate expiration
- **Domain organization**: Organize domains by project or client
- **Access control**: Implement proper domain access controls

## 🎯 **AI Assistant Integration**

### **Automated Management:**

- **App deployment**: Automated application installation and configuration
- **Update orchestration**: Automated platform and app updates
- **Backup management**: Automated backup scheduling and verification
- **Resource optimization**: Automated resource allocation and scaling
- **Security monitoring**: Automated security scanning and compliance

### **Intelligent Operations:**

- **Predictive scaling**: AI-driven resource scaling recommendations
- **Anomaly detection**: Automated detection of unusual system behavior
- **Performance optimization**: Automated performance tuning recommendations
- **Cost optimization**: Automated cost analysis and optimization suggestions
- **Maintenance scheduling**: Intelligent maintenance window scheduling

---

**Cloudron provides a comprehensive app platform with excellent management capabilities, making it ideal for organizations needing easy-to-manage, self-hosted applications.** 🚀
