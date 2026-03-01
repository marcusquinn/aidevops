---
description: PaddleOCR - Scene text OCR, PP-OCRv5, PaddleOCR-VL, and MCP server integration
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
---

# PaddleOCR - Scene Text OCR

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Extract text from screenshots, photos, signs, UI captures, and documents
- **Repo**: <https://github.com/PaddlePaddle/PaddleOCR> (71k stars, Apache-2.0)
- **Version**: v3.4.0 (Jan 2026), PP-OCRv5 + PaddleOCR-VL-1.5
- **Install**: `pip install paddleocr` (library) / `pip install paddleocr-mcp` (MCP server)
- **Languages**: 100+ (PP-OCRv5), 111 (VL-1.5)
- **Backend**: PaddlePaddle 3.0 (CPU, NVIDIA GPU, Apple Silicon)

**When to use PaddleOCR**:

- Screenshot / photo / sign / UI capture text extraction
- Batch OCR of image files with bounding box positions
- Scene text with varied lighting, angles, fonts
- Table and layout recognition (PP-StructureV3)
- Local document understanding (PaddleOCR-VL, 0.9B)
- MCP server integration with agent frameworks

**When to use alternatives**:

- PDF to markdown with layout preservation -- use MinerU
- Structured JSON extraction from invoices -- use Docling + ExtractThinker
- Quick local OCR with zero setup -- use GLM-OCR via Ollama
- PDF form filling / signing -- use LibPDF

<!-- AI-CONTEXT-END -->

## Installation

### Python Library

```bash
# Install PaddleOCR (includes PaddlePaddle CPU backend)
pip install paddleocr

# Or with uv (faster)
uv pip install paddleocr

# GPU support (CUDA 12)
pip install paddlepaddle-gpu paddleocr
```

### MCP Server

```bash
# Install MCP server with local inference
pip install "paddleocr-mcp[local]"

# CPU-only (no CUDA required)
pip install "paddleocr-mcp[local-cpu]"

# Zero-install via uvx
uvx --from paddleocr-mcp paddleocr_mcp

# Verify
paddleocr_mcp --help
```

## Models

### PP-OCRv5 (Text Detection + Recognition)

The default OCR pipeline. Detects and recognises text in any image.

- **Accuracy**: 13% improvement over PP-OCRv4 on real-world scenarios
- **Languages**: 100+ (Chinese, English, Japanese, Korean, Latin, Cyrillic, Arabic, Devanagari, etc.)
- **Multilingual models**: 2M parameters, lightweight enough for mobile
- **Handwriting**: Improved cursive and non-standard handwriting recognition
- **Output**: Text + bounding boxes (polygon coordinates)

### PaddleOCR-VL-1.5 (Vision-Language Model)

A 0.9B parameter VLM for document understanding -- not just OCR but reasoning about document content.

- **Architecture**: NaViT dynamic-resolution encoder + ERNIE-4.5-0.3B language model
- **Languages**: 111 (added Tibetan, Bengali over VL-1.0)
- **Accuracy**: 94.5% on OmniDocBench v1.5 (SOTA for models under 4B)
- **Capabilities**: Text spotting, seal recognition, irregular layout positioning, cross-page table merging, cross-page paragraph/heading recognition
- **Handles**: Skew, warping, scanning artefacts, varied lighting, screen photography
- **HuggingFace**: `PaddlePaddle/PaddleOCR-VL-1.5`
- **Requires GPU** -- not recommended for CPU inference

### PP-StructureV3 (Layout + Table Recognition)

Document structure analysis: detects tables, figures, headers, and converts tables to HTML/markdown.

### Model Selection

| Scenario | Model | Why |
|----------|-------|-----|
| Screenshot / photo text | PP-OCRv5 | Fast, accurate, CPU-friendly |
| Batch image OCR | PP-OCRv5 | Lightweight, 100+ languages |
| Document understanding | PaddleOCR-VL-1.5 | Structured reasoning, cross-page |
| Table extraction | PP-StructureV3 | HTML/markdown table output |
| Mobile / edge | PP-OCRv5 (mobile) | 2M param multilingual models |
| Maximum accuracy | PaddleOCR-VL-1.5 | SOTA on benchmarks, needs GPU |

## Python API

```python
from paddleocr import PaddleOCR

# Basic OCR (auto-downloads PP-OCRv5 models on first run)
ocr = PaddleOCR(use_angle_cls=True, lang='en')
result = ocr.ocr('screenshot.png', cls=True)

# Each result contains: [[bounding_box], (text, confidence)]
for line in result[0]:
    bbox, (text, confidence) = line[0], line[1]
    print(f"{text} ({confidence:.2f})")
```

