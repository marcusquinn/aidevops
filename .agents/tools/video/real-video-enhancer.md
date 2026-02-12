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

# REAL Video Enhancer

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: AI-powered video enhancement for upscaling, frame interpolation, denoising, and decompression
- **Primary Use Cases**: Upscale 720p→1080p/4K, interpolate 24fps→48/60fps, denoise compressed video, restore H.264 artifacts
- **Backends**: TensorRT (NVIDIA), PyTorch (CUDA/ROCm), NCNN (Vulkan - CPU/integrated GPU)
- **Platform**: Cross-platform (Linux/Windows/macOS), Python 3.10-3.12, Qt GUI + CLI mode
- **CLI**: `real-video-enhancer-helper.sh [install|enhance|interpolate|upscale|denoise|models|backends|help]`

**When to Use**: Read this when you need to enhance AI-generated or existing video content through upscaling, frame interpolation, denoising, or artifact removal. Integrates into video production workflows as a post-processing step.

**Core Capabilities**:

| Feature | Models | Output |
|---------|--------|--------|
| **Frame Interpolation** | RIFE, GMFSS, IFRNet | 24fps → 48/60fps |
| **Upscaling** | SPAN, Real-ESRGAN, AnimeJaNai | 2x/4x resolution |
| **Denoising** | DRUnet, DnCNN | Noise reduction |
| **Decompression** | DeH264 | H.264 artifact removal |

**Backend Selection** (auto-detected by helper):

```text
GPU Type?
├─ NVIDIA (CUDA 11.8+)
│  └─ TensorRT (fastest, 2-5x speedup)
├─ AMD (ROCm)
│  └─ PyTorch (ROCm backend)
├─ Apple Silicon / Intel
│  └─ NCNN (Vulkan, CPU fallback)
└─ No GPU
   └─ NCNN (CPU mode, slower)
```

**Critical Workflow Integration Points**:
- Post-generation enhancement: After Sora/Veo/Runway generation
- Upscaling: 720p AI output → 1080p/4K delivery
- Interpolation: 24fps cinematic → 60fps social media
- Denoising: Clean up compressed/low-quality source material
- Batch processing: Process entire video libraries

<!-- AI-CONTEXT-END -->

## Installation

Use the helper script for automated installation:

```bash
# Install REAL Video Enhancer with auto-detected backend
real-video-enhancer-helper.sh install

# Install with specific backend
real-video-enhancer-helper.sh install --backend tensorrt  # NVIDIA
real-video-enhancer-helper.sh install --backend pytorch   # AMD/CUDA
real-video-enhancer-helper.sh install --backend ncnn      # CPU/Vulkan
```

**Manual installation** (if helper fails):

```bash
# Clone repository
git clone https://github.com/TNTwise/REAL-Video-Enhancer.git
cd REAL-Video-Enhancer

# Install Python dependencies (Python 3.10-3.12 required)
pip install -r requirements.txt

# Install backend-specific dependencies
# TensorRT (NVIDIA):
pip install tensorrt

# PyTorch CUDA (NVIDIA):
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu118

# PyTorch ROCm (AMD):
pip install torch torchvision --index-url https://download.pytorch.org/whl/rocm5.7

# NCNN (CPU/Vulkan):
pip install ncnn
```

**System Requirements**:
- Python 3.10, 3.11, or 3.12
- 8GB+ RAM (16GB+ recommended for 4K)
- GPU: NVIDIA (CUDA 11.8+), AMD (ROCm 5.7+), or Vulkan-compatible
- Storage: 2-10GB for models (downloaded on first use)

## Usage

### Quick Start

```bash
# Upscale video 2x with auto-detected backend
real-video-enhancer-helper.sh upscale input.mp4 output.mp4 --scale 2

# Interpolate 24fps → 60fps
real-video-enhancer-helper.sh interpolate input.mp4 output.mp4 --fps 60

# Full enhancement pipeline (upscale + interpolate + denoise)
real-video-enhancer-helper.sh enhance input.mp4 output.mp4 \
  --scale 2 \
  --fps 60 \
  --denoise

# Batch process directory
real-video-enhancer-helper.sh batch /path/to/videos/ /path/to/output/ \
  --scale 2 \
  --fps 48
```

### Model Selection

**Interpolation Models**:

