---
description: Telfon cloud VoIP app - Twilio-powered calling, SMS, WhatsApp with user-friendly interface
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

# Telfon - Cloud VoIP & Virtual Phone System

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Twilio-powered cloud phone system with mobile/desktop apps
- **Website**: https://mytelfon.com/
- **Apps**: iOS, Android, Chrome Extension, Microsoft Edge Add-on
- **Features**: Calls, SMS, WhatsApp, Call Recording, Bulk SMS, Multi-number
- **Pricing**: Pay-as-you-go via Twilio credits
- **Setup Time**: ~5 minutes
- **Best For**: End users who want a calling/SMS interface without coding

**Key Capabilities**:

- Virtual phone numbers in 180+ countries
- Inbound/outbound calls and SMS
- Call recording with cloud storage
- WhatsApp Business integration
- Bulk SMS campaigns
- Chrome extension for click-to-call
- Multi-account management

**When to Recommend Telfon**:

- User needs a phone interface (not just API)
- Sales/support teams needing softphone
- Users who want WhatsApp + SMS in one app
- Non-technical users managing Twilio numbers

<!-- AI-CONTEXT-END -->

Telfon is a Twilio-based cloud phone system that provides a user-friendly interface for making calls, sending SMS, and managing WhatsApp communications. It's ideal for users who want the power of Twilio without writing code.

## Overview

### What is Telfon?

Telfon is a third-party application built on top of Twilio that provides:

- **Mobile Apps** (iOS/Android) for calls and SMS on the go
- **Chrome Extension** for click-to-call from any webpage
- **Web Dashboard** for account management and analytics
- **WhatsApp Integration** for business messaging

### Telfon vs Direct Twilio

| Aspect | Telfon | Direct Twilio |
|--------|--------|---------------|
| **Interface** | Mobile/desktop apps | API/CLI only |
| **Setup** | 5 minutes | Requires development |
| **Best For** | End users, sales teams | Developers, automation |
| **Customization** | Limited to app features | Fully customizable |
| **Cost** | Telfon subscription + Twilio usage | Twilio usage only |
| **WhatsApp** | Built-in | Requires setup |
| **Call Recording** | One-click enable | Requires TwiML config |

### When to Use Each

**Use Telfon when**:

- You need a phone interface for daily calling/SMS
- Sales or support teams need a softphone
- You want WhatsApp + SMS in one place
- Quick setup is more important than customization

**Use Direct Twilio when**:

- Building automated workflows
- Integrating with custom applications
- Need full API control
- Cost optimization is critical

## Getting Started

### Prerequisites

1. **Twilio Account** - Sign up at https://www.twilio.com/try-twilio
2. **Twilio Phone Number** - Purchase via Twilio console or Telfon
3. **Telfon Account** - Sign up at https://mytelfon.com/

### Quick Setup (5 Minutes)

#### Step 1: Get Twilio Credentials

