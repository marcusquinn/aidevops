---
description: Twilio communications platform - SMS, voice, WhatsApp, verify with multi-account support
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

# Twilio Communications Provider

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Cloud communications platform (CPaaS)
- **Auth**: Account SID + Auth Token (per account)
- **Config**: `configs/twilio-config.json`
- **Commands**: `twilio-helper.sh [accounts|numbers|sms|call|verify|lookup|recordings|transcriptions|whatsapp|status|audit] [account] [args]`
- **Capabilities**: SMS, Voice, WhatsApp, Verify (2FA), Lookup, Recordings, Transcriptions
- **Regions**: Global with local number availability in 180+ countries
- **Pricing**: Pay-as-you-go per message/minute
- **AUP**: Must comply with Twilio Acceptable Use Policy
- **Recommended Client**: Telfon app (see `telfon.md`)

**Critical Compliance Rules**:

- Obtain consent before sending marketing messages
- Honor opt-out requests immediately
- No spam, phishing, or deceptive content
- Follow country-specific regulations (TCPA, GDPR, etc.)

<!-- AI-CONTEXT-END -->

Twilio is a cloud communications platform that enables programmatic SMS, voice calls, WhatsApp messaging, phone number verification, and more.

## Acceptable Use Policy (AUP) Compliance

**CRITICAL**: Before any messaging operation, verify compliance with Twilio's AUP.

### Prohibited Activities

| Category | Examples | Action |
|----------|----------|--------|
| **Spam** | Unsolicited bulk messages, marketing without consent | BLOCK - Do not send |
| **Phishing** | Deceptive links, credential harvesting | BLOCK - Do not send |
| **Illegal Content** | Fraud, harassment, threats | BLOCK - Do not send |
| **Identity Spoofing** | Misleading sender information | BLOCK - Do not send |
| **Bypassing Limits** | Circumventing rate limits or restrictions | BLOCK - Do not attempt |

### Pre-Send Validation Checklist

Before sending any message, the AI assistant should verify:

1. **Consent**: Does the recipient expect this message?
2. **Opt-out**: Is there a clear way to unsubscribe?
3. **Content**: Is the message legitimate and non-deceptive?
4. **Compliance**: Does it meet country-specific requirements?

### Country-Specific Requirements

| Region | Key Requirements |
|--------|------------------|
| **US (TCPA)** | Prior express consent for marketing, 10DLC registration for A2P |
| **EU (GDPR)** | Explicit consent, right to erasure, data protection |
| **UK** | PECR compliance, consent for marketing |
| **Canada (CASL)** | Express or implied consent, unsubscribe mechanism |
| **Australia** | Spam Act compliance, consent required |

### When AI Should Refuse

The AI assistant should **refuse** to send messages that:

- Target recipients who haven't opted in
- Contain deceptive or misleading content
- Attempt to bypass Twilio's systems
- Violate local telecommunications laws
- Could be considered harassment or spam

**Response template when refusing**:

```text
I cannot send this message because it may violate Twilio's Acceptable Use Policy:
- [Specific concern]

To proceed legitimately:
1. [Suggested alternative approach]
2. [Compliance requirement to meet]

See: https://www.twilio.com/en-us/legal/aup
```

## Provider Overview

### Twilio Characteristics

- **Service Type**: Cloud communications platform (CPaaS)
- **Global Coverage**: Phone numbers in 180+ countries
- **Authentication**: Account SID + Auth Token per account
- **API Support**: REST API, SDKs (Node.js, Python, etc.)
- **Pricing**: Pay-per-use (SMS, minutes, verifications)
- **Compliance**: SOC 2, HIPAA eligible, GDPR compliant

### Best Use Cases

- **Transactional SMS** (order confirmations, alerts, OTPs)
- **Voice calls** (outbound notifications, IVR systems)
- **Two-factor authentication** (Verify API)
- **WhatsApp Business** messaging
- **Phone number validation** (Lookup API)
- **Call recording and transcription**
- **CRM integration** for communication logging

