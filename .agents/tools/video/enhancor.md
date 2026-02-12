---
mode: subagent
model: sonnet
tools: [bash, read, write, edit]
---

# Enhancor AI - Portrait and Image Enhancement

**Purpose**: AI-powered portrait enhancement, image upscaling, and generation via Enhancor AI API.

**CLI**: `enhancor-helper.sh` - REST API client for Enhancor AI services

**Base URL**: `https://apireq.enhancor.ai/api`

**Authentication**: API key via `x-api-key` header (stored in `aidevops secret` or `~/.config/aidevops/credentials.sh`)

## Quick Start

```bash
# Setup API key
aidevops secret set ENHANCOR_API_KEY

# Skin enhancement with v3 model
enhancor-helper.sh enhance --img-url https://example.com/portrait.jpg \
    --model enhancorv3 --skin-refinement 50 --resolution 2048 --sync -o result.png

# Portrait upscale (professional mode)
enhancor-helper.sh upscale --img-url https://example.com/portrait.jpg \
    --mode professional --sync -o upscaled.png

# AI image generation
enhancor-helper.sh generate "A serene mountain landscape at sunset" \
    --model kora_pro_cinema --generation-mode 4k_ultra --size landscape_16:9 \
    --sync -o generated.png
```

## Capabilities

### 1. Realistic Skin Enhancement

Advanced portrait enhancement with granular control over facial features and skin refinement.

**API Path**: `/realistic-skin/v1`

**Models**:
- `enhancorv1`: Standard model with face/body modes
- `enhancorv3`: Advanced model with mask support and higher resolution

**Enhancement Modes** (v1 only):
- `standard`: Balanced enhancement
- `heavy`: Intensive enhancement with portrait depth control

**Enhancement Types**:
- `face`: Facial enhancement (default)
- `body`: Full body enhancement

**Key Parameters**:
- `skin_refinement_level` (0-100): Skin texture enhancement intensity
- `skin_realism_Level`: Realism level (v1: 0-5, v3: 0-3)
- `portrait_depth` (0.2-0.4): Portrait depth (v3 or v1 heavy mode)
- `output_resolution` (1024-3072): Output size (v3 only)
- `mask_image_url`: Mask for selective enhancement (v3 only)
- `mask_expand` (-20 to 20): Mask expansion amount (v3 only)

**Area Control** (keep unchanged):
- `background`, `skin`, `nose`, `eye_g`, `r_eye`, `l_eye`
- `r_brow`, `l_brow`, `r_ear`, `l_ear`, `mouth`, `u_lip`, `l_lip`
- `hair`, `hat`, `ear_r`, `neck_l`, `neck`, `cloth`

**CLI Usage**:

```bash
# Basic enhancement
enhancor-helper.sh enhance --img-url URL --sync -o output.png

# Advanced v3 with granular control
enhancor-helper.sh enhance --img-url URL \
    --model enhancorv3 \
    --skin-refinement 70 \
    --skin-realism 1.5 \
    --portrait-depth 0.3 \
    --resolution 2048 \
    --area-background \
    --area-hair \
    --sync -o enhanced.png

# With mask (v3 only)
enhancor-helper.sh enhance --img-url URL \
    --model enhancorv3 \
    --mask-url https://example.com/mask.png \
    --mask-expand 10 \
    --sync -o masked_enhanced.png
```

### 2. Portrait Upscaler

Specialized upscaling for portrait images with facial feature optimization.

**API Path**: `/upscaler/v1`

**Modes**:
- `fast`: Quick processing with good quality
- `professional`: Higher quality with enhanced details

**CLI Usage**:

```bash
# Fast mode
enhancor-helper.sh upscale --img-url URL --mode fast --sync -o upscaled.png

# Professional mode
enhancor-helper.sh upscale --img-url URL --mode professional --sync -o upscaled.png
```

### 3. General Image Upscaler

Universal upscaling for all image types (not just portraits).

**API Path**: `/general-upscaler/v1`

**CLI Usage**:

```bash
enhancor-helper.sh upscale-general --img-url URL --sync -o upscaled.png
```

### 4. Detailed API

Advanced upscaling combined with detailed enhancement for professional work.

**API Path**: `/detailed/v1`

