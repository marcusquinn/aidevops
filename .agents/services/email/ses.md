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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Amazon SES Provider Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Access**: named SSO profile preferred; account-tagged secrets for unattended work. See `services/hosting/aws.md` for provisioning, naming, rotation and compromise.
- **Config**: `configs/ses-config.json.txt` → `configs/ses-config.json`, metadata only; override location with `SES_CONFIG_FILE`. Requires AWS CLI v2 and jq.
- **Auth**: `profile` or `credential_prefix` per account; explicit `--profile` before the command overrides metadata. Never store AWS key values in JSON.
- **IAM**: SESv2 CLI commands still use IAM actions with the `ses:` prefix.
- **Delivery**: a MessageId is acceptance, not delivery. Check suppression and delivery/bounce events.
- **Thresholds**: bounce < 5%, complaint < 0.1%; use SES simulator addresses for tests.

<!-- AI-CONTEXT-END -->

## Configuration

```json
{
  "accounts": {
    "production": {
      "credential_prefix": "AWS_PRODUCTION",
      "region": "us-east-1",
      "description": "Production SES account",
      "verified_domains": ["yourdomain.com"],
      "verified_emails": ["noreply@yourdomain.com"]
    },
    "staging": {
      "profile": "aidevops-staging",
      "region": "us-east-1",
      "description": "Staging SES account"
    }
  }
}
```

`credential_prefix: AWS_PRODUCTION` selects `AWS_PRODUCTION_ACCESS_KEY_ID` and
`AWS_PRODUCTION_SECRET_ACCESS_KEY` from `aidevops secret`. For temporary keys add
`"session_token": true` and store `AWS_PRODUCTION_SESSION_TOKEN`. Each invocation
injects only this tuple, maps it to AWS's conventional environment, and removes
inherited profile/session credentials. Profile mode clears inherited key values.
No default account is inferred. Legacy plaintext AWS fields are ignored with a
warning: migrate through hidden `aidevops secret set` prompts, remove the fields,
and rotate the exposed keys. No helper copies plaintext keys automatically.

## Commands

```bash
ses-helper.sh accounts
ses-helper.sh quota production
ses-helper.sh --profile aidevops-staging quota staging
ses-helper.sh stats production
ses-helper.sh monitor production
ses-helper.sh verified-emails production
ses-helper.sh verified-domains production
ses-helper.sh verify-email production newuser@yourdomain.com
ses-helper.sh verify-domain production yourdomain.com
ses-helper.sh verify-identity production yourdomain.com
ses-helper.sh dkim production yourdomain.com
ses-helper.sh enable-dkim production yourdomain.com
ses-helper.sh notifications production yourdomain.com
ses-helper.sh reputation production
ses-helper.sh suppressed production
ses-helper.sh suppressed production --filter example.com  # exact domain, case insensitive, all pages
ses-helper.sh suppression-details production user@example.com
ses-helper.sh remove-suppression production user@example.com
ses-helper.sh account-suppression production get
ses-helper.sh account-suppression production put BOUNCE COMPLAINT
ses-helper.sh config-set production list
ses-helper.sh config-set production create internal-recipients
ses-helper.sh config-set production suppression internal-recipients  # explicit []
ses-helper.sh config-set production suppression normal-mail BOUNCE COMPLAINT
ses-helper.sh config-sets production     # legacy listing command
ses-helper.sh send-test production noreply@yourdomain.com success@simulator.amazonses.com "Test"
ses-helper.sh debug production user@example.com
ses-helper.sh audit production
```

Suppression/configuration-set writes change delivery policy. Verify account,
region, authorization and intended recipients before applying them. Suppression
listings explicitly follow service `NextToken` values; the JSON-array domain
filter runs after collecting every page, not only the first response. No raw
SigV4 signing is used; let the AWS CLI encode
suppression-list email paths.

## Suppression and silent drops

An address previously hard-bounced or reported as a complaint can remain on the
account-level suppression list. A subsequent send may return a MessageId while
SES does not attempt delivery: an application log saying "sent" is not proof of
delivery. Check the suppression entry, regional account settings and event
destinations. Fix the recipient/cause before removing suppression; do not clear
complaints or retry invalid addresses indiscriminately.

A configuration set can override account suppression: setting
`SuppressedReasons: []` explicitly disables account-level suppression for sends
using that set. An absent override instead inherits account settings. Use a
dedicated set only for controlled internal recipients; it is not a domain filter,
does not bypass every SES safeguard, and can damage reputation if applied widely.

The sender must attach the set with API `ConfigurationSetName` (AWS CLI
`--configuration-set-name internal-recipients`) or SMTP/raw MIME header
`X-SES-CONFIGURATION-SET: internal-recipients`. Creating the set alone changes
nothing for messages that do not select it. Account-wide `put` with no reasons
also sends `[]`, so prefer the narrowly selected configuration-set override.

## IAM Policy

Read-only diagnostics baseline (trim further for the task):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ses:GetSendQuota",
      "ses:GetSendStatistics",
      "ses:ListIdentities",
      "ses:ListVerifiedEmailAddresses",
      "ses:GetIdentityVerificationAttributes",
      "ses:GetIdentityDkimAttributes",
      "ses:GetIdentityNotificationAttributes",
      "ses:GetAccountSendingEnabled",
      "ses:GetAccount",
      "ses:GetSuppressedDestination",
      "ses:ListSuppressedDestinations",
      "ses:ListConfigurationSets"
    ],
    "Resource": "*"
  }]
}
```

Grant write actions only when authorized: `ses:DeleteSuppressedDestination`,
`ses:PutAccountSuppressionAttributes`, `ses:CreateConfigurationSet`, and
`ses:PutConfigurationSetSuppressionOptions`. Identity writes require
`ses:VerifyEmailIdentity`, `ses:VerifyDomainIdentity` and
`ses:SetIdentityDkimEnabled`; test sending requires `ses:SendEmail` (and
`ses:SendRawEmail` for raw mail). Restrict identity/configuration-set resources
where supported, sender/recipient conditions and regions to the workload. Account
and list actions require `Resource: "*"`; do not use this as a blanket write policy.

## Troubleshooting and compliance

| Problem | Verification |
|---------|--------------|
| Auth | `aidevops secret verify aws AWS_PRODUCTION_ACCESS_KEY_ID` or `aws --profile aidevops-staging sts get-caller-identity` |
| Limits | `ses-helper.sh quota production`; request a quota increase through AWS Support |
| Delivery | `suppression-details`, `account-suppression get`, delivery/bounce events and the selected configuration set |
| Verification | `ses-helper.sh verify-identity production yourdomain.com`, DNS TXT and DKIM records |

Configure SPF, DKIM and DMARC. Process bounces/complaints promptly, preserve
unsubscribe controls, follow GDPR/CAN-SPAM, warm up new IPs and clean mailing
lists. Protect audit/listing output as recipient data, not public logs.
