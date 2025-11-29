# Spaceship Domain Registrar Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Domain registrar + DNS hosting
- **Auth**: API key + secret
- **Config**: `configs/spaceship-config.json`
- **Commands**: `spaceship-helper.sh [accounts|domains|domain-details|dns-records|add-dns|update-dns|delete-dns|nameservers|update-ns|check-availability|contacts|lock|unlock|transfer-status|monitor-expiration|audit] [account] [domain] [args]`
- **DNS records**: A, AAAA, CNAME, MX, TXT, NS
- **Security**: Domain locking, privacy protection, DNSSEC
- **API key storage**: `setup-local-api-keys.sh set spaceship YOUR_API_KEY`
- **Monitoring**: `monitor-expiration [account] [days]` for renewal alerts
<!-- AI-CONTEXT-END -->

Spaceship is a modern domain registrar offering competitive pricing, comprehensive domain management, and developer-friendly APIs for domain and DNS management.

## Provider Overview

### **Spaceship Characteristics:**

- **Service Type**: Domain registrar and DNS hosting
- **API Quality**: RESTful API with comprehensive functionality
- **Pricing**: Competitive domain pricing with transparent fees
- **DNS Management**: Full DNS management with API access
- **Global Presence**: International domain extensions supported
- **Developer Tools**: API-first approach with good documentation
- **Security**: Domain locking, privacy protection, DNSSEC support

### **Best Use Cases:**

- **Domain portfolio management** with multiple domains
- **DNS automation** for development and production environments
- **Cost-effective domain registration** with good API access
- **Multi-account domain management** for agencies and businesses
- **Automated domain monitoring** and expiration tracking
- **DNS record management** for complex infrastructures

## 🔧 **Configuration**

### **Setup Configuration:**

```bash
# Copy template
cp configs/spaceship-config.json.txt configs/spaceship-config.json

# Edit with your actual API credentials
```

### **Multi-Account Configuration:**

```json
{
  "accounts": {
    "personal": {
      "api_key": "YOUR_SPACESHIP_API_KEY_HERE",
      "api_secret": "YOUR_SPACESHIP_API_SECRET_HERE",
      "email": "your-email@domain.com",
      "description": "Personal domain account",
      "domains": ["yourdomain.com", "anotherdomain.com"]
    },
    "business": {
      "api_key": "YOUR_BUSINESS_SPACESHIP_API_KEY_HERE",
      "api_secret": "YOUR_BUSINESS_SPACESHIP_API_SECRET_HERE",
      "email": "business@company.com",
      "description": "Business domain account",
      "domains": ["company.com", "businessdomain.com"]
    }
  }
}
```

### **API Credentials Setup:**

1. **Login to Spaceship Dashboard**
2. **Navigate to API Settings**
3. **Generate API Key and Secret**
4. **Store securely**: `bash .agent/scripts/setup-local-api-keys.sh set spaceship YOUR_API_KEY`
5. **Test access** with the helper script

## 🚀 **Usage Examples**

### **Basic Commands:**

```bash
# List all Spaceship accounts
./.agent/scripts/spaceship-helper.sh accounts

# List domains for account
./.agent/scripts/spaceship-helper.sh domains personal

# Get domain details
./.agent/scripts/spaceship-helper.sh domain-details personal example.com

# Audit complete domain configuration
./.agent/scripts/spaceship-helper.sh audit personal example.com
```

### **DNS Management:**

```bash
# List DNS records
./.agent/scripts/spaceship-helper.sh dns-records personal example.com

# Add DNS record
./.agent/scripts/spaceship-helper.sh add-dns personal example.com www A 192.168.1.100 3600

# Update DNS record
./.agent/scripts/spaceship-helper.sh update-dns personal example.com record-id www A 192.168.1.101 3600

# Delete DNS record
./.agent/scripts/spaceship-helper.sh delete-dns personal example.com record-id
```

### **Nameserver Management:**

```bash
# Get current nameservers
./.agent/scripts/spaceship-helper.sh nameservers personal example.com

# Update to Cloudflare nameservers
./.agent/scripts/spaceship-helper.sh update-ns personal example.com ns1.cloudflare.com ns2.cloudflare.com

# Update to Route 53 nameservers
./.agent/scripts/spaceship-helper.sh update-ns personal example.com ns-1.awsdns-01.com ns-2.awsdns-02.net ns-3.awsdns-03.org ns-4.awsdns-04.co.uk
```

### **Domain Management:**

```bash
# Check domain availability
./.agent/scripts/spaceship-helper.sh check-availability personal newdomain.com

# Get domain contacts
./.agent/scripts/spaceship-helper.sh contacts personal example.com

# Lock domain
./.agent/scripts/spaceship-helper.sh lock personal example.com

# Unlock domain
./.agent/scripts/spaceship-helper.sh unlock personal example.com

# Check transfer status
./.agent/scripts/spaceship-helper.sh transfer-status personal example.com
```

### **Monitoring & Automation:**

```bash
# Monitor domain expiration (30 days warning)
./.agent/scripts/spaceship-helper.sh monitor-expiration personal 30

# Monitor domain expiration (60 days warning)
./.agent/scripts/spaceship-helper.sh monitor-expiration personal 60

# Audit all aspects of a domain
./.agent/scripts/spaceship-helper.sh audit personal example.com
```

## 🛡️ **Security Best Practices**

### **API Security:**