**CLI Usage**:

```bash
enhancor-helper.sh detailed --img-url URL --sync -o detailed.png
```

### 5. Kora Pro - AI Image Generation

Generate images from text prompts with cinematic AI models.

**API Path**: `/kora/v1`

**Models**:
- `kora_pro`: Standard high-quality generation
- `kora_pro_cinema`: Cinematic style generation

**Generation Modes**:
- `normal`: Standard resolution, quick generation
- `2k_pro`: 2K resolution, high quality
- `4k_ultra`: 4K resolution, maximum quality

**Image Sizes**:
- `portrait_3:4`: Standard portrait (3:4)
- `portrait_9:16`: Mobile/story format (9:16)
- `square`: Square format (1:1)
- `landscape_4:3`: Standard landscape (4:3)
- `landscape_16:9`: Widescreen format (16:9)
- `custom_WIDTH_HEIGHT`: Custom dimensions (e.g., `custom_2048_1536`)

**CLI Usage**:

```bash
# Basic text-to-image
enhancor-helper.sh generate "A serene mountain landscape at sunset" \
    --sync -o generated.png

# Cinematic 4K generation
enhancor-helper.sh generate "Epic sci-fi cityscape with neon lights" \
    --model kora_pro_cinema \
    --generation-mode 4k_ultra \
    --size landscape_16:9 \
    --sync -o cinematic.png

# Image-to-image with custom size
enhancor-helper.sh generate "Transform into watercolor painting style" \
    --img-url https://example.com/reference.jpg \
    --generation-mode 2k_pro \
    --size custom_2048_1536 \
    --sync -o transformed.png
```

## Async Queue-Based API

All Enhancor APIs use an async queue-based workflow:

1. **Queue**: Submit request, receive `requestId`
2. **Poll**: Check status via `/status` endpoint
3. **Webhook**: Optional callback when complete
4. **Download**: Retrieve result from returned URL

**Status Codes**:
- `PENDING`: Request pending processing
- `IN_QUEUE`: Request in processing queue
- `IN_PROGRESS`: Request being processed
- `COMPLETED`: Request completed successfully
- `FAILED`: Request failed

**Sync Mode**: Use `--sync` flag to automatically poll and download result.

**Manual Status Check**:

```bash
enhancor-helper.sh status REQUEST_ID --api /realistic-skin/v1
```

## Batch Processing

Process multiple images from a file (one URL per line):

```bash
# Create input file
cat > urls.txt <<EOF
https://example.com/portrait1.jpg
https://example.com/portrait2.jpg
https://example.com/portrait3.jpg
EOF

# Batch enhance
enhancor-helper.sh batch --command enhance --input urls.txt \
    --output-dir results/ --model enhancorv3 --skin-refinement 50

# Batch upscale
enhancor-helper.sh batch --command upscale --input urls.txt \
    --output-dir results/ --mode professional
```

## Webhook Notifications

Configure webhook URL to receive completion notifications:

```bash
enhancor-helper.sh enhance --img-url URL --webhook https://your-webhook.com/callback
```

**Webhook Payload**:

```json
{
  "request_id": "unique_request_id",
  "result": "https://example.com/processed-image.png",
  "status": "success"
}
```

## Integration with Content Pipeline

Enhancor integrates into the content production pipeline as a post-processing step for portrait and headshot content.

**Workflow**:

1. **Generate/capture** initial image (camera, AI generation, stock)
2. **Enhance** with Enhancor (skin refinement, upscaling)
3. **Optimize** for web delivery (compression, format conversion)
4. **Distribute** to target platforms

**See**: `content/production/image.md` for full integration details.

## Use Cases

**Portrait Enhancement**:
- Professional headshots
- Social media profile pictures
- Dating app photos
- Corporate photography
- Event photography

**Image Upscaling**:
- Print-ready enlargements
- High-resolution displays
- Archival restoration
- Low-quality source recovery

**AI Generation**:
- Marketing visuals
- Social media content
- Concept art
- Product mockups
- Creative content

## Cost Optimization

**Model Selection**:
- Use `enhancorv1` for basic enhancement (lower cost)
- Use `enhancorv3` for advanced features (mask support, higher resolution)
- Use `fast` mode for upscaling when speed matters
- Use `professional` mode for final deliverables

