<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Brief - t15176: Tighten Stagehand Benchmark Scripts Agent Doc

## Origin
- Session: Headless continuation
- Issue: https://github.com/marcusquinn/aidevops/issues/15176

## What
Tighten the prose in `.agents/tools/browser/browser-benchmark-scripts-05-stagehand.md` to improve token efficiency while preserving all institutional knowledge and code examples.

## Why
The file was flagged by the automated simplification scan for being slightly over the 50-line threshold for agent docs. Tightening prose reduces token costs for every agent load.

## How
1. Create a worktree `feature/t15176-tighten-stagehand-doc`.
2. Edit `.agents/tools/browser/browser-benchmark-scripts-05-stagehand.md`.
3. Compress the introductory prose and comments.
4. Ensure the code block remains intact and functional.
5. Verify with `markdownlint-cli2`.

## Acceptance Criteria
- [ ] Prose is tightened (fewer words, same meaning).
- [ ] Code block is preserved exactly.
- [ ] No broken links or references.
- [ ] Markdown linting passes.
- [ ] PR created and merged.

## Context
- The file is a "Reference corpus" chapter, already part of a split structure indexed by `browser-benchmark-scripts.md`.
- It's 52 lines long, just over the 50-line scan threshold.
- Classification: Instruction doc (prose tightening) / Reference corpus (restructuring already done).
