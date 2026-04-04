<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1498: Email security agent doc — prompt injection, phishing, executables, secretlint, PrivateBin

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 1 foundation)
- **Conversation context:** Email is an external access vector for communicating with systems. Planning identified critical security concerns: prompt injection via email content, executable attachments, phishing links, credential leakage, and need for secure information sharing.

## What

Create `services/email/email-security.md` agent doc covering:

1. **Prompt injection defense**: emails processed by AI are an attack vector — mandatory scanning with `prompt-guard-helper.sh` before any AI processing of email content
2. **Executable blocking**: never open executable files or files potentially containing executable macros (.exe, .bat, .cmd, .ps1, .vbs, .js, .jar, .msi, .scr, .com, .docm, .xlsm, .pptm)
3. **Link safety**: no following links from untrusted senders, URL reputation checking before click-through
4. **Phishing detection**: DNS verification of sender domains, SPF/DKIM/DMARC validation, known-sender matching
5. **Secretlint integration**: scan outbound emails for accidental credential inclusion
6. **PrivateBin with self-destruct**: recommended method for sending confidential information (not plain email)
7. **S/MIME setup guidance**: certificate acquisition, installation per provider/client
8. **OpenPGP setup guidance**: key generation, Mailvelope/Thunderbird config, public key distribution
9. **Inbound command interface security**: only permitted senders can trigger aidevops tasks via email
10. **Transaction email phishing**: verify authenticity before forwarding receipts/invoices to accounts@

## Why

Email is the #1 attack vector for social engineering and the most likely channel for prompt injection attacks against AI systems. Every email processed by the AI layer must be treated as potentially adversarial. Without explicit security guidance, the system will eventually process a malicious email that manipulates agent behavior.

## How (Approach)

- Agent doc following standard pattern
- Reference existing `tools/security/prompt-injection-defender.md` for scanning patterns
- Reference existing `tools/security/opsec.md` for operational security
- Executable file extension blocklist as a concrete, deterministic rule
- DNS verification patterns using `dig` for SPF/DKIM/DMARC (reuse email-health-check patterns)

## Acceptance Criteria

- [ ] `services/email/email-security.md` exists with comprehensive security guidance
  ```yaml
  verify:
    method: codebase
    pattern: "AI-CONTEXT-START"
    path: ".agents/services/email/email-security.md"
  ```
- [ ] Executable file extension blocklist is explicit and complete
- [ ] Prompt injection scanning requirement documented with `prompt-guard-helper.sh` reference
- [ ] PrivateBin self-destruct workflow documented
- [ ] S/MIME and OpenPGP setup guidance included
- [ ] Permitted sender allowlist pattern for inbound commands

## Context & Decisions

- Prompt injection via email is a real and growing attack vector — mandatory scanning, not optional
- Executable blocking is a deterministic rule (blocklist), not a judgment call — appropriate for a script
- PrivateBin preferred over encrypted email for one-time confidential sharing (simpler, self-destructs)
- S/MIME and OpenPGP are optional enhancements, not requirements — guidance only

## Relevant Files

- `.agents/tools/security/prompt-injection-defender.md` — existing prompt injection defense
- `.agents/tools/security/opsec.md` — operational security guidance
- `.agents/services/email/email-health-check.md` — DNS verification patterns

## Dependencies

- **Blocked by:** none
- **Blocks:** t1510 (inbound command interface needs security rules)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Review existing security docs |
| Implementation | 2.5h | Write comprehensive security agent doc |
| Testing | 15m | Verify completeness |
| **Total** | **3h** | |
