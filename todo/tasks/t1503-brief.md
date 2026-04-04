<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1503: Sieve rule generator — auto-sort rules from triage patterns

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 2 intelligence)
- **Conversation context:** Triage patterns should be codified into server-side Sieve rules for automatic sorting on compatible mail servers (Cloudron, Fastmail, etc.).

## What

Create `scripts/email-sieve-helper.sh` that:

1. Generates Sieve filter rules from triage classification patterns
2. Deploys rules to compatible mail servers via ManageSieve protocol
3. Supports Cloudron mailbox Sieve configuration
4. Generates rules for: sender-based sorting, subject pattern matching, mailing list detection, transaction email routing

## Why

Server-side rules sort email before the client sees it, reducing triage load. Codifying AI triage patterns into Sieve rules means the AI only needs to handle novel/ambiguous emails.

## How (Approach)

- Shell script generating Sieve syntax from pattern definitions
- ManageSieve protocol support for remote deployment (Python `sievelib` or direct TCP)
- Pattern input from triage results (t1502)

## Acceptance Criteria

- [ ] `scripts/email-sieve-helper.sh` exists and passes ShellCheck
- [ ] Generates valid Sieve syntax
- [ ] Supports at least: fileinto, redirect, flag actions

## Dependencies

- **Blocked by:** t1502 (triage patterns to codify)
- **Blocks:** none
- **External:** ManageSieve-compatible mail server for deployment testing

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 3h | Sieve generation + ManageSieve deployment |
| Testing | 1h | Validate generated rules |
| **Total** | **4h** | |