1. Log in to [Twilio Console](https://console.twilio.com/)
2. Copy your **Account SID** and **Auth Token** from the dashboard
3. Note your Twilio phone number(s)

#### Step 2: Install Telfon

**Mobile Apps**:

- [iOS App Store](https://apps.apple.com/in/app/telfon-twilio-calls-chats/id6443471885)
- [Google Play Store](https://play.google.com/store/apps/details?id=com.wmt.cloud_telephony.android)

**Browser Extensions**:

- [Chrome Web Store](https://chromewebstore.google.com/detail/telfon-twilio-calls/bgkbahmggkomlcagkagcmiggkmcjmgdi)
- [Microsoft Edge Add-ons](https://microsoftedge.microsoft.com/addons/detail/telfon-virtual-phone-sys/hbdeajgckookmiogfljihebodfammogd)

#### Step 3: Connect Twilio to Telfon

1. Open Telfon app and sign up/login
2. Go to Settings > Twilio Integration
3. Enter your Twilio Account SID
4. Enter your Twilio Auth Token
5. Select your Twilio phone number(s)
6. Save and verify connection

### Video Tutorial

Telfon provides setup guides at: https://mytelfon.com/demo/

## Number Management

### Scenario 1: Numbers Purchased via Twilio

If you already have Twilio numbers:

1. Open Telfon app
2. Go to Settings > Phone Numbers
3. Your Twilio numbers will appear automatically
4. Select which numbers to use in Telfon
5. Configure each number's settings (voicemail, forwarding, etc.)

**Note**: Numbers remain in your Twilio account. Telfon just provides the interface.

### Scenario 2: Numbers Purchased via Telfon

Telfon can also help you purchase numbers:

1. Open Telfon app
2. Go to Phone Numbers > Buy New Number
3. Search by country, area code, or capabilities
4. Purchase directly (charged to your Twilio account)
5. Number is automatically configured in Telfon

**Advantage**: Simpler purchase flow, automatic configuration.

### Scenario 3: Numbers Not Available via API

Some numbers require contacting Twilio support:

- Toll-free in certain countries
- Short codes
- Specific area codes with limited availability

**AI-Assisted Process**:

1. Search in Telfon/Twilio - if unavailable
2. AI can compose support request (see `twilio.md`)
3. Once acquired, add to Telfon manually

## Features Guide

### Making Calls

**Mobile App**:

1. Open Telfon
2. Tap the dialer icon
3. Enter number or select contact
4. Tap call button
5. Select which Twilio number to call from (if multiple)

**Chrome Extension**:

1. Click any phone number on a webpage
2. Telfon popup appears
3. Click to initiate call
4. Call connects via your Twilio number

### Sending SMS

**Single SMS**:

1. Open Telfon > Messages
2. Tap compose
3. Enter recipient number
4. Type message
5. Send

**Bulk SMS**:

1. Open Telfon > Broadcasts
2. Create new broadcast
3. Import contacts (CSV) or select from list
4. Compose message
5. Schedule or send immediately

**Compliance Note**: Ensure recipients have opted in for bulk messages.

### Call Recording

1. Go to Settings > Call Recording
2. Enable recording (per number or all)
3. Recordings are stored in Telfon cloud
4. Access via Telfon > Recordings
5. Download or share as needed

**Storage**: Recordings count against Twilio storage limits.

### WhatsApp Integration

**Setup**:

1. Go to Settings > WhatsApp
2. Link your WhatsApp Business account
3. Scan QR code with WhatsApp
4. WhatsApp messages appear in Telfon

**Features**:

- Send/receive WhatsApp messages
- Manage multiple WhatsApp accounts
- Unified inbox with SMS

**Requirements**:

- WhatsApp Business account
- Approved message templates for outbound (outside 24h window)

### Voicemail

1. Go to Settings > Voicemail
2. Enable voicemail for each number
3. Record custom greeting (or use default)
4. Voicemails appear in Telfon > Voicemail
5. Optionally enable voicemail-to-text transcription

### Call Forwarding

1. Go to Settings > Call Forwarding
2. Select number to configure
3. Set forwarding rules:
   - Always forward
   - Forward when busy
   - Forward when no answer
   - Forward when unreachable
4. Enter destination number
5. Save

## Use Cases

### Sales Teams

**Setup**:

- Multiple sales reps, each with their own Twilio number
- Shared team number for inbound
- Call recording for training
- Chrome extension for CRM click-to-call

**Workflow**:

1. Lead comes in via website
2. Rep clicks phone number in CRM
3. Telfon initiates call via their Twilio number
4. Call is recorded automatically
5. Recording linked to CRM contact

### Customer Support

**Setup**:

- Toll-free number for inbound support
- Call forwarding to available agents
- Voicemail for after-hours
- SMS for ticket updates

**Workflow**:

1. Customer calls toll-free number
2. IVR routes to available agent (via Twilio Studio)
3. Agent answers in Telfon app
4. Call recorded for quality assurance
5. Follow-up SMS sent via Telfon

### Remote Teams

**Setup**:

- Virtual numbers in multiple countries
- Team members use mobile app anywhere
- Unified company presence

**Benefits**:

- Local presence in multiple markets
- No hardware required
- Work from anywhere

### Real Estate

**Setup**:

- Dedicated number per listing or agent
- SMS for appointment reminders
- Call tracking for marketing attribution

**Workflow**:

1. Prospect sees listing with dedicated number
2. Calls or texts that number
3. Agent receives in Telfon with listing context
4. Follow-up automated via SMS

## Integration with aidevops

### Recommended Architecture

```text
+------------------+     +------------------+     +------------------+
|   AI Workflows   |---->|   Twilio API     |---->|   Telfon App     |
|   (Automation)   |     |   (Backend)      |     |   (User UI)      |
+------------------+     +------------------+     +------------------+
        |                        |                        |
        v                        v                        v
   Scheduled SMS            Webhooks for             Manual calls
   Automated calls          CRM logging              SMS conversations
   Verify/OTP               Recording storage        WhatsApp chats
```

### When AI Uses Twilio Directly

- Automated appointment reminders
- OTP/verification codes
- Bulk notifications
- Webhook-triggered messages

### When Users Use Telfon

- Manual outbound calls
- Conversational SMS
- WhatsApp conversations
- Reviewing recordings

### Hybrid Workflow Example

1. **AI** sends appointment reminder SMS via Twilio API
2. **Customer** replies with question
3. **Webhook** logs reply to CRM
4. **User** sees notification in Telfon
5. **User** responds via Telfon app
6. **Twilio** delivers response
7. **Webhook** logs outbound message to CRM

## Pricing

### Telfon Subscription

Check current pricing at: https://mytelfon.com/pricing/

Typical tiers:

- **Free Trial**: Limited features, try before buying
- **Starter**: Basic calling/SMS for individuals
- **Professional**: Full features, multiple numbers
- **Enterprise**: Custom pricing, dedicated support

### Twilio Usage (Separate)

Telfon uses your Twilio account for actual communications:

- **SMS**: ~$0.0079/message (US)
- **Voice**: ~$0.014/minute (US outbound)
- **Phone Numbers**: ~$1.15/month (US local)
- **Recording Storage**: ~$0.0025/minute

See: https://www.twilio.com/en-us/pricing

### Cost Optimization

1. **Use Messaging Services** for bulk SMS (better deliverability)
2. **Monitor usage** in Twilio console
3. **Set alerts** for spending thresholds
4. **Review unused numbers** monthly

## Troubleshooting

### Connection Issues

**Telfon can't connect to Twilio**:

1. Verify Account SID is correct
2. Verify Auth Token is correct (regenerate if needed)
3. Check Twilio account is active (not suspended)
4. Ensure phone number is active

### Call Quality Issues

**Poor audio quality**:

1. Check internet connection (WiFi preferred)
2. Close other bandwidth-heavy apps
3. Try switching between WiFi and cellular
4. Check Twilio status: https://status.twilio.com/

### SMS Not Delivering

**Messages not received**:

1. Verify recipient number format (+1XXXXXXXXXX)
2. Check message status in Telfon > Messages
3. Review Twilio debugger for errors
4. Ensure compliance with carrier requirements (10DLC for US A2P)

### WhatsApp Issues

**Can't send WhatsApp messages**:

1. Verify WhatsApp Business account is connected
2. Check if within 24-hour conversation window
3. Use approved templates for outbound outside window
4. Review WhatsApp Business API requirements

## Security Considerations

### Data Storage

- Call recordings stored in Telfon cloud (and Twilio)
- Messages stored in Telfon for conversation history
- Review Telfon's privacy policy for data handling

### Access Control

- Use strong passwords for Telfon account
- Enable 2FA if available
- Regularly review connected devices
- Revoke access for departed team members

### Compliance

- Telfon inherits Twilio's compliance certifications
- Additional compliance depends on Telfon's practices
- For regulated industries, verify Telfon meets requirements

## Alternatives to Telfon

If Telfon doesn't meet your needs:

| App | Strengths | Best For |
|-----|-----------|----------|
| **OpenPhone** | Team features, shared numbers | Small teams |
| **Dialpad** | AI features, transcription | Enterprise |
| **Grasshopper** | Simple, reliable | Solopreneurs |
| **RingCentral** | Full UCaaS | Large organizations |
| **JustCall** | CRM integrations | Sales teams |

## Related Documentation

- `twilio.md` - Direct Twilio API usage
- `ses.md` - Email integration for multi-channel
- Telfon Help: https://mytelfon.com/support/
- Telfon Blog: https://mytelfon.com/blog/
