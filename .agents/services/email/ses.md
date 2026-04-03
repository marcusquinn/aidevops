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

- **Type**: AWS cloud email service | **Auth**: IAM credentials (access key + secret)
- **Config**: `cp configs/ses-config.json.txt configs/ses-config.json` | **Regions**: us-east-1, eu-west-1, etc.
- **Commands**: `ses-helper.sh [accounts|quota|stats|monitor|verified-emails|verified-domains|verify-email|verify-domain|dkim|enable-dkim|reputation|suppressed|suppression-details|remove-suppression|send-test|debug|audit] [account] [args]`
- **Thresholds**: Bounce < 5%, Complaint < 0.1% | **Prerequisite**: `awscli` installed
- **Test addresses**: success@simulator.amazonses.com, bounce@simulator.amazonses.com
- **DKIM**: Enable for all domains | **Security**: Rotate IAM keys regularly; separate AWS accounts for prod/staging
- **IAM permissions**: ses:GetSendQuota, ses:SendEmail, sesv2:ListSuppressedDestinations (full policy below)

<!-- AI-CONTEXT-END -->

## Configuration

```json
{
  "accounts": {
    "production": {
      "aws_access_key_id": "YOUR_KEY",
      "aws_secret_access_key": "YOUR_SECRET",
      "region": "us-east-1",
      "description": "Production SES account",
      "verified_domains": ["yourdomain.com"],
      "verified_emails": ["noreply@yourdomain.com"]
    },
    "staging": {
      "aws_access_key_id": "YOUR_KEY",
      "aws_secret_access_key": "YOUR_SECRET",
      "region": "us-east-1",
      "description": "Staging SES account",
      "verified_domains": ["staging.yourdomain.com"],
      "verified_emails": ["test@yourdomain.com"]
    }
  }
}
```

## Commands

```bash
ses-helper.sh accounts
ses-helper.sh quota production           # send quota
ses-helper.sh stats production           # send statistics
ses-helper.sh monitor production         # bounce, complaint, quota, reputation
ses-helper.sh verified-emails production
ses-helper.sh verified-domains production
ses-helper.sh verify-email production newuser@yourdomain.com
ses-helper.sh verify-domain production newdomain.com
ses-helper.sh verify-identity production yourdomain.com
ses-helper.sh dkim production yourdomain.com
ses-helper.sh enable-dkim production yourdomain.com
ses-helper.sh reputation production
ses-helper.sh suppressed production
ses-helper.sh suppression-details production user@example.com
ses-helper.sh remove-suppression production user@example.com
ses-helper.sh send-test production noreply@yourdomain.com success@simulator.amazonses.com "Test"
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

## Troubleshooting

| Problem | Commands |
|---------|----------|
| Auth | `aws sts get-caller-identity` then `ses-helper.sh quota production` |
| Limits | `ses-helper.sh quota production` — request increase via AWS Support |
| Delivery | `ses-helper.sh reputation production`, `ses-helper.sh suppressed production`, `ses-helper.sh debug production user@example.com` |
| Verification | `ses-helper.sh verify-identity production yourdomain.com`, `dig TXT _amazonses.yourdomain.com` |

## Compliance & Backup

- Configure SPF, DKIM, DMARC; process bounces/complaints promptly
- Maintain suppression list; provide unsubscribe mechanisms; follow GDPR/CAN-SPAM
- Warm up new IPs; clean lists regularly

```bash
ses-helper.sh audit production > ses-config-backup-$(date +%Y%m%d).txt
ses-helper.sh verified-emails production > verified-emails-backup.txt
ses-helper.sh verified-domains production > verified-domains-backup.txt
```
