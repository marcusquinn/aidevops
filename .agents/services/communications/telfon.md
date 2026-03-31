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

## Quick Reference

- **Website**: https://mytelfon.com/
- **Apps**: iOS, Android, Chrome Extension, Microsoft Edge Add-on
- **Setup time**: ~5 minutes
- **Pricing**: Telfon subscription + Twilio pay-as-you-go usage
- **Best for**: end users, sales/support teams, WhatsApp + SMS in one app, non-technical users managing Twilio numbers
- **Core features**: calls, SMS, WhatsApp, call recording, bulk SMS, multi-number

## Telfon vs Direct Twilio

- **Telfon**: mobile/desktop interface, ~5 minute setup, built-in WhatsApp, one-click recording, limited to app features
- **Direct Twilio**: API/CLI only, requires development, fully customizable, lower software cost, recording/WhatsApp need custom setup
- Use direct Twilio for automated workflows, custom integrations, full API control, or cost optimization. Use Telfon when people need a softphone UI on top of Twilio.

## Setup

**Prerequisites**: Twilio account (https://www.twilio.com/try-twilio), Twilio phone number, Telfon account (https://mytelfon.com/).

1. Get Twilio Account SID + Auth Token from https://console.twilio.com/
2. Install Telfon:
   - iOS: https://apps.apple.com/in/app/telfon-twilio-calls-chats/id6443471885
   - Android: https://play.google.com/store/apps/details?id=com.wmt.cloud_telephony.android
   - Chrome: https://chromewebstore.google.com/detail/telfon-twilio-calls/bgkbahmggkomlcagkagcmiggkmcjmgdi
   - Edge: https://microsoftedge.microsoft.com/addons/detail/telfon-virtual-phone-sys/hbdeajgckookmiogfljihebodfammogd
3. Open **Settings > Twilio Integration**, enter the SID + Auth Token, then select number(s)

Demo and guides: https://mytelfon.com/demo/

## Numbers and Features

- **Numbers already in Twilio**: open **Settings > Phone Numbers**; they auto-appear and can be activated there
- **Buy via Telfon**: **Phone Numbers > Buy New Number**; the charge still lands in the Twilio account
- **Unavailable via API** (toll-free, short codes): contact Twilio support; see `twilio.md` for AI-assisted requests
- Numbers remain in the Twilio account; Telfon is the interface layer

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

## aidevops Usage

- **AI uses Twilio directly** for automated reminders, OTP, bulk notifications, and webhook-triggered messages
- **Users use Telfon** for manual calls, conversational SMS, WhatsApp, and reviewing recordings
- **Hybrid flow**: AI sends reminder → customer replies → webhook logs to CRM → user responds in Telfon

## Pricing, Troubleshooting, Security

- **Telfon subscription**: https://mytelfon.com/pricing/ (Free Trial / Starter / Professional / Enterprise)
- **Twilio usage**: SMS ~$0.0079/msg, Voice ~$0.014/min, Numbers ~$1.15/mo, Recording ~$0.0025/min — https://www.twilio.com/en-us/pricing
- **Cost tips**: use Messaging Services for bulk SMS, set Twilio spend alerts, review unused numbers monthly

| Issue | Steps |
|-------|-------|
| Can't connect to Twilio | Verify Account SID + Auth Token; check account not suspended; verify number active |
| Poor call quality | Prefer Wi-Fi, close bandwidth-heavy apps, check https://status.twilio.com/ |
| SMS not delivering | Verify +1XXXXXXXXXX format; check Telfon > Messages status; review Twilio debugger; 10DLC required for US A2P |
| WhatsApp not sending | Verify Business account connected; check 24h window; use approved templates outside window |

- Recordings are stored in Telfon cloud + Twilio; review the Telfon privacy policy
- Use strong passwords + 2FA and revoke access for departed team members
- Telfon inherits Twilio compliance certifications; verify fit for regulated industries

## Alternatives and Related

| App | Strengths | Best For |
|-----|-----------|----------|
| OpenPhone | Team features, shared numbers | Small teams |
| Dialpad | AI features, transcription | Enterprise |
| Grasshopper | Simple, reliable | Solopreneurs |
| RingCentral | Full UCaaS | Large organizations |
| JustCall | CRM integrations | Sales teams |

- `twilio.md` — direct Twilio API usage
- `ses.md` — email integration for multi-channel
- Telfon Help: https://mytelfon.com/support/
