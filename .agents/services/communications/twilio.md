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
- **Regions**: Global, 180+ countries
- **Pricing**: Pay-as-you-go per message/minute
- **Recommended Client**: Telfon app (see `telfon.md`)

**Critical Compliance Rules**: Obtain consent before marketing messages · Honor opt-out requests immediately · No spam, phishing, or deceptive content · Follow country-specific regulations (TCPA, GDPR, etc.)

<!-- AI-CONTEXT-END -->

## Acceptable Use Policy (AUP) Compliance

**CRITICAL**: Before any messaging operation, verify compliance with Twilio's AUP.

**Block and refuse** any message that is: unsolicited/spam, phishing or deceptive, illegal content (fraud, harassment, threats), identity spoofing, or attempting to bypass rate limits.

**Pre-send checklist**: (1) Consent — recipient expects this? (2) Opt-out — clear unsubscribe mechanism? (3) Content — legitimate and non-deceptive? (4) Compliance — meets country-specific requirements?

### Country-Specific Requirements

| Region | Key Requirements |
|--------|------------------|
| **US (TCPA)** | Prior express consent for marketing, 10DLC registration for A2P |
| **EU (GDPR)** | Explicit consent, right to erasure, data protection |
| **UK** | PECR compliance, consent for marketing |
| **Canada (CASL)** | Express or implied consent, unsubscribe mechanism |
| **Australia** | Spam Act compliance, consent required |

**Refusal template**:

```text
I cannot send this message because it may violate Twilio's Acceptable Use Policy:
- [Specific concern]

To proceed legitimately:
1. [Suggested alternative approach]
2. [Compliance requirement to meet]

See: https://www.twilio.com/en-us/legal/aup
```

## Configuration

```bash
cp configs/twilio-config.json.txt configs/twilio-config.json
# Edit with credentials from https://console.twilio.com/
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
brew tap twilio/brew && brew install twilio  # macOS
npm install -g twilio-cli                     # npm
twilio login  # interactive, stores credentials locally
# Or: export TWILIO_ACCOUNT_SID="ACxxx" TWILIO_AUTH_TOKEN="xxx"
```

## Usage Examples

### SMS

```bash
./.agents/scripts/twilio-helper.sh sms production "+1234567890" "Hello from aidevops!"
./.agents/scripts/twilio-helper.sh sms production "+1234567890" "Order confirmed" --callback "https://your-webhook.com/status"
./.agents/scripts/twilio-helper.sh messages production --limit 20
./.agents/scripts/twilio-helper.sh message-status production "SMxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

### Voice

```bash
./.agents/scripts/twilio-helper.sh call production "+1234567890" --twiml "<Response><Say>Hello!</Say></Response>"
./.agents/scripts/twilio-helper.sh call production "+1234567890" --url "https://your-server.com/voice.xml"
./.agents/scripts/twilio-helper.sh calls production --limit 20
./.agents/scripts/twilio-helper.sh call-details production "CAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

### Recordings & Transcriptions

```bash
./.agents/scripts/twilio-helper.sh recordings production
./.agents/scripts/twilio-helper.sh recording production "RExxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
./.agents/scripts/twilio-helper.sh download-recording production "RExxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ./recordings/
./.agents/scripts/twilio-helper.sh transcription production "TRxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
./.agents/scripts/twilio-helper.sh transcriptions production
```

### Phone Number Management

```bash
./.agents/scripts/twilio-helper.sh numbers production
./.agents/scripts/twilio-helper.sh search-numbers production US --area-code 415
./.agents/scripts/twilio-helper.sh search-numbers production GB --sms --voice
./.agents/scripts/twilio-helper.sh buy-number production "+14155551234"    # requires confirmation
./.agents/scripts/twilio-helper.sh release-number production "+14155551234" # requires confirmation
```

### Verify (2FA/OTP)

```bash
./.agents/scripts/twilio-helper.sh verify-create-service production "MyApp Verification"
./.agents/scripts/twilio-helper.sh verify-send production "+1234567890" --channel sms
./.agents/scripts/twilio-helper.sh verify-check production "+1234567890" "123456"
```

