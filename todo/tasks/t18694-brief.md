## What

Replace the GenAIPro "Candidates Pending Verification" entry in
`.agents/content/media-generation-providers.md` with a verified
"reviewed, do not route" record, and add a general decision check that rejects
gateways backed by pooled consumer subscriptions.

## Why

The original entry (PR #34702) said GenAIPro had no verifiable API contract.
The user supplied the API docs. Its OpenAPI 3.1 spec (the docs page's download
source) documents a real API: bearer auth at `https://genaipro.io/api`;
ElevenLabs-model TTS (`eleven_multilingual_v2` … `eleven_v4`); four further TTS
providers; Veo text/frames/ingredients-to-video; Nano Banana images; and a
"ChatGPT Image" endpoint. It is credit-billed, async with webhooks/WebSocket,
and keeps files for 7 days.

First-party evidence suggests the capacity comes from pooled consumer accounts
rather than official APIs:

- The public `GET /api/packages` lists "ChatGPT Plus" day/week/month packages
  priced in VND with "Free choice of ChatGPT account".
- The public frontend bundle has admin views for ChatGPT accounts, Veo
  accounts with Ultra/Pro tiers, Hotmail, and proxies. It also shows user
  notices such as "Please do not log out of your ChatGPT account from all
  devices".
- Veo costs a flat 1 credit per request, whatever the number of videos.

This carries upstream terms, account-ban, continuity and data-handling risk, so
aidevops should not route client or production work to it.

## How

- `.agents/content/media-generation-providers.md`: rename the section to cover
  reviewed services, record the verified API facts and the evidence above, and
  set the status to "Do not route". Add a Decision Checks bullet: reject routes
  whose capacity comes from shared/resold consumer subscriptions.
- No provider agent is created; routing to it is not recommended.

### Files Scope

- `.agents/content/media-generation-providers.md`

## Acceptance

- The GenAIPro entry cites the verified spec facts and the evidence, with a
  "do not route" status.
- The decision check exists once (`rg -n "consumer subscription"`).
- `markdownlint-cli2` passes on the changed file.

## Verification

`markdownlint-cli2 .agents/content/media-generation-providers.md`

Ref #34700
