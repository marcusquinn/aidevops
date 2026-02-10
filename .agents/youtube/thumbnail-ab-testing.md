---
description: "YouTube thumbnail A/B testing pipeline - generate, score, and test multiple thumbnail variants per video"
mode: subagent
model: sonnet
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# YouTube Thumbnail A/B Testing

Generate and test multiple thumbnail variants per video using a systematic pipeline: brief generation, variant creation, automated scoring, and YouTube Studio A/B testing integration.

## When to Use

Read this subagent when the user wants to:

- Generate multiple thumbnail options for a YouTube video
- Score thumbnails against a quality rubric before uploading
- Set up A/B testing for thumbnails on YouTube
- Analyse competitor thumbnails for a topic
- Track thumbnail performance across videos
- Build a style library of winning thumbnail templates

## Architecture

```text
thumbnail-factory-helper.sh (CLI tool)
  |
  +-- brief         Generate design brief from video metadata
  +-- generate      Create thumbnail variants via DALL-E 3 / prompt files
  +-- score         Score individual thumbnails against rubric
  +-- record-score  Store manual/AI-assisted scores
  +-- batch-score   Score all thumbnails in a directory
  +-- competitors   Download and analyse competitor thumbnails
  +-- compare       Compare two sets of thumbnails
  +-- ab-status     Check A/B test status for a video
  +-- history       View test history
  +-- report        Generate performance report
  |
  +-- SQLite DB     thumbnail-tests.db (variants, scores, CTR, winners)
  +-- Workspace     ~/.aidevops/.agent-workspace/work/youtube/thumbnails/
  +-- Style Library ~/.aidevops/.agent-workspace/work/youtube/thumbnails/style-library/
```

### Integration Points

| Component | Role |
|-----------|------|
| `youtube-helper.sh` | Fetch video metadata, search competitors |
| `content/production/image.md` | Nanobanana Pro JSON templates, style library |
| `content/optimization.md` | A/B testing methodology, thresholds |
| `youtube/optimizer.md` | Thumbnail brief templates |
| `tools/vision/image-understanding.md` | AI-powered thumbnail scoring |
| `tools/vision/image-generation.md` | DALL-E 3, Midjourney, FLUX generation |
| `memory-helper.sh` | Store winning patterns cross-session |

## Pipeline Workflow

### Phase 1: Brief Generation

Generate a design brief from video metadata to guide thumbnail creation.

```bash
# Generate brief for a video
thumbnail-factory-helper.sh brief VIDEO_ID
```

The brief includes:
- Video title, tags, and description context
- 5 concept options (face+emotion, before/after, bold text, product focus, contrarian)
- Design constraints (dimensions, text space, mobile readability)
- Scoring criteria with weights
- Style library template recommendations

### Phase 2: Variant Generation

Generate 5-10 thumbnail variants per video.

```bash
# Generate 10 variants (requires OPENAI_API_KEY for DALL-E 3)
thumbnail-factory-helper.sh generate VIDEO_ID 10

# Without API key, generates prompt files for manual use
thumbnail-factory-helper.sh generate VIDEO_ID 10
```

**Variant concepts** (automatically rotated):

| # | Concept | Best For |
|---|---------|----------|
| 1 | Close-up face, surprised expression | Talking head videos |
| 2 | Before/after split composition | Tutorials, transformations |
| 3 | Centered subject, bold graphics | Reviews, comparisons |
| 4 | Product in dramatic lighting | Product reviews, unboxings |
| 5 | Wide shot, cinematic environment | Vlogs, travel, lifestyle |
| 6 | Extreme close-up, macro detail | Tech, cooking, crafts |
| 7 | Subject pointing at element | Educational, how-to |
| 8 | Minimalist, single bold element | Thought leadership, essays |
| 9 | Action shot, motion blur | Sports, gaming, action |
| 10 | Overhead flat lay, organized | Gear reviews, collections |

**Image generation options**:

| Method | Cost | Quality | Setup |
|--------|------|---------|-------|
| DALL-E 3 (via script) | $0.08/img | High | Set OPENAI_API_KEY |
| Midjourney (manual) | $0.10/img | Very high | Use prompt files |
| Nanobanana Pro (JSON) | Varies | High | Use JSON templates from style library |
| FLUX (local) | Free | High | Requires GPU + ComfyUI |

### Phase 3: Scoring

Score each variant against the quality rubric.