## Configuration

### Setup Configuration

```bash
# Copy template
cp configs/twilio-config.json.txt configs/twilio-config.json

# Edit with your Twilio credentials
# Get credentials from: https://console.twilio.com/
```

### Multi-Account Configuration

```json
{
  "accounts": {
    "production": {
      "account_sid": "ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
      "auth_token": "your_auth_token_here",
      "description": "Production Twilio account",
      "phone_numbers": ["+1234567890"],
      "messaging_service_sid": "MGxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
      "default_from": "+1234567890"
    },
    "staging": {
      "account_sid": "ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
      "auth_token": "your_auth_token_here",
      "description": "Staging/Test account",
      "phone_numbers": ["+1987654321"],
      "default_from": "+1987654321"
    }
  }
}
```

### Twilio CLI Setup

```bash
# Install Twilio CLI
brew tap twilio/brew && brew install twilio  # macOS
npm install -g twilio-cli                     # npm

# Verify installation
twilio --version

# Login (interactive - stores credentials locally)
twilio login

# Or use environment variables
export TWILIO_ACCOUNT_SID="ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
export TWILIO_AUTH_TOKEN="your_auth_token_here"
```

## Usage Examples

### SMS Operations

```bash
# Send SMS
./.agent/scripts/twilio-helper.sh sms production "+1234567890" "Hello from aidevops!"

# Send SMS with status callback
./.agent/scripts/twilio-helper.sh sms production "+1234567890" "Order confirmed" --callback "https://your-webhook.com/status"

# List recent messages
./.agent/scripts/twilio-helper.sh messages production --limit 20

# Get message status
./.agent/scripts/twilio-helper.sh message-status production "SMxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

### Voice Operations

```bash
# Make outbound call with TwiML
./.agent/scripts/twilio-helper.sh call production "+1234567890" --twiml "<Response><Say>Hello!</Say></Response>"

# Make call with URL
./.agent/scripts/twilio-helper.sh call production "+1234567890" --url "https://your-server.com/voice.xml"

# List recent calls
./.agent/scripts/twilio-helper.sh calls production --limit 20

# Get call details
./.agent/scripts/twilio-helper.sh call-details production "CAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

### Call Recording & Transcription

```bash
# List recordings for account
./.agent/scripts/twilio-helper.sh recordings production

# Get recording details
./.agent/scripts/twilio-helper.sh recording production "RExxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# Download recording
./.agent/scripts/twilio-helper.sh download-recording production "RExxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ./recordings/

# Get transcription
./.agent/scripts/twilio-helper.sh transcription production "TRxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# List all transcriptions
./.agent/scripts/twilio-helper.sh transcriptions production
```

### Phone Number Management

```bash
# List owned numbers
./.agent/scripts/twilio-helper.sh numbers production

# Search available numbers
./.agent/scripts/twilio-helper.sh search-numbers production US --area-code 415

# Search by capabilities
./.agent/scripts/twilio-helper.sh search-numbers production GB --sms --voice

# Purchase number (requires confirmation)
./.agent/scripts/twilio-helper.sh buy-number production "+14155551234"

# Release number (requires confirmation)
./.agent/scripts/twilio-helper.sh release-number production "+14155551234"
```

### Verify (2FA/OTP)

```bash
# Create verification service (one-time setup)
./.agent/scripts/twilio-helper.sh verify-create-service production "MyApp Verification"

# Send verification code
./.agent/scripts/twilio-helper.sh verify-send production "+1234567890" --channel sms

# Check verification code
./.agent/scripts/twilio-helper.sh verify-check production "+1234567890" "123456"
```

### Lookup (Phone Validation)

```bash
# Basic lookup
./.agent/scripts/twilio-helper.sh lookup production "+1234567890"

# Carrier lookup
./.agent/scripts/twilio-helper.sh lookup production "+1234567890" --type carrier

# Caller name lookup
./.agent/scripts/twilio-helper.sh lookup production "+1234567890" --type caller-name
```