| Model | Speed | Quality | Use Case |
|-------|-------|---------|----------|
| **RIFE** | Fast | High | General purpose, 24→48/60fps |
| **GMFSS** | Medium | Very High | Cinematic, complex motion |
| **IFRNet** | Very Fast | Medium | Real-time, low-end hardware |

**Upscaling Models**:

| Model | Speed | Quality | Use Case |
|-------|-------|---------|----------|
| **SPAN** | Fast | High | General purpose, 2x/4x |
| **Real-ESRGAN** | Medium | Very High | Photo-realistic content |
| **AnimeJaNai** | Medium | High | Anime/animation content |

**Denoising Models**:

| Model | Speed | Quality | Use Case |
|-------|-------|---------|----------|
| **DRUnet** | Medium | High | General denoising |
| **DnCNN** | Fast | Medium | Light noise reduction |

**Decompression Models**:

| Model | Speed | Quality | Use Case |
|-------|-------|---------|----------|
| **DeH264** | Fast | High | H.264 artifact removal |

### Advanced Usage

**Custom model selection**:

```bash
# Use specific interpolation model
real-video-enhancer-helper.sh interpolate input.mp4 output.mp4 \
  --fps 60 \
  --model rife-4.6

# Use specific upscaling model
real-video-enhancer-helper.sh upscale input.mp4 output.mp4 \
  --scale 4 \
  --model realesrgan-x4plus

# Chain multiple operations
real-video-enhancer-helper.sh enhance input.mp4 output.mp4 \
  --upscale-model span \
  --interpolate-model gmfss \
  --denoise-model drunet \
  --scale 2 \
  --fps 60
```

**Backend override**:

```bash
# Force specific backend (overrides auto-detection)
real-video-enhancer-helper.sh upscale input.mp4 output.mp4 \
  --backend tensorrt \
  --scale 2

# Check available backends
real-video-enhancer-helper.sh backends
```

**Quality vs Speed tuning**:

```bash
# Maximum quality (slow)
real-video-enhancer-helper.sh enhance input.mp4 output.mp4 \
  --scale 4 \
  --fps 60 \
  --model realesrgan-x4plus \
  --interpolate-model gmfss \
  --denoise

# Balanced (recommended)
real-video-enhancer-helper.sh enhance input.mp4 output.mp4 \
  --scale 2 \
  --fps 48 \
  --model span \
  --interpolate-model rife

# Maximum speed (lower quality)
real-video-enhancer-helper.sh enhance input.mp4 output.mp4 \
  --scale 2 \
  --fps 48 \
  --model span \
  --interpolate-model ifrnet \
  --backend ncnn
```

## Workflow Integration

### Post-Generation Enhancement

After generating video with Sora/Veo/Runway, enhance for delivery:

```bash
# 1. Generate video (example: Sora 2)
video-gen-helper.sh generate "your prompt" --model sora-2 --output raw.mp4

# 2. Enhance for social media (1080p, 60fps)
real-video-enhancer-helper.sh enhance raw.mp4 final.mp4 \
  --scale 2 \
  --fps 60 \
  --denoise

# 3. Verify output
ffprobe final.mp4  # Check resolution and frame rate
```

### Batch Processing Pipeline

Process entire video libraries:

```bash
# Process all videos in directory
real-video-enhancer-helper.sh batch \
  ~/Videos/raw/ \
  ~/Videos/enhanced/ \
  --scale 2 \
  --fps 60 \
  --denoise \
  --parallel 2  # Process 2 videos simultaneously
```

### Integration with Remotion

Enhance Remotion-rendered videos:

```bash
# 1. Render with Remotion
npx remotion render src/index.ts MyComp out/video.mp4

# 2. Upscale and interpolate
real-video-enhancer-helper.sh enhance out/video.mp4 out/video-enhanced.mp4 \
  --scale 2 \
  --fps 60
```

### Content Production Workflow

See `content/production/video.md` for full production pipeline integration:

1. **Pre-production**: Script, storyboard, prompt design
2. **Generation**: Sora/Veo/Runway/Remotion
3. **Enhancement** (this tool): Upscale, interpolate, denoise
4. **Post-production**: Color grading, audio mixing, final export
5. **Distribution**: Platform-specific encoding

## Performance Optimization

### Backend Performance Comparison

Tested on 1080p → 4K upscaling (30-second clip):

