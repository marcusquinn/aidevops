<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Clip (Google Key Moments)

Add `hasPart` array to `VideoObject`. Each `Clip` maps to one chapter.

```json
"hasPart": [
  {
    "@type": "Clip",
    "name": "Cold Brew Ratio",
    "startOffset": 90,
    "endOffset": 240,
    "url": "https://youtu.be/VIDEO_ID?t=90"
  },
  {
    "@type": "Clip",
    "name": "Steeping Time",
    "startOffset": 240,
    "endOffset": 390,
    "url": "https://youtu.be/VIDEO_ID?t=240"
  }
]
```

`startOffset` and `endOffset` are in seconds. `name` must match a search query for Key Moments eligibility — use the same phrasing as YouTube chapter titles.
