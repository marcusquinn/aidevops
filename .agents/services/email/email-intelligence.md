---
description: Email intelligence patterns for triage, voice mining, model routing, and response quality control
mode: subagent
tools: { read: true, write: false, edit: false, bash: false, glob: false, grep: false, webfetch: false, task: false }
model: haiku
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Email Intelligence

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Structured, cost-aware AI workflows that preserve user voice
- **Outputs**: triage labels, drafts, confidence checks, emotion tags, FAQ templates
- **Model policy**: cheapest tier meeting quality requirements
- **Core loop**: classify → retrieve context → draft → fact-check → tone check → queue/send

## Model Tier Routing

| Operation | Tier | Rationale |
|---|---|---|
| Priority triage (spam/low/normal/urgent) | `haiku` | Fast classification |
| Intent classification (support/sales/legal/billing) | `haiku` | Deterministic labeling |
| Sentiment/emotion tagging | `haiku` | Short-context extraction |
| Duplicate-thread detection | `haiku` | Lightweight similarity |
| FAQ template ranking | `haiku` | Cheap retrieval scoring |
| Newsletter summarization | `flash` | Large context batches |
| Mailbox pattern extraction | `flash` | Bulk transformation |
| Routine reply drafting | `sonnet` | Style control |
| Multi-question responses | `sonnet` | Mixed-intent reasoning |
| Fact-checking against sources | `sonnet` | Contradiction handling |
| High-stakes communication (exec/legal) | `opus` | Maximum reliability |
| Escalation with trade-off explanation | `opus` | Multi-variable judgment |

**Escalation**: Move up one tier when confidence is low, source coverage incomplete, or error consequence high.

## Voice Mining

### 1) Build training slice

- Sample sent emails across contexts (replies, explanations, follow-ups, corrections, declines)
- Exclude atypical voice (delegated, legal templates, boilerplate)
- Keep chronology to measure style drift

### 2) Extract style features

- **Structure**: length, paragraph rhythm, bullet preference, question density
- **Openings/closings**: greeting forms, sign-offs, CTA framing
- **Lexicon**: recurring phrases, preferred verbs, taboo phrasing, hedging
- **Tone**: directness, warmth, firmness, certainty language
- **Decision style**: how trade-offs are explained

### 3) Distill to voice spec

- Voice card: do, avoid, preferred transitions, sample rewrites
- Store snippets as patterns, not full messages; update monthly

### 4) Apply at generation

- Attach voice card + 2-3 exemplar snippets to drafting prompts
- Require style self-check before final draft
- Fall back to neutral if voice-match confidence is low

## Newsletter Extraction

Use newsletters as domain/style priors, not copy sources.

1. Ingest archive → split into issue-level records
2. Tag sections: hook, explainer, evidence, CTA, closing
3. Extract patterns: headline templates, transitions, evidence framing
4. Capture facts separately from rhetoric
5. Store indexed for retrieval

**Guardrails**: Keep attribution (source, date, topic); prefer paraphrase over reuse; filter stale claims.

## Fact-Checking

**Contract**: Separate claims into factual, interpretive, action-request. Factual claims require source coverage; missing coverage → rewrite with uncertainty or request confirmation.

**Checks**: Verify names, dates, numbers, prices, policy statements; detect contradictions; confirm links match claims.

| Field | Description |
|---|---|
| `claim` | Statement in draft |
| `status` | `verified` / `uncertain` / `contradicted` / `missing-source` |
| `source_refs` | Sources used |
| `action` | Keep / rewrite / remove / escalate |

## Emotion Tagging

**Primary**: `neutral`, `curious`, `confused`, `frustrated`, `angry`, `anxious`, `excited`, `appreciative`
**Secondary**: `urgent`, `defensive`, `skeptical`, `collaborative`

**Response calibration**:
- Frustration/anger → shorten latency, increase acknowledgment, reduce jargon
- Anxiety/confusion → more structure, explicit next steps, reassurance
- Appreciative/excited → maintain momentum, clear CTA, timebox

## Token Efficiency

- AI for high-volume filtering; humans for irreversible/high-cost decisions
- Compact prompts: voice card + thread summary + minimal context
- Cache thread summaries; don't replay full history
- Cheap prefilters (`haiku`) before expensive composition (`sonnet`/`opus`)
- Batch classification; avoid per-message high-tier calls

## FAQ Templates

**Design**: Intent-based entries with question pattern, required variables, canonical answer, confidence gates. Separate facts from phrasing.

**Lifecycle**: Mine frequent questions → draft canonical answer → add voice variants → track usage/failures → retire stale templates.

| Field | Purpose |
|---|---|
| `intent` | What user asks |
| `slots` | Variables needed |
| `answer_core` | Source-backed answer |
| `voice_variants` | Style variants |
| `escalate_if` | Human review conditions |
| `last_verified_at` | Freshness timestamp |

## Continuous Improvement

- **Weekly**: Sample threads for new patterns
- **Monthly**: Refresh voice card and FAQ metrics
- **Quarterly**: Recalibrate model routing with quality/cost data
- **Always**: Record false positives for retraining

## Related

- `services/email/email-agent.md` — mission email execution
- `services/email/mission-email.md` — orchestrator communication patterns
- `tools/context/model-routing.md` — global tier guidance

<!-- AI-CONTEXT-END -->
