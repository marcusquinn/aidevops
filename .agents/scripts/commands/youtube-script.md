---
description: Generate YouTube video scripts with hooks, retention optimization, and remix mode
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Generate retention-optimized YouTube scripts. Read `content/distribution-youtube-script-writer.md` for hook formulas, storytelling frameworks, retention checks, pacing, and output format.

Arguments: $ARGUMENTS

## Workflow

### 1. Parse and Load Context

Parse topic/title plus optional flags: `--remix VIDEO_ID`, `--hook-only`, `--outline-only`, `--length [short|medium|long]`.

```bash
memory-helper.sh recall --namespace youtube-topics "$TOPIC"
memory-helper.sh recall --namespace youtube "channel voice"
```

### 2. Generate

| Mode | Flag | Output |
|------|------|--------|
| **Full Script** | *(default)* | Hook → Intro → Body (pattern interrupts) → Climax → CTA |
| **Hook Only** | `--hook-only` | 5-10 hook variants (Bold Claim, Question, Story, Contrarian, Result, List, Problem) |
| **Outline Only** | `--outline-only` | Hook concept, intro roadmap, body sections (3-7), interrupt placements, CTA strategy |
| **Remix** | `--remix VIDEO_ID` | Fetch transcript via `youtube-helper.sh transcript VIDEO_ID`, analyze structure, rewrite with new angle |

Length flag: `--length short` (5-8 min), `medium` (8-12 min), `long` (12-20 min).

### 3. Store and Follow-up

```bash
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube-scripts \
  "Script: {title}. Hook: {formula}. Length: {duration}. Generated: {date}"
```

Offer: hook variants, thumbnail brief, title/tags/description, B-roll shot list, YouTube Short (first 60s).

## Related

- `content/distribution-youtube.md` — main YouTube agent
- `content/distribution-youtube-script-writer.md` — full script writing guide (hook formulas, output format, worked examples)
- `content/story.md` — storytelling frameworks and hook formulas
- `/youtube research` — research topics before scripting
- `/youtube setup` — configure channel and niche
- `youtube-helper.sh` — competitor transcripts for remix mode
