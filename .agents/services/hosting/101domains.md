---
description: 101domains registrar integration
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: true
---

# 101domains Registrar Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Domain registrar + DNS hosting (extensive TLD coverage)
- **Auth**: API key + secret + username
- **Config**: `configs/101domains-config.json`
- **Commands**: `101domains-helper.sh [accounts|domains|domain-details|dns-records|add-dns|update-dns|delete-dns|nameservers|update-ns|check-availability|contacts|lock|unlock|transfer-status|privacy-status|enable-privacy|disable-privacy|monitor-expiration|audit] [account] [domain] [args]`
- **Features**: WHOIS privacy, volume discounts, international TLDs
- **Privacy**: `privacy-status`, `enable-privacy`, `disable-privacy`
- **Monitoring**: `monitor-expiration [account] [days]`
- **Bulk ops**: Iterate domains with `domains [account] | awk`
<!-- AI-CONTEXT-END -->

101domains is a comprehensive domain registrar offering extensive TLD coverage, competitive pricing, and robust API access for domain and DNS management.

## Provider Overview

### **101domains Characteristics:**

- **Service Type**: Domain registrar and DNS hosting
- **TLD Coverage**: Extensive coverage of global and specialty TLDs
- **API Quality**: Comprehensive REST API with detailed documentation
- **Pricing**: Competitive pricing with volume discounts
- **DNS Management**: Full DNS management with API access
- **Privacy Protection**: Comprehensive WHOIS privacy options
- **Global Presence**: International domain extensions and local presence

### **Best Use Cases:**

- **Large domain portfolios** with diverse TLD requirements
- **International businesses** needing global TLD coverage
- **Domain resellers** and agencies managing client domains
- **Privacy-focused** domain management with comprehensive protection
- **Automated domain operations** with extensive API functionality
- **Bulk domain management** with volume pricing benefits

## 🔧 **Configuration**

### **Setup Configuration:**

```bash
# Copy template
cp configs/101domains-config.json.txt configs/101domains-config.json

# Edit with your actual API credentials
```

### **Multi-Account Configuration:**

```json
{
  "accounts": {
    "personal": {
      "api_key": "YOUR_101DOMAINS_API_KEY_HERE",
      "api_secret": "YOUR_101DOMAINS_API_SECRET_HERE",
      "username": "your-101domains-username",
      "email": "your-email@domain.com",
      "description": "Personal domain account",
      "domains": ["yourdomain.com", "anotherdomain.com"]
    },
    "business": {
      "api_key": "YOUR_BUSINESS_101DOMAINS_API_KEY_HERE",
      "api_secret": "YOUR_BUSINESS_101DOMAINS_API_SECRET_HERE",
      "username": "business-101domains-username",
      "email": "business@company.com",
      "description": "Business domain account",
      "domains": ["company.com", "businessdomain.com"]
    }
  }
}
```

### **API Credentials Setup:**

1. **Login to 101domains Control Panel**
2. **Navigate to API Management**
3. **Generate API Key and Secret**
4. **Configure API permissions**
5. **Copy credentials** to your configuration file
6. **Test access** with the helper script

## 🚀 **Usage Examples**

### **Basic Commands:**

```bash
# List all 101domains accounts
./.agents/scripts/101domains-helper.sh accounts

# List domains for account
./.agents/scripts/101domains-helper.sh domains personal

# Get domain details
./.agents/scripts/101domains-helper.sh domain-details personal example.com

# Audit complete domain configuration
./.agents/scripts/101domains-helper.sh audit personal example.com
```

### **DNS Management:**

```bash
# List DNS records
./.agents/scripts/101domains-helper.sh dns-records personal example.com

# Add DNS record
./.agents/scripts/101domains-helper.sh add-dns personal example.com www A 192.168.1.100 3600

# Update DNS record
./.agents/scripts/101domains-helper.sh update-dns personal example.com record-id www A 192.168.1.101 3600

# Delete DNS record
./.agents/scripts/101domains-helper.sh delete-dns personal example.com record-id
```

