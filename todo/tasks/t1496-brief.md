<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1496: Email template library — FAQs, holding patterns, follow-ups, notifications

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 1 foundation)
- **Conversation context:** Planning identified need for reusable email templates covering common patterns: FAQ answers, acknowledgements, follow-ups, reminders, project updates, formal/casual variants.

## What

Create `templates/email/` directory with markdown template files covering:

1. **Holding patterns**: acknowledgement of receipt, managing expectations for full response
2. **Follow-ups**: delayed response confirmation, awareness and pending response
3. **Reminders**: polite reminder for outstanding requests (escalating tone over iterations)
4. **Project updates**: status notification to stakeholders
5. **FAQ answers**: templated responses to common questions (extensible per-project)
6. **Meeting scheduling**: propose times, confirm dates
7. **Introduction/referral**: introduce two parties
8. **Thank you / appreciation**: post-meeting, post-delivery
9. **Formal variants**: legal-adjacent, contractual, official
10. **Casual variants**: colleague, familiar contact, internal team

Each template uses `{{VARIABLE}}` placeholders (matching existing email-agent template system). Templates include guidance comments on when to use formal vs casual variant.

Also create a **common attachments library** concept: `~/.aidevops/.agent-workspace/email-attachments/` for frequently-sent files (company info, rate cards, brochures) with a manifest tracking what's available.

## Why

Templated responses save time and ensure consistency. The existing mission-email templates are vendor-communication focused. General business communication needs broader coverage. FAQ templating is particularly high-leverage — answer once, reuse many times.

## How (Approach)

- Markdown templates in `.agents/templates/email/` following existing pattern
- Each template: first line `# Template Description`, then `Subject:` line, then body with `{{PLACEHOLDERS}}`
- Formal/casual variants as separate files with `-formal` / `-casual` suffix
- Common attachments manifest: `email-attachments-manifest.json` listing available files

## Acceptance Criteria

- [ ] At least 10 template files created in `.agents/templates/email/`
  ```yaml
  verify:
    method: bash
    run: "ls .agents/templates/email/*.md 2>/dev/null | wc -l | xargs test 10 -le"
  ```
- [ ] Each template has `Subject:` line and `{{VARIABLE}}` placeholders
- [ ] Formal and casual variants exist for at least 3 template types
- [ ] Common attachments manifest structure documented
- [ ] Templates follow one-paragraph-per-sentence rule

## Context & Decisions

- Extends existing template system from email-agent-helper.sh (same `{{VAR}}` syntax)
- FAQ templates are project-specific — provide a framework and examples, not exhaustive list
- Escalating reminder tone: polite → firm → final notice (3 levels)

## Relevant Files

- `.agents/templates/email/` — existing template directory (may need creation)
- `.agents/services/email/email-agent.md:137-163` — existing template format documentation

## Dependencies

- **Blocked by:** none
- **Blocks:** t1495 (composition helper uses templates)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Review existing templates |
| Implementation | 3h | Write 10+ templates with variants |
| Testing | 15m | Validate placeholder syntax |
| **Total** | **3.5h** | |
