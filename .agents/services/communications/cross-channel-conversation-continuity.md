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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cross-Channel Conversation Continuity

One relationship history per person across email, Matrix, SimpleX, Slack, CLI, and similar channels — no private context leaks between unrelated identities. Resolve identity first, then continue the conversation. Never infer continuity from display name alone — require explicit channel mapping and explicit confidence level.

Continuity key: entity ID in `memory.db` (Layer 2: `entities`+`entity_channels` → Layer 1: `conversations` → Layer 0: `interactions`).

## Workflow

1. Resolve incoming sender and channel to an entity.
2. If unresolved, suggest candidates and require confirmation. Never merge entities automatically; keep confidence explicit (`suggested` until verified).
3. Reuse existing conversation when topic and participants still align; start new when topic or audience changed.
4. Log interaction to Layer 0 with channel metadata.
5. Load context from same entity before replying. Use `--privacy-filter` for shared or lower-trust channels. Keep irreversible decisions (identity merges, external sends) human-verifiable.

**Email normalization** (`entity-helper.sh`): trim whitespace, lowercase, strip plus aliases. Example: ` User+alerts@Example.COM ` → `user@example.com`

## Commands

```bash
entity-helper.sh resolve --channel email --channel-id "sender@example.com"
entity-helper.sh suggest email "sender@example.com"
entity-helper.sh link <entity_id> --channel email --channel-id "sender@example.com" --verified
entity-helper.sh log-interaction <entity_id> --channel email --channel-id "sender@example.com" --content "..."
entity-helper.sh context <entity_id> --channel email --limit 20 --privacy-filter
```

## Threading

| Condition | Action |
|-----------|--------|
| Same topic, recent history (≤30 days), stable recipients | Reply in existing thread |
| New topic, dormant thread, or audience changed | Start new thread |

When starting a new thread, reference the old thread in the first line.

## Verification

- `entity-helper.sh resolve` returns expected entity for known email aliases.
- `entity-helper.sh suggest email` proposes known candidates for partial matches.
- Context output includes relevant multi-channel interactions for same entity.
- No unverified identity assumptions introduced automatically.
