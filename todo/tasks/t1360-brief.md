---
mode: subagent
---
# t1360: Email Agent for Mission 3rd-Party Communication

## Origin

- **Created:** 2026-02-28
- **Session:** claude-code:full-loop-t1360
- **Created by:** ai-interactive
- **Parent task:** t1357 (Mission system)
- **Conversation context:** Missions that involve signing up for services, requesting API access, or communicating with vendors need email capabilities. This is a dependent feature of the mission system (p034).

## What

A helper script (`email-agent-helper.sh`) and subagent documentation (`services/email/email-agent.md`) that enable missions to:

1. **Send templated emails** via AWS SES — signup confirmations, API access requests, vendor communications with variable substitution
2. **Receive and parse responses** — poll SES-received emails from S3, convert to structured data
3. **Extract verification codes** — detect OTP codes, confirmation links, and activation URLs from email bodies
4. **Thread conversations** — track multi-message exchanges with vendors using Message-ID/In-Reply-To chains
5. **Integrate with mission credential management** — store extracted credentials in mission state, link conversations to mission IDs

## Why

Missions that involve signing up for third-party services (domain registrars, API providers, hosting) currently require human intervention for every email exchange. This blocks autonomous execution and defeats the purpose of multi-day missions. The email agent closes the loop: mission orchestrator requests a service -> email agent handles the signup conversation -> credentials flow back to the mission.

## How (Approach)

- **Send**: Extend SES helper patterns — use `aws ses send-email` with templated bodies. Templates stored as markdown files with `{{variable}}` substitution.
- **Receive**: SES Receipt Rules deliver to S3 bucket. Helper polls S3 for new messages, downloads `.eml` files, converts via existing `email-to-markdown.py`.
- **Verification extraction**: Regex patterns for common OTP formats (6-digit codes, UUID links, confirmation URLs). AI fallback via `ai-research` MCP for non-standard formats.
- **Threading**: SQLite conversation table keyed by Message-ID, linking to mission ID. Uses existing `email-thread-reconstruction.py` patterns.
- **Config**: `configs/email-agent-config.json.txt` template following procurement-config pattern.

Key files to reference:
- `scripts/ses-helper.sh` — existing SES operations
- `scripts/procurement-helper.sh` — pattern for mission-integrated helper scripts
- `scripts/email-to-markdown.py` — email parsing
- `scripts/email-thread-reconstruction.py` — thread building
- `scripts/email-signature-parser-helper.sh` — contact extraction patterns

## Acceptance Criteria

- [ ] `email-agent-helper.sh send` sends a templated email via SES with variable substitution

  ```yaml
  verify:
    method: codebase
    pattern: "cmd_send"
    path: ".agents/scripts/email-agent-helper.sh"
  ```

- [ ] `email-agent-helper.sh poll` retrieves new emails from S3 and converts to structured data

  ```yaml
  verify:
    method: codebase
    pattern: "cmd_poll"
    path: ".agents/scripts/email-agent-helper.sh"
  ```

- [ ] `email-agent-helper.sh extract-codes` detects verification codes and confirmation links

  ```yaml
  verify:
    method: codebase
    pattern: "cmd_extract_codes"
    path: ".agents/scripts/email-agent-helper.sh"
  ```

- [ ] `email-agent-helper.sh thread` shows conversation history for a mission

  ```yaml
  verify:
    method: codebase
    pattern: "cmd_thread"
    path: ".agents/scripts/email-agent-helper.sh"
  ```

- [ ] Subagent documentation at `services/email/email-agent.md` with YAML frontmatter

  ```yaml
  verify:
    method: codebase
    pattern: "mode: subagent"
    path: ".agents/services/email/email-agent.md"
  ```

- [ ] Config template at `configs/email-agent-config.json.txt`

  ```yaml
  verify:
    method: bash
    run: "test -f configs/email-agent-config.json.txt"
  ```

- [ ] Test suite passes

  ```yaml
  verify:
    method: bash
    run: "bash tests/test-email-agent-helper.sh"
  ```

- [ ] ShellCheck clean on helper script

  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/email-agent-helper.sh"
  ```

- [ ] Updated subagent-index.toon with email-agent entry

  ```yaml
  verify:
    method: codebase
    pattern: "email-agent"
    path: ".agents/subagent-index.toon"
  ```

## Context & Decisions

- Uses SES for both send and receive (SES Receipt Rules -> S3) rather than IMAP polling — consistent with existing SES infrastructure, no new credentials needed
- SQLite for conversation state (consistent with mail-helper.sh pattern) rather than file-based tracking
- Verification code extraction uses regex first, AI fallback second — cheaper and faster for common patterns
- Templates are markdown files with `{{var}}` syntax — simple, readable, no template engine dependency
- Mission integration via `--mission` flag on all commands — links conversations to mission IDs in the database

## Relevant Files

- `.agents/scripts/ses-helper.sh` — existing SES operations to extend
- `.agents/scripts/procurement-helper.sh` — pattern for mission-integrated helper
- `.agents/scripts/email-to-markdown.py` — email parsing pipeline
- `.agents/scripts/email-thread-reconstruction.py` — thread building
- `.agents/scripts/shared-constants.sh` — shared utilities
- `.agents/services/email/email-delivery-test.md` — existing email subagent pattern
- `.agents/subagent-index.toon` — needs email-agent entry

## Dependencies

- **Blocked by:** t1357 (mission system foundation) — partially, the email agent can function standalone
- **Blocks:** Full autonomous mission execution requiring 3rd-party communication
- **External:** AWS SES configured with Receipt Rules, S3 bucket for received emails

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Existing email infrastructure, SES receive patterns |
| Implementation | 2.5h | Helper script, documentation, config template |
| Testing | 45m | Test suite, shellcheck, integration patterns |
| **Total** | **~4h** | |
