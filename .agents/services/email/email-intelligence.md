---
description: Email intelligence patterns for triage, voice mining, model routing, and response quality control
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
  webfetch: false
  task: false
model: haiku
---

# Email Intelligence

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Turn inbox traffic into structured, cost-aware AI workflows that preserve user voice
- **Primary outputs**: triage labels, draft quality, confidence checks, emotion tags, reusable FAQ templates
- **Default model policy**: route to the cheapest tier that can still meet quality requirements
- **Core loop**: classify -> retrieve context -> draft -> fact-check -> tone check -> queue/send

## Model Tier Routing (Operation -> Tier -> Rationale)

| Operation | Tier | Why this tier |
|---|---|---|
| Inbox priority triage (spam, low, normal, urgent) | `haiku` | Fast classification with low reasoning depth |
| Intent classification (support, sales, legal, billing, personal) | `haiku` | Deterministic labeling and taxonomy mapping |
| Sentiment/emotion tagging for inbound mail | `haiku` | Structured extraction and short-context tagging |
| Duplicate-thread detection | `haiku` | Lightweight similarity + metadata checks |
| FAQ template retrieval candidate ranking | `haiku` | Cheap retrieval scoring over known template set |
| Newsletter corpus summarization | `flash` | Efficient processing of large context batches |
| Mailbox pattern extraction (phrase frequency, openings, closings) | `flash` | Bulk transformation across many threads |
| Routine reply drafting from known patterns | `sonnet` | Better style control and instruction following |
| Ambiguous multi-question responses | `sonnet` | Stronger reasoning across mixed intents |
| Fact-checking assertions against provided sources | `sonnet` | Verification logic and contradiction handling |
| High-stakes external communication (executive, legal-adjacent) | `opus` | Maximum reliability for nuanced stakes |
| Escalation recommendation with trade-off explanation | `opus` | Multi-variable judgment and risk framing |

**Escalation rule**: Start at the listed tier. Escalate one tier up when confidence is below threshold, source coverage is incomplete, or consequence of error is high.

## Voice Mining Methodology

### 1) Build a representative training slice

- Sample sent emails across contexts: short replies, long explanations, follow-ups, corrections, and declines
- Exclude threads with known atypical voice (delegated responses, legal templates, copied boilerplate)
- Keep chronology so style drift over time is measurable

### 2) Extract style features

- **Structure**: typical length, paragraph rhythm, bullet preference, question density
- **Openings/closings**: greeting forms, sign-off variants, CTA framing
- **Lexicon**: recurring phrases, preferred verbs, taboo phrasing, hedging patterns
- **Tone profile**: directness, warmth, firmness, certainty language
- **Decision style**: how trade-offs and constraints are explained

### 3) Distill to a compact voice spec

- Write a short voice card with: do, avoid, preferred transitions, and sample rewrites
- Store reusable snippets as patterns rather than full-message copies
- Update monthly or after major role/context changes

### 4) Apply at generation time

- Attach voice card + 2-3 nearest exemplar snippets to each drafting prompt
- Require style self-check before final draft ("what differs from target voice")
- Fall back to neutral style if confidence in voice match is low

## Newsletter-as-Training-Material Extraction

Use high-quality newsletters as domain and style priors, not as copy sources.

### Extraction workflow

1. Ingest newsletter archive and split into issue-level records
2. Tag each section by function: hook, explainer, evidence, CTA, closing
3. Extract reusable patterns: headline templates, transition devices, evidence framing
4. Capture factual claims separately from rhetoric
5. Store in an indexed library for retrieval during drafting

### Guardrails

- Keep attribution metadata (source, date, topic)
- Prefer paraphrased pattern transfer over direct text reuse
- Filter stale or unverifiable claims before adding to retrieval store

## Fact-Checking Before Send

### Verification contract

- Separate claims into: factual, interpretive, and action-request
- Factual claims require source coverage before send
- When coverage is missing, rewrite with uncertainty language or request confirmation

### Practical checks

- Verify names, dates, numbers, prices, and policy statements
- Detect internal contradictions within the draft
- Confirm links and referenced documents match the claim

### Output schema (recommended)

| Field | Description |
|---|---|
| `claim` | The exact statement in the draft |
| `status` | `verified`, `uncertain`, `contradicted`, `missing-source` |
| `source_refs` | Source IDs or links used to evaluate the claim |
| `action` | Keep, rewrite, remove, or escalate |

## Emotion Tagging for Response Calibration

Tag inbound messages with one primary and optional secondary emotions:

- Primary set: `neutral`, `curious`, `confused`, `frustrated`, `angry`, `anxious`, `excited`, `appreciative`
- Secondary modifiers: `urgent`, `defensive`, `skeptical`, `collaborative`

Use tags to adjust response policy:

- Higher frustration/anger -> shorten latency, increase acknowledgment, reduce jargon
- Anxiety/confusion -> increase structure, explicit next steps, reassurance
- Appreciative/excited -> maintain momentum with clear CTA and timebox

## Token Efficiency Principles

- **AI bandwidth > human bandwidth**: use AI for high-volume filtering; reserve human attention for irreversible or high-cost decisions
- Keep prompts compact: voice card, current thread summary, and minimal needed context only
- Reuse cached summaries for long threads instead of replaying full history each time
- Run cheap prefilters (`haiku`) before expensive composition (`sonnet`/`opus`)
- Batch similar classification tasks; do not invoke high-tier models per message by default

## FAQ Template System

### Design

- Store templates as intent-based entries: question pattern, required variables, canonical answer, confidence gates
- Separate stable facts from phrasing so facts update without rewriting style examples

### Lifecycle

1. Mine frequent resolved questions from mailbox history
2. Draft canonical answer with source references
3. Add variation examples in target voice
4. Track usage, edits, and failure reasons
5. Retire templates with persistent low confidence or stale facts

### Minimum template shape

| Field | Purpose |
|---|---|
| `intent` | What user is asking |
| `slots` | Variables needed to answer |
| `answer_core` | Source-backed factual answer |
| `voice_variants` | Optional style variants |
| `escalate_if` | Conditions requiring human review |
| `last_verified_at` | Freshness timestamp |

## Mailbox Training and Continuous Improvement

- Weekly: sample recent sent and received threads for new patterns
- Monthly: refresh voice card and FAQ confidence metrics
- Quarterly: recalibrate model routing with observed quality/cost outcomes
- Always record false positives (bad triage/emotion labels) for retraining prompts

## Related

- `services/email/email-agent.md` - mission email execution and thread handling
- `services/email/mission-email.md` - orchestrator-focused mission communication patterns
- `tools/context/model-routing.md` - global model tier guidance and fallback rules

<!-- AI-CONTEXT-END -->