**Generation Modes**:
- `normal`: Testing and iteration
- `2k_pro`: Professional work
- `4k_ultra`: Print and maximum quality only

**Batch Processing**:
- Process multiple images in one session
- Reduces API overhead
- Easier result management

## Error Handling

The helper script handles common errors:

- **Missing API key**: Prompts for setup via `aidevops secret`
- **Invalid parameters**: Clear error messages with usage examples
- **API errors**: Displays full error response from API
- **Timeout**: Configurable via `--timeout` (default: 600s)
- **Download failures**: Retries and reports errors

**Polling Configuration**:

```bash
# Custom poll interval and timeout
enhancor-helper.sh enhance --img-url URL \
    --sync --poll 10 --timeout 900 -o result.png
```

## API Reference

**Helper Script**: `.agents/scripts/enhancor-helper.sh`

**Commands**:
- `enhance`: Realistic skin enhancement
- `upscale`: Portrait upscaler
- `upscale-general`: General image upscaler
- `detailed`: Detailed API
- `generate`: Kora Pro AI generation
- `status`: Check request status
- `batch`: Batch processing
- `setup`: API key setup
- `help`: Show help message

**Global Options**:
- `--sync`: Wait for completion and download result
- `--poll SECONDS`: Poll interval (default: 5)
- `--timeout SECONDS`: Timeout (default: 600)
- `--output, -o FILE`: Output file path (requires --sync)
- `--webhook URL`: Webhook URL for completion notification

**Environment Variables**:
- `ENHANCOR_API_KEY`: API key for authentication

## Resources

- **Website**: https://www.enhancor.ai/
- **API Docs**: https://github.com/rohan-kulkarni-25/enhancor-api-docs
- **Helper Script**: `.agents/scripts/enhancor-helper.sh:1`
- **Integration**: `content/production/image.md` (post-processing step)

## Examples

### Professional Headshot Enhancement

```bash
# High-quality headshot with v3 model
enhancor-helper.sh enhance --img-url https://example.com/headshot.jpg \
    --model enhancorv3 \
    --type face \
    --skin-refinement 60 \
    --skin-realism 1.2 \
    --portrait-depth 0.25 \
    --resolution 2048 \
    --area-background \
    --sync -o professional_headshot.png
```

### Social Media Content Generation

```bash
# Generate cinematic portrait for social media
enhancor-helper.sh generate "Professional portrait of a confident entrepreneur" \
    --model kora_pro_cinema \
    --generation-mode 2k_pro \
    --size portrait_9:16 \
    --sync -o social_portrait.png
```

### Batch Portrait Processing

```bash
# Process entire photoshoot
cat > photoshoot.txt <<EOF
https://example.com/photo1.jpg
https://example.com/photo2.jpg
https://example.com/photo3.jpg
EOF

enhancor-helper.sh batch --command enhance --input photoshoot.txt \
    --output-dir enhanced_photoshoot/ \
    --model enhancorv3 \
    --skin-refinement 50 \
    --resolution 2048
```

### Image Restoration and Upscaling

```bash
# Restore old photo with detailed enhancement
enhancor-helper.sh detailed --img-url https://example.com/old_photo.jpg \
    --sync -o restored.png
```

## Tips for Best Results

**Skin Enhancement**:
- Start with `skin_refinement_level` 40-60 for natural results
- Use `skin_realism_Level` 1.0-2.0 for v1, 0.1-0.5 for v3
- Enable area control for background/hair to preserve non-skin areas
- Use v3 with masks for selective enhancement

**Upscaling**:
- Use `professional` mode for final deliverables
- Use `fast` mode for testing and iteration
- Portrait upscaler is optimized for faces (better than general upscaler)

**AI Generation**:
- Detailed prompts yield better results
- Include style descriptors (photorealistic, oil painting, minimalist)
- Use `4k_ultra` only for final production (slower, more expensive)
- Experiment with `kora_pro_cinema` for dramatic, cinematic effects

**Batch Processing**:
- Test parameters on single image first
- Use consistent parameters across batch for uniform results
- Monitor output directory for failures
- Consider rate limits and API quotas
