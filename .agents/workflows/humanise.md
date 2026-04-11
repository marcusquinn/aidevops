---
description: Remove AI writing patterns from text to make it sound more natural and human
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Remove AI-generated writing patterns from text. Makes output sound natural and human-written.

Text to humanise: $ARGUMENTS

## Quick Reference

- **Purpose**: Remove AI writing patterns, add human voice
- **Patterns**: `content/humanise.md` (24 named patterns with triggers and fixes)
- **Upstream**: [blader/humanizer](https://github.com/blader/humanizer) · `humanise-update-helper.sh check`

## Process

1. Read `content/humanise.md` for the full pattern list
2. Identify patterns in the provided text
3. Rewrite with natural alternatives — don't just remove patterns, add voice

## Usage

```text
/humanise [paste text here]
/humanise path/to/content.md
```

## Output Format

```text
Humanised Text
==============

[The rewritten text]

---

Changes made:
- Removed "serves as a testament" (#1 Undue Significance)
- Replaced "Moreover" with natural transition (#7 AI Vocabulary)
```
