<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GH#14022: Tighten `.agents/tools/browser/stealth-patches.md`

## Session Origin
Interactive `/full-loop` run for GitHub issue #14022 under the headless continuation contract.

## What
Restructure `.agents/tools/browser/stealth-patches.md` into a tighter reference card that preserves every command, URL, limitation, and decision signal while reducing redundant prose.

## Why
The doc is already a compact reference, but it still repeats setup details across sections and buries the selection guidance behind narrative text. A slimmer layout reduces token cost on load without changing the agent guidance.

## How
1. Classify the file as a short single-topic reference card, not a multi-chapter corpus.
2. Keep one page, but reorder it for primacy: choose tool, install/use, test, limits.
3. Preserve all command examples, detection URLs, and comparisons; compress explanatory sentences.
4. Run markdown lint on the edited file.

## Acceptance Criteria
- [ ] All existing command examples, URLs, and comparison facts remain present.
- [ ] Tool-selection guidance appears before implementation details.
- [ ] The file is shorter than the original 129 lines without adding companion chapter files.
- [ ] Markdown lint passes for `.agents/tools/browser/stealth-patches.md`.
- [ ] PR created with `Closes #14022`.

## Context
Issue #14022 is a simplification-debt task created by the automated scan. The issue asked for classification first; current assessment is that this file is a small reference card, so the correct action is prose tightening and reordering rather than chapter splitting.
