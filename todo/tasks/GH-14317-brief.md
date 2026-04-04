<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GH#14317: Tighten `.agents/tools/git/github-actions.md`

## Session Origin

Interactive `/full-loop` run operating under the headless continuation contract for GitHub issue #14317.

## What

Restructure `.agents/tools/git/github-actions.md` into a shorter setup card that preserves every workflow trigger, job name, secret requirement, dashboard URL, and concurrent-push pattern.

## Why

The file is an instruction doc, not a reference corpus. It is already small, so the correct simplification is prose tightening and better ordering rather than splitting or deleting content.

## How

1. Keep the document single-file.
2. Put the quick-reference summary first, then secrets, workflow behavior, and concurrent-push guidance.
3. Preserve the `SONAR_TOKEN`, `CODACY_API_TOKEN`, and `GITHUB_TOKEN` guidance, all URLs, both YAML snippets, and the scenario-to-pattern table.
4. Run markdown lint on the edited file.

## Acceptance Criteria

- [ ] All existing triggers, job names, secrets, URLs, and push-pattern examples remain present.
- [ ] The file stays single-file and shorter than the original 84-line version.
- [ ] The quick-reference block surfaces the workflow, triggers, jobs, secrets, and dashboards before detailed setup steps.
- [ ] Markdown lint passes for `.agents/tools/git/github-actions.md`.
- [ ] PR created with `Closes #14317`.

## Context

Issue #14317 is an automated simplification-debt task. The file covers one operational concern, so progressive disclosure is unnecessary; the win is tighter wording and clearer order.
