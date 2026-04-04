<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GH#14200: Tighten .agents/tools/credentials/list-keys.md

## Session Origin

Headless `/full-loop` worker continuation for GitHub issue #14200.

## What

Simplify `.agents/tools/credentials/list-keys.md` by tightening repeated prose while preserving command usage, source order, statuses, placeholder detection, and security guidance.

## Why

The file is an instruction doc, not a reference corpus. It can be made shorter and easier to load without changing the documented behavior of `/list-keys`.

## How

1. Keep the YAML frontmatter and AI-CONTEXT block intact.
2. Compress the usage, output, status, and integration sections.
3. Preserve all example output, source ordering, placeholder patterns, and security rules.
4. Verify with markdownlint-cli2.

## Acceptance Criteria

- [ ] All command examples and sample output remain present
- [ ] Source ordering and placeholder detection rules remain documented
- [ ] Security notes still prohibit value disclosure
- [ ] Markdown lint passes for the updated files
- [ ] PR created with `Closes #14200`

## Context

Issue #14200 is simplification debt from the automated scan. The governing guidance is `.agents/tools/build-agent/build-agent.md` prose tightening for instruction docs.
