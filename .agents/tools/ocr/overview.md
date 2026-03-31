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

**Tool selection:**

| Input | Tool | Output | Use when |
|-------|------|--------|----------|
| Screenshot / photo / sign | PaddleOCR | Raw text + bounding boxes | You need scene-text accuracy, UI capture support, or varied lighting / angles |
| Complex PDF (tables, columns, formulas) | MinerU | Markdown / JSON | You need LLM-ready document conversion |
| Invoice / receipt / form | Docling + ExtractThinker | Structured JSON | You need schema validation or PII redaction |
| Any image (quick, local) | GLM-OCR (Ollama) | Plain text | You need a private local fallback with minimal setup |
| PDF text + positions | LibPDF | Text with coordinates | You need form filling, signing, or PDF manipulation |
| Simple text PDF | Pandoc | Markdown | You need the fastest text-only conversion |
| Document understanding (VLM) | PaddleOCR-VL | Structured understanding | You need local document understanding, not plain OCR |

**Subagents:**

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

| Tool | Fit | Limits | Avoid when |
|------|-----|--------|------------|
| **PaddleOCR** (Baidu, 71k, Apache-2.0) | Best scene-text accuracy; bounding boxes; PP-StructureV3 tables; PaddleOCR-VL (0.9B); native MCP server (v3.1.0+); 100+ languages | ~500MB PaddlePaddle dependency; not for doc-to-markdown | PDF-to-markdown → MinerU; structured invoices → Docling; PDF forms → LibPDF |
| **MinerU** (OpenDataLab, 53k, AGPL-3.0) | Layout-aware multi-column, tables, formulas; LaTeX conversion; strips headers/footers; 109 languages; JSON with reading order; pipeline / hybrid / VLM backends | PDF-only; AGPL copyleft; heavier hybrid/VLM backends | Screenshot OCR → PaddleOCR; schema extraction → Docling; simple text PDFs → Pandoc |
| **Docling + ExtractThinker** (IBM, 52.7k, MIT) | Schema-mapped Pydantic output; PDF/DOCX/PPTX/XLSX/HTML/images; PII redaction (Presidio); local/edge/cloud privacy modes; UK VAT schemas + QuickFile; MCP server | Requires an LLM; three-component setup; slower than pure OCR | Simple screenshot text → PaddleOCR/GLM-OCR; PDF-to-markdown → MinerU; PDF manipulation → LibPDF |
| **GLM-OCR** (THUDM/Ollama, MIT) | Zero-config via `ollama pull glm-ocr`; fully local; Peekaboo screen capture integration | No bounding boxes; no structured JSON; weaker on scene text; ~2GB model | Bounding boxes or max scene accuracy → PaddleOCR; structured extraction → Docling |
| **LibPDF** (Commercial) | Text with coordinate positions; form filling; digital signatures (PAdES); handles malformed PDFs; ~5MB, no Python/GPU | PDF-only; cannot OCR scanned/image PDFs; no layout-aware markdown | Scanned PDFs → MinerU; image OCR → PaddleOCR; structured extraction → Docling |

## Common Workflows

```bash
# Screenshot to text
# PaddleOCR (best accuracy, bounding boxes)
paddleocr-helper.sh ocr screenshot.png

# GLM-OCR (simplest, Ollama required)
ollama run glm-ocr "Extract all text" --images screenshot.png

# PDF to LLM-ready markdown
# MinerU (complex layouts, tables, formulas)
mineru -p document.pdf -o output_dir

# Pandoc (simple text PDFs, fastest)
pandoc document.pdf -o document.md

# Invoice to structured JSON
# Docling + ExtractThinker pipeline
document-extraction-helper.sh extract invoice.pdf --schema purchase-invoice --privacy local

# Batch image OCR
# PaddleOCR (100+ languages, bounding boxes)
for img in ./images/*.png; do paddleocr-helper.sh ocr "$img"; done

# GLM-OCR (simpler, no bounding boxes)
for img in ./images/*.png; do ollama run glm-ocr "Extract all text" --images "$img"; done
```

## Integration Points

- Image / screenshot → PaddleOCR → raw text → LLM analysis
- Image / screenshot → PaddleOCR → ExtractThinker → structured JSON
- PDF → MinerU → markdown → LLM context window
- PDF → Docling → ExtractThinker → structured JSON → QuickFile
- PaddleOCR MCP server and Docling MCP server both plug into Claude Desktop / the agent framework
