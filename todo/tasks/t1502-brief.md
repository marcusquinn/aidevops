<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1502: Email triage engine — classify, prioritize, detect reports, flag phishing

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 2 intelligence)
- **Conversation context:** High email volume requires AI triage: classify by urgency/category, detect reports needing attention, identify genuine opportunities vs spam, flag phishing.

## What

Create `scripts/email-triage-helper.sh` that processes inbox messages and:

1. **Classifies** by category: Primary, Transactions, Updates, Promotions, Junk/Spam
2. **Prioritizes** by urgency: Critical (action needed today), High (action needed this week), Normal, Low (FYI only)
3. **Detects reports** needing attention: SEO reports, expiry notifications, renewal considerations, optimization inspiration
4. **Identifies opportunities**: genuine business opportunities vs spam (source authentication via DNS checks)
5. **Flags phishing**: sender domain verification, SPF/DKIM/DMARC checks, known-sender matching
6. **Creates todos**: for emails requiring action, create aidevops tasks with appropriate priority
7. **Emotion tags**: classify emotional tone for response calibration

Uses haiku for bulk triage (cost-efficient), sonnet for ambiguous cases requiring judgment.

## Why

Humans spend 2+ hours daily on email triage. AI can do this in minutes at haiku cost. The triage engine is the highest-leverage email automation — it multiplies human attention by filtering noise.

## How (Approach)

- Shell script orchestrating: fetch headers via email-mailbox-helper.sh → classify via ai-research (haiku) → apply flags/moves → create todos for actionable items
- Phishing detection: reuse email-health-check-helper.sh DNS verification patterns
- Report detection: pattern matching on sender domains + subject lines for known report types
- Prompt injection scanning: mandatory before AI processing of any email content

## Acceptance Criteria

- [ ] `scripts/email-triage-helper.sh` exists and passes ShellCheck
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/email-triage-helper.sh"
  ```
- [ ] Classifies emails into 5 categories
- [ ] Assigns urgency levels
- [ ] Detects phishing via DNS verification
- [ ] Creates todos for actionable emails
- [ ] Uses prompt-guard-helper.sh before AI processing
- [ ] Uses haiku for bulk triage, sonnet for ambiguous

## Dependencies

- **Blocked by:** t1493 (mailbox helper), t1497 (mailbox guidance), t1498 (security rules), t1500 (intelligence guidance)
- **Blocks:** t1503 (Sieve rule generation from triage patterns)
- **External:** IMAP credentials, ai-research MCP tool

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 5h | Shell orchestration + AI classification pipeline |
| Testing | 2h | Test with real inbox, verify classification accuracy |
| **Total** | **7h** | |
