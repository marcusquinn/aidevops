---
description: Vaultwarden self-hosted password management
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Vaultwarden (Self-hosted Bitwarden) Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Self-hosted password manager (Bitwarden API compatible)
- **CLI**: `npm install -g @bitwarden/cli` then `bw`
- **Auth**: `bw login email` then `export BW_SESSION=$(bw unlock --raw)`
- **Config**: `configs/vaultwarden-config.json`
- **Commands**: `vaultwarden-helper.sh [instances|status|login|unlock|list|search|get|get-password|create|audit|start-mcp] [instance] [args]`
- **Session**: `BW_SESSION` env var required after unlock
- **Lock**: `bw lock` and `unset BW_SESSION` when done
- **MCP**: Port 3002 for AI assistant credential access
- **Backup**: `bw export --format json` (encrypt with GPG)
<!-- AI-CONTEXT-END -->

Vaultwarden is a self-hosted, lightweight implementation of the Bitwarden server API, providing secure password and secrets management with full API access and MCP integration.

## Provider Overview

### **Vaultwarden Characteristics:**

- **Service Type**: Self-hosted password and secrets management
- **Compatibility**: Full Bitwarden API compatibility
- **Architecture**: Lightweight Rust implementation
- **Security**: End-to-end encryption with zero-knowledge architecture
- **API Support**: Complete REST API for automation
- **MCP Integration**: Real-time vault access for AI assistants
- **Multi-platform**: Web, desktop, mobile, and CLI access

### **Best Use Cases:**

- **DevOps credential management** with secure API access
- **Team password sharing** with organization support
- **Development secrets** management and rotation
- **Infrastructure credentials** with automated access
- **Secure note storage** for configuration and documentation
- **API key management** with audit trails and access control

## Bitwarden Cloud vs Vaultwarden Self-Hosted

### Service Detection

The same `bw` CLI works for both Bitwarden cloud and Vaultwarden self-hosted. Detect which service you're using by the server URL:

| Server URL | Service | Description |
|------------|---------|-------------|
| `vault.bitwarden.com` (default) | Bitwarden Cloud | Official hosted service |
| `bitwarden.com` | Bitwarden Cloud | Official hosted service |
| Any other domain | Vaultwarden | Self-hosted instance |

```bash
# Check current server configuration
bw config server

# Default (Bitwarden cloud) shows:
# https://vault.bitwarden.com

# Self-hosted shows your custom domain:
# https://vault.yourdomain.com
```

### CLI Compatibility

The official Bitwarden CLI (`bw`) works identically with both services:

```bash
# Install once, use for both
npm install -g @bitwarden/cli

# Configure for Bitwarden cloud (default, no config needed)
bw config server https://vault.bitwarden.com

# Configure for Vaultwarden self-hosted
bw config server https://vault.yourdomain.com

# All commands work the same after configuration
bw login user@example.com
bw unlock
bw list items
```

### Behavioral Differences

| Feature | Bitwarden Cloud | Vaultwarden Self-Hosted |
|---------|-----------------|-------------------------|
| **Hosting** | Managed by Bitwarden Inc. | Self-managed infrastructure |
| **Pricing** | Free tier + paid plans | Free (open source) |
| **Premium features** | Require paid subscription | All features unlocked |
| **TOTP/2FA storage** | Premium only | Always available |
| **File attachments** | Premium only | Always available |
| **Emergency access** | Premium only | Always available |
| **API rate limits** | Enforced by Bitwarden | Configurable (or none) |
| **Data location** | Bitwarden's servers (US/EU) | Your infrastructure |
| **Uptime/SLA** | 99.9% SLA on paid plans | Depends on your setup |
| **Support** | Official support channels | Community support |
| **Updates** | Automatic | Manual (Docker pull) |
| **Admin panel** | Web vault only | `/admin` endpoint available |

### When to Use Each

**Choose Bitwarden Cloud when:**
- You want zero infrastructure management
- You need official support and SLA guarantees
- Compliance requires a certified vendor
- Team size justifies the subscription cost

**Choose Vaultwarden when:**
- You need all premium features without subscription
- Data sovereignty requires self-hosting
- You want full control over your infrastructure
- You're comfortable with Docker/server management

### Configuration Examples

