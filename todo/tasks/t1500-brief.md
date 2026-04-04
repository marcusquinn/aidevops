<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1500: Email intelligence agent doc — triage, voice mining, model routing, emotion tagging

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 2 intelligence)
- **Conversation context:** Planning identified need for AI layer guidance: model tier routing per operation, voice mining methodology, newsletter-as-training-material extraction, fact-checking, emotion tagging, token efficiency.

## What

Create `services/email/email-intelligence.md` agent doc covering:

1. Model tier routing table: haiku for triage/classification, sonnet for routine drafts, opus for important composition
2. Voice mining methodology: analyze existing mailbox to extract writing patterns, tone, vocabulary, greeting/closing preferences
3. Newsletter analysis: extract training material from well-crafted newsletters for domain knowledge or email style examples
4. Fact-checking: verify assertions in emails and replies before sending
5. Emotion tagging: classify emotional tone of inbound emails for priority/response calibration
6. Token efficiency: AI bandwidth > human bandwidth, preserve human attention for necessary decisions only
7. FAQ template system: how to build and maintain FAQ answer library
8. Mailbox training: mining existing mailboxes for user habits and improvement potential

## Why

This is the strategic guidance that makes email AI operations cost-efficient and high-quality. Without model routing guidance, every email operation defaults to the most expensive model. Without voice mining, AI-composed emails sound generic instead of matching the user's style.

## How (Approach)

- Agent doc following standard pattern
- Model routing as a concrete table (operation → model tier → rationale)
- Voice mining as a methodology section (what to extract, how to condense, where to store)

## Acceptance Criteria

- [ ] `services/email/email-intelligence.md` exists with AI-CONTEXT-START/END markers
  ```yaml
  verify:
    method: codebase
    pattern: "AI-CONTEXT-START"
    path: ".agents/services/email/email-intelligence.md"
  ```
- [ ] Model routing table with at least 10 operation→tier mappings
- [ ] Voice mining methodology documented
- [ ] Token efficiency principles documented

## Relevant Files

- `.agents/tools/context/model-routing.md` — existing model routing guidance

## Dependencies

- **Blocked by:** none
- **Blocks:** t1501 (voice mining script), t1505 (triage engine)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 2.5h | Write comprehensive agent doc |
| **Total** | **2.5h** | |