### **Nameserver Management:**

```bash
# Get current nameservers
./.agents/scripts/101domains-helper.sh nameservers personal example.com

# Update to Cloudflare nameservers
./.agents/scripts/101domains-helper.sh update-ns personal example.com ns1.cloudflare.com ns2.cloudflare.com

# Update to Route 53 nameservers
./.agents/scripts/101domains-helper.sh update-ns personal example.com ns-1.awsdns-01.com ns-2.awsdns-02.net ns-3.awsdns-03.org ns-4.awsdns-04.co.uk
```

### **Domain Management:**

```bash
# Check domain availability
./.agents/scripts/101domains-helper.sh check-availability personal newdomain.com

# Get domain contacts
./.agents/scripts/101domains-helper.sh contacts personal example.com

# Lock domain
./.agents/scripts/101domains-helper.sh lock personal example.com

# Unlock domain
./.agents/scripts/101domains-helper.sh unlock personal example.com

# Check transfer status
./.agents/scripts/101domains-helper.sh transfer-status personal example.com
```

### **Privacy Management:**

```bash
# Check privacy status
./.agents/scripts/101domains-helper.sh privacy-status personal example.com

# Enable domain privacy
./.agents/scripts/101domains-helper.sh enable-privacy personal example.com

# Disable domain privacy
./.agents/scripts/101domains-helper.sh disable-privacy personal example.com
```

### **Monitoring & Automation:**

```bash
# Monitor domain expiration (30 days warning)
./.agents/scripts/101domains-helper.sh monitor-expiration personal 30

# Monitor domain expiration (60 days warning)
./.agents/scripts/101domains-helper.sh monitor-expiration personal 60

# Comprehensive domain audit
./.agents/scripts/101domains-helper.sh audit personal example.com
```

## 🛡️ **Security Best Practices**

### **API Security:**

- **Secure credentials**: Store API credentials securely
- **Permission scoping**: Use API keys with minimal required permissions
- **Regular rotation**: Rotate API credentials every 6-12 months
- **Access monitoring**: Monitor API access and usage
- **Environment separation**: Use different credentials for different environments

### **Domain Security:**

```bash
# Enable domain lock
./.agents/scripts/101domains-helper.sh lock personal example.com

# Enable privacy protection
./.agents/scripts/101domains-helper.sh enable-privacy personal example.com

# Monitor transfer status
./.agents/scripts/101domains-helper.sh transfer-status personal example.com

# Regular security audit
./.agents/scripts/101domains-helper.sh audit personal example.com
```

### **Privacy Protection:**

- **WHOIS privacy**: Enable WHOIS privacy for all domains
- **Contact privacy**: Use privacy protection for contact information
- **Admin privacy**: Protect administrative contact details
- **Regular monitoring**: Monitor privacy settings regularly

## 🔍 **Troubleshooting**

### **Common Issues:**

#### **API Authentication Errors:**

```bash
# Verify API credentials
./.agents/scripts/101domains-helper.sh accounts

# Check API permissions in 101domains control panel
# Ensure username and API key are correct
```

#### **DNS Management Issues:**

```bash
# Check DNS records
./.agents/scripts/101domains-helper.sh dns-records personal example.com

# Verify nameservers
./.agents/scripts/101domains-helper.sh nameservers personal example.com

# Check DNS propagation
dig @8.8.8.8 example.com
nslookup example.com 8.8.8.8
```

#### **Domain Transfer Issues:**

```bash
# Check domain lock status
./.agents/scripts/101domains-helper.sh audit personal example.com

# Verify transfer status
./.agents/scripts/101domains-helper.sh transfer-status personal example.com

# Check domain contacts
./.agents/scripts/101domains-helper.sh contacts personal example.com
```

## 📊 **Monitoring & Analytics**

### **Domain Portfolio Monitoring:**