```python
# Table / layout recognition
from paddleocr import PPStructureV3

engine = PPStructureV3()
result = engine.predict("document.png")
# Returns structured layout with tables, text blocks, figures
```

```python
# PaddleOCR-VL (document understanding)
from paddleocr import PaddleOCRVL

vlm = PaddleOCRVL(model_name="PaddleOCR-VL-1.5")
result = vlm.predict("complex_document.png")
```

## MCP Server Setup

PaddleOCR ships a native MCP server (v0.5.0) built on FastMCP v2. Four working modes:

| Mode | Flag | Use Case |
|------|------|----------|
| Local | `--ppocr_source local` | Offline, runs inference on your machine |
| AI Studio | `--ppocr_source aistudio` | Baidu cloud, no local GPU needed |
| Qianfan | `--ppocr_source qianfan` | Baidu AI Cloud |
| Self-hosted | `--ppocr_source self_hosted` | Your own inference server |

### Claude Desktop / Agent Config (Local Mode)

```json
{
  "mcpServers": {
    "paddleocr": {
      "command": "paddleocr_mcp",
      "args": [],
      "env": {
        "PADDLEOCR_MCP_PIPELINE": "OCR",
        "PADDLEOCR_MCP_PPOCR_SOURCE": "local"
      }
    }
  }
}
```

### Pipeline Options

Set `PADDLEOCR_MCP_PIPELINE` to one of:

- `OCR` -- PP-OCRv5 text detection + recognition
- `PP-StructureV3` -- layout and table recognition
- `PaddleOCR-VL` -- vision-language model (v1.0)
- `PaddleOCR-VL-1.5` -- vision-language model (v1.5, recommended)

### MCP Server CLI

```bash
# Local OCR via stdio (default transport)
paddleocr_mcp --pipeline OCR --ppocr_source local

# VL-1.5 via stdio
paddleocr_mcp --pipeline PaddleOCR-VL-1.5 --ppocr_source local

# HTTP transport (for remote / multi-client)
paddleocr_mcp --pipeline OCR --ppocr_source local --http

# Self-hosted inference server
paddleocr_mcp --pipeline OCR --ppocr_source self_hosted --server_url http://127.0.0.1:8080
```

## Workflow Examples

### Screenshot OCR

```bash
# Python one-liner
python -c "
from paddleocr import PaddleOCR
ocr = PaddleOCR(use_angle_cls=True, lang='en')
for line in ocr.ocr('screenshot.png')[0]:
    print(line[1][0])
"
```

### Batch Image OCR

```bash
# Process all images in a directory
python -c "
import glob
from paddleocr import PaddleOCR
ocr = PaddleOCR(use_angle_cls=True, lang='en')
for img in sorted(glob.glob('images/*.png')):
    print(f'=== {img} ===')
    for line in ocr.ocr(img)[0]:
        print(line[1][0])
"
```

### Screenshot Capture + OCR (Linux)

```bash
# Capture region and OCR
import -window root /tmp/capture.png && python -c "
from paddleocr import PaddleOCR
ocr = PaddleOCR(use_angle_cls=True, lang='en')
for line in ocr.ocr('/tmp/capture.png')[0]:
    print(line[1][0])
"
```

### Multi-Language OCR

```bash
# Chinese + English mixed text
python -c "
from paddleocr import PaddleOCR
ocr = PaddleOCR(use_angle_cls=True, lang='ch')  # 'ch' handles Chinese + English
for line in ocr.ocr('mixed_text.png')[0]:
    print(f'{line[1][0]} ({line[1][1]:.2f})')
"
```

## Language Support

PP-OCRv5 supports 100+ languages via lightweight multilingual models (2M parameters each):

| Language Group | Examples | Lang Code |
|---------------|----------|-----------|
| Chinese | Simplified, Traditional | `ch`, `chinese_cht` |
| Latin | English, French, German, Spanish | `en`, `fr`, `german`, `es` |
| Cyrillic | Russian, Ukrainian, Serbian | `ru`, `uk`, `rs_cyrillic` |
| Arabic | Arabic, Farsi, Urdu | `ar`, `fa`, `ur` |
| Devanagari | Hindi, Marathi, Nepali | `hi`, `mr`, `ne` |
| CJK | Japanese, Korean | `japan`, `korean` |
| Southeast Asian | Thai, Vietnamese, Tamil | `th`, `vi`, `ta` |

Full list: <https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/model_list/multi_languages.en.md>

## Hardware Requirements

| Component | PP-OCRv5 (CPU) | PP-OCRv5 (GPU) | PaddleOCR-VL-1.5 |
|-----------|----------------|----------------|-------------------|
| **RAM** | 4GB+ | 4GB+ | 8GB+ |
| **VRAM** | N/A | 2GB+ | 4GB+ (recommended) |
| **Disk** | ~500MB (PaddlePaddle + models) | ~1.5GB | ~2GB |
| **CPU** | Any x86_64 / ARM64 | Any | Any |
| **GPU** | N/A | NVIDIA CUDA 12, Apple Silicon | NVIDIA GPU strongly recommended |

