---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1385: Chat Platform Integration Agents

## Origin

- **Created:** 2026-03-03
- **Session:** claude-code:interactive
- **Created by:** human (interactive)
- **Conversation context:** User requested subagent docs for 11 messaging platforms (Telegram, Signal, WhatsApp, iMessage/BlueBubbles, Nostr, Slack, Discord, Google Chat, MS Teams, Nextcloud Talk, Urbit) following the pattern of existing simplex.md, matrix-bot.md, and matterbridge.md. Key requirement: document privacy/security characteristics of each platform so users understand AI training and metadata risks.

## What

Create 11 new subagent docs in `.agents/services/communications/` plus a cross-platform privacy comparison matrix in opsec.md. Each doc provides:

1. **Bot/API integration guide** — how to build a bot on the platform, which SDK/library to use, setup steps, message handling patterns
2. **aidevops runner dispatch integration** — how to wire the bot to aidevops runners (following matrix-bot.md pattern)
3. **Privacy and security assessment** — encryption method, metadata exposure, push notification privacy, AI training data policies, open-source status
4. **Matterbridge bridging notes** — whether the platform has native Matterbridge support or needs an adapter

The cross-platform privacy matrix (t1385.12) gives users a single table to compare all platforms across privacy dimensions, enabling informed decisions about which platforms to use for sensitive communications.

## Why

aidevops currently supports SimpleX, Matrix, XMTP, and Bitchat for chat integration. Users need the same integration patterns for mainstream platforms (Telegram, WhatsApp, Slack, Discord, Teams, Google Chat) and privacy-focused alternatives (Signal, Nostr, Urbit, Nextcloud Talk, iMessage). The privacy documentation is critical because:

- Some platforms (Slack, Discord, Google Chat, Teams) actively use chat data for AI training by default
- Users may not realise that "E2E encrypted" WhatsApp still harvests extensive metadata for Meta's AI
- Self-hosted options (Nextcloud Talk) and decentralized protocols (Nostr, Urbit) offer stronger privacy but with trade-offs
- The opsec.md comparison matrix doesn't yet cover these platforms

## How (Approach)

Each subtask creates one `.agents/services/communications/<platform>.md` file following the established pattern:

**Template structure** (derived from simplex.md):
```
---
description: <platform> — <one-line summary>
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  ...
---

# <Platform>

<!-- AI-CONTEXT-START -->
## Quick Reference
- Type, License, SDK, Bot API, Docs links
- Key differentiator
- When to use vs other protocols (comparison table)
<!-- AI-CONTEXT-END -->

## Architecture (ASCII diagram)
## Installation
## Bot API / SDK Usage
## Access Control
## Security Considerations
  - Encryption method and default
  - Metadata exposure
  - Push notification privacy
  - AI training data policy
  - Open-source status
  - Threat model (protects against / does not protect against)
## Integration with aidevops
## Matterbridge Integration
## Limitations
## Related
```

**Key libraries per platform:**
- Telegram: grammY (TypeScript, MIT, github.com/grammyjs/grammY)
- Signal: signal-cli (Java/native, GPLv3, github.com/AsamK/signal-cli)
- WhatsApp: Baileys (TypeScript, MIT, github.com/WhiskeySockets/Baileys)
- iMessage: BlueBubbles (REST API, bluebubbles.app) + imsg (Swift CLI, github.com/steipete/imsg)
- Nostr: nostr-tools (TypeScript, github.com/nbd-wtf/nostr-tools)
- Slack: @slack/bolt or @slack/web-api (TypeScript, MIT)
- Discord: discord.js (TypeScript, Apache-2.0)
- Google Chat: Google Chat API (HTTP webhook + service account)
- MS Teams: Bot Framework SDK (TypeScript, MIT)
- Nextcloud Talk: Talk Bot API (webhook + OCC CLI)
- Urbit: HTTP API + Ames protocol

**Reference material:**
- OpenClaw channel docs (fetched) for feature coverage and configuration patterns
- Existing simplex.md (954 lines), matrix-bot.md (431 lines), matterbridge.md (470 lines) for structure
- opsec.md for existing privacy comparison patterns

