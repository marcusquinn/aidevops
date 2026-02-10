---
description: Generate YouTube video scripts with hooks, retention optimization, and metadata
agent: YouTube
mode: subagent
---

Generate YouTube video scripts from a topic, outline, or competitor video. Includes hook generation, retention curve optimization, and optional metadata (titles, tags, description).

Arguments: $ARGUMENTS

## Usage

```text
/youtube script "topic name"                   # Generate script from a topic
/youtube script remix VIDEO_ID                 # Remix a competitor video into unique script
/youtube script hook "topic name"              # Generate hook options only
/youtube script outline "topic name"           # Generate outline only (no full script)
/youtube script optimize                       # Optimize an existing script (paste or file)
/youtube script list                           # List previously generated scripts
```

## Workflow

### Step 1: Parse Arguments

Parse `$ARGUMENTS` to determine the script mode:

| Argument | Action |
|----------|--------|
| `"topic"` | Full script generation from topic |
| `remix VIDEO_ID` | Remix competitor video |
| `hook "topic"` | Hook options only |
| `outline "topic"` | Outline without full script |
| `optimize` | Optimize existing script |
| `list` | List generated scripts |

### Step 2: Load Context

Before generating any script, recall stored context:

```bash
# Channel voice and audience
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube "My channel"
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube "Channel voice"

# Topic research for this topic (if available)
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube-topics "$TOPIC"

# Previous script patterns
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube-scripts --recent

# Successful patterns
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube-patterns "script"
```

If no channel profile exists, prompt:

```text
No YouTube channel configured. Run /youtube setup first to set your channel voice and audience.
```

### Step 3: Route to Script Mode

**For `"topic"` (full script generation):**

Read `youtube/script-writer.md` for the full workflow.

1. **Check for existing research** on this topic in memory
2. **Get competitor coverage** (if not already in memory):

```bash
~/.aidevops/agents/scripts/youtube-helper.sh search "topic" video 10
```

3. **Get competitor transcripts** for the top 2-3 results:

```bash
~/.aidevops/agents/scripts/youtube-helper.sh transcript VIDEO_ID
```

4. **Choose framework** based on content type:

| Content Type | Framework |
|-------------|-----------|
| Product review | AIDA |
| Tutorial / how-to | Problem-Solution-Result |
| Documentary / explainer | Three-Act Structure |
| Personal story | Hero's Journey |
| List / roundup | Listicle with Stakes |

5. **Generate the full script** following the structure from `youtube/script-writer.md`:
   - HOOK (0-30s) -- pattern interrupt + promise + credibility
   - INTRO (30-60s) -- context + roadmap + stakes
   - BODY -- sections with pattern interrupts every 2-3 minutes
   - CLIMAX -- payoff the hook's promise
   - CTA -- subscribe + next video + comment prompt

6. **Generate metadata** using `youtube/optimizer.md`:
   - 3-5 title options with CTR signals
   - 15-30 tags across categories
   - SEO-optimized description with timestamps
   - Thumbnail brief

7. **Save to workspace**:

```bash
mkdir -p ~/.aidevops/.agent-workspace/work/youtube/scripts/$(date +%Y-%m-%d)-$(echo "$TOPIC" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | head -c 40)
```

Save files: `script.md`, `titles.md`, `tags.txt`, `description.md`, `thumbnail-brief.md`

**For `remix VIDEO_ID`:**

Read `youtube/script-writer.md` "Remix Mode" section.

1. **Get the source video metadata and transcript**:

```bash
~/.aidevops/agents/scripts/youtube-helper.sh video VIDEO_ID
~/.aidevops/agents/scripts/youtube-helper.sh transcript VIDEO_ID
```

2. **Analyze the source structure** -- extract hook formula, framework, key points, pattern interrupts, CTA approach
3. **Choose remix mode**:
   - Same topic, new angle (default)
   - Same structure, new topic
   - Update (cover what changed)
   - Response (add your expertise)
   - Deep dive (expand one point)

4. **Generate remixed script** that keeps successful structural elements but uses your voice, angle, and new information
5. **Generate metadata** and save to workspace