### WhatsApp

```bash
# Send WhatsApp message (requires approved template or 24h window)
./.agent/scripts/twilio-helper.sh whatsapp production "+1234567890" "Hello via WhatsApp!"

# Send WhatsApp template
./.agent/scripts/twilio-helper.sh whatsapp-template production "+1234567890" "appointment_reminder" '{"1":"John","2":"Tomorrow 3pm"}'
```

### Account Status & Audit

```bash
# List all configured accounts
./.agent/scripts/twilio-helper.sh accounts

# Get account balance
./.agent/scripts/twilio-helper.sh balance production

# Get usage summary
./.agent/scripts/twilio-helper.sh usage production

# Full account audit
./.agent/scripts/twilio-helper.sh audit production
```

## Number Acquisition

### Via Twilio API (Standard)

Most numbers can be purchased directly via the API:

```bash
# Search and purchase
./.agent/scripts/twilio-helper.sh search-numbers production US --area-code 212
./.agent/scripts/twilio-helper.sh buy-number production "+12125551234"
```

### Via Telfon App (Recommended for End Users)

For a better user experience with calling/SMS interface, use Telfon:

- See `telfon.md` for setup guide
- Numbers purchased via Telfon are managed in Telfon's interface
- Numbers purchased via Twilio can be connected to Telfon

### Via Twilio Support (Special Numbers)

Some numbers are not available via API and require contacting Twilio support:

- Toll-free numbers in certain countries
- Short codes
- Specific area codes with limited availability
- Numbers requiring regulatory approval

**When API returns no results for a desired number**:

```bash
# If search returns empty
./.agent/scripts/twilio-helper.sh search-numbers production GB --area-code 020
# Result: No numbers available

# AI should offer to help contact support
```

**AI-Assisted Support Request**:

When numbers aren't available via API, the AI can help by:

1. **Composing an email** to Twilio support with the request
2. **Using browser automation** to submit via Twilio console
3. **Drafting a support ticket** with all required details

Template for support request:

```text
Subject: Phone Number Request - [Country] [Type]

Account SID: ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
Request Type: Phone Number Acquisition

Details:
- Country: [Country]
- Number Type: [Local/Toll-Free/Mobile]
- Desired Area Code: [Area code if applicable]
- Quantity: [Number of numbers needed]
- Use Case: [Brief description]
- Regulatory Documents: [Available/Will provide]

Please advise on availability and any requirements.
```

## Webhook Configuration

### Inbound SMS/Call Handling

Configure webhooks for receiving messages and calls:

```bash
# Update number webhook URLs
./.agent/scripts/twilio-helper.sh configure-webhooks production "+1234567890" \
  --sms-url "https://your-server.com/sms" \
  --voice-url "https://your-server.com/voice"
```

### Webhook Endpoints for CRM/AI Integration

For CRM logging and AI orchestration, configure status callbacks:

```json
{
  "webhooks": {
    "sms_status": "https://your-server.com/webhooks/twilio/sms-status",
    "voice_status": "https://your-server.com/webhooks/twilio/voice-status",
    "recording_status": "https://your-server.com/webhooks/twilio/recording",
    "transcription_callback": "https://your-server.com/webhooks/twilio/transcription"
  }
}
```

### Deployment Options for Webhooks

| Platform | Use Case | Setup |
|----------|----------|-------|
| **Coolify** | Self-hosted, full control | Deploy webhook handler app |
| **Vercel** | Serverless, quick setup | Edge functions for webhooks |
| **Cloudflare Workers** | Low latency, global | Worker scripts |
| **n8n/Make** | No-code automation | Built-in Twilio triggers |

## AI Orchestration Integration

### Use Cases for AI Agents

| Scenario | Implementation |
|----------|----------------|
| **Appointment Reminders** | Scheduled SMS via cron/workflow |
| **Order Notifications** | Triggered by e-commerce events |
| **2FA for Apps** | Verify API integration |
| **Lead Follow-up** | CRM-triggered outreach |
| **Support Escalation** | Voice call when ticket urgent |
| **Survey Collection** | SMS with response handling |

