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

- **Access**: named login/SSO profile preferred; account-tagged secrets for unattended work. See `services/hosting/aws.md` for readiness, provisioning, rotation and compromise.
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

WordPress FluentSMTP's SES mailer sends raw MIME (`SendRawEmail`), so a `wp_mail`
filter adding `X-SES-CONFIGURATION-SET` to the message headers works. Its mail log
does not show custom headers: verify SES events, not the log alone. Attach the
override only when **every recipient**, including CC/BCC, is controlled/internal.
For the test below, make the temporary filter match only the exact controlled test
alias; leave all other messages unchanged and reject the override if any To/CC/BCC
recipient is outside that scope. Remove the filter with `remove_filter()` using
the same callback and priority after the test, including sending or verification
failures (for example, in a `finally` block). Do not leave a persistent snippet or
plugin applying the bypass to later mail.

### Prove the configuration-set bypass

With authorization, use a new plus alias of a controlled internal inbox, never a
customer address. Confirm the alias receives mail and is not already suppressed;
do not overwrite an existing suppression entry. Keep the regional account-level
suppression policy enabled and confirm `SuppressionAttributes.SuppressedReasons`
includes `BOUNCE` before adding the test entry below. If it does not, stop: delivery
of a `BOUNCE` entry would not prove a bypass. Do not change the account policy just
for this test. The selected configuration set must already have the
explicit empty override and a CloudWatch event destination enabled for
`SEND`, `DELIVERY`, `BOUNCE` and `REJECT`, publishing the
`ses-configuration-set` dimension.

```bash
# Examples: use the same authorized profile/region for every command.
aws sesv2 get-account --profile aidevops-production --region eu-west-2 \
  --query 'SuppressionAttributes.SuppressedReasons'
# Continue only if the returned reasons include BOUNCE.
aws sesv2 put-suppressed-destination --profile aidevops-production --region eu-west-2 \
  --email-address 'support+ses-test@example.com' --reason BOUNCE
```

Send one message from a verified identity to that alias through the configuration
set (API `ConfigurationSetName` or the raw MIME header above). Record the send time
and MessageId, then check the inbox and CloudWatch **AWS/SES → Delivery**, with
dimension **`ses-configuration-set=<name>`**, for a datapoint in the send window.
Allow 1–2 minutes for metrics to appear. Configuration-set metrics aggregate all
mail using that set: use a quiet test window/dedicated set and correlate with the
received message or recipient-specific delivery event, not an unrelated datapoint.
A missing datapoint is not proof of a drop until the event destination/dimensions
are verified. A MessageId alone is still not delivery proof.

Always remove the test entry after the attempt, including when sending or metric
verification fails; confirm cleanup with `get-suppressed-destination` returning
`NotFoundException` (HTTP 404). Other errors do not prove absence.

```bash
aws sesv2 delete-suppressed-destination --profile aidevops-production --region eu-west-2 \
  --email-address 'support+ses-test@example.com'
```

### Periodic own-domain checks

Periodically run `ses-helper.sh suppressed <account> --filter <own-domain>` for
**each verified domain** in each account/region. Inspect internal support and
notification inboxes too: a live audit found an own-domain support inbox suppressed
since 2024. Investigate the original bounce/complaint and verify the inbox before
removing any real entry; do not bulk-clear the list or weaken customer suppression.

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

### Workload send-only policy

Per-site or per-app sending keys (for example WordPress FluentSMTP) should not
hold `AmazonSESFullAccess`: a leaked key could then change identities,
suppression and configuration sets for every domain in the account. Scope each
key to its own domain and every configuration set its mail can use:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SendAsOwnDomain",
      "Effect": "Allow",
      "Action": ["ses:SendRawEmail", "ses:SendEmail"],
      "Resource": [
        "arn:aws:ses:<region>:<account>:identity/<domain>",
        "arn:aws:ses:<region>:<account>:identity/*@<domain>",
        "arn:aws:ses:<region>:<account>:configuration-set/<each-set-used>"
      ]
    },
    {
      "Sid": "ClientReadChecks",
      "Effect": "Allow",
      "Action": ["ses:ListIdentities", "ses:GetSendQuota"],
      "Resource": "*"
    }
  ]
}
```

- **Default configuration set:** SES authorizes a send against the configuration
  set it uses. An identity with a default set (`aws sesv2 get-email-identity
  --email-identity <domain> --query ConfigurationSetName`; consoles often create
  `my-first-configuration-set`) applies it to every send that names no set, so
  omitting it fails plain sends with `AccessDenied` while sends that name an
  allowed set still work. List every identity's default set before scoping.
- **Client read calls:** FluentSMTP calls `ListIdentities` when a connection is
  saved or checked and `GetSendQuota` for its stats; other clients differ, so
  check CloudTrail (`lookup-events --lookup-attributes
  AttributeKey=Username,AttributeValue=<user>`) for what each key really calls.
  `SendRawEmail`/`SendEmail` are not in CloudTrail management events.
- **Verify before and after:** `aws iam simulate-principal-policy` per user (own
  domain and sets allowed; other domains, regions and sets, identity/suppression
  writes, SNS and IAM denied), then a real send through each client to
  `success@simulator.amazonses.com`, once plain and once with the
  `X-SES-CONFIGURATION-SET` header. The simulator checks one resource at a time,
  so only the real send proves the default-set case. Run the same send as a
  baseline first, and roll out to one key before the rest; rollback is
  re-attaching the previous managed policies.

The controlled bypass proof additionally needs `ses:PutSuppressedDestination` and
`ses:DeleteSuppressedDestination`; CloudWatch verification needs
`cloudwatch:GetMetricStatistics` or `cloudwatch:GetMetricData` (and
`cloudwatch:ListMetrics` for discovery). Event-destination setup is a separate
authorized configuration change, not an implicit permission grant for the test.

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
