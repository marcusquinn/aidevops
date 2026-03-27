# 2-Track Production Workflow

**Track 1 (Objects & Environments)**: Midjourney → Veo 3.1

```text
/imagine [object/environment description] --ar 16:9 --style raw --v 6
```

Upload Midjourney output as ingredient, apply VEO framework for animation.

**Track 2 (Characters & People)**: Freepik → Seedream 4 → Veo 3.1

```bash
# Refine to 4K via Higgsfield API
curl -X POST 'https://platform.higgsfield.ai/bytedance/seedream/v4/upscale' \
  --header 'Authorization: Key {api_key}:{api_secret}' \
  --data '{"image_url": "https://freepik-output.jpg", "target_resolution": "4K"}'
```

## Track Routing

| Content Type | Track | Reason |
|--------------|-------|--------|
| Product demo | Track 1 | Objects, no facial consistency needed |
| Landscape flythrough | Track 1 | Environment, no characters |
| Talking head | Track 2 | Facial expressions, character consistency |
| Mixed (character + product) | Both | Generate separately, composite in post |
