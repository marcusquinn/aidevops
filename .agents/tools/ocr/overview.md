---
description: OCR tools overview and selection guide for text extraction from images, screenshots, and documents
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# OCR Tools Overview

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Scene text (screenshots, photos)**: PaddleOCR PP-OCRv5 — best accuracy on varied images
- **Document-to-markdown**: MinerU — layout-aware PDF conversion with built-in OCR
- **Structured extraction**: Docling + ExtractThinker — schema-mapped JSON from documents
- **Local quick OCR**: GLM-OCR via Ollama — no install beyond `ollama pull glm-ocr`
- **PDF manipulation**: LibPDF — text extraction with positions, form filling, signing

**Tool Selection**:

| Input | Tool | Output | Best For |
|-------|------|--------|----------|
| Screenshot / photo / sign | PaddleOCR | Raw text + bounding boxes | Scene text, UI captures, varied lighting/angles |
| Complex PDF (tables, columns, formulas) | MinerU | Markdown / JSON | LLM-ready document conversion |
| Invoice / receipt / form | Docling + ExtractThinker | Structured JSON | Schema-validated extraction with PII redaction |
| Any image (quick, local) | GLM-OCR (Ollama) | Plain text | Privacy-sensitive, no install overhead |
| PDF text + positions | LibPDF | Text with coordinates | Form filling, signing, PDF manipulation |
| Simple text PDF | Pandoc | Markdown | Fast conversion, no GPU needed |
| Document understanding (VLM) | PaddleOCR-VL | Structured understanding | Complex document reasoning, local |

**Subagents**:

| File | Purpose |
|------|---------|
| `tools/ocr/paddleocr.md` | PaddleOCR — scene text OCR, MCP server, PP-OCRv5 and VL models |
| `tools/ocr/glm-ocr.md` | GLM-OCR — local OCR via Ollama |
| `tools/ocr/ocr-research.md` | OCR research findings and pipeline design |
| `tools/conversion/mineru.md` | MinerU — PDF to markdown/JSON |
| `tools/document/document-extraction.md` | Docling + ExtractThinker — structured extraction |
| `tools/pdf/overview.md` | LibPDF — PDF manipulation and text extraction |

<!-- AI-CONTEXT-END -->

## Tool Profiles

| Tool | Stars / License | Strengths | Weaknesses | Do NOT use when |
|------|----------------|-----------|------------|-----------------|
| **PaddleOCR** (Baidu) | 71k / Apache-2.0 | Best scene text accuracy; bounding boxes; PP-StructureV3 tables; PaddleOCR-VL (0.9B); native MCP server (v3.1.0+); 100+ languages | ~500MB PaddlePaddle dep; not for doc-to-markdown | PDF-to-markdown → MinerU; structured invoices → Docling; PDF forms → LibPDF |
| **MinerU** (OpenDataLab) | 53k / AGPL-3.0 | Layout-aware (multi-column, tables, formulas); LaTeX conversion; strips headers/footers; 109 languages; JSON with reading order; multiple backends (pipeline/hybrid/VLM) | PDF-only; AGPL copyleft; heavier hybrid/VLM backends | Screenshot OCR → PaddleOCR; schema extraction → Docling; simple text PDFs → Pandoc |
| **Docling + ExtractThinker** (IBM) | 52.7k / MIT | Schema-mapped Pydantic output; multi-format (PDF, DOCX, PPTX, XLSX, HTML, images); PII redaction (Presidio); local/edge/cloud privacy modes; UK VAT schemas + QuickFile; MCP server | Requires LLM; 3-component setup; slower than pure OCR | Simple screenshot text → PaddleOCR/GLM-OCR; PDF-to-markdown → MinerU; PDF manipulation → LibPDF |
| **GLM-OCR** (THUDM/Ollama) | N/A / MIT | Zero-config (`ollama pull glm-ocr`); fully local; Peekaboo screen capture integration | No bounding boxes; no structured JSON; less accurate on scene text; ~2GB model | Bounding boxes → PaddleOCR; structured extraction → Docling; max scene accuracy → PaddleOCR |
| **LibPDF** | N/A / Commercial | Text + coordinate positions; form filling; digital signatures (PAdES); handles malformed PDFs; ~5MB, no Python/GPU | PDF-only; cannot OCR scanned/image PDFs; no layout-aware markdown | Scanned PDFs → MinerU; image OCR → PaddleOCR; structured extraction → Docling |

## Common Workflows

### Screenshot to Text

```bash
# PaddleOCR (best accuracy, bounding boxes)
paddleocr-helper.sh ocr screenshot.png

# GLM-OCR (simplest, Ollama required)
ollama run glm-ocr "Extract all text" --images screenshot.png
```

### PDF to LLM-Ready Markdown

```bash
# MinerU (complex layouts, tables, formulas)
mineru -p document.pdf -o output_dir

# Pandoc (simple text PDFs, fastest)
pandoc document.pdf -o document.md
```

### Invoice to Structured JSON

```bash
# Docling + ExtractThinker pipeline
document-extraction-helper.sh extract invoice.pdf --schema purchase-invoice --privacy local
```

### Batch Image OCR

```bash
# PaddleOCR (100+ languages, bounding boxes)
for img in ./images/*.png; do paddleocr-helper.sh ocr "$img"; done

# GLM-OCR (simpler, no bounding boxes)
for img in ./images/*.png; do ollama run glm-ocr "Extract all text" --images "$img"; done
```

## Integration Points

```text
Image/Screenshot ──→ PaddleOCR ──→ Raw text ──→ LLM analysis
                                       │
                                       └──→ ExtractThinker ──→ Structured JSON

PDF ──→ MinerU ──→ Markdown ──→ LLM context window
    └──→ Docling ──→ ExtractThinker ──→ Structured JSON ──→ QuickFile

PaddleOCR MCP Server ──→ Claude Desktop / Agent framework
Docling MCP Server   ──→ Claude Desktop / Agent framework
```