```json
{
  "instances": {
    "bitwarden-cloud": {
      "server_url": "https://vault.bitwarden.com",
      "description": "Official Bitwarden cloud service",
      "type": "cloud"
    },
    "vaultwarden-prod": {
      "server_url": "https://vault.yourdomain.com",
      "description": "Self-hosted Vaultwarden instance",
      "type": "self-hosted"
    }
  }
}
```

## 🔧 **Configuration**

### **Setup Configuration:**

```bash
# Copy template
cp configs/vaultwarden-config.json.txt configs/vaultwarden-config.json

# Edit with your Vaultwarden instance details
```

### **Multi-Instance Configuration:**

```json
{
  "instances": {
    "production": {
      "server_url": "https://vault.yourdomain.com",
      "description": "Production Vaultwarden instance",
      "users_count": 25,
      "organizations": [
        {
          "name": "Company Organization",
          "id": "org-uuid-here"
        }
      ]
    },
    "development": {
      "server_url": "https://dev-vault.yourdomain.com",
      "description": "Development Vaultwarden instance",
      "users_count": 10
    }
  }
}
```

### **Bitwarden CLI Setup:**

```bash
# Install Bitwarden CLI
npm install -g @bitwarden/cli

# Or download binary from:
# https://bitwarden.com/download/

# Verify installation
bw --version
```

## 🚀 **Usage Examples**

### **Basic Commands:**

```bash
# List all Vaultwarden instances
./.agent/scripts/vaultwarden-helper.sh instances

# Get vault status
./.agent/scripts/vaultwarden-helper.sh status production

# Login to vault
./.agent/scripts/vaultwarden-helper.sh login production user@example.com

# Unlock vault (after login)
./.agent/scripts/vaultwarden-helper.sh unlock
```

### **Vault Management:**

```bash
# List all vault items
./.agent/scripts/vaultwarden-helper.sh list production

# Search vault items
./.agent/scripts/vaultwarden-helper.sh search production "github"

# Get specific item
./.agent/scripts/vaultwarden-helper.sh get production item-uuid

# Get password for item
./.agent/scripts/vaultwarden-helper.sh get-password production "GitHub Account"

# Get username for item
./.agent/scripts/vaultwarden-helper.sh get-username production "GitHub Account"
```

### **Item Management:**

```bash
# Create new vault item
./.agent/scripts/vaultwarden-helper.sh create production "New Service" username password123 https://service.com

# Update vault item
./.agent/scripts/vaultwarden-helper.sh update production item-uuid password newpassword123

# Delete vault item
./.agent/scripts/vaultwarden-helper.sh delete production item-uuid

# Generate secure password
./.agent/scripts/vaultwarden-helper.sh generate 20 true
```

### **Organization Management:**

```bash
# List organization vault items
./.agent/scripts/vaultwarden-helper.sh org-list production org-uuid

# Sync vault with server
./.agent/scripts/vaultwarden-helper.sh sync production

# Export vault (encrypted)
./.agent/scripts/vaultwarden-helper.sh export production json vault-backup.json
```

### **Security & Auditing:**

```bash
# Audit vault security
./.agent/scripts/vaultwarden-helper.sh audit production

# Lock vault
./.agent/scripts/vaultwarden-helper.sh lock

# Start MCP server for AI access
./.agent/scripts/vaultwarden-helper.sh start-mcp production 3002

# Test MCP connection
./.agent/scripts/vaultwarden-helper.sh test-mcp 3002
```

## 🛡️ **Security Best Practices**

### **Instance Security:**

- **HTTPS only**: Always use HTTPS for Vaultwarden instances
- **Strong master passwords**: Enforce strong master password policies
- **Two-factor authentication**: Enable 2FA for all users
- **Regular backups**: Maintain encrypted backups of vault data
- **Access monitoring**: Monitor and audit vault access

### **API Security:**

```bash
# Use secure session management
export BW_SESSION=$(bw unlock --raw)

# Clear session when done
unset BW_SESSION
bw lock

# Regular security audits
./.agent/scripts/vaultwarden-helper.sh audit production
```

### **Organizational Security:**

- **Role-based access**: Implement proper role-based access control
- **Shared vault policies**: Define clear policies for shared vaults
- **Regular audits**: Perform regular security audits
- **Access reviews**: Review user access regularly
- **Incident response**: Have incident response procedures

## 🔍 **Troubleshooting**

### **Common Issues:**

#### **Connection Issues:**