**For `hook "topic"`:**

Generate 5 hook options using formulas from `youtube/script-writer.md`:

1. Bold claim hook
2. Question hook
3. Story hook
4. Result hook
5. Curiosity gap hook

For each hook, include:

- Spoken text (15-30 seconds when read aloud)
- `[VISUAL]` cue for what appears on screen
- Why this hook works for this specific topic

**For `outline "topic"`:**

Generate a structured outline without full script text:

```text
## [Working Title]

**Framework**: [chosen framework]
**Target length**: [X minutes]
**Primary keyword**: [keyword]

### [00:00] HOOK
- Formula: [hook type]
- Promise: [what viewer will learn]
- Credibility: [why they should listen]

### [00:30] INTRO
- Context: [topic background]
- Roadmap: [what the video covers]
- Stakes: [why it matters]

### [01:00] Section 1: [Title]
- Key point: [main idea]
- Evidence: [data/example/story]
- Pattern interrupt: [type]

### [04:00] Section 2: [Title]
...

### [XX:XX] CTA
- Action: [specific ask]
- Next video: [related content]
```

**For `optimize`:**

Ask the user to paste their existing script or provide a file path. Then review against the retention checklist from `youtube/script-writer.md`:

| Checkpoint | What to Verify |
|-----------|---------------|
| First 5 seconds | Does it stop the scroll? |
| First 30 seconds | Is the hook complete? |
| 60-second mark | Does the viewer know what they get? |
| Every 2-3 minutes | Is there a pattern interrupt? |
| Midpoint | Is there a re-engagement moment? |
| Before CTA | Was the hook's promise fulfilled? |
| CTA | Is it specific and content-related? |

Provide specific suggestions for each checkpoint that fails.

**For `list`:**

```bash
ls -la ~/.aidevops/.agent-workspace/work/youtube/scripts/ 2>/dev/null || echo "No scripts generated yet."

# Also check memory for script metadata
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube-scripts --recent
```

### Step 4: Present Output

After generating a script, present it with:

```text
Script Generated: "[Title]"

Framework:  [framework name]
Length:      ~[X] minutes ([Y] words)
Hook:       [hook type] formula
Sections:   [N] sections with [N] pattern interrupts

Titles (pick one):
1. [Title option 1] -- [CTR signals used]
2. [Title option 2] -- [CTR signals used]
3. [Title option 3] -- [CTR signals used]

Saved to: ~/.aidevops/.agent-workspace/work/youtube/scripts/[date]-[topic]/

Next steps:
1. Review and refine the script
2. /youtube script optimize -- check retention signals
3. Record the video
```

### Step 5: Store in Memory

```bash
~/.aidevops/agents/scripts/memory-helper.sh store --type WORKING_SOLUTION --namespace youtube-scripts \
  "Script: [topic]. Framework: [name]. Hook: [type]. Length: [X min]. \
   Titles: [top 2 options]. Saved: [path]."
```

## Quota Budget

| Script Mode | Estimated Cost |
|-------------|---------------|
| Full script (with research) | ~110 units (search + video lookups) |
| Full script (topic pre-researched) | ~10 units (transcript only) |
| Remix | ~2 units (video lookup + transcript via yt-dlp) |
| Hook only | ~100 units (search for competitor hooks) |
| Outline only | ~100 units (search for competitor coverage) |
| Optimize | 0 units (AI analysis only) |

## Prerequisites

- YouTube channel configured via `/youtube setup`
- For best results, run `/youtube research` first to identify validated topics
- `yt-dlp` installed for transcript extraction (`/yt-dlp status`)

## Related

- `youtube.md` -- Main YouTube agent
- `youtube/script-writer.md` -- Detailed script generation workflows
- `youtube/optimizer.md` -- Title, tag, description optimization
- `youtube/topic-research.md` -- Topic validation before scripting
- `youtube-helper.sh` -- YouTube Data API wrapper
- `youtube-research.md` -- Research command for topic discovery
- `youtube-setup.md` -- Initial channel configuration
