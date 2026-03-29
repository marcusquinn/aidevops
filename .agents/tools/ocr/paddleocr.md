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

- **Repo**: <https://github.com/PaddlePaddle/PaddleOCR> (71k stars, Apache-2.0)
- **Version**: v3.4.0 (Jan 2026) — PP-OCRv5 + PaddleOCR-VL-1.5
- **Install**: `pip install paddleocr` / `pip install paddleocr-mcp` (MCP server)
- **Languages**: 100+ (PP-OCRv5), 111 (VL-1.5)
- **Backend**: PaddlePaddle 3.0 — CPU, NVIDIA GPU, Apple Silicon

**Use PaddleOCR for**: screenshot/photo/sign/UI text extraction, batch OCR with bounding boxes, scene text (varied lighting/angles/fonts), table/layout recognition (PP-StructureV3), local document understanding (PaddleOCR-VL, 0.9B), MCP server integration.

**Use alternatives for**: PDF→markdown (MinerU), structured JSON from invoices (Docling + ExtractThinker), zero-setup local OCR (GLM-OCR via Ollama), PDF form filling (LibPDF).

<!-- AI-CONTEXT-END -->

## Installation

```bash
pip install paddleocr                        # CPU (includes PaddlePaddle)
pip install paddlepaddle-gpu paddleocr       # CUDA 12
pip install "paddleocr-mcp[local]"           # MCP server (local inference)
pip install "paddleocr-mcp[local-cpu]"       # MCP server (CPU-only)
uvx --from paddleocr-mcp paddleocr_mcp       # Zero-install via uvx
```

## Models

| Model | Best For | Size | GPU | Bbox |
|-------|----------|------|-----|------|
| **PP-OCRv5** | Screenshots, scene text, batch OCR | ~100MB | No | Yes |
| **PaddleOCR-VL-1.5** | Document understanding, cross-page | ~2GB | Yes | Yes |
| **PP-StructureV3** | Tables, layout → HTML/markdown | ~200MB | No | Yes |

**PP-OCRv5**: 13% accuracy over v4, 100+ languages, 2M-param multilingual models, improved handwriting, polygon bounding boxes.

**PaddleOCR-VL-1.5**: NaViT + ERNIE-4.5-0.3B, 94.5% OmniDocBench v1.5 (SOTA <4B), handles skew/warping/cross-page tables. HuggingFace: `PaddlePaddle/PaddleOCR-VL-1.5`. Requires GPU (4GB+ VRAM).

**Limitations**: PaddlePaddle dependency (~500MB), not for PDF→markdown (use MinerU), no built-in structured extraction (pair with ExtractThinker).

## Python API

```python
import paddle
paddle.set_flags({"FLAGS_use_mkldnn": False})  # Required on Linux CPU (PaddlePaddle 3.3.0)
from paddleocr import PaddleOCR

# Basic OCR — use .predict() not .ocr() (3.4.0+), enable_mkldnn=False on Linux CPU
ocr = PaddleOCR(lang='en', enable_mkldnn=False)
for result in ocr.predict('screenshot.png'):
    for text, score in zip(result['rec_texts'], result['rec_scores']):
        print(f"{text} ({score:.2f})")
```

```python
from paddleocr import PPStructureV3   # Table / layout
engine = PPStructureV3()
result = engine.predict("document.png")

from paddleocr import PaddleOCRVL    # Document understanding
vlm = PaddleOCRVL(model_name="PaddleOCR-VL-1.5")
result = vlm.predict("complex_document.png")
```

**3.4.0 breaking changes**:

| Old | New | Notes |
|-----|-----|-------|
| `PaddleOCR(show_log=False)` | Removed | Causes `ValueError` |
| `use_angle_cls=True` | `use_textline_orientation=True` | Deprecated, still works |
| `ocr.ocr(image)` | `ocr.predict(image)` | Returns `OCRResult`, not nested lists |

## MCP Server

Four modes via `--ppocr_source`: `local` (offline), `aistudio` (Baidu cloud), `qianfan` (Baidu AI Cloud), `self_hosted`.

**Claude Desktop config** (`PADDLEOCR_MCP_PIPELINE`: `OCR`, `PP-StructureV3`, `PaddleOCR-VL`, `PaddleOCR-VL-1.5`):

