# Post-Production Guidelines

## Upscaling

**REAL Video Enhancer** (open-source, GPU-accelerated):

```bash
real-video-enhancer-helper.sh upscale input.mp4 output.mp4 --scale 2
real-video-enhancer-helper.sh upscale input.mp4 output.mp4 --scale 4 --model realesrgan
# Models: span (fast, default), realesrgan (photo-realistic), animejanai (animation)
```

**Topaz Video AI** (commercial): Max 1.25-1.75x upscale. Settings: Artemis High Quality, low noise reduction, minimal sharpening, grain preservation on. 4K→8K NOT RECOMMENDED.

## Frame Rate Conversion

```bash
real-video-enhancer-helper.sh interpolate input.mp4 output.mp4 --fps 60
# Models: rife (fast, default), gmfss (very high quality), ifrnet (very fast)
```

**CRITICAL**: Never upconvert 24fps to 60fps for non-action content (creates soap opera effect).

## Denoising and Full Enhancement Pipeline

```bash
real-video-enhancer-helper.sh denoise input.mp4 output.mp4
# All-in-one for social media delivery:
real-video-enhancer-helper.sh enhance input.mp4 output.mp4 --scale 2 --fps 60 --denoise
```

## Film Grain

Add subtle grain for organic, less-AI-detected aesthetic. DaVinci Resolve settings: grain_size 0.5-0.8, intensity 5-10%, color_variation 2-5%. Always for cinematic; optional for UGC; selective for commercial.

See `tools/video/real-video-enhancer.md` for full documentation.