- **Separate API keys**: Use different API keys for different projects
- **Key rotation**: Rotate API keys every 6-12 months
- **Minimal permissions**: Use API keys with minimal required permissions
- **Secure storage**: Store API credentials in `~/.config/aidevops/` (user-private only)
- **Environment separation**: Use different accounts for prod/staging
- **Never in repository**: API keys must never be stored in repository files

### **Domain Security:**

```bash
# Enable domain lock for protection
./.agent/scripts/spaceship-helper.sh lock personal example.com

# Monitor transfer status
./.agent/scripts/spaceship-helper.sh transfer-status personal example.com

# Regular security audit
./.agent/scripts/spaceship-helper.sh audit personal example.com
```

### **DNS Security:**

- **DNSSEC**: Enable DNSSEC for domains when available
- **Regular monitoring**: Monitor DNS records for unauthorized changes
- **Backup records**: Maintain backups of DNS configurations
- **Access control**: Limit API access to trusted systems only

## 🔍 **Troubleshooting**

### **Common Issues:**

#### **API Authentication Errors:**

```bash
# Verify API credentials
./.agent/scripts/spaceship-helper.sh accounts

# Check API key permissions in Spaceship dashboard
# Ensure API key has required permissions for operations
```

#### **DNS Propagation Issues:**

```bash
# Check DNS records
./.agent/scripts/spaceship-helper.sh dns-records personal example.com

# Verify nameservers
./.agent/scripts/spaceship-helper.sh nameservers personal example.com

# Check DNS propagation externally
dig @8.8.8.8 example.com
nslookup example.com 8.8.8.8
```

#### **Domain Management Issues:**

```bash
# Check domain status
./.agent/scripts/spaceship-helper.sh domain-details personal example.com

# Verify domain lock status
./.agent/scripts/spaceship-helper.sh audit personal example.com

# Check transfer status if domain issues persist
./.agent/scripts/spaceship-helper.sh transfer-status personal example.com
```

## 📊 **Monitoring & Analytics**

### **Domain Portfolio Monitoring:**

```bash
# Monitor all domains for expiration
./.agent/scripts/spaceship-helper.sh monitor-expiration personal 30

# Audit multiple domains
for domain in example.com another.com; do
    ./.agent/scripts/spaceship-helper.sh audit personal $domain
done
```

### **Automated Monitoring:**

```bash
# Create monitoring script
#!/bin/bash
ACCOUNT="personal"
THRESHOLD=30

# Check expiring domains
EXPIRING=$(./.agent/scripts/spaceship-helper.sh monitor-expiration $ACCOUNT $THRESHOLD)

if [[ -n "$EXPIRING" ]]; then
    echo "Domains expiring soon:"
    echo "$EXPIRING"
    # Add your alerting logic here
fi
```

### **DNS Health Monitoring:**

- **Record validation**: Regularly validate DNS record configurations
- **Propagation monitoring**: Monitor DNS propagation across global resolvers
- **Performance tracking**: Track DNS resolution performance
- **Change detection**: Monitor for unauthorized DNS changes

## 🔄 **Backup & Disaster Recovery**

### **DNS Record Backup:**

```bash
# Backup DNS records for a domain
./.agent/scripts/spaceship-helper.sh dns-records personal example.com > dns-backup-example.com-$(date +%Y%m%d).txt

# Backup all domain configurations
./.agent/scripts/spaceship-helper.sh audit personal example.com > domain-audit-example.com-$(date +%Y%m%d).txt
```

### **Configuration Backup:**

```bash
# Export domain list
./.agent/scripts/spaceship-helper.sh domains personal > domains-backup-$(date +%Y%m%d).txt

# Backup nameserver configurations
./.agent/scripts/spaceship-helper.sh nameservers personal example.com > ns-backup-example.com-$(date +%Y%m%d).txt
```

## 📚 **Best Practices**

### **Domain Management:**

1. **Regular monitoring**: Monitor domain expiration dates
2. **Security settings**: Enable domain lock and privacy protection
3. **DNS backup**: Maintain backups of DNS configurations
4. **Change tracking**: Document all domain and DNS changes
5. **Access control**: Limit API access to necessary systems

### **DNS Management:**

- **Consistent TTL values**: Use appropriate TTL values for different record types
- **Record validation**: Validate DNS records before applying changes
- **Gradual changes**: Make DNS changes gradually to avoid service disruption
- **Monitoring**: Monitor DNS propagation after changes
- **Documentation**: Document DNS architecture and changes

### **Automation Workflow:**

- **Staged deployments**: Test DNS changes in staging first
- **Rollback procedures**: Have rollback procedures for DNS changes
- **Change approval**: Implement approval workflows for critical changes
- **Monitoring integration**: Integrate with monitoring systems
- **Alert configuration**: Configure alerts for domain and DNS issues

## 🎯 **AI Assistant Integration**

### **Automated Domain Management:**

- **Expiration monitoring**: Automated monitoring of domain expiration dates
- **DNS change detection**: Automated detection of unauthorized DNS changes
- **Health monitoring**: Automated DNS health and propagation monitoring
- **Security auditing**: Automated security audits of domain configurations
- **Performance optimization**: Automated DNS performance optimization

### **Intelligent Troubleshooting:**

- **Issue diagnosis**: Automated diagnosis of domain and DNS issues
- **Configuration validation**: Automated validation of domain configurations
- **Performance analysis**: Automated analysis of DNS performance
- **Security assessment**: Automated security assessment of domain settings
- **Compliance monitoring**: Automated compliance monitoring for domain policies

---

**Spaceship provides excellent domain management capabilities with comprehensive API access, making it ideal for automated domain and DNS management workflows.** 🚀