```bash
# Monitor all domains for expiration
./.agents/scripts/101domains-helper.sh monitor-expiration personal 30

# Audit multiple domains
for domain in example.com another.com; do
    ./.agents/scripts/101domains-helper.sh audit personal $domain
done
```

### **Privacy Monitoring:**

```bash
# Check privacy status for all domains
for domain in $(./.agents/scripts/101domains-helper.sh domains personal | awk '{print $1}'); do
    echo "Privacy status for $domain:"
    ./.agents/scripts/101domains-helper.sh privacy-status personal $domain
done
```

### **Automated Monitoring:**

```bash
# Create comprehensive monitoring script
#!/bin/bash
ACCOUNT="personal"
THRESHOLD=30

# Check expiring domains
echo "=== EXPIRING DOMAINS ==="
./.agents/scripts/101domains-helper.sh monitor-expiration $ACCOUNT $THRESHOLD

# Check privacy settings
echo "=== PRIVACY AUDIT ==="
for domain in $(./.agents/scripts/101domains-helper.sh domains $ACCOUNT | awk '{print $1}'); do
    privacy_status=$(./.agents/scripts/101domains-helper.sh privacy-status $ACCOUNT $domain)
    echo "$domain: $privacy_status"
done
```

## 🔄 **Backup & Disaster Recovery**

### **Configuration Backup:**

```bash
# Backup DNS records
./.agents/scripts/101domains-helper.sh dns-records personal example.com > dns-backup-example.com-$(date +%Y%m%d).txt

# Backup domain configuration
./.agents/scripts/101domains-helper.sh audit personal example.com > domain-audit-example.com-$(date +%Y%m%d).txt

# Backup privacy settings
./.agents/scripts/101domains-helper.sh privacy-status personal example.com > privacy-backup-example.com-$(date +%Y%m%d).txt
```

### **Bulk Operations:**

```bash
# Backup all domains
for domain in $(./.agents/scripts/101domains-helper.sh domains personal | awk '{print $1}'); do
    ./.agents/scripts/101domains-helper.sh audit personal $domain > "backup-$domain-$(date +%Y%m%d).txt"
done
```

## 📚 **Best Practices**

### **Domain Portfolio Management:**

1. **Centralized monitoring**: Monitor all domains from a central dashboard
2. **Privacy by default**: Enable privacy protection for all domains
3. **Regular audits**: Perform regular security and configuration audits
4. **Expiration tracking**: Track domain expiration dates proactively
5. **Change documentation**: Document all domain and DNS changes

### **Privacy Management:**

- **Default privacy**: Enable privacy protection by default
- **Regular reviews**: Review privacy settings regularly
- **Contact updates**: Keep contact information current
- **Compliance monitoring**: Monitor privacy compliance requirements
- **Access control**: Limit access to privacy settings

### **Automation Strategies:**

- **Bulk operations**: Use bulk operations for managing large portfolios
- **Scheduled monitoring**: Schedule regular monitoring and audits
- **Alert integration**: Integrate with alerting systems
- **Change approval**: Implement approval workflows for critical changes
- **Rollback procedures**: Have rollback procedures for changes

## 🎯 **AI Assistant Integration**

### **Automated Domain Management:**

- **Portfolio monitoring**: Automated monitoring of entire domain portfolio
- **Privacy compliance**: Automated privacy setting compliance monitoring
- **Expiration management**: Automated domain renewal and expiration tracking
- **Security auditing**: Automated security audits of domain configurations
- **Change detection**: Automated detection of unauthorized changes

### **Intelligent Operations:**

- **Bulk management**: Automated bulk operations for large portfolios
- **Cost optimization**: Automated cost analysis and optimization recommendations
- **Compliance monitoring**: Automated compliance monitoring for regulations
- **Performance tracking**: Automated performance tracking and optimization
- **Risk assessment**: Automated risk assessment of domain configurations

---

**101domains provides comprehensive domain management with extensive TLD coverage and robust privacy features, making it ideal for large-scale domain portfolio management.** 🚀
