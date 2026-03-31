---
description: Generate YouTube video scripts with hooks, retention optimization, and remix mode
agent: Build+
mode: subagent
---

Generate retention-optimized YouTube scripts. Use `content/distribution-youtube-script-writer.md` for hook formulas, storytelling frameworks, retention checks, pacing, and output format.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Parse Request and Load Context

Parse a topic/title plus optional flags: `--remix VIDEO_ID`, `--hook-only`, `--outline-only`, `--length [short|medium|long]`.

```bash
memory-helper.sh recall --namespace youtube-topics "$TOPIC"
memory-helper.sh recall --namespace youtube "channel voice"
```

### Step 2: Select Mode and Generate

| Mode | Flag | Output |
|------|------|--------|
| **Full Script** | *(default)* | Hook → Intro → Body (with pattern interrupts) → Climax → CTA |
| **Hook Only** | `--hook-only` | 5-10 hook variants (Bold Claim, Question, Story, Contrarian, Result, List, Problem) |
| **Outline Only** | `--outline-only` | Hook concept, intro roadmap, body sections (3-7), interrupt placements, CTA strategy |
| **Remix** | `--remix VIDEO_ID` | Fetch transcript via `youtube-helper.sh transcript VIDEO_ID`, analyze the source structure, then rewrite with a new angle and examples |

Read `content/distribution-youtube-script-writer.md` before drafting.

### Step 3: Store and Offer Follow-up

```bash
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube-scripts \
  "Script: {title}. Hook: {formula}. Length: {duration}. Generated: {date}"
```

Offer follow-up help for hook variants, thumbnail brief, title/tags/description optimization, B-roll shot list, or a YouTube Short version (first 60s).

## Options

| Command | Purpose |
|---------|---------|
| `/youtube script "topic"` | Full script generation |
| `/youtube script "topic" --hook-only` | Generate 5-10 hook variants |
| `/youtube script "topic" --outline-only` | Structured outline only |
| `/youtube script --remix VIDEO_ID` | Transform competitor video |
| `/youtube script "topic" --length short` | 5-8 minute script |
| `/youtube script "topic" --length medium` | 8-12 minute script |
| `/youtube script "topic" --length long` | 12-20 minute script |

## Related

- `content/distribution-youtube.md` — Main YouTube agent
- `content/distribution-youtube-script-writer.md` — Full script writing guide (hook formulas, output format, worked examples)
- `content/story.md` — Storytelling frameworks and hook formulas
- `/youtube research` — Research topics before scripting
- `/youtube setup` — Configure channel and niche
- `youtube-helper.sh` — Get competitor transcripts for remix mode
