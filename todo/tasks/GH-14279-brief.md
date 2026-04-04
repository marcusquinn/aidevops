<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GH#14279: Tighten `.agents/scripts/commands/email-inbox.md`

## Session Origin

Interactive `/full-loop` run for GitHub issue #14279 under the headless continuation contract.

## What

Restructure `.agents/scripts/commands/email-inbox.md` into a shorter command card that keeps every inbox operation, output expectation, follow-up prompt, security guardrail, and dependency reference intact.

## Why

The current doc repeats routing and formatting guidance for one command. A tighter layout lowers prompt cost without changing mailbox behavior or weakening phishing and forwarding safeguards.

## How

1. Keep the file as a single instruction doc.
2. Lead with the operation table, then output expectations, follow-up actions, flags, and safety/dependency references.
3. Preserve every supported command, helper call, flag meaning, phishing rule, and related reference.
4. Run markdown lint on the edited doc.

## Acceptance Criteria

- [ ] All existing inbox operations and helper mappings remain present.
- [ ] Output guidance still covers inbox summaries, triage categories, and search result formatting.
- [ ] Follow-up prompts, flag meanings, and security rules remain present.
- [ ] The file is shorter than the original 93-line worktree version and stays single-file.
- [ ] Markdown lint passes for `.agents/scripts/commands/email-inbox.md`.
- [ ] PR created with `Closes #14279`.

## Context

Issue #14279 is an automated simplification-debt task for an instruction doc. The right action is prose tightening and better ordering, not chapter splitting or content removal.
