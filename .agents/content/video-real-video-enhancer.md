---
description: "REAL Video Enhancer - AI-powered video upscaling, interpolation, denoising, and decompression using RIFE, SPAN, Real-ESRGAN, and more"
mode: subagent
upstream_url: https://github.com/TNTwise/REAL-Video-Enhancer
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# REAL Video Enhancer

<!-- AI-CONTEXT-START -->

## Quick Reference

- **CLI**: `real-video-enhancer-helper.sh [install|enhance|interpolate|upscale|denoise|models|backends|help]`
- **Platform**: Linux/Windows/macOS, Python 3.10-3.12, Qt GUI + CLI
- **Use when**: Post-processing AI-generated or existing video — upscale, interpolate, denoise, remove H.264 artifacts

**Capabilities**:

| Feature | Models | Output |
|---------|--------|--------|
| Frame Interpolation | RIFE, GMFSS, IFRNet | 24fps → 48/60fps |
| Upscaling | SPAN, Real-ESRGAN, AnimeJaNai | 2x/4x resolution |
| Denoising | DRUnet, DnCNN | Noise reduction |
| Decompression | DeH264 | H.264 artifact removal |

**Backend** (auto-detected):

```text
NVIDIA (CUDA 11.8+) → TensorRT (fastest, 2-5x speedup)
AMD (ROCm 5.7+)     → PyTorch ROCm
Apple/Intel         → NCNN Vulkan
No GPU              → NCNN CPU (slow)
```

<!-- AI-CONTEXT-END -->

## Installation

```bash
real-video-enhancer-helper.sh install                       # auto-detect
real-video-enhancer-helper.sh install --backend tensorrt    # NVIDIA
real-video-enhancer-helper.sh install --backend pytorch     # AMD/CUDA
real-video-enhancer-helper.sh install --backend ncnn        # CPU/Vulkan
```

Requirements: Python 3.10-3.12, 8GB+ RAM (16GB+ for 4K), 2-10GB model cache.

## Usage

```bash
real-video-enhancer-helper.sh upscale input.mp4 output.mp4 --scale 2
real-video-enhancer-helper.sh interpolate input.mp4 output.mp4 --fps 60
real-video-enhancer-helper.sh enhance input.mp4 output.mp4 --scale 2 --fps 60 --denoise
real-video-enhancer-helper.sh batch /raw/ /enhanced/ --scale 2 --fps 60 --parallel 2

# Custom models + backend
real-video-enhancer-helper.sh enhance input.mp4 output.mp4 \
  --upscale-model span --interpolate-model gmfss --denoise-model drunet \
  --scale 2 --fps 60
real-video-enhancer-helper.sh upscale input.mp4 output.mp4 --backend tensorrt --scale 2
real-video-enhancer-helper.sh upscale input.mp4 output.mp4 --scale 2 --tile-size 512  # low VRAM

# Diagnostics
real-video-enhancer-helper.sh backends [--verbose]
real-video-enhancer-helper.sh models list
real-video-enhancer-helper.sh models clear
```

## Model Reference

| Type (`--flag`) | Model | Speed | Quality | Use Case |
|-----------------|-------|-------|---------|----------|
| Interpolation (`--interpolate-model`) | rife | Fast | High | General purpose |
| Interpolation | gmfss | Medium | Very High | Cinematic/complex motion |
| Interpolation | ifrnet | Very Fast | Medium | Low-end hardware |
| Upscaling (`--upscale-model`) | span | Fast | High | General purpose |
| Upscaling | realesrgan-x4plus | Medium | Very High | Photo-realistic |
| Upscaling | animejaNai | Medium | High | Anime/animation |
| Denoising (`--denoise-model`) | drunet | Medium | High | High quality |
| Denoising | dncnn | Fast | Medium | Fast/light |
| Decompression | deh264 | — | — | H.264 artifact removal |

Model cache: `~/.cache/real-video-enhancer/models/` (auto-downloaded on first use).  
Sizes: RIFE ~200MB, SPAN ~150MB, Real-ESRGAN ~65MB, GMFSS ~300MB, DRUnet ~50MB.

## Performance

| Backend | GPU | Time (1080p→4K, 30s) |
|---------|-----|----------------------|
| TensorRT | RTX 4090 | 45s |
| PyTorch CUDA | RTX 4090 | 2m 15s |
| PyTorch ROCm | RX 7900 XTX | 3m 30s |
| NCNN Vulkan | RTX 4090 | 4m 45s |
| NCNN CPU | Ryzen 9 7950X | 18m 20s |

Use TensorRT on NVIDIA for production. Default tile-size 1024; reduce to 512/256 for low VRAM.

## Troubleshooting

| Error | Fix |
|-------|-----|
| CUDA out of memory | `--tile-size 512` or switch to NCNN |
| Model not found | Check internet; verify `~/.cache/real-video-enhancer/models/` is writable |
| Unsupported codec | `ffmpeg -i input.mp4 -c:v libx264 output.mp4` |
| Slow on NVIDIA | Verify TensorRT: `real-video-enhancer-helper.sh backends` |

## Related

- `video-gen-helper.sh` — AI video generation (Sora, Veo, Higgsfield)
- `content/production-video.md` — full production pipeline
- `remotion` — programmatic video creation
- GitHub: https://github.com/TNTwise/REAL-Video-Enhancer (GPL-3.0)
