<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1505: Contact sync — extract/update macOS Contacts from email correspondence

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 2 actions)
- **Conversation context:** Emails contain contact information that should update local Address Book records. Existing email-signature-parser-helper.sh extracts contacts — this bridges to macOS Contacts.

## What

Create `scripts/email-contact-sync-helper.sh` that:

1. Extracts contact data from email signatures (reuse existing `email-signature-parser-helper.sh`)
2. Matches against existing macOS Contacts (AddressBook framework via AppleScript or `contacts` CLI)
3. Creates new contacts or updates existing ones with extracted information
4. Handles: name, title, company, phone, email, website
5. Deduplication against existing contacts

## Why

Contact information scattered across emails is invisible. Syncing to the address book makes it searchable and available across all apps.

## How (Approach)

- Shell script wrapping existing email-signature-parser-helper.sh for extraction
- AppleScript for macOS Contacts read/write operations
- Deduplication by email address matching

## Acceptance Criteria

- [ ] `scripts/email-contact-sync-helper.sh` exists and passes ShellCheck
- [ ] Extracts contacts via existing signature parser
- [ ] Creates/updates macOS Contacts via AppleScript
- [ ] Deduplicates by email address

## Dependencies

- **Blocked by:** t1494 (Apple Mail helper for AppleScript patterns)
- **Blocks:** none
- **External:** macOS with Contacts app

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 3h | Shell + AppleScript integration |
| Testing | 1h | Test with real contacts |
| **Total** | **4h** | |
