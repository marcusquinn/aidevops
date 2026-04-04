<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Brief: t15472 - Simplification: tighten agent doc Importing .srt subtitles into Remotion

## Context
- **Session Origin**: Headless worker dispatch
- **Issue**: [GH#15472](https://github.com/marcusquinn/aidevops/issues/15472)
- **File**: `.agents/tools/video/remotion-import-srt-captions.md`

## What
Tighten and restructure the agent doc for importing .srt subtitles into Remotion to improve token efficiency and readability.

## Why
The file was flagged by an automated scan as a candidate for simplification (60 lines). Reducing verbosity while preserving institutional knowledge helps agents process context faster.

## How
1. **Classify**: This is an **instruction doc** (setup, usage).
2. **Tighten prose**: Remove filler words, use concise bullet points.
3. **Order by importance**: Ensure core usage and install steps are prominent.
4. **Preserve knowledge**: Keep all URLs, command examples, and code logic.
5. **Verify**: Ensure no broken links, all code blocks preserved, and agent behavior remains unchanged.

## Acceptance Criteria
- [ ] File size reduced (lines/tokens)
- [ ] All institutional knowledge (URLs, commands, code) preserved
- [ ] No broken internal links
- [ ] PR opened with `t15472: {description}` format
- [ ] Signature footer included in PR and closing comments
