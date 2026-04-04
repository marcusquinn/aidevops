---
description: MinerU PDF-to-markdown/JSON conversion for LLM-ready output
mode: subagent
tools:
  read: true
  write: true
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# MinerU Document Conversion

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Convert PDFs to LLM-ready markdown/JSON with layout-aware parsing
- **GitHub**: https://github.com/opendatalab/MinerU (53k+ stars, AGPL-3.0)
- **Install**: `uv pip install "mineru[all]"` or `pip install "mineru[all]"`
- **CLI**: `mineru -p input.pdf -o output_dir`
- **Python**: 3.10-3.13
- **Web**: https://mineru.net (hosted version, no install)

**When to use MinerU vs Pandoc**:

| Scenario | Tool | Why |
|----------|------|-----|
| Complex PDF layouts (multi-column, tables, formulas) | MinerU | Layout detection, structure preservation |
| Scanned PDFs / image-based PDFs | MinerU | Built-in OCR (109 languages) |
| Scientific papers with LaTeX formulas | MinerU | Auto formula-to-LaTeX conversion |
| Simple text PDFs | Pandoc | Faster, lighter, no GPU needed |
| Non-PDF formats (DOCX, HTML, EPUB, etc.) | Pandoc | MinerU is PDF-only |
| Batch format conversion (any-to-markdown) | Pandoc | Broader format support |

<!-- AI-CONTEXT-END -->

## Capabilities

- Removes headers, footers, footnotes, page numbers for semantic coherence
- Outputs text in human-readable order (single-column, multi-column, complex layouts)
- Preserves structure (headings, paragraphs, lists), extracts images and tables
- Auto-converts formulas to LaTeX, tables to HTML
- Detects scanned/garbled PDFs and enables OCR automatically (109 languages)
- Output formats: markdown, JSON (reading-order sorted), rich intermediate

## Installation

```bash
# Using uv (fastest)
uv pip install "mineru[all]"

# Verify
mineru --version
```

The `[all]` extra installs all optional backend dependencies including VLM acceleration engines.

### Hardware Requirements

| Backend | Min VRAM | Min RAM | CPU-only |
|---------|----------|---------|----------|
| `pipeline` | 6GB | 16GB | Yes |
| `hybrid` (default) | 8GB | 16GB | No |
| `vlm` | 10GB | 16GB | No |
| `*-http-client` | N/A | 8GB | Yes (remote) |

Platforms: Linux, Windows, macOS 14.0+. GPU: NVIDIA Volta+, Apple Silicon (MPS), Ascend NPU.

### Docker

```bash
docker pull opendatalab/mineru:latest-gpu   # GPU version
docker pull opendatalab/mineru:latest-cpu   # CPU version
```

## CLI Usage

```bash
# Basic conversion (hybrid backend by default)
mineru -p input.pdf -o output_dir

# Specify backend
mineru -p input.pdf -o output_dir --backend pipeline
mineru -p input.pdf -o output_dir --backend hybrid-auto-engine
mineru -p input.pdf -o output_dir --backend vlm-auto-engine

# Multiple files
mineru -p file1.pdf file2.pdf -o output_dir

# OCR language (for scanned PDFs)
mineru -p input.pdf -o output_dir --lang en

# JSON output
mineru -p input.pdf -o output_dir --format json

# Batch: all PDFs in a directory
for pdf in ./documents/*.pdf; do
  [ -f "$pdf" ] && mineru -p "$pdf" -o ./markdown
done

# Remote model server (vLLM, SGLang, LMDeploy)
mineru -p input.pdf -o output_dir --backend vlm-http-client \
  --server-url http://localhost:8000/v1

# Local web UI (Gradio)
mineru-gradio
```

## Parsing Backends

| Backend | Accuracy | Speed | GPU Required | Best For |
|---------|----------|-------|--------------|----------|
| `pipeline` | Good (82+) | Fast | Optional | General use, CPU environments |
| `hybrid` | High (90+) | Medium | Yes | Best balance (default since v2.7.0) |
| `vlm` | High (90+) | Slower | Yes | Maximum accuracy |
| `*-http-client` | High (90+) | Varies | No (remote) | External model servers |

The `hybrid` backend combines `pipeline` and `vlm` advantages: direct text extraction from text PDFs (reduces hallucinations), 109-language OCR for scanned PDFs, independent inline formula recognition toggle.

## Output Structure

```text
output_dir/
├── input/
│   ├── input.md          # Markdown output
│   ├── input.json        # JSON output (reading-order sorted)
│   ├── images/           # Extracted images
│   │   ├── img_0.png
│   │   └── img_1.png
│   └── tables/           # Extracted tables (HTML)
│       └── table_0.html
```

## Configuration

```bash
mineru --init-config  # Creates mineru.json in current directory
```

```json
{
  "backend": "hybrid-auto-engine",
  "lang": "en",
  "formula": true,
  "table": true,
  "ocr": "auto"
}
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Out of VRAM | `mineru -p input.pdf -o out --backend pipeline` (CPU-compatible) or use `*-http-client` with remote server |
| Slow processing | Use GPU acceleration or hosted version at https://mineru.net |
| Poor OCR quality | Specify language: `--lang ja` (Japanese), `--lang zh` (Chinese) |
| Installation issues | Use `uv` instead of `pip` for faster dependency resolution |

## Related

- `pandoc.md` - General-purpose document conversion (broader format support)
- `../pdf/overview.md` - PDF manipulation tools (form filling, signing)
- `../data-extraction/` - Data extraction from web sources
- `../ocr/` - OCR-specific tools
