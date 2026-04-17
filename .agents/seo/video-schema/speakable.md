<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Speakable

Marks page sections for TTS extraction and LLM retrieval prioritisation. Apply to the 1–3 paragraphs that directly answer the primary query.

```json
{
  "@context": "https://schema.org",
  "@type": "WebPage",
  "speakable": {
    "@type": "SpeakableSpecification",
    "cssSelector": ["#transcript p:first-of-type", "h2 + p"]
  },
  "url": "https://example.com/cold-brew-guide"
}
```
