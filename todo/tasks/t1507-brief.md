<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1507: Receipt/invoice forwarding with phishing protection

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 2 actions)
- **Conversation context:** Transaction receipt/invoice emails not sent to accounts@ should be forwarded there, but only after phishing verification.

## What

Add receipt/invoice detection and forwarding to email-triage-helper.sh (t1502):

1. Detect transaction emails (receipts, invoices, payment confirmations)
2. Verify sender authenticity: DNS checks (SPF/DKIM/DMARC), known sender matching
3. Forward verified transaction emails to accounts@ address
4. Flag suspicious transaction emails for manual review (never auto-forward)
5. Attachments from accounting systems may need to be created/attached

## Why

Financial documents scattered across personal inboxes create accounting gaps. Centralized forwarding to accounts@ ensures nothing is missed, but phishing protection prevents forwarding malicious invoices.

## How (Approach)

- Extend triage engine (t1502) with transaction email detection
- Reuse email-health-check DNS verification for sender authentication
- Forward via email-compose-helper.sh (t1495)

## Acceptance Criteria

- [ ] Transaction email detection works (receipts, invoices, payment confirmations)
- [ ] Sender authenticity verified before forwarding
- [ ] Suspicious emails flagged, not forwarded
- [ ] Forwarding to configurable accounts@ address

## Dependencies

- **Blocked by:** t1502 (triage engine), t1495 (composition for forwarding)
- **Blocks:** none
- **External:** accounts@ mailbox configured

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 2.5h | Detection + verification + forwarding |
| Testing | 1h | Test with real transaction emails |
| **Total** | **3.5h** | |