```bash
# Test server connectivity
curl -I https://vault.yourdomain.com

# Check Bitwarden CLI configuration
bw config

# Verify server URL
bw config server https://vault.yourdomain.com
```

#### **Authentication Issues:**

```bash
# Check login status
bw status

# Re-login if needed
bw logout
bw login user@example.com

# Unlock vault
bw unlock
```

#### **Sync Issues:**

```bash
# Force sync with server
bw sync --force

# Check sync status
bw status

# Clear local cache if needed
bw logout
bw login user@example.com
```

## 📊 **MCP Integration**

### **Bitwarden MCP Server:**

```bash
# Start Bitwarden MCP server
./.agent/scripts/vaultwarden-helper.sh start-mcp production 3002

# Test MCP server
./.agent/scripts/vaultwarden-helper.sh test-mcp 3002

# Configure in AI assistant
# Add to MCP servers configuration:
{
  "bitwarden": {
    "command": "bitwarden-mcp-server",
    "args": ["--port", "3002"],
    "env": {
      "BW_SERVER": "https://vault.yourdomain.com"
    }
  }
}
```

### **AI Assistant Integration:**

The MCP server enables AI assistants to:

- **Retrieve credentials** securely for automation tasks
- **Generate secure passwords** with custom policies
- **Audit vault security** and identify weak passwords
- **Manage vault items** with proper authentication
- **Access shared organization** vaults for team credentials

## 🔄 **Backup & Recovery**

### **Vault Backup:**

```bash
# Export encrypted vault
./.agent/scripts/vaultwarden-helper.sh export production json vault-backup-$(date +%Y%m%d).json

# Secure backup file
chmod 600 vault-backup-*.json

# Store backup securely (encrypted storage recommended)
```

### **Automated Backup:**

```bash
#!/bin/bash
# Automated vault backup script
INSTANCE="production"
BACKUP_DIR="/secure/backups/vaultwarden"
DATE=$(date +%Y%m%d-%H%M%S)

# Create backup
./.agent/scripts/vaultwarden-helper.sh export $INSTANCE json "$BACKUP_DIR/vault-$DATE.json"

# Encrypt backup
gpg --cipher-algo AES256 --compress-algo 1 --s2k-mode 3 \
    --s2k-digest-algo SHA512 --s2k-count 65536 --symmetric \
    "$BACKUP_DIR/vault-$DATE.json"

# Remove unencrypted backup
rm "$BACKUP_DIR/vault-$DATE.json"

# Cleanup old backups (keep 30 days)
find "$BACKUP_DIR" -name "vault-*.json.gpg" -mtime +30 -delete
```

## 📚 **Best Practices**

### **Vault Organization:**

1. **Logical categorization**: Organize items by service, environment, or team
2. **Consistent naming**: Use consistent naming conventions
3. **Regular cleanup**: Remove unused or outdated credentials
4. **Documentation**: Document credential purposes and rotation schedules
5. **Access control**: Implement proper access controls for shared items

### **Password Management:**

- **Strong passwords**: Use generated passwords with high entropy
- **Regular rotation**: Rotate passwords regularly, especially for critical services
- **Unique passwords**: Never reuse passwords across services
- **Secure sharing**: Use organization vaults for team credential sharing
- **Audit regularly**: Regular security audits to identify weak passwords

### **Automation Integration:**

- **API access**: Use API access for automated credential retrieval
- **Session management**: Properly manage CLI sessions and tokens
- **Error handling**: Implement proper error handling for automation
- **Logging**: Log credential access for audit purposes
- **Rate limiting**: Respect API rate limits in automation

## 🎯 **AI Assistant Integration**

### **Automated Credential Management:**

- **Secure retrieval**: AI can securely retrieve credentials for automation
- **Password generation**: AI can generate secure passwords with policies
- **Vault auditing**: AI can audit vault security and identify issues
- **Credential rotation**: AI can assist with credential rotation workflows
- **Access monitoring**: AI can monitor and report on credential access

### **DevOps Workflows:**

- **Infrastructure deployment**: Secure credential access for deployments
- **CI/CD integration**: Secure credential injection into pipelines
- **Service configuration**: Automated service configuration with credentials
- **Monitoring integration**: Secure access to monitoring service credentials
- **Incident response**: Quick access to emergency credentials

  task: true
---

**Vaultwarden provides enterprise-grade password and secrets management with comprehensive API access, making it ideal for secure DevOps workflows and AI-assisted credential management.** 🚀
