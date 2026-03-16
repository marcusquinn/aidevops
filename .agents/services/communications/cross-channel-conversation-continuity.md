---
description: Entity-aware conversation continuity guidance across email and messenger channels
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: false
  task: false
---

# Cross-Channel Conversation Continuity

## Goal

Maintain one coherent relationship history per person across channels (email, Matrix, SimpleX, Slack, CLI) without leaking private context between unrelated identities.

The continuity key is the entity ID in `memory.db`:

- Layer 2 identity: `entities` + `entity_channels`
- Layer 1 threads: `conversations`
- Layer 0 evidence: `interactions`

## Core Principle

Resolve identity first, then continue the conversation.

Do not infer continuity from display name alone. Use explicit channel mapping and confidence levels.

## Continuity Workflow

1. Resolve incoming sender/channel to an entity.
2. If no entity exists, suggest candidates and require confirmation.
3. Reuse existing conversation when topic + participants align.
4. Start a new conversation when topic or audience has changed.
5. Log the interaction to Layer 0 with channel metadata.
6. Load context from the same entity before responding.

## Email-Specific Identity Rules

Use `entity-helper.sh` email normalization behavior for stable matching:

- trim whitespace
- lowercase address
- strip plus aliases from local part

Examples:

- ` User+alerts@Example.COM ` -> `user@example.com`
- `sales+q1@company.com` -> `sales@company.com`

This normalization improves continuity when the same person uses tagged aliases for filtering.

## Recommended Command Pattern

```bash
# Resolve sender to known entity
entity-helper.sh resolve --channel email --channel-id "sender@example.com"

# If unresolved, check suggestions
entity-helper.sh suggest email "sender@example.com"

# Confirm link once validated
entity-helper.sh link <entity_id> --channel email --channel-id "sender@example.com" --verified

# Log message on the resolved entity
entity-helper.sh log-interaction <entity_id> --channel email --channel-id "sender@example.com" --content "..."

# Load continuity context before replying
entity-helper.sh context <entity_id> --channel email --limit 20 --privacy-filter
```

## Channel Boundary Guardrails

- Never merge entities automatically.
- Keep confidence explicit: `suggested` until verified.
- Use `--privacy-filter` when rendering context to shared or lower-trust channels.
- Keep irreversible decisions (identity merges, external sends) human-verifiable.

## Threading Decision Guide

Reply in existing thread when:

- same topic
- recent history (roughly <= 30 days)
- recipient set is stable

Start a new thread when:

- new decision/request topic
- long dormant thread
- materially different audience

When starting new thread, reference the old thread in the first line for continuity.

## Verification Checklist

- `entity-helper.sh resolve` returns the expected entity for known email aliases.
- `entity-helper.sh suggest email` proposes known candidates for partial matches.
- Context output includes relevant multi-channel interactions for the same entity.
- No unverified identity assumptions are introduced automatically.