## Acceptance Criteria

- [ ] Each of the 11 platform docs exists at `.agents/services/communications/<platform>.md`
  ```yaml
  verify:
    method: bash
    run: "for f in telegram signal whatsapp imessage nostr slack discord google-chat msteams nextcloud-talk urbit; do test -f .agents/services/communications/$f.md || exit 1; done"
  ```
- [ ] Each doc has YAML frontmatter with `mode: subagent` and `description`
  ```yaml
  verify:
    method: bash
    run: "for f in .agents/services/communications/{telegram,signal,whatsapp,imessage,nostr,slack,discord,google-chat,msteams,nextcloud-talk,urbit}.md; do grep -q 'mode: subagent' \"$f\" || exit 1; done"
  ```
- [ ] Each doc includes a Security Considerations section with encryption, metadata, push notifications, and AI training subsections
  ```yaml
  verify:
    method: bash
    run: "for f in .agents/services/communications/{telegram,signal,whatsapp,imessage,nostr,slack,discord,google-chat,msteams,nextcloud-talk,urbit}.md; do rg -q 'Security Considerations' \"$f\" || exit 1; done"
  ```
- [ ] opsec.md contains a cross-platform privacy comparison table covering all platforms
  ```yaml
  verify:
    method: codebase
    pattern: "Telegram.*Signal.*WhatsApp"
    path: ".agents/tools/security/opsec.md"
  ```
- [ ] AGENTS.md domain index Communications row updated with new platforms
  ```yaml
  verify:
    method: codebase
    pattern: "telegram|signal|whatsapp|imessage|nostr|slack|discord|google-chat|msteams|nextcloud-talk|urbit"
    path: ".agents/AGENTS.md"
  ```
- [ ] subagent-index.toon updated with new entries
- [ ] Lint clean (markdownlint)

## Context & Decisions

- **OpenClaw as inspiration, not dependency**: OpenClaw docs were studied for feature coverage and configuration patterns, but aidevops integrations are direct bot implementations (TypeScript/Bun + helper scripts), not OpenClaw plugins. The architecture follows the existing matrix-bot.md pattern (bot process -> runner dispatch).
- **Privacy documentation is a first-class requirement**: Not just a nice-to-have section. Users need to make informed decisions about which platforms expose their data to AI training. The comparison matrix in opsec.md is the key deliverable for this.
- **Unofficial APIs carry risk**: WhatsApp (Baileys) and iMessage (BlueBubbles) use unofficial/reverse-engineered APIs. Docs must clearly state ToS risks and account ban potential.
- **Urbit is aspirational**: Limited bot tooling exists. The doc will be shorter and more forward-looking than the others.
- **One task per platform**: Enables parallel worker dispatch. Each subtask is independently deliverable.
- **Matterbridge coverage**: Telegram, Signal, WhatsApp, Slack, Discord, MS Teams, Nextcloud Talk all have native Matterbridge support. Nostr, iMessage, Google Chat, Urbit do not.

## Relevant Files

- `.agents/services/communications/simplex.md` — primary template (954 lines, most comprehensive)
- `.agents/services/communications/matrix-bot.md` — runner dispatch integration pattern
- `.agents/services/communications/matterbridge.md` — bridging reference
- `.agents/services/communications/xmtp.md` — protocol comparison pattern
- `.agents/services/communications/bitchat.md` — shorter doc pattern for limited-API platforms
- `.agents/tools/security/opsec.md` — privacy comparison matrix target
- `.agents/AGENTS.md` — domain index to update
- `subagent-index.toon` — index to update

## Dependencies

- **Blocked by:** none
- **Blocks:** future chat bot implementations, multi-channel gateway
- **External:** none (all docs are reference material, no runtime dependencies)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5h | OpenClaw docs, SDK docs, privacy policies per platform |
| Implementation | 33h | 11 platform docs (~3-4h each) + privacy matrix (~3h) + index updates (~1h) |
| Testing | 6h | markdownlint, verify structure, cross-reference consistency |
| **Total** | **44h** | 13 subtasks, parallelizable (11 independent + 2 sequential) |