```bash
# Score a single thumbnail (generates scoring prompt for vision AI)
thumbnail-factory-helper.sh score /path/to/variant-1.png

# Score all thumbnails in a directory
thumbnail-factory-helper.sh batch-score /path/to/variants/

# Record scores (manual or from vision AI output)
thumbnail-factory-helper.sh record-score /path/to/variant-1.png 8 7 9 8 7 8
#                                                                 ^  ^  ^  ^  ^  ^
#                                                              face contrast text brand emotion clarity
```

**Scoring rubric** (1-10 scale, weighted):

| Criterion | Weight | What to Check |
|-----------|--------|---------------|
| **Face Prominence** | 25% | Face visible, >30% of frame, clear emotion |
| **Contrast** | 20% | Stands out in thumbnail grid, high contrast |
| **Text Space** | 15% | Clear area (30%+) for title overlay |
| **Brand Alignment** | 15% | Matches channel visual identity |
| **Emotion** | 15% | Evokes curiosity, surprise, or excitement |
| **Clarity** | 10% | Readable at small sizes (120x90px) |

**Thresholds**:
- **7.5+**: Ready for A/B testing (PASS)
- **5.0-7.4**: Below threshold, regenerate or improve
- **<5.0**: Reject, start over

**AI-assisted scoring** (recommended):

Use a vision model (Claude, GPT-4o, Gemini) with the generated scoring prompt:

```bash
# The score command generates a prompt file alongside the image
thumbnail-factory-helper.sh score /path/to/variant-1.png
# → Creates /path/to/variant-1-score-prompt.txt

# Feed the image + prompt to your vision model, then record the scores
thumbnail-factory-helper.sh record-score /path/to/variant-1.png 8 7 9 8 7 8
```

### Phase 4: A/B Testing

Upload passing variants to YouTube Studio for A/B testing.

```bash
# Check which variants pass threshold
thumbnail-factory-helper.sh ab-status VIDEO_ID
```

**YouTube Studio A/B testing**:

1. Go to YouTube Studio > Content > Select video
2. Click "Thumbnail" > "Test & Compare"
3. Upload 2-3 passing variants (YouTube supports up to 3)
4. Wait for 1000+ impressions per variant (minimum for significance)
5. YouTube declares a winner based on watch time share

**Manual A/B testing** (if YouTube A/B not available):

1. Upload variant A as thumbnail
2. Wait 7 days, collect CTR data
3. Switch to variant B
4. Wait 7 days, collect CTR data
5. Compare CTR with 95% confidence threshold

### Phase 5: Analysis and Pattern Storage

```bash
# View test history
thumbnail-factory-helper.sh history VIDEO_ID

# Generate performance report
thumbnail-factory-helper.sh report --recent

# Store winning pattern in memory
memory-helper.sh store --type SUCCESS_PATTERN --namespace youtube-patterns \
  "Thumbnail pattern: [description]. Style: [template]. CTR: [X]%. Video: [ID]."
```

## Competitor Analysis

Analyse what thumbnails work in your niche before generating your own.

```bash
# Download competitor thumbnails for the same topic
thumbnail-factory-helper.sh competitors VIDEO_ID 5

# Score competitor thumbnails
thumbnail-factory-helper.sh batch-score ~/.aidevops/.agent-workspace/work/youtube/thumbnails/VIDEO_ID/competitors/
```

**What to look for**:

- Face presence and expression type
- Color palette (warm vs cool, saturated vs muted)
- Text overlay style (font, size, position)
- Composition pattern (centered vs rule of thirds)
- Emotional trigger (curiosity, shock, FOMO)

## Style Library

Build a library of winning thumbnail templates for brand consistency.

### Creating Templates

1. Generate thumbnails using `content/production/image.md` JSON schema
2. Score and A/B test variants
3. Save winning JSON templates to style library:

```bash
# Style library location
~/.aidevops/.agent-workspace/work/youtube/thumbnails/style-library/

# Example: save a winning template
cp winning-template.json ~/.aidevops/.agent-workspace/work/youtube/thumbnails/style-library/face-emotion-v1.json
```

### Template Categories

| Category | Use Case | Key Attributes |
|----------|----------|----------------|
| **Face + Emotion** | Talking head, reactions | Close-up, dramatic lighting, shallow DOF |
| **Before/After** | Tutorials, transformations | Split composition, high contrast |
| **Product Focus** | Reviews, unboxings | Clean background, dramatic lighting |
| **Bold Graphics** | Comparisons, lists | Centered, vibrant colors, graphic elements |
| **Cinematic** | Vlogs, travel | Wide shot, natural lighting, 16:9 |

