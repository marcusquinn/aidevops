---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1902: Compressed context notation for chat app memory

## Origin

- **Created:** 2026-04-07
- **Session:** claude-code (interactive)
- **Created by:** marcus (human, ai-interactive)
- **Conversation context:** User shared [milla-jovovich/mempalace](https://github.com/milla-jovovich/mempalace) repo for evaluation. Analysis identified their AAAK compression dialect as the one concept worth adapting — not the format itself, but the principle of token-budgeted structured notation for context injection. Applied to aidevops chat app integrations where `conversation-helper.sh context` injects ~400-800 tokens of English prose per LLM call.

## What

A `--compact` output mode for `conversation-helper.sh context` and `entity-helper.sh` that produces structured shorthand notation LLMs parse natively, reducing per-message context injection from ~400-800 tokens to ~180-260 tokens. A new `compress.sh` module in `.agents/scripts/memory/` provides the compression functions. A `compact_summary` column in `conversation_summaries` stores pre-compressed notation at summarization time.

## Why

Chat app integrations (Matrix, SimpleX, Telegram) inject conversation context into every LLM call. At 50 exchanges/day, current prose context costs 20K-40K tokens/day just on repeated injection. Compressed notation cuts this by 50-65% (to 9K-13K tokens/day) while preserving all actionable information. MemPalace benchmarks demonstrate LLMs achieve 100% recall on structured notation — the concept is proven.

## Tier

`tier:standard`

**Tier rationale:** Multi-file implementation touching conversation-helper, entity-helper, a new module, schema migration, and tests. Requires judgment on notation format and integration with existing summarization pipeline. Not simple enough for copy-paste; not novel enough for reasoning tier.

## How (Approach)

### Files to Modify

- NEW: `.agents/scripts/memory/compress.sh` — model on `.agents/scripts/memory/_common.sh` for structure (sourced module, not standalone)
- EDIT: `.agents/scripts/conversation-helper.sh:749-777` — add `--compact` flag parsing alongside existing `--json`/`--privacy-filter`
- EDIT: `.agents/scripts/conversation-helper.sh:607-670` — add compact branch to `_context_text_profile_and_summary`
- EDIT: `.agents/scripts/conversation-helper.sh:676-707` — add compact branch to `_context_text_recent_messages`
- EDIT: `.agents/scripts/conversation-helper.sh:710-738` — add compact branch to `_context_output_text`
- EDIT: `.agents/scripts/conversation-helper.sh:920-977` — extend `_summarise_call_ai` to also produce compact notation
- EDIT: `.agents/scripts/conversation-helper.sh:~100-130` (schema) — add `compact_summary TEXT` column to `conversation_summaries`
- EDIT: `.agents/scripts/entity-helper.sh` — add `--compact` flag to profile output
- EDIT: `.agents/reference/entity-memory-architecture.md` — document compact format and token budget tiers

### Compact notation format

```
CTX:<name>|<type>|<channel>|<topic>
PREF:<val1>+<val2>|<val3>|<val4>
SUM:<topic>|decided:<X>|concern:<Y>|resolved:<Z>
ACT:<action1>|<action2>
MSG[-N]:<kw1>→<kw2>→<kw3>
```

### Token budget tiers

| Tier | Content | Budget | When |
|---|---|---|---|
| T0 | Entity + key preferences | ~30 tokens | Every message |
| T1 | Compressed summary + actions | ~50-80 tokens | Every message |
| T2 | Last 3-5 messages compressed | ~100-150 tokens | Every message |
| T3 | Full semantic search | Unlimited | On explicit recall |

### compress.sh functions

- `compress_entity_profile()` — entity profiles → `PREF:` line
- `compress_summary()` — prose summary → `SUM:` line with `topic|decided:|concern:|resolved:` structure
- `compress_recent_messages()` — recent messages → `MSG[-N]:kw→kw→kw` directional flow
- `compress_context()` — orchestrator calling all above with token budget enforcement

### Key design decisions

- Compress at summarization time (store `compact_summary` in DB) for summaries; compress at load time for entity profiles and recent messages (these change frequently)
- Token budget enforcement: truncate to character budget (chars/4 ≈ tokens), not message count
- No new dependencies — pure bash string manipulation
- Backward compatible: `--compact` is opt-in, existing output unchanged

## Acceptance Criteria

1. `conversation-helper.sh context <id> --compact` produces structured notation
2. `entity-helper.sh context <id> --compact` produces compressed profile
3. Compact output ≤260 tokens for conversation with 10+ interactions and 5+ profile keys
4. Existing `cmd_context` (no `--compact`) output unchanged
5. `compact_summary` column added via schema migration in `init_conv_db`
6. `compress.sh` passes `shellcheck` with zero violations
7. Function-level tests in `tests/`

## Verification

```bash
shellcheck .agents/scripts/memory/compress.sh
shellcheck .agents/scripts/conversation-helper.sh
shellcheck .agents/scripts/entity-helper.sh
bash tests/test-conversation-helper.sh --verbose
bash tests/test-entity-helper.sh --verbose
```

## Context

- MemPalace research: AAAK dialect at `mempalace/dialect.py`, layers at `mempalace/layers.py`
- Our context loading: `conversation-helper.sh:607-824` (`_context_text_profile_and_summary`, `_context_text_recent_messages`, `cmd_context`)
- Our entity model: `.agents/reference/entity-memory-architecture.md`
- Our memory system: `.agents/reference/memory.md`
- Compress module pattern: `.agents/scripts/memory/_common.sh`