| Backend | GPU | Time | Speedup |
|---------|-----|------|---------|
| TensorRT | RTX 4090 | 45s | 5.3x |
| PyTorch CUDA | RTX 4090 | 2m 15s | 2.2x |
| PyTorch ROCm | RX 7900 XTX | 3m 30s | 1.4x |
| NCNN Vulkan | RTX 4090 | 4m 45s | 1.0x |
| NCNN CPU | Ryzen 9 7950X | 18m 20s | 0.3x |

**Recommendation**: Use TensorRT on NVIDIA GPUs for production workloads.

### Memory Management

```bash
# Reduce memory usage (slower, but works on 8GB GPUs)
real-video-enhancer-helper.sh upscale input.mp4 output.mp4 \
  --scale 2 \
  --tile-size 512  # Default: 1024

# Increase tile size for faster processing (requires more VRAM)
real-video-enhancer-helper.sh upscale input.mp4 output.mp4 \
  --scale 2 \
  --tile-size 2048  # Requires 16GB+ VRAM
```

## Troubleshooting

### Common Issues

**"CUDA out of memory"**:
- Reduce `--tile-size` (default 1024 → 512 or 256)
- Process shorter clips and concatenate
- Switch to NCNN backend (slower, less memory)

**"Model not found"**:
- Models download automatically on first use
- Check internet connection
- Verify `~/.cache/real-video-enhancer/models/` has write permissions

**"Unsupported video codec"**:
- Re-encode input with ffmpeg: `ffmpeg -i input.mp4 -c:v libx264 -preset fast output.mp4`
- Use `.mp4` or `.mkv` containers

**Slow processing on NVIDIA GPU**:
- Verify TensorRT backend is active: `real-video-enhancer-helper.sh backends`
- Install CUDA 11.8+ and cuDNN 8.6+
- Update GPU drivers

### Debug Mode

```bash
# Enable verbose logging
real-video-enhancer-helper.sh upscale input.mp4 output.mp4 \
  --scale 2 \
  --verbose

# Check backend detection
real-video-enhancer-helper.sh backends --verbose
```

## Model Downloads

Models are downloaded automatically on first use to `~/.cache/real-video-enhancer/models/`.

**Manual model management**:

```bash
# List available models
real-video-enhancer-helper.sh models list

# Download specific model
real-video-enhancer-helper.sh models download rife-4.6

# Clear model cache (re-download on next use)
real-video-enhancer-helper.sh models clear
```

**Model sizes**:
- RIFE: ~200MB
- SPAN: ~150MB
- Real-ESRGAN: ~65MB
- GMFSS: ~300MB
- DRUnet: ~50MB

## GUI Mode

REAL Video Enhancer includes a Qt-based GUI for interactive use:

```bash
# Launch GUI
real-video-enhancer-helper.sh gui

# Or run directly (if installed via pip)
python -m real_video_enhancer
```

**GUI features**:
- Drag-and-drop video input
- Real-time preview
- Model selection dropdowns
- Progress tracking
- Batch queue management

## API Reference

For programmatic integration, see the Python API:

```python
from real_video_enhancer import VideoEnhancer

# Initialize enhancer
enhancer = VideoEnhancer(
    backend='tensorrt',  # or 'pytorch', 'ncnn'
    device='cuda:0'
)

# Upscale video
enhancer.upscale(
    input_path='input.mp4',
    output_path='output.mp4',
    scale=2,
    model='span'
)

# Interpolate frames
enhancer.interpolate(
    input_path='input.mp4',
    output_path='output.mp4',
    target_fps=60,
    model='rife-4.6'
)

# Full enhancement pipeline
enhancer.enhance(
    input_path='input.mp4',
    output_path='output.mp4',
    scale=2,
    target_fps=60,
    denoise=True,
    upscale_model='span',
    interpolate_model='rife',
    denoise_model='drunet'
)
```

## Related Tools

- **video-gen-helper.sh**: AI video generation (Sora, Veo, Higgsfield)
- **remotion**: Programmatic video creation
- **ffmpeg**: Video encoding and format conversion
- **content/production/video.md**: Full video production workflow

## References

- **GitHub**: https://github.com/TNTwise/REAL-Video-Enhancer
- **Models**: RIFE, SPAN, Real-ESRGAN, GMFSS, IFRNet, DRUnet, DnCNN, DeH264
- **Backends**: TensorRT, PyTorch, NCNN
- **License**: GPL-3.0 (check upstream for latest)
