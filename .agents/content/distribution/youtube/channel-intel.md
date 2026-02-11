---
description: "YouTube channel intelligence - competitor profiling, outlier detection, content DNA analysis"
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

# YouTube Channel Intelligence

Analyze YouTube channels to extract competitive insights: upload patterns, engagement metrics, outlier videos, content DNA, and strategic positioning.

## When to Use

Read this subagent when the user wants to:

- Profile a YouTube channel (theirs or a competitor's)
- Compare multiple channels side-by-side
- Find outlier videos that dramatically outperformed the channel average
- Extract a channel's "content DNA" (recurring topics, formats, angles)
- Understand upload frequency and consistency patterns
- Calculate engagement ratios (views/sub, likes/view, comments/view)

## Quick Reference

```bash
# Channel overview
youtube-helper.sh channel @handle

# Full video list with stats
youtube-helper.sh videos @handle 200

# Side-by-side comparison
youtube-helper.sh competitors @channel1 @channel2 @channel3

# Get transcript of an outlier video
youtube-helper.sh transcript VIDEO_ID

# Check quota before heavy operations
youtube-helper.sh quota
```

## Channel Profiling Workflow

### Step 1: Basic Channel Data

```bash
youtube-helper.sh channel @handle json
```

Extract and store:
- Subscriber count, total views, video count
- Channel creation date (age)
- Description and positioning
- Upload frequency (total videos / channel age)

### Step 2: Video Enumeration

```bash
youtube-helper.sh videos @handle 200 json
```

From the video list, calculate:
- **Average views per video** (total views / video count)
- **Median views** (more useful than average — resistant to outliers)
- **Upload frequency** (videos per week/month)
- **View trend** (are recent videos getting more or fewer views?)
- **Duration distribution** (short-form vs long-form mix)

### Step 3: Outlier Detection

An outlier video is one that performs significantly above the channel's baseline. The standard threshold is **3x the channel's median views**.

```bash
# Get videos as JSON, then analyze
youtube-helper.sh videos @handle 200 json | node -e "
process.stdin.on('data', d => {
    const videos = JSON.parse(d);
    const views = videos.map(v => Number(v.statistics?.viewCount || 0)).sort((a,b) => a-b);
    const median = views[Math.floor(views.length / 2)];
    const threshold = median * 3;

    console.log('Median views:', median.toLocaleString());
    console.log('Outlier threshold (3x):', threshold.toLocaleString());
    console.log('');

    const outliers = videos
        .filter(v => Number(v.statistics?.viewCount || 0) > threshold)
        .sort((a,b) => Number(b.statistics?.viewCount || 0) - Number(a.statistics?.viewCount || 0));

    console.log('Outlier videos (' + outliers.length + '):');
    outliers.forEach(v => {
        const views = Number(v.statistics?.viewCount || 0);
        const multiplier = (views / median).toFixed(1);
        console.log('  ' + multiplier + 'x | ' + views.toLocaleString() + ' views | ' + v.snippet?.title);
    });
});
"
```

### Step 4: Content DNA Extraction

Analyze outlier videos to identify patterns:

1. **Topic clusters**: What subjects do outliers cover?
2. **Title patterns**: Numbers? Questions? How-to? Brackets?
3. **Duration sweet spot**: What length performs best?
4. **Thumbnail style**: Faces? Text? Colors? (use `image-understanding.md`)
5. **Hook patterns**: Get transcripts of top 5 outliers, analyze first 30 seconds

```bash
# Get transcripts of top outlier videos
for vid in VIDEO_ID_1 VIDEO_ID_2 VIDEO_ID_3; do
    echo "=== $vid ==="
    youtube-helper.sh transcript "$vid" | head -20
    echo ""
done
```

### Step 5: Store Findings in Memory

```bash
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube \
  "Channel profile @handle: [subs] subs, [views/vid] avg views, uploads [freq]. \
   Content DNA: [topics], [formats]. Outlier pattern: [description]. \
   Weakness: [gap identified]."
```

## Competitor Comparison Matrix

When comparing multiple channels, build this matrix:

| Metric | Your Channel | Competitor 1 | Competitor 2 | Competitor 3 |
|--------|-------------|-------------|-------------|-------------|
| Subscribers | | | | |
| Total views | | | | |
| Video count | | | | |
| Avg views/video | | | | |
| Views/subscriber | | | | |
| Upload frequency | | | | |
| Avg duration | | | | |
| Top topic | | | | |
| Outlier count (3x) | | | | |

```bash
# Quick comparison
youtube-helper.sh competitors @you @comp1 @comp2 @comp3
```

## Engagement Metrics

Calculate these ratios for each channel:

| Metric | Formula | Good Benchmark |
|--------|---------|----------------|
| Views/Subscriber | total_views / subscribers | > 5.0 |
| Avg Views/Video | total_views / video_count | Varies by niche |
| Like Rate | likes / views | > 3% |
| Comment Rate | comments / views | > 0.5% |
| Upload Consistency | std_dev of days between uploads | Lower = better |

## Quota Budget for Channel Intel

| Operation | Cost | Typical Usage |
|-----------|------|---------------|
| Channel lookup (per channel) | 1 unit | 5 channels = 5 units |
| Video enumeration (per 50 videos) | 1 unit | 200 videos = 4 units |
| Video details (per 50 videos) | 1 unit | 200 videos = 4 units |
| Transcripts (via yt-dlp) | 0 units | Unlimited |
| **Total for full competitor analysis** | | **~50 units** |

A full analysis of 5 competitors (200 videos each) costs approximately 50 quota units — well within the 10,000 daily limit.

## Output Format

When reporting channel intel, use this structure:

```markdown
## Channel Profile: [Name] (@handle)

**Overview**: [subscribers] subscribers, [total_views] total views, [video_count] videos
**Created**: [date] | **Upload frequency**: [X videos/week]
**Niche**: [primary topic]

### Performance Metrics
- Average views/video: [X]
- Median views/video: [X]
- Views/subscriber ratio: [X]
- Like rate: [X]%

### Content DNA
- **Primary topics**: [topic1], [topic2], [topic3]
- **Dominant format**: [format description]
- **Duration sweet spot**: [X-Y minutes]
- **Title patterns**: [patterns observed]

### Outlier Videos ([count] found, threshold: [X] views)
1. [Title] - [views] views ([multiplier]x median)
2. [Title] - [views] views ([multiplier]x median)
3. [Title] - [views] views ([multiplier]x median)

### Strategic Insights
- **Strength**: [what they do well]
- **Weakness**: [content gap or missed opportunity]
- **Opportunity**: [what you could do differently]
```

## Related

- `youtube.md` - Main YouTube orchestrator (this directory)
- `topic-research.md` - Find content gaps from intel data
- `optimizer.md` - Apply outlier title/tag patterns
- `seo/keyword-research.md` - Deep keyword analysis
- `tools/data-extraction/outscraper.md` - YouTube comment extraction
