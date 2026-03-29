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

Analyze YouTube channels for competitive insights: upload patterns, engagement metrics, outlier videos, content DNA, and strategic positioning. Use for channel profiling, competitor comparison, outlier detection, content DNA extraction, and engagement ratio calculation.

## Quick Reference

```bash
youtube-helper.sh channel @handle          # Channel overview
youtube-helper.sh videos @handle 200       # Full video list with stats
youtube-helper.sh competitors @c1 @c2 @c3  # Side-by-side comparison
youtube-helper.sh transcript VIDEO_ID      # Transcript of a video
youtube-helper.sh quota                    # Check quota before heavy ops
```

## Channel Profiling Workflow

### Step 1: Basic Channel Data

```bash
youtube-helper.sh channel @handle json
```

Extract: subscriber count, total views, video count, creation date, upload frequency (total videos / channel age).

### Step 2: Video Enumeration

```bash
youtube-helper.sh videos @handle 200 json
```

Calculate: avg views/video, median views, upload frequency, view trend (recent vs historical), duration distribution.

### Step 3: Outlier Detection

Threshold: **3x the channel's median views**.

```bash
youtube-helper.sh videos @handle 200 json | node -e "
process.stdin.on('data', d => {
    const videos = JSON.parse(d);
    const views = videos.map(v => Number(v.statistics?.viewCount || 0)).sort((a,b) => a-b);
    const median = views[Math.floor(views.length / 2)];
    const outliers = videos
        .filter(v => Number(v.statistics?.viewCount || 0) > median * 3)
        .sort((a,b) => Number(b.statistics?.viewCount || 0) - Number(a.statistics?.viewCount || 0));
    console.log('Median:', median.toLocaleString(), '| Threshold (3x):', (median*3).toLocaleString());
    outliers.forEach(v => {
        const vv = Number(v.statistics?.viewCount || 0);
        console.log((vv/median).toFixed(1)+'x |', vv.toLocaleString(), 'views |', v.snippet?.title);
    });
});
"
```

### Step 4: Content DNA Extraction

Analyze outlier videos for: topic clusters, title patterns (numbers/questions/how-to/brackets), duration sweet spot, thumbnail style (use `image-understanding.md`), hook patterns (first 30s of top 5 transcripts).

```bash
for vid in VIDEO_ID_1 VIDEO_ID_2 VIDEO_ID_3; do echo "=== $vid ===" && youtube-helper.sh transcript "$vid" | head -20; done
```

### Step 5: Store Findings in Memory

```bash
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube \
  "Channel @handle: [subs] subs, [views/vid] avg views, [freq] uploads. DNA: [topics], [formats]. Outlier: [description]. Gap: [weakness]."
```

## Competitor Comparison

```bash
youtube-helper.sh competitors @you @comp1 @comp2 @comp3
```

Metrics to compare: subscribers, total views, video count, avg views/video, views/subscriber, upload frequency, avg duration, top topic, outlier count (3x).

## Engagement Metrics

| Metric | Formula | Good Benchmark |
|--------|---------|----------------|
| Views/Subscriber | total_views / subscribers | > 5.0 |
| Avg Views/Video | total_views / video_count | Varies by niche |
| Like Rate | likes / views | > 3% |
| Comment Rate | comments / views | > 0.5% |
| Upload Consistency | std_dev of days between uploads | Lower = better |

## Quota Budget

| Operation | Cost |
|-----------|------|
| Channel lookup (per channel) | 1 unit |
| Video enumeration or details (per 50 videos) | 1 unit |
| Transcripts (via yt-dlp) | 0 units |
| **Full competitor analysis (5 channels, 200 videos each)** | **~50 units** |

Daily limit: 10,000 units.

## Output Format

```markdown
## Channel Profile: [Name] (@handle)

**Overview**: [subscribers] subs · [total_views] views · [video_count] videos · created [date] · [X videos/week]
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
1. [Title] — [views] views ([multiplier]x median)
<!-- repeat for each outlier -->

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