```json
{
  "mcpServers": {
    "paddleocr": {
      "command": "paddleocr_mcp",
      "args": [],
      "env": { "PADDLEOCR_MCP_PIPELINE": "OCR", "PADDLEOCR_MCP_PPOCR_SOURCE": "local" }
    }
  }
}
```

```bash
paddleocr_mcp --pipeline OCR --ppocr_source local              # stdio (default)
paddleocr_mcp --pipeline PaddleOCR-VL-1.5 --ppocr_source local # VL model
paddleocr_mcp --pipeline OCR --ppocr_source local --http       # HTTP transport
paddleocr_mcp --pipeline OCR --ppocr_source self_hosted --server_url http://127.0.0.1:8080
```

## Workflow Examples

```bash
paddleocr-helper.sh ocr screenshot.png   # recommended — handles API differences

# Batch directory
python -c "
import glob, paddle; paddle.set_flags({'FLAGS_use_mkldnn': False})
from paddleocr import PaddleOCR
ocr = PaddleOCR(lang='en', enable_mkldnn=False)
for img in sorted(glob.glob('images/*.png')):
    for r in ocr.predict(img):
        for text in r['rec_texts']: print(text)
"
# Chinese+English mixed: lang='ch'
# Linux capture: import -window root /tmp/capture.png && paddleocr-helper.sh ocr /tmp/capture.png
```

## Language Support

Common codes: `ch` (Chinese simplified), `chinese_cht` (traditional), `en`, `fr`, `german`, `es`, `ru`, `uk`, `ar`, `fa`, `hi`, `japan`, `korean`, `th`, `vi`. Full list (100+ languages): <https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/model_list/multi_languages.en.md>

## Hardware & Troubleshooting

**Requirements**: PP-OCRv5 CPU: 4GB RAM, ~500MB disk. PP-OCRv5 GPU: 2GB+ VRAM, ~1.5GB disk. PaddleOCR-VL-1.5: 8GB+ RAM, 4GB+ VRAM, ~2GB disk. Accelerators: NVIDIA (incl. RTX 50, CUDA 12), Apple Silicon (MPS), Kunlunxin XPU, Huawei Ascend NPU, Hygon DCU.

**OneDNN crash on Linux CPU** (`NotImplementedError: ConvertPirAttribute2RuntimeAttribute`): set `FLAGS_use_mkldnn=False` and `enable_mkldnn=False` (see Python API above). `paddleocr-helper.sh` applies this automatically.

**Model cache**: `~/.paddlex/official_models/` (~100MB PP-OCRv5). Set `PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True` to skip connectivity check (~5s savings).

**Slow CPU**: resize to max 1920px; reuse `PaddleOCR()` instance; use mobile models. `enable_mkldnn=True` improves speed but crashes on PaddlePaddle 3.3.0.

**MCP not responding**: `paddleocr_mcp --help` or test with `echo '{"jsonrpc":"2.0","method":"initialize","params":{},"id":1}' | paddleocr_mcp --pipeline OCR --ppocr_source local`.

## Integration

```text
Image/Screenshot --> PaddleOCR --> Raw text + bounding boxes
PDF document     --> MinerU    --> Markdown/JSON (layout-aware)
```

For structured JSON extraction (invoices, receipts): pass `ocr.predict()` output to ExtractThinker — see `tools/document/document-extraction.md`.

## Platform Notes

- **Linux x86_64**: Verified 2026-03-01 (3.4.0 + PP 3.3.0 CPU). OneDNN fix required; 42 regions from 800×600, >95% confidence.
- **macOS Apple Silicon**: Unverified. CPU backend expected; MPS via PaddlePaddle 3.0+.
- **Linux NVIDIA GPU**: Unverified. Install `paddlepaddle-gpu`; OneDNN workaround not needed.

## Resources

- GitHub: <https://github.com/PaddlePaddle/PaddleOCR> | MCP: <https://pypi.org/project/paddleocr-mcp/>
- VL-1.5: <https://huggingface.co/PaddlePaddle/PaddleOCR-VL-1.5> | Paper: <https://arxiv.org/abs/2510.14528>
- `tools/ocr/overview.md`, `tools/ocr/glm-ocr.md`, `tools/document/document-extraction.md`, `tools/conversion/mineru.md`