### Reusing Templates

```bash
# Generate variants using a specific style template
thumbnail-factory-helper.sh generate VIDEO_ID 5 face-emotion-v1
```

## Pipeline Automation

Integrate thumbnail generation into the YouTube content pipeline.

### As Pipeline Worker (Phase 5)

Add to the YouTube pipeline (`youtube/pipeline.md`) as a new worker:

```text
Worker 5: Thumbnail Generation
  Input:  draft scripts + metadata from workspace
  Output: 5-10 scored thumbnail variants per video -> workspace
  Quota:  0 YouTube API units (image generation only)
  Cost:   ~$0.40-0.80 per video (5-10 DALL-E 3 images)
```

### Supervisor Integration

```bash
# Add thumbnail task to supervisor
supervisor-helper.sh add yt-thumbnails --repo "$(pwd)" \
  --description "Generate and score thumbnail variants for draft videos"

# Add to existing YouTube batch
supervisor-helper.sh batch "youtube-daily" \
  --concurrency 1 \
  --tasks "yt-intel,yt-research,yt-scripts,yt-optimize,yt-thumbnails"
```

### Worker Prompt

```text
You are a YouTube thumbnail production worker. Your task is to generate and score
thumbnail variants for videos in the production pipeline.

1. List draft videos: ls ~/.aidevops/.agent-workspace/work/youtube/scripts/
2. For each video with a script but no thumbnails:
   a. Generate brief: thumbnail-factory-helper.sh brief VIDEO_ID
   b. Generate 10 variants: thumbnail-factory-helper.sh generate VIDEO_ID 10
   c. Score each variant using vision AI
   d. Record scores: thumbnail-factory-helper.sh record-score ...
   e. Flag variants scoring 7.5+ as ready for A/B testing
3. Download competitor thumbnails for context:
   thumbnail-factory-helper.sh competitors VIDEO_ID 5
4. Store winning patterns in memory
5. Report via mailbox: mail-helper.sh send --type status_report
```

## Data Storage

```text
~/.aidevops/.agent-workspace/
├── work/youtube/thumbnails/
│   ├── VIDEO_ID/
│   │   ├── brief.md                    # Design brief
│   │   ├── variants/
│   │   │   ├── variant-1.png           # Generated thumbnail
│   │   │   ├── variant-1-prompt.json   # Generation prompt (if no API key)
│   │   │   ├── variant-1-score-prompt.txt  # Scoring prompt for vision AI
│   │   │   └── ...
│   │   └── competitors/
│   │       ├── COMP_VIDEO_ID.jpg       # Competitor thumbnails
│   │       └── ...
│   └── style-library/
│       ├── face-emotion-v1.json        # Winning style templates
│       ├── before-after-v1.json
│       └── ...
└── thumbnail-tests.db                  # SQLite: variants, scores, CTR, winners
```

## Memory Integration

```bash
# Store winning thumbnail pattern
memory-helper.sh store --type SUCCESS_PATTERN --namespace youtube-patterns \
  "Thumbnail: face-emotion style with surprised expression gets 5.2% CTR. \
   Colors: #FF6B35 accent on dark background. Template: face-emotion-v1."

# Store style preference
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube \
  "Thumbnail style: close-up face, dramatic side lighting, #FF6B35 accent. \
   Consistently scores 8+ on rubric. Use face-emotion-v1 template."

# Recall patterns for new videos
memory-helper.sh recall --namespace youtube-patterns "thumbnail"
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| No API key for generation | Script generates prompt files instead; use manually |
| Low scores across all variants | Review style templates, try different concepts |
| YouTube A/B test not available | Use manual rotation method (7 days per variant) |
| Competitor search uses quota | Each search costs 100 units; limit to 5 results |
| Images too small | DALL-E 3 generates 1792x1024; resize to 1280x720 |
| Vision AI scoring inconsistent | Use the same model and prompt for all variants |

## Related

- `youtube.md` — Main YouTube agent
- `youtube/optimizer.md` — Title, tag, description optimization + thumbnail briefs
- `youtube/pipeline.md` — Automated content pipeline (thumbnail = Phase 5)
- `content/production/image.md` — Nanobanana Pro JSON templates, style library
- `content/optimization.md` — A/B testing methodology, thresholds
- `tools/vision/image-understanding.md` — AI-powered thumbnail analysis
- `tools/vision/image-generation.md` — Image generation model comparison
- `scripts/thumbnail-factory-helper.sh` — CLI tool reference