### Lookup, WhatsApp, Account

```bash
./.agents/scripts/twilio-helper.sh lookup production "+1234567890" --type carrier
./.agents/scripts/twilio-helper.sh whatsapp production "+1234567890" "Hello via WhatsApp!"
./.agents/scripts/twilio-helper.sh whatsapp-template production "+1234567890" "appointment_reminder" '{"1":"John","2":"Tomorrow 3pm"}'
./.agents/scripts/twilio-helper.sh accounts
./.agents/scripts/twilio-helper.sh balance production
./.agents/scripts/twilio-helper.sh usage production
./.agents/scripts/twilio-helper.sh audit production
```

## Number Acquisition

**Via API** (standard): `search-numbers` then `buy-number` as shown above.

**Via Telfon** (recommended for end users): See `telfon.md`. Numbers purchased via Twilio can be connected to Telfon.

**Via Twilio Support** (special numbers — toll-free in certain countries, short codes, specific area codes, numbers requiring regulatory approval):

```text
Subject: Phone Number Request - [Country] [Type]
Account SID: ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
Details: Country, Number Type, Desired Area Code, Quantity, Use Case, Regulatory Documents
```

## Webhook Configuration

```bash
./.agents/scripts/twilio-helper.sh configure-webhooks production "+1234567890" \
  --sms-url "https://your-server.com/sms" \
  --voice-url "https://your-server.com/voice"
```

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

**Deployment options**: Coolify (self-hosted), Vercel (serverless), Cloudflare Workers (low latency), n8n/Make (no-code).

## AI Orchestration Integration

**Use cases**: Appointment reminders, order notifications, 2FA (Verify API), lead follow-up, support escalation (voice), survey collection (SMS with response handling).

**Recording transcription for AI analysis**:

```bash
./.agents/scripts/twilio-helper.sh call production "+1234567890" \
  --record --transcribe \
  --transcription-callback "https://your-server.com/webhooks/twilio/transcription"
```

Transcriptions can be stored for compliance/training, analyzed for sentiment/intent, summarized for CRM notes, or used for quality assurance.

## Security

```bash
# In ~/.config/aidevops/credentials.sh (600 permissions — never commit to git)
export TWILIO_ACCOUNT_SID_PRODUCTION="ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
export TWILIO_AUTH_TOKEN_PRODUCTION="your_token_here"
```

**Webhook signature validation** (Node.js):

```javascript
const twilio = require('twilio');
const valid = twilio.validateRequest(
  authToken,
  req.headers['x-twilio-signature'],
  webhookUrl,
  req.body
);
```

**Rate limiting**: Twilio has built-in rate limits. Implement application-level throttling for bulk operations. Use Messaging Services for high-volume SMS (automatic queuing).

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Auth errors | `twilio-helper.sh status production` · check `$TWILIO_ACCOUNT_SID` |
| Message undelivered | `twilio-helper.sh message-status production "SMxxxxxxxx"` |
| Number not available | Try different criteria; contact Twilio support for special numbers |
| Webhook not receiving | `curl -X POST https://your-server.com/webhooks/twilio/sms -d "test=1"` · check [console.twilio.com/debugger](https://console.twilio.com/debugger) |

**Message status codes**: queued → sent → delivered / undelivered / failed

## Monitoring

```bash
./.agents/scripts/twilio-helper.sh usage production --period day
./.agents/scripts/twilio-helper.sh usage production --period month
./.agents/scripts/twilio-helper.sh analytics production messages --days 7
./.agents/scripts/twilio-helper.sh analytics production calls --days 7
# Set up alerts in Twilio console for: balance threshold, error rate spike, unusual activity
```

## Related

- `telfon.md` — Telfon app setup and integration
- `ses.md` — Email integration (multi-channel)
- `workflows/webhook-handlers.md` — Webhook deployment patterns
- [Twilio Docs](https://www.twilio.com/docs) · [Twilio AUP](https://www.twilio.com/en-us/legal/aup) · [Twilio Console](https://console.twilio.com/)
