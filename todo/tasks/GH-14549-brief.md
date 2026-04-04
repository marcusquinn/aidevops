<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GH#14549: Tighten `.agents/scripts/commands/ip-check.md`

## Session Origin

Interactive `/full-loop` run for GitHub issue #14549 under the headless continuation contract.

## What

Restructure `.agents/scripts/commands/ip-check.md` into a shorter command card that keeps every supported invocation, provider name, output example, and follow-up prompt intact.

## Why

The doc is already small, but it still spends lines on repeated routing phrasing for a single helper script. A tighter layout reduces prompt cost without changing command behavior or operator guidance.

## How

1. Classify the file as an instruction doc, not a reference corpus.
2. Keep a single file, but order it as helper, primary commands, output, follow-up, related references.
3. Preserve all command variants, ops subcommands, provider names, and output example.
4. Run markdown lint on the edited doc.

## Acceptance Criteria

- [ ] All existing command variants, provider names, and the output example remain present.
- [ ] The primary `check` workflow appears before niche variants and ops subcommands.
- [ ] The file is shorter than the original 49-line worktree version and stays single-file.
- [ ] Markdown lint passes for `.agents/scripts/commands/ip-check.md`.
- [ ] PR created with `Closes #14549`.

## Context

Issue #14549 is an automated simplification-debt task. The file is a short operational command doc, so the correct action is prose tightening and reordering rather than chapter splitting.
