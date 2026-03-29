---
mode: subagent
model: sonnet
tools: [bash, read, write, edit]
---

# Enhancor AI - Portrait and Image Enhancement

**Purpose**: AI-powered portrait enhancement, image upscaling, and generation via Enhancor AI API.

**CLI**: `enhancor-helper.sh` — `.agents/scripts/enhancor-helper.sh`

**Base URL**: `https://apireq.enhancor.ai/api` | **Auth**: `x-api-key` header — `aidevops secret set ENHANCOR_API_KEY`

**Resources**: [Website](https://www.enhancor.ai/) · [API Docs](https://github.com/rohan-kulkarni-25/enhancor-api-docs)

## Commands

| Command | API Path | Description |
|---------|----------|-------------|
| `enhance` | `/realistic-skin/v1` | Skin enhancement (v1/v3 models) |
| `upscale` | `/upscaler/v1` | Portrait upscaler (face-optimized) |
| `upscale-general` | `/general-upscaler/v1` | General image upscaler |
| `detailed` | `/detailed/v1` | Advanced upscaling + detail enhancement |
| `generate` | `/kora/v1` | Kora Pro AI text-to-image generation |
| `status` | — | Check request status by ID |
| `batch` | — | Batch process from URL file |
| `setup` | — | API key setup |

```bash
# Skin enhancement (v3)
enhancor-helper.sh enhance --img-url URL --model enhancorv3 --skin-refinement 50 --resolution 2048 --sync -o result.png

# Portrait upscale
enhancor-helper.sh upscale --img-url URL --mode professional --sync -o upscaled.png

# AI image generation
enhancor-helper.sh generate "A serene mountain landscape at sunset" \
    --model kora_pro_cinema --generation-mode 4k_ultra --size landscape_16:9 --sync -o generated.png
```

## Enhance Parameters

**Models**: `enhancorv1` (standard — face/body modes, `standard`/`heavy` enhancement) · `enhancorv3` (advanced — mask support, higher resolution, more realism control)

| Parameter | Range | Notes |
|-----------|-------|-------|
| `--skin-refinement` | 0–100 | Skin texture intensity; 40–60 for natural results |
| `--skin-realism` | v1: 0–5, v3: 0–3 | v1 use 1.0–2.0; v3 use 0.1–0.5 |
| `--portrait-depth` | 0.2–0.4 | v3 or v1 heavy mode only |
| `--resolution` | 1024–3072 | v3 only |
| `--type` | `face`/`body` | Enhancement type (default: `face`) |
| `--mask-url` | URL | Selective enhancement mask (v3 only) |
| `--mask-expand` | -20 to 20 | Mask expansion (v3 only) |

**Area control** (pass flags to keep unchanged): `--area-background`, `--area-skin`, `--area-hair`, `--area-nose`, `--area-eye-g`, `--area-r-eye`, `--area-l-eye`, `--area-r-brow`, `--area-l-brow`, `--area-mouth`, `--area-u-lip`, `--area-l-lip`, `--area-neck`, `--area-cloth`

```bash
# v3 with granular control
enhancor-helper.sh enhance --img-url URL \
    --model enhancorv3 --skin-refinement 70 --skin-realism 1.5 \
    --portrait-depth 0.3 --resolution 2048 --area-background --area-hair --sync -o enhanced.png

# With mask (v3 only)
enhancor-helper.sh enhance --img-url URL \
    --model enhancorv3 --mask-url https://example.com/mask.png --mask-expand 10 --sync -o masked.png
```

## Upscale Parameters

| Mode | Use |
|------|-----|
| `fast` | Testing and iteration |
| `professional` | Final deliverables |

```bash
enhancor-helper.sh upscale --img-url URL --mode professional --sync -o upscaled.png
enhancor-helper.sh upscale-general --img-url URL --sync -o upscaled.png
enhancor-helper.sh detailed --img-url URL --sync -o detailed.png
```

## Kora Pro Generation Parameters

| Parameter | Options |
|-----------|---------|
| `--model` | `kora_pro`, `kora_pro_cinema` (cinematic/dramatic) |
| `--generation-mode` | `normal` (testing), `2k_pro` (professional), `4k_ultra` (print/final only) |
| `--size` | `portrait_3:4`, `portrait_9:16`, `square`, `landscape_4:3`, `landscape_16:9`, `custom_WIDTH_HEIGHT` |
| `--img-url` | Reference image for image-to-image |

```bash
# Cinematic 4K
enhancor-helper.sh generate "Epic sci-fi cityscape" \
    --model kora_pro_cinema --generation-mode 4k_ultra --size landscape_16:9 --sync -o cinematic.png

# Image-to-image
enhancor-helper.sh generate "Transform into watercolor painting style" \
    --img-url https://example.com/reference.jpg --generation-mode 2k_pro --size custom_2048_1536 --sync -o transformed.png
```

## Async Queue Workflow

All APIs are async queue-based: **Submit → Poll → Download**

**Status codes**: `PENDING` → `IN_QUEUE` → `IN_PROGRESS` → `COMPLETED` / `FAILED`

Use `--sync` to auto-poll and download. Manual check: `enhancor-helper.sh status REQUEST_ID --api /realistic-skin/v1`

## Global Options

| Option | Default | Description |
|--------|---------|-------------|
| `--sync` | — | Wait for completion and download |
| `--poll SECONDS` | 5 | Poll interval |
| `--timeout SECONDS` | 600 | Max wait time |
| `-o FILE` | — | Output file (requires `--sync`) |
| `--webhook URL` | — | Callback on completion |

**Webhook payload**: `{"request_id": "...", "result": "https://.../image.png", "status": "success"}`

## Batch Processing

```bash
# urls.txt: one URL per line
enhancor-helper.sh batch --command enhance --input urls.txt --output-dir results/ --model enhancorv3 --skin-refinement 50
enhancor-helper.sh batch --command upscale --input urls.txt --output-dir results/ --mode professional
```

Test parameters on a single image first. Use consistent parameters across a batch for uniform results.

## Error Handling

| Error | Behaviour |
|-------|-----------|
| Missing API key | Prompts for setup via `aidevops secret` |
| Invalid parameters | Clear error with usage examples |
| API errors | Full error response displayed |
| Timeout | Configurable via `--timeout` |
| Download failures | Retries and reports |

## Integration

**Content pipeline**: Generate/capture → Enhance (Enhancor) → Optimize → Distribute

See `.agents/content/production-image.md` for full integration details.