**Supported accelerators**: NVIDIA GPU (including RTX 50 series), Apple Silicon (MPS), Kunlunxin XPU, Huawei Ascend NPU, Hygon DCU.

**Performance note**: PP-OCRv5 runs well on CPU with MKL-DNN acceleration. PaddleOCR-VL-1.5 is not recommended for CPU inference -- use GPU.

## Model Comparison

| Model | Best For | Size | Speed | Local | Bounding Boxes |
|-------|----------|------|-------|-------|----------------|
| **PP-OCRv5** | Scene text, screenshots | ~100MB | Fast (CPU/GPU) | Yes | Yes |
| **PaddleOCR-VL-1.5** | Document understanding | ~2GB | Medium (GPU) | Yes | Yes |
| **PP-StructureV3** | Tables, layout | ~200MB | Medium | Yes | Yes |
| **GLM-OCR** (Ollama) | Quick local OCR | ~2GB | Fast | Yes | No |
| **GPT-4o / Claude** | Complex reasoning + vision | Cloud | Fast | No | No |

**PaddleOCR advantages over GLM-OCR**:

- Bounding box output for text localisation
- 100+ language models (vs. prompt-dependent)
- Better scene text accuracy (varied lighting, angles)
- Table and layout recognition (PP-StructureV3)
- Native MCP server for agent integration
- Active development with regular releases

**PaddleOCR limitations**:

- PaddlePaddle framework dependency (~500MB)
- Not designed for PDF-to-markdown (use MinerU)
- No built-in structured extraction (use with ExtractThinker for that)
- VL models require GPU for practical use

## Integration with aidevops

### With ExtractThinker (Structured Extraction)

```python
# PaddleOCR for raw text, then ExtractThinker for structured JSON
from paddleocr import PaddleOCR
ocr = PaddleOCR(use_angle_cls=True, lang='en')
raw_text = "\n".join(line[1][0] for line in ocr.ocr('receipt.png')[0])

# Pass raw_text to ExtractThinker with a Pydantic schema
# See tools/document/document-extraction.md
```

### With MinerU (PDF Pipeline)

PaddleOCR handles image inputs; MinerU handles PDF inputs. They complement each other:

```text
Image/Screenshot --> PaddleOCR --> Raw text + bounding boxes
PDF document     --> MinerU    --> Markdown/JSON (layout-aware)
```

### MCP Server in Agent Framework

The PaddleOCR MCP server integrates directly with Claude Desktop and the aidevops agent framework. Configure it in your MCP config (see MCP Server Setup above), then agents can call OCR tools directly.

## Troubleshooting

### PaddlePaddle Installation Issues

```bash
# Check PaddlePaddle is installed correctly
python -c "import paddle; print(paddle.__version__)"

# If GPU not detected, install GPU version explicitly
pip install paddlepaddle-gpu

# Apple Silicon: use CPU version (MPS support via PaddlePaddle 3.0)
pip install paddlepaddle
```

### Model Download Failures

```bash
# Models auto-download on first use (~100MB for PP-OCRv5)
# If download fails, check network and retry
# Models are cached in ~/.paddleocr/
```

### Slow Performance on CPU

- Enable MKL-DNN: `PaddleOCR(enable_mkldnn=True)`
- Reduce image size before OCR (resize to max 1920px width)
- Use PP-OCRv5 mobile models for faster inference
- For batch processing, reuse the `PaddleOCR()` instance (model loads once)

### MCP Server Not Responding

```bash
# Verify MCP server starts
paddleocr_mcp --help

# Test with stdio
echo '{"jsonrpc":"2.0","method":"initialize","params":{},"id":1}' | paddleocr_mcp --pipeline OCR --ppocr_source local

# Check logs for model download progress on first run
```

## Resources

- **GitHub**: <https://github.com/PaddlePaddle/PaddleOCR>
- **MCP Server**: <https://pypi.org/project/paddleocr-mcp/>
- **PaddleOCR-VL-1.5**: <https://huggingface.co/PaddlePaddle/PaddleOCR-VL-1.5>
- **PP-OCRv5 Paper**: <https://arxiv.org/abs/2510.14528>
- **Language List**: <https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/model_list/multi_languages.en.md>
- **OCR Overview**: `tools/ocr/overview.md`
- **GLM-OCR (alternative)**: `tools/ocr/glm-ocr.md`
- **Document Extraction**: `tools/document/document-extraction.md`
- **MinerU (PDF)**: `tools/conversion/mineru.md`
