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

Maintain one relationship history per person across email, Matrix, SimpleX, Slack, CLI, and similar channels without leaking private context between unrelated identities.

Use the entity ID in `memory.db` as the continuity key:

- Layer 2 identity: `entities` + `entity_channels`
- Layer 1 threads: `conversations`
- Layer 0 evidence: `interactions`

## Core Rule

Resolve identity first, then continue the conversation.

Never infer continuity from display name alone. Require explicit channel mapping and an explicit confidence level.

## Workflow

1. Resolve the incoming sender and channel to an entity.
2. If unresolved, suggest candidates and require confirmation.
3. Reuse an existing conversation when topic and participants still align.
4. Start a new conversation when topic or audience changed.
5. Log the interaction to Layer 0 with channel metadata.
6. Load context from the same entity before replying.

## Email Identity Rules

Use `entity-helper.sh` email normalization for stable matching:

- trim whitespace
- lowercase the address
- strip plus aliases from the local part

Examples:

- ` User+alerts@Example.COM ` -> `user@example.com`
- `sales+q1@company.com` -> `sales@company.com`

This preserves continuity when the same person uses tagged aliases for filtering.

## Command Pattern

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

## Threading Guide

Reply in the existing thread when:

- topic is the same
- history is recent (roughly <= 30 days)
- recipient set is stable

Start a new thread when:

- the decision or request topic is new
- the thread is long dormant
- the audience changed materially

When starting a new thread, reference the old thread in the first line for continuity.

## Verification Checklist

- `entity-helper.sh resolve` returns the expected entity for known email aliases.
- `entity-helper.sh suggest email` proposes known candidates for partial matches.
- Context output includes relevant multi-channel interactions for the same entity.
- No unverified identity assumptions are introduced automatically.
