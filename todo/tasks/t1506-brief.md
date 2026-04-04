<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1506: Calendar event creation from email — detect agreed dates, create events

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 2 actions)
- **Conversation context:** When dates/times are agreed in email threads, calendar events should be created automatically.

## What

Create functionality in email-triage-helper.sh (or standalone) that:

1. Detects agreed dates/times in email threads (AI extraction)
2. Creates calendar events via AppleScript (macOS Calendar) or `gws calendar +insert` (Google Calendar)
3. Includes relevant email context in event notes
4. Adds attendees from email participants

## Why

Agreed dates that don't become calendar events get forgotten. Bridging email→calendar closes this gap.

## How (Approach)

- AI extraction of date/time agreements using haiku (structured extraction)
- AppleScript for macOS Calendar or gws CLI for Google Calendar
- Event creation with email thread reference in notes

## Acceptance Criteria

- [ ] Date/time extraction from email threads works
- [ ] Calendar events created via AppleScript or gws
- [ ] Event includes attendees and email context

## Dependencies

- **Blocked by:** t1493 (mailbox helper), t1494 (Apple Mail/AppleScript patterns)
- **Blocks:** none
- **External:** macOS Calendar or Google Calendar access

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 3h | AI extraction + calendar integration |
| Testing | 1h | Test with real email threads |
| **Total** | **4h** | |
