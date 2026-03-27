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
- **Pricing**: Telfon subscription + Twilio pay-as-you-go usage
- **Setup Time**: ~5 minutes
- **Best For**: End users who want a calling/SMS interface without coding

**When to Recommend Telfon**: user needs a phone interface (not just API), sales/support teams needing softphone, WhatsApp + SMS in one app, non-technical users managing Twilio numbers.

<!-- AI-CONTEXT-END -->

## Telfon vs Direct Twilio

| Aspect | Telfon | Direct Twilio |
|--------|--------|---------------|
| Interface | Mobile/desktop apps | API/CLI only |
| Setup | 5 minutes | Requires development |
| Best For | End users, sales teams | Developers, automation |
| Customization | Limited to app features | Fully customizable |
| Cost | Telfon subscription + Twilio usage | Twilio usage only |
| WhatsApp | Built-in | Requires setup |
| Call Recording | One-click enable | Requires TwiML config |

Use Direct Twilio for: automated workflows, custom integrations, full API control, cost optimization.

## Setup (5 Minutes)

**Prerequisites**: Twilio account (https://www.twilio.com/try-twilio), Twilio phone number, Telfon account (https://mytelfon.com/).

1. Get Twilio Account SID + Auth Token from https://console.twilio.com/
2. Install Telfon:
   - iOS: https://apps.apple.com/in/app/telfon-twilio-calls-chats/id6443471885
   - Android: https://play.google.com/store/apps/details?id=com.wmt.cloud_telephony.android
   - Chrome: https://chromewebstore.google.com/detail/telfon-twilio-calls/bgkbahmggkomlcagkagcmiggkmcjmgdi
   - Edge: https://microsoftedge.microsoft.com/addons/detail/telfon-virtual-phone-sys/hbdeajgckookmiogfljihebodfammogd
3. Settings > Twilio Integration → enter Account SID, Auth Token, select number(s)

Demo/guides: https://mytelfon.com/demo/

## Number Management

| Scenario | Action |
|----------|--------|
| Numbers already in Twilio | Settings > Phone Numbers — auto-appear, select to activate |
| Buy via Telfon | Phone Numbers > Buy New Number (charged to Twilio account) |
| Unavailable via API (toll-free, short codes) | Contact Twilio support; see `twilio.md` for AI-assisted request |

Numbers always remain in your Twilio account; Telfon provides the interface only.

## Features

| Feature | Path | Notes |
|---------|------|-------|
| Calls (mobile) | Dialer icon → enter number → select outbound number | |
| Calls (Chrome ext) | Click any phone number on webpage | Auto-initiates via Twilio number |
| SMS (single) | Messages > Compose | |
| SMS (bulk) | Broadcasts > New Broadcast → import CSV → schedule/send | Recipients must have opted in |
| Call Recording | Settings > Call Recording → enable per-number or all | Counts against Twilio storage |
| WhatsApp | Settings > WhatsApp → link Business account → scan QR | Approved templates required outside 24h window |
| Voicemail | Settings > Voicemail → enable, record greeting, optional transcription | |
| Call Forwarding | Settings > Call Forwarding → always/busy/no-answer/unreachable rules | |

## Use Cases

| Use Case | Key Setup |
|----------|-----------|
| Sales teams | Per-rep numbers, shared inbound, call recording, Chrome ext for CRM click-to-call |
| Customer support | Toll-free inbound, call forwarding, voicemail, SMS for ticket updates |
| Remote teams | Virtual numbers in multiple countries, mobile app |
| Real estate | Dedicated number per listing, SMS reminders, call tracking |

## Integration with aidevops

```text
AI Workflows → Twilio API → Telfon App
(automation)   (backend)    (user UI)
```

- **AI uses Twilio directly**: automated reminders, OTP, bulk notifications, webhook-triggered messages
- **Users use Telfon**: manual calls, conversational SMS, WhatsApp, reviewing recordings
- **Hybrid**: AI sends reminder → customer replies → webhook logs to CRM → user responds in Telfon

## Pricing

- **Telfon subscription**: https://mytelfon.com/pricing/ (Free Trial / Starter / Professional / Enterprise)
- **Twilio usage** (separate): SMS ~$0.0079/msg, Voice ~$0.014/min, Numbers ~$1.15/mo, Recording ~$0.0025/min — https://www.twilio.com/en-us/pricing
- **Cost tips**: use Messaging Services for bulk SMS, set Twilio spend alerts, review unused numbers monthly

## Troubleshooting

| Issue | Steps |
|-------|-------|
| Can't connect to Twilio | Verify Account SID + Auth Token; check account not suspended; verify number active |
| Poor call quality | WiFi preferred; close bandwidth-heavy apps; check https://status.twilio.com/ |
| SMS not delivering | Verify +1XXXXXXXXXX format; check Telfon > Messages status; review Twilio debugger; 10DLC required for US A2P |
| WhatsApp not sending | Verify Business account connected; check 24h window; use approved templates outside window |

## Security

- Recordings stored in Telfon cloud + Twilio; review Telfon privacy policy
- Strong passwords + 2FA; revoke access for departed team members
- Telfon inherits Twilio compliance certifications; verify for regulated industries

## Alternatives

| App | Strengths | Best For |
|-----|-----------|----------|
| OpenPhone | Team features, shared numbers | Small teams |
| Dialpad | AI features, transcription | Enterprise |
| Grasshopper | Simple, reliable | Solopreneurs |
| RingCentral | Full UCaaS | Large organizations |
| JustCall | CRM integrations | Sales teams |

## Related

- `twilio.md` — Direct Twilio API usage
- `ses.md` — Email integration for multi-channel
- Telfon Help: https://mytelfon.com/support/
