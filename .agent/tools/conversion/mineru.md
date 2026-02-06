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

## Overview

MinerU converts PDFs into machine-readable markdown and JSON, preserving document structure including headings, tables, formulas, images, and reading order. It excels at complex layouts where Pandoc's text-based extraction falls short.

**Key capabilities**:

- Removes headers, footers, footnotes, page numbers for semantic coherence
- Outputs text in human-readable order (single-column, multi-column, complex layouts)
- Preserves document structure (headings, paragraphs, lists)
- Extracts images with descriptions, tables with titles, footnotes
- Auto-converts formulas to LaTeX, tables to HTML
- Detects scanned/garbled PDFs and enables OCR automatically
- OCR supports 109 languages
- Multiple output formats: markdown, JSON (reading-order sorted), rich intermediate

## Installation

### Quick Install (recommended)

```bash
# Using uv (fastest)
uv pip install "mineru[all]"

# Using pip
pip install "mineru[all]"
```

The `[all]` extra installs all optional backend dependencies including VLM acceleration engines.

### Verify Installation

```bash
mineru --version
```

### Hardware Requirements

| Backend | Min VRAM | Min RAM | CPU-only |
|---------|----------|---------|----------|
| `pipeline` | 6GB | 16GB | Yes |
| `hybrid` (default) | 8GB | 16GB | No |
| `vlm` | 10GB | 16GB | No |
| `*-http-client` | N/A | 8GB | Yes (remote) |

**Supported platforms**: Linux, Windows, macOS 14.0+
**GPU**: NVIDIA Volta+, Apple Silicon (MPS), Ascend NPU

### Docker

```bash
# GPU version
docker pull opendatalab/mineru:latest-gpu

# CPU version
docker pull opendatalab/mineru:latest-cpu
```

## Usage

### CLI

```bash
# Basic conversion (uses hybrid backend by default)
mineru -p input.pdf -o output_dir

# Specify backend
mineru -p input.pdf -o output_dir --backend pipeline
mineru -p input.pdf -o output_dir --backend hybrid-auto-engine
mineru -p input.pdf -o output_dir --backend vlm-auto-engine

# Process multiple files
mineru -p file1.pdf file2.pdf -o output_dir

# Specify OCR language (for scanned PDFs)
mineru -p input.pdf -o output_dir --lang en

# Output JSON instead of markdown
mineru -p input.pdf -o output_dir --format json
```

### Python API

```python
from mineru import MinerU

# Basic usage
converter = MinerU()
result = converter.parse("input.pdf")

# Access markdown output
markdown_text = result.get_markdown()

# Access structured JSON
json_data = result.get_json()
```

### Web Interface (Gradio)

```bash
# Launch local web UI
mineru-gradio
```

## Parsing Backends

MinerU offers three backends with different accuracy/speed tradeoffs:

| Backend | Accuracy | Speed | GPU Required | Best For |
|---------|----------|-------|--------------|----------|
| `pipeline` | Good (82+) | Fast | Optional | General use, CPU environments |
| `hybrid` | High (90+) | Medium | Yes | Best balance of accuracy and features |
| `vlm` | High (90+) | Slower | Yes | Maximum accuracy |
| `*-http-client` | High (90+) | Varies | No (remote) | Using external model servers |

The `hybrid` backend (default since v2.7.0) combines `pipeline` and `vlm` advantages:

- Directly extracts text from text PDFs (reduces hallucinations)
- Supports 109-language OCR for scanned PDFs
- Independent inline formula recognition toggle

### Using with OpenAI-compatible servers

```bash
# Use a remote model server (vLLM, SGLang, LMDeploy)
mineru -p input.pdf -o output_dir --backend vlm-http-client \
  --server-url http://localhost:8000/v1
```

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

## AI Assistant Integration

### Convert PDFs for AI analysis

```bash
# Convert a research paper
mineru -p paper.pdf -o ./converted

# Read the markdown output
cat ./converted/paper/paper.md
```

### Batch processing

```bash
# Convert all PDFs in a directory
for pdf in ./documents/*.pdf; do
  mineru -p "$pdf" -o ./markdown
done
```

### Comparison with Pandoc for PDFs

```bash
# Pandoc (text extraction, fast but loses layout)
pandoc input.pdf -o output.md

# MinerU (layout-aware, preserves structure)
mineru -p input.pdf -o output_dir
```

For complex PDFs (academic papers, reports with tables/figures, multi-column layouts), MinerU produces significantly better results. For simple text-heavy PDFs, Pandoc is faster and sufficient.

## Configuration

MinerU uses a JSON config file. Generate a template:

```bash
# Creates mineru.json in current directory
mineru --init-config
```

Key configuration options:

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

### Common Issues

**Out of VRAM**: Switch to `pipeline` backend (CPU-compatible) or use `*-http-client` with a remote server.

```bash
mineru -p input.pdf -o output_dir --backend pipeline
```

**Slow processing**: Use GPU acceleration or the hosted version at https://mineru.net.

**OCR quality**: Specify the correct language for better recognition:

```bash
mineru -p input.pdf -o output_dir --lang ja  # Japanese
mineru -p input.pdf -o output_dir --lang zh  # Chinese
```

**Installation issues**: Use `uv` instead of `pip` for faster, more reliable dependency resolution.

## Related

- `pandoc.md` - General-purpose document conversion (broader format support)
- `tools/pdf/overview.md` - PDF manipulation tools (form filling, signing)
- `tools/data-extraction/` - Data extraction from web sources
- `tools/ocr/` - OCR-specific tools
