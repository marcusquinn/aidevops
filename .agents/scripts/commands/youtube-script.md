---
description: Generate YouTube video scripts with hooks, retention optimization, and remix mode
agent: Build+
mode: subagent
---

Generate YouTube video scripts optimized for audience retention, with hooks, pattern interrupts, and storytelling frameworks.

Topic: $ARGUMENTS

## Workflow

### Step 1: Parse Input and Load Context

1. **Parse $ARGUMENTS:**
   - Topic/title (e.g., "AI coding tools comparison")
   - Optional flags: `--remix VIDEO_ID`, `--hook-only`, `--outline-only`, `--length [short|medium|long]`

2. **Load research context from memory:**

```bash
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube-topics "$TOPIC"
```

3. **Load channel configuration:**

```bash
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube "channel"
```

### Step 2: Determine Script Mode

**Mode A: Full Script (default)** — Hook (0-30s) → Intro (30-60s) → Body (sections with pattern interrupts) → Climax → CTA

**Mode B: Hook Only (`--hook-only`)** — Generate 5-10 variants: Bold Claim, Question, Story, Contrarian, Result, List, Problem

**Mode C: Outline Only (`--outline-only`)** — Hook concept, intro roadmap, body sections (3-7 points), pattern interrupt placements, CTA strategy

**Mode D: Remix (`--remix VIDEO_ID`)** — Transform competitor video into unique script:

```bash
~/.aidevops/agents/scripts/youtube-helper.sh transcript VIDEO_ID
```

Analyze structure (hook, intro, body, CTA), then generate unique version: same topic, different angle, new examples, your voice.

### Step 3: Generate Script

Read `content/distribution/youtube/script-writer.md` for full guidance on hook formulas, pattern interrupt types, retention curve optimization, storytelling frameworks (AIDA, Hero's Journey, Problem-Solution-Result), B-roll markers, and pacing (120-150 words/minute).

Script sections: `[HOOK - 0:00-0:30]` → `[INTRO - 0:30-1:00]` → `[SECTION N - start:end]` (with `[B-roll: ...]` and `[Pattern interrupt: type]`) → `[CLIMAX]` → `[CTA]`

Output includes: title, target length, audience, hook formula, production notes (word count, duration, pattern interrupt count, B-roll shots), retention optimization scores.

### Step 4: Optimize for Retention

- **Hook**: creates curiosity + promises value + establishes credibility
- **Pattern interrupts**: every 2-3 minutes, before drop-off points, after dense sections
- **Pacing**: 120-150 words/minute, vary sentence length, use pauses
- **B-roll**: visual change every 5-10 seconds, illustrate abstract concepts

### Step 5: Present Script

Format as production-ready with header (title, length, audience, hook formula), timestamped sections, and production notes. See `content/distribution/youtube/script-writer.md` for full output format.

### Step 6: Store and Offer Follow-up

```bash
~/.aidevops/agents/scripts/memory-helper.sh store \
  --type WORKING_SOLUTION \
  --namespace youtube-scripts \
  "Script: {title}. Hook: {formula}. Length: {duration}. Generated: {date}"
```

Offer: hook variants, thumbnail brief, title/tags/description optimization, B-roll shot list, YouTube Short version (first 60s).

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

- `content/distribution/youtube/youtube.md` - Main YouTube agent
- `content/distribution/youtube/script-writer.md` - Full script writing guide (hook formulas, output format, worked examples)
- `content/story.md` - Storytelling frameworks and hook formulas
- `/youtube research` - Research topics before scripting
- `/youtube setup` - Configure channel and niche
- `youtube-helper.sh` - Get competitor transcripts for remix mode
