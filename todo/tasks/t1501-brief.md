<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1501: Voice mining script — extract user writing patterns from existing mailbox

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 2 intelligence)
- **Conversation context:** AI-composed emails sound generic without learning the user's voice. Mining existing sent mail extracts patterns for personalized composition.

## What

Create `scripts/email-voice-miner.py` — analyze sent mail folder to extract and condense user writing patterns into a style guide stored at `~/.aidevops/.agent-workspace/email-intelligence/voice-profile-{account}.md`. Extracts:

1. Greeting patterns (formal/casual distribution, specific phrases)
2. Closing patterns (sign-offs, signature usage)
3. Sentence structure (average length, complexity, paragraph patterns)
4. Vocabulary preferences (common words, industry jargon, avoided words)
5. Tone distribution (formal ↔ casual ratio across recipients)
6. Response timing patterns (how quickly user typically replies)
7. CC/BCC habits
8. Attachment patterns

Uses sonnet for analysis (one-time per mailbox, worth the cost). Output is a condensed markdown style guide that the composition helper (t1495) references.

## Why

The difference between "AI wrote this" and "this sounds like me" is voice mining. One-time cost per mailbox, ongoing value for every composed email.

## How (Approach)

- Python script using email_imap_adapter.py (t1493) to read sent folder
- Sample 50-100 recent sent emails (configurable)
- Use ai-research MCP tool with sonnet for pattern extraction
- Output condensed style guide as markdown
- Store at `~/.aidevops/.agent-workspace/email-intelligence/` with 600 permissions

## Acceptance Criteria

- [ ] `scripts/email-voice-miner.py` exists
  ```yaml
  verify:
    method: bash
    run: "test -f .agents/scripts/email-voice-miner.py"
  ```
- [ ] Produces voice profile markdown file
- [ ] Samples configurable number of sent emails
- [ ] Privacy: voice profile contains patterns, never raw email content

## Dependencies

- **Blocked by:** t1493 (mailbox helper for reading sent folder), t1500 (intelligence guidance)
- **Blocks:** t1495 (composition helper references voice profile)
- **External:** IMAP credentials, ai-research MCP tool

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 4h | Python script + AI analysis pipeline |
| Testing | 1h | Test with real sent folder |
| **Total** | **5h** | |
