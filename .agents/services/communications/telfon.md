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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Telfon - Cloud VoIP & Virtual Phone System

## Quick Reference

- **Website**: https://mytelfon.com/
- **Role**: operator UI on top of Twilio
- **Apps**: iOS, Android, Chrome, Edge
- **Setup time**: ~5 minutes
- **Pricing**: Telfon subscription + Twilio pay-as-you-go
- **Best fit**: sales/support teams that want calls, SMS, WhatsApp, recording, and multi-number handling without building on Twilio directly

## Selection

- Use **Telfon** for fast setup, built-in WhatsApp, one-click recording, and lower operational complexity.
- Use **direct Twilio** for automation, custom integrations, full API control, or lower software spend.
- Numbers stay in Twilio; Telfon is the operator interface.

## Setup

**Prerequisites**: Twilio account (https://www.twilio.com/try-twilio), a Twilio number, and a Telfon account (https://mytelfon.com/).

1. Copy the Twilio Account SID and Auth Token from https://console.twilio.com/.
2. Install Telfon: iOS https://apps.apple.com/in/app/telfon-twilio-calls-chats/id6443471885 · Android https://play.google.com/store/apps/details?id=com.wmt.cloud_telephony.android · Chrome https://chromewebstore.google.com/detail/telfon-twilio-calls/bgkbahmggkomlcagkagcmiggkmcjmgdi · Edge https://microsoftedge.microsoft.com/addons/detail/telfon-virtual-phone-sys/hbdeajgckookmiogfljihebodfammogd
3. Open **Settings > Twilio Integration**, enter the credentials, and activate the required number(s).

Guides and demo: https://mytelfon.com/demo/

## Numbers and Features

- **Existing Twilio numbers**: **Settings > Phone Numbers**; they should auto-appear for activation.
- **Buy in Telfon**: **Phone Numbers > Buy New Number**; Twilio still bills the number.
- **Special inventory**: toll-free, short codes, and similar inventory may require Twilio support; see `twilio.md`.

| Feature | Path | Notes |
|---------|------|-------|
| Calls (mobile) | Dialer → enter number → select outbound number | |
| Calls (Chrome) | Click a phone number on a webpage | Starts via the connected Twilio number |
| SMS | Messages > Compose | |
| Bulk SMS | Broadcasts > New Broadcast | Recipients must have opted in |
| Call Recording | Settings > Call Recording | Per-number or global; Twilio storage billed separately |
| WhatsApp | Settings > WhatsApp | Business account link + approved templates outside the 24h window |
| Voicemail | Settings > Voicemail | Greeting + optional transcription |
| Call Forwarding | Settings > Call Forwarding | Always/busy/no-answer/unreachable rules |

## aidevops Usage

- **AI uses Twilio directly** for reminders, OTP, bulk notifications, and webhook-driven messaging.
- **Humans use Telfon** for manual calls, conversational SMS, WhatsApp, and recording review.
- **Hybrid pattern**: AI starts outreach, the reply lands in system workflows, then a user continues the conversation in Telfon.

## Operations

- **Pricing**: Telfon plans https://mytelfon.com/pricing/ · Twilio usage https://www.twilio.com/en-us/pricing
- **Typical Twilio costs**: SMS ~$0.0079/msg, Voice ~$0.014/min, Numbers ~$1.15/mo, Recording ~$0.0025/min
- **Cost control**: use Messaging Services for bulk SMS, set Twilio spend alerts, and review unused numbers monthly

| Issue | Checks |
|-------|--------|
| Can't connect to Twilio | Verify SID/Auth Token, account status, and number activation |
| Poor call quality | Prefer Wi-Fi, close bandwidth-heavy apps, check https://status.twilio.com/ |
| SMS not delivering | Verify E.164 format, Telfon message status, Twilio debugger, and US 10DLC where required |
| WhatsApp not sending | Verify Business account link, 24h window, and approved templates outside it |

- **Security**: recordings live in Telfon cloud + Twilio; review privacy/compliance posture, enforce strong passwords + 2FA, and remove access for departed staff.

## Alternatives and Related

- **Alternatives**: OpenPhone (small teams), Dialpad (enterprise AI), Grasshopper (solo), RingCentral (full UCaaS), JustCall (CRM-heavy sales).
- **Related**: `twilio.md` for direct API usage, `ses.md` for email workflows, Telfon help https://mytelfon.com/support/
