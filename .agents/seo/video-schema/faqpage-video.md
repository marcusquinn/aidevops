<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# FAQPage with VideoObject

Combine FAQ structured data with video for pages that answer multiple questions.

```json
[
  {
    "@context": "https://schema.org",
    "@type": "VideoObject",
    "name": "Cold Brew FAQ",
    "description": "Answers to the 5 most common cold brew questions.",
    "thumbnailUrl": "https://example.com/thumb.jpg",
    "uploadDate": "2026-01-15"
  },
  {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    "mainEntity": [
      {
        "@type": "Question",
        "name": "What is the cold brew coffee ratio?",
        "acceptedAnswer": {
          "@type": "Answer",
          "text": "The standard ratio is 1:8 coffee to water by weight for a concentrate."
        }
      }
    ]
  }
]
```