### CRM Logging Pattern

```javascript
// Example webhook handler for CRM logging
app.post('/webhooks/twilio/sms-status', (req, res) => {
  const { MessageSid, MessageStatus, To, From } = req.body;
  
  // Log to CRM
  crm.logCommunication({
    type: 'sms',
    direction: 'outbound',
    status: MessageStatus,
    recipient: To,
    sender: From,
    externalId: MessageSid,
    timestamp: new Date()
  });
  
  res.sendStatus(200);
});
```

### Recording Transcription for AI Analysis

```bash
# Enable recording on calls
./.agent/scripts/twilio-helper.sh call production "+1234567890" \
  --record \
  --transcribe \
  --transcription-callback "https://your-server.com/webhooks/twilio/transcription"
```

Transcriptions can be:

- Stored for compliance/training
- Analyzed by AI for sentiment/intent
- Summarized for CRM notes
- Used for quality assurance

## Security Best Practices

### Credential Security

```bash
# Store credentials securely
# In ~/.config/aidevops/mcp-env.sh (600 permissions)
export TWILIO_ACCOUNT_SID_PRODUCTION="ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
export TWILIO_AUTH_TOKEN_PRODUCTION="your_token_here"

# Never commit credentials to git
# Use configs/twilio-config.json (gitignored)
```

### Webhook Security

```bash
# Validate webhook signatures
# Twilio signs all webhook requests
# Verify X-Twilio-Signature header

# Example validation (Node.js)
const twilio = require('twilio');
const valid = twilio.validateRequest(
  authToken,
  req.headers['x-twilio-signature'],
  webhookUrl,
  req.body
);
```

### Rate Limiting

- Twilio has built-in rate limits
- Implement application-level throttling for bulk operations
- Use Messaging Services for high-volume SMS (automatic queuing)

## Troubleshooting

### Common Issues

#### Authentication Errors

```bash
# Verify credentials
./.agent/scripts/twilio-helper.sh status production

# Check environment variables
echo $TWILIO_ACCOUNT_SID
```

#### Message Delivery Issues

```bash
# Check message status
./.agent/scripts/twilio-helper.sh message-status production "SMxxxxxxxx"

# Common status codes:
# - queued: Message queued for sending
# - sent: Message sent to carrier
# - delivered: Confirmed delivery
# - undelivered: Delivery failed
# - failed: Message could not be sent
```

#### Number Not Available

```bash
# Search returns empty - try different criteria
./.agent/scripts/twilio-helper.sh search-numbers production US --contains "555"

# If still unavailable, contact Twilio support (see above)
```

#### Webhook Not Receiving

```bash
# Verify webhook URL is accessible
curl -X POST https://your-server.com/webhooks/twilio/sms -d "test=1"

# Check Twilio debugger
# https://console.twilio.com/debugger
```

## Monitoring & Analytics

### Usage Monitoring

```bash
# Daily usage summary
./.agent/scripts/twilio-helper.sh usage production --period day

# Monthly costs
./.agent/scripts/twilio-helper.sh usage production --period month

# Set up alerts in Twilio console for:
# - Balance threshold
# - Error rate spike
# - Unusual activity
```

### Delivery Analytics

```bash
# Message delivery rates
./.agent/scripts/twilio-helper.sh analytics production messages --days 7

# Call completion rates
./.agent/scripts/twilio-helper.sh analytics production calls --days 7
```

## Related Documentation

- `telfon.md` - Telfon app setup and integration
- `ses.md` - Email integration (for multi-channel)
- `workflows/webhook-handlers.md` - Webhook deployment patterns
- Twilio Docs: https://www.twilio.com/docs
- Twilio AUP: https://www.twilio.com/en-us/legal/aup
- Twilio Console: https://console.twilio.com/
