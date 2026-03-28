---
description: Amazon SES email service integration
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

# Amazon SES Provider Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: AWS cloud email service
- **Auth**: AWS IAM credentials (access key + secret key)
- **Config**: `configs/ses-config.json`
- **Commands**: `ses-helper.sh [accounts|quota|stats|monitor|verified-emails|verified-domains|verify-email|verify-domain|dkim|reputation|suppressed|send-test|audit] [account] [args]`
- **Key metrics**: Bounce rate < 5%, Complaint rate < 0.1%
- **Regions**: us-east-1, eu-west-1, etc.
- **Test addresses**: success@simulator.amazonses.com, bounce@simulator.amazonses.com
- **DKIM**: Enable for all domains
- **IAM policy**: ses:GetSendQuota, ses:SendEmail, sesv2:ListSuppressedDestinations

<!-- AI-CONTEXT-END -->

## Configuration

```bash
# Copy template and edit with actual AWS credentials
cp configs/ses-config.json.txt configs/ses-config.json
```

**Multi-account config (`configs/ses-config.json`):**

```json
{
  "accounts": {
    "production": {
      "aws_access_key_id": "YOUR_PRODUCTION_AWS_ACCESS_KEY_ID_HERE",
      "aws_secret_access_key": "YOUR_PRODUCTION_AWS_SECRET_ACCESS_KEY_HERE",
      "region": "us-east-1",
      "description": "Production SES account",
      "verified_domains": ["yourdomain.com"],
      "verified_emails": ["noreply@yourdomain.com"]
    },
    "staging": {
      "aws_access_key_id": "YOUR_STAGING_AWS_ACCESS_KEY_ID_HERE",
      "aws_secret_access_key": "YOUR_STAGING_AWS_SECRET_ACCESS_KEY_HERE",
      "region": "us-east-1",
      "description": "Staging/Development SES account",
      "verified_domains": ["staging.yourdomain.com"],
      "verified_emails": ["test@yourdomain.com"]
    }
  }
}
```

**AWS CLI** (credentials managed per account — no `aws configure` needed):

```bash
brew install awscli   # macOS
sudo apt-get install awscli  # Linux
aws --version
```

## Commands

```bash
# Account overview
ses-helper.sh accounts
ses-helper.sh quota production
ses-helper.sh stats production
ses-helper.sh monitor production

# Identity management
ses-helper.sh verified-emails production
ses-helper.sh verified-domains production
ses-helper.sh verify-email production newuser@yourdomain.com
ses-helper.sh verify-domain production newdomain.com
ses-helper.sh verify-identity production yourdomain.com

# DKIM
ses-helper.sh dkim production yourdomain.com
ses-helper.sh enable-dkim production yourdomain.com

# Reputation & suppression
ses-helper.sh reputation production
ses-helper.sh suppressed production
ses-helper.sh suppression-details production user@example.com
ses-helper.sh remove-suppression production user@example.com

# Testing
ses-helper.sh send-test production noreply@yourdomain.com test@example.com "Subject" "Body"
ses-helper.sh send-test production noreply@yourdomain.com success@simulator.amazonses.com "Success Test"
ses-helper.sh send-test production noreply@yourdomain.com bounce@simulator.amazonses.com "Bounce Test"
ses-helper.sh debug production problematic@example.com
ses-helper.sh audit production
```

## IAM Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ses:GetSendQuota",
        "ses:GetSendStatistics",
        "ses:ListIdentities",
        "ses:ListVerifiedEmailAddresses",
        "ses:GetIdentityVerificationAttributes",
        "ses:GetIdentityDkimAttributes",
        "ses:GetIdentityNotificationAttributes",
        "ses:SendEmail",
        "ses:SendRawEmail",
        "sesv2:GetSuppressedDestination",
        "sesv2:ListSuppressedDestinations",
        "sesv2:DeleteSuppressedDestination"
      ],
      "Resource": "*"
    }
  ]
}
```

Use dedicated IAM users per environment. Rotate access keys regularly. Use separate AWS accounts for prod/staging.

## Monitoring

```bash
# Daily routine
ses-helper.sh monitor production   # bounce rate, complaint rate, quota, reputation
ses-helper.sh stats production
```

Thresholds: bounce < 5%, complaint < 0.1%. Alert script skeleton:

```bash
#!/bin/bash
ACCOUNT="production"
BOUNCE_THRESHOLD=5.0
COMPLAINT_THRESHOLD=0.1
STATS=$(ses-helper.sh stats "$ACCOUNT")
# Add alerting logic
```

## Troubleshooting

**Auth errors:**

```bash
aws sts get-caller-identity
ses-helper.sh quota production
```

**Sending limits:**

```bash
ses-helper.sh quota production   # check current
ses-helper.sh stats production   # monitor rate
# Request increase via AWS Support if needed
```

**Delivery issues:**

```bash
ses-helper.sh reputation production
ses-helper.sh suppressed production
ses-helper.sh debug production problematic@example.com
ses-helper.sh monitor production
```

**Verification problems:**

```bash
ses-helper.sh verify-identity production yourdomain.com
ses-helper.sh verify-domain production yourdomain.com
dig TXT _amazonses.yourdomain.com
```

## Compliance & Backup

```bash
# Export config snapshot
ses-helper.sh audit production > ses-config-backup-$(date +%Y%m%d).txt
ses-helper.sh verified-emails production > verified-emails-backup.txt
ses-helper.sh verified-domains production > verified-domains-backup.txt
```

- Configure SPF, DKIM, DMARC for all sending domains
- Process bounces and complaints promptly; maintain suppression list
- Provide unsubscribe mechanisms; follow GDPR/CAN-SPAM
- Warm up new sending IPs gradually; clean lists regularly
