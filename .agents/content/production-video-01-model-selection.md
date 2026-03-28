# Model Selection & Comparison

## Quick Reference

- **Primary Models**: Sora 2 Pro (UGC/authentic, <$10k), Veo 3.1 (cinematic/character-consistent, >$100k)
- **Key Technique**: Seed bracketing (15% → 70%+ success rate)
- **Seed ranges**: people 1000-1999, action 2000-2999, landscape 3000-3999, product 4000-4999, YouTube 2000-3000
- **2-Track production**: objects/environments (Midjourney→VEO) vs characters (Freepik→Seedream→VEO)
- **Veo 3.1**: ALWAYS use ingredients-to-video, NEVER frame-to-video (produces grainy yellow output)

## Decision Tree

```text
Content Type?
├─ UGC/Authentic/Social (<$10k)  → Sora 2 Pro
├─ Cinematic/Commercial (>$100k) → Veo 3.1
└─ Character-Consistent Series   → Veo 3.1 (with Ingredients)
```

## Model Comparison

| Model | Strengths | Limitations | Best For |
|-------|-----------|-------------|----------|
| **Sora 2 Pro** | Authentic UGC, fast (<2 min), lower cost, natural movement | Max 10s, less cinematography control, 1080p native | TikTok, Reels, Shorts, testimonials |
| **Veo 3.1** | Cinematic quality, character consistency, 8K, precise control | Slower (5-10 min), higher cost, complex prompting | Commercials, brand content, character series |
| **Higgsfield** | 100+ models via single API, Kling/Seedance/DOP, webhook support | API-based only, model availability varies | Automated pipelines, batch generation, A/B testing |

## Content Type Presets

| Format | Aspect | Duration | Camera | Model | Seed Range |
|--------|--------|----------|--------|-------|------------|
| UGC | 9:16 | 3-10s | Handheld | Sora 2 Pro | 2000-3000 |
| Commercial | 16:9 | 15-30s | Gimbal | Veo 3.1 | 4000-4999 (product) / 1000-1999 (people) |
| Cinematic | 2.39:1 | 10-30s | Dolly/crane | Veo 3.1 | 3000-3999 / 1000-1999 |
| Documentary | 16:9 | 15-60s | Tripod/handheld | Sora 2 Pro or Veo 3.1 | 2000-2999 / 3000-3999 |

> See Quick Reference above for the full seed range breakdown by content type.
