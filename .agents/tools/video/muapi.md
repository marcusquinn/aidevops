---
description: MuAPI - multimodal AI API for image, video, audio, VFX, workflows, and agents
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: true
  task: false
---

# MuAPI

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Unified API for multimodal AI generation (image, video, audio, VFX, music, lipsync, specialized apps, storyboarding, workflows, agents)
- **API**: REST API at `https://api.muapi.ai/api/v1`
- **Auth**: API key via `x-api-key` header, stored as `MUAPI_API_KEY` env var
- **CLI**: `muapi-helper.sh [flux|video-effects|vfx|motion|music|lipsync|face-swap|upscale|bg-remove|dress-change|stylize|product-shot|storyboard|agent-*|balance|usage|status|help]`
- **Pattern**: Async submit + poll (same as WaveSpeed/Runway)
- **Docs**: [muapi.ai/docs](https://muapi.ai/docs/introduction)

**When to use**:

- Generating images (Flux Dev/Schnell/Pro/Max, Midjourney v7, HiDream)
- Generating video (Wan 2.1/2.2, Runway Gen-3, Kling v2.1, Luma Dream Machine)
- AI video effects (stylization, animation, pretrained effects like VHS, Film Noir, Samurai)
- VFX (explosions, disintegration, levitation, elemental forces)
- Motion controls (zoom, spin, shake, pan, rotate, bounce, 360 orbit)
- Music generation (Suno create/remix/extend)
- Lip-synchronization (Sync-Lipsync, LatentSync, Creatify, Veed)
- Audio utilities (MMAudio text-to-audio, video-to-video audio sync)
- Specialized apps (face swap, skin enhancer, dress change, upscale, background removal, object eraser, image extension, product photography, Ghibli/anime stylization)
- Storyboarding (character persistence, scene management, episodic structure)
- Multi-step workflows (node-based AI pipelines via API)
- AI agents (persistent personas with skills and memory)
- Payments and credits (balance check, usage tracking)

<!-- AI-CONTEXT-END -->

## Setup

### 1. Get API Key

1. Sign up at [muapi.ai/signup](https://muapi.ai/signup)
2. Go to [muapi.ai/access-keys](https://muapi.ai/access-keys)
3. Generate a new API key
4. Copy and store securely (shown only once)

### 2. Store Credentials

```bash
aidevops secret set MUAPI_API_KEY
# Or plaintext fallback:
echo 'export MUAPI_API_KEY="your-key-here"' >> ~/.config/aidevops/credentials.sh
chmod 600 ~/.config/aidevops/credentials.sh
```

### 3. Test Connection

```bash
muapi-helper.sh flux "A test image" --sync
```

## API Reference

### Base URL

```text
https://api.muapi.ai/api/v1
```

All requests require `x-api-key: $MUAPI_API_KEY` header.

### Authentication

```bash
curl -X POST "https://api.muapi.ai/api/v1/endpoint" \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${MUAPI_API_KEY}" \
  -d '{"param1": "value1"}'
```

### Async Pattern (Submit + Poll)

All generation endpoints return a `request_id`. Poll for results:

```bash
# Submit task
curl -X POST "https://api.muapi.ai/api/v1/{endpoint}" \
  -H "x-api-key: ${MUAPI_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "...", ...}'

# Poll for result
curl -X GET "https://api.muapi.ai/api/v1/predictions/${request_id}/result" \
  -H "x-api-key: ${MUAPI_API_KEY}"
```

Statuses: `processing` -> `completed` | `failed`

### Webhooks

Add `?webhook=https://your.endpoint` as query parameter to any generation endpoint to receive a POST notification on completion instead of polling.

## Endpoints

### Image Generation (Flux Dev)

```bash
POST /api/v1/flux-dev-image
```

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `prompt` | string | Yes | - | Text prompt for image generation |
| `image` | string | No | - | Reference image URL (img2img) |
| `mask_image` | string | No | - | Mask for inpainting (white=generate, black=preserve) |
| `strength` | number | No | 0.8 | Transform strength for reference image (0.0-1.0) |
| `size` | string | No | 1024*1024 | Output size (512-1536 per dimension) |
| `num_inference_steps` | integer | No | 28 | Inference steps (1-50) |
| `seed` | integer | No | -1 | Reproducibility seed (-1 for random) |
| `guidance_scale` | number | No | 3.5 | CFG scale (1.0-20.0) |
| `num_images` | integer | No | 1 | Number of images (1-4) |

### AI Video Effects

```bash
POST /api/v1/generate_wan_ai_effects
```

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `prompt` | string | Yes | - | Effect description |
| `image_url` | string | Yes | - | Source image URL |
| `name` | string | Yes | - | Effect name (e.g., "Cakeify", "Film Noir", "VHS Footage") |
| `aspect_ratio` | string | No | 16:9 | 1:1, 9:16, 16:9 |
| `resolution` | string | No | 480p | 480p, 720p |
| `quality` | string | No | medium | medium, high |
| `duration` | number | No | 5 | 5-10 seconds |

### VFX (Visual Effects)

Same endpoint as AI Video Effects (`POST /api/v1/generate_wan_ai_effects`) with VFX-specific effect names:

- Building Explosion, Car Explosion, Disintegration, Levitation
- Lightning, Tornado, Fire, Ice, and more

### Motion Controls

Same endpoint as AI Video Effects (`POST /api/v1/generate_wan_ai_effects`) with motion-specific effect names:

- 360 Orbit, Zoom In/Out, Spin, Shake, Bounce, Pan Left/Right

### Music Generation (Suno)

```bash
POST /api/v1/suno-create-music    # Generate new tracks
POST /api/v1/suno-remix-music     # Remix existing audio
POST /api/v1/suno-extend-music    # Extend existing tracks
```

### Lip-Synchronization

```bash
POST /api/v1/sync-lipsync         # Sync-Lipsync (high-fidelity)
POST /api/v1/latentsync-video     # LatentSync (fast)
POST /api/v1/creatify-lipsync     # Creatify
POST /api/v1/veed-lipsync         # Veed
```

### Audio Utilities (MMAudio)

```bash
POST /api/v1/mmaudio-v2/text-to-audio     # Text to audio/Foley/SFX
POST /api/v1/mmaudio-v2/video-to-video     # Sync audio with video
```

### Workflows

```bash
POST /api/workflow/{workflow_id}/run    # Execute a workflow
```

Workflows are multi-node execution graphs combining text, image, video, audio, and utility nodes. Build via the web UI or the Agentic Workflow Architect (natural language).

### Agents

```bash
POST   /agents/quick-create              # Create agent from goal
POST   /agents/suggest                   # Get agent config suggestion
GET    /agents/skills                    # List available skills
POST   /agents                           # Create agent with skills
GET    /agents/user/agents               # List user's agents
GET    /agents/{agent_id}                # Get agent details
PUT    /agents/{agent_id}                # Update agent
DELETE /agents/{agent_id}                # Delete agent
POST   /agents/{agent_id}/chat           # Chat with agent
```

Agents are persistent AI personas with skills, memory (via `conversation_id`), and access to the full model catalog.

### Specialized Apps

All specialized apps follow the standard async submit + poll pattern. Submit with input data, receive `request_id`, poll at `/api/v1/predictions/{id}/result`.

#### Portrait & Identity

```bash
POST /api/v1/ai-image-face-swap         # Face swap on images
POST /api/v1/ai-video-face-swap         # Face swap on videos
POST /api/v1/ai-skin-enhancer           # Skin retouching and blemish removal
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `image` / `image_url` | string | Yes | Source image/video URL |
| `face_image` | string | Yes (face-swap) | Face reference image URL |

#### Creative Transformations

```bash
POST /api/v1/ai-dress-change            # Swap outfits via text or reference
POST /api/v1/ai-ghibli-style            # Studio Ghibli stylization
POST /api/v1/ai-anime-generator         # Anime style transformation
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `image_url` | string | Yes | Source image URL |
| `prompt` | string | No | Description of desired outfit/style |

#### Image Processing & Utilities

```bash
POST /api/v1/ai-image-upscale           # Increase resolution with detail regeneration
POST /api/v1/ai-background-remover      # High-precision subject isolation
POST /api/v1/ai-object-eraser           # Remove unwanted elements with inpainting
POST /api/v1/ai-image-extension         # Outpaint beyond original borders
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `image_url` | string | Yes | Source image URL |
| `mask_url` | string | No (eraser) | Mask indicating area to erase |
| `prompt` | string | No (extension) | Description for outpainted area |

#### Product & Marketing

```bash
POST /api/v1/ai-product-shot            # Studio-quality product backgrounds
POST /api/v1/ai-product-photography     # High-converting product assets
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `image_url` | string | Yes | Product image URL |
| `prompt` | string | No | Background/scene description |

### Storyboarding

Cinematic production system with character persistence across scenes and episodes.

```bash
POST /api/storyboard/projects           # Create storyboard project
```

**Process**:

1. **Character Creation** — Define `StoryboardCharacter` with static features (age, hair) and dynamic features (outfit, mood)
2. **Project Setup** — Create project housing characters and creative brief
3. **Episode Generation** — Generate or manually create episodes within the project
4. **Scene & Shot Definition** — Link shots to characters and backgrounds for visual consistency

Asset generation uses models like Flux and Runway. Storyboard assets can feed into workflows for post-processing (VFX, color grading).

### Payments & Credits

Credit-based consumption system with Stripe integration.

```bash
GET /api/payments/create_credits_checkout_session   # Purchase credits via Stripe
```

- **Credit Wallet** — Every user has a `CreditWallet`; generations deduct credits based on model cost and duration
- **Usage Log** — Complete history of API calls with cost, status, input/output data
- **Enterprise** — Custom credit limits, private deployment billing, multi-key project tracking

## CLI Helper

```bash
# Image generation (Flux Dev)
muapi-helper.sh flux "A cyberpunk city at night"
muapi-helper.sh flux "A portrait" --size 1024*1536 --steps 40

# AI Video Effects
muapi-helper.sh video-effects "a cute kitten" --image https://example.com/cat.jpg --effect "Cakeify"
muapi-helper.sh video-effects "dramatic scene" --image https://example.com/scene.jpg --effect "Film Noir"

# VFX
muapi-helper.sh vfx "a car" --image https://example.com/car.jpg --effect "Car Explosion"

# Motion Controls
muapi-helper.sh motion "a person" --image https://example.com/person.jpg --effect "360 Orbit"

# Music
muapi-helper.sh music "upbeat electronic track with synths"

# Lip-sync
muapi-helper.sh lipsync --video https://example.com/video.mp4 --audio https://example.com/audio.mp3

# Specialized apps
muapi-helper.sh face-swap --image https://example.com/photo.jpg --face https://example.com/face.jpg
muapi-helper.sh face-swap --video https://example.com/video.mp4 --face https://example.com/face.jpg --mode video
muapi-helper.sh upscale --image https://example.com/lowres.jpg
muapi-helper.sh bg-remove --image https://example.com/product.jpg
muapi-helper.sh dress-change --image https://example.com/person.jpg "red evening gown"
muapi-helper.sh stylize --image https://example.com/photo.jpg --style ghibli
muapi-helper.sh product-shot --image https://example.com/product.jpg "minimalist white studio"
muapi-helper.sh object-erase --image https://example.com/scene.jpg --mask https://example.com/mask.png
muapi-helper.sh image-extend --image https://example.com/photo.jpg "extend the landscape"
muapi-helper.sh skin-enhance --image https://example.com/portrait.jpg

# Credits
muapi-helper.sh balance
muapi-helper.sh usage

# Check task status
muapi-helper.sh status <request-id>

# Agent operations
muapi-helper.sh agent-create "I want an agent that creates brand assets"
muapi-helper.sh agent-chat <agent-id> "Design a logo for Vapor"
muapi-helper.sh agent-list
```

## Available Models

### Image

| Model | Notes |
|-------|-------|
| Flux Dev/Schnell/Pro/Max | Professional text-to-image |
| Midjourney v7 | Aesthetic quality, reference support |
| HiDream | Speed-optimized, stylized |

### Video

| Model | Notes |
|-------|-------|
| Wan 2.1/2.2 | Speech-to-video, LoRA support |
| Runway Gen-3/Act-Two | Cinematic motion |
| Kling v2.1 | Exceptional realism |
| Luma Dream Machine | Video reframing |

### Audio

| Model | Notes |
|-------|-------|
| Suno | Music create/remix/extend |
| MMAudio-v2 | Text-to-audio, video-to-audio sync |
| Sync-Lipsync/LatentSync | Lip synchronization |

## MuAPI vs WaveSpeed vs Runway

| Feature | MuAPI | WaveSpeed | Runway |
|---------|-------|-----------|--------|
| Image models | Flux, Midjourney, HiDream | Flux, DALL-E, Imagen, Z-Image | Gen-4 Image, Gemini |
| Video models | Wan, Runway, Kling, Luma | Wan, Kling, Sora, Veo | Gen-4, Veo 3, Act Two |
| Audio | Suno music, MMAudio, lipsync | Ace Step music, TTS | ElevenLabs TTS/STS/SFX |
| VFX/Effects | Built-in effects library | None | None |
| Specialized Apps | Face swap, upscale, bg-remove, dress change, stylize, product shot | None | None |
| Storyboarding | Character persistence, episodic structure | None | None |
| Workflows | Node-based pipeline builder | None | None |
| Agents | Persistent AI personas | None | None |
| Auth | `x-api-key` header | Bearer token | Bearer token |
| Best for | Creative orchestration, effects | Unified model access | Full media pipeline |

## Troubleshooting

### "Unauthorized" or 401

1. Verify key is set: `echo "${MUAPI_API_KEY:+set}"`
2. Check key was copied correctly from dashboard
3. Verify account has credits

### Task stuck in "processing"

Video and effects tasks can take 1-2 minutes. The helper polls with configurable interval and timeout. For long tasks, use `--timeout 600`.

### Effect not found

Effect names are case-sensitive. Use the exact name from the MuAPI playground (e.g., "Cakeify", "Film Noir", "Car Explosion", "360 Orbit").

## Related

- [MuAPI Documentation](https://muapi.ai/docs/introduction)
- [MuAPI Playground](https://muapi.ai/playground)
- `tools/video/wavespeed.md` - WaveSpeed AI (alternative unified API)
- `tools/video/runway.md` - Runway API (alternative media pipeline)
- `tools/video/video-prompt-design.md` - Prompt engineering for video models
- `tools/vision/image-generation.md` - Image generation workflows
- `content/production/video.md` - Video production pipeline
- `content/production/audio.md` - Audio production pipeline
