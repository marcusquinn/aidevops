<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# VideoObject (Required for All Video Pages)

```json
{
  "@context": "https://schema.org",
  "@type": "VideoObject",
  "name": "How to Make Cold Brew Coffee",
  "description": "Step-by-step cold brew guide with ratio science and steeping times.",
  "thumbnailUrl": "https://example.com/cold-brew-thumb.jpg",
  "uploadDate": "2026-01-15T08:00:00+00:00",
  "duration": "PT8M30S",
  "contentUrl": "https://example.com/videos/cold-brew.mp4",
  "embedUrl": "https://www.youtube.com/embed/VIDEO_ID",
  "interactionStatistic": {
    "@type": "InteractionCounter",
    "interactionType": "https://schema.org/WatchAction",
    "userInteractionCount": 12400
  }
}
```

**Required fields**: `name`, `description`, `thumbnailUrl`, `uploadDate`.
**For Key Moments eligibility**: add `hasPart` with `Clip` segments.
