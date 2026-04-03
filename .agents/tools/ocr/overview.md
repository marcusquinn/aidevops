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

| Input | Tool | Fit | Limits | Avoid when |
|-------|------|-----|--------|------------|
| Screenshot / photo / sign | **PaddleOCR** (Baidu, 71k, Apache-2.0) | Best scene-text accuracy; bounding boxes; PP-StructureV3 tables; PaddleOCR-VL (0.9B); MCP server (v3.1.0+); 100+ languages | ~500MB PaddlePaddle dependency; not for doc-to-markdown | PDF-to-markdown → MinerU; structured invoices → Docling; PDF forms → LibPDF |
| Complex PDF (tables, columns, formulas) | **MinerU** (OpenDataLab, 53k, AGPL-3.0) | Layout-aware multi-column, tables, formulas; LaTeX; strips headers/footers; 109 languages; JSON with reading order; pipeline/hybrid/VLM backends | PDF-only; AGPL copyleft; heavier hybrid/VLM backends | Screenshot OCR → PaddleOCR; schema extraction → Docling; simple text PDFs → Pandoc |
| Invoice / receipt / form | **Docling + ExtractThinker** (IBM, 52.7k, MIT) | Schema-mapped Pydantic output; PDF/DOCX/PPTX/XLSX/HTML/images; PII redaction (Presidio); local/edge/cloud privacy modes; UK VAT + QuickFile; MCP server | Requires an LLM; three-component setup; slower than pure OCR | Simple screenshot text → PaddleOCR/GLM-OCR; PDF-to-markdown → MinerU; PDF manipulation → LibPDF |
| Any image (quick, local) | **GLM-OCR** (THUDM/Ollama, MIT) | Zero-config via `ollama pull glm-ocr`; fully local; Peekaboo screen capture integration | No bounding boxes; no structured JSON; weaker on scene text; ~2GB model | Bounding boxes or max scene accuracy → PaddleOCR; structured extraction → Docling |
| PDF text + positions | **LibPDF** (Commercial) | Text with coordinate positions; form filling; digital signatures (PAdES); handles malformed PDFs; ~5MB, no Python/GPU | PDF-only; cannot OCR scanned/image PDFs; no layout-aware markdown | Scanned PDFs → MinerU; image OCR → PaddleOCR; structured extraction → Docling |
| Simple text PDF | **Pandoc** | Fastest text-only conversion | No layout awareness; no OCR | Complex layouts → MinerU |
| Document understanding (VLM) | **PaddleOCR-VL** | Local document understanding, structured understanding | Not plain OCR | Plain text extraction → PaddleOCR |

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

## Common Workflows

```bash
# Screenshot to text
paddleocr-helper.sh ocr screenshot.png                                          # PaddleOCR (best accuracy, bounding boxes)
ollama run glm-ocr "Extract all text" --images screenshot.png                   # GLM-OCR (simplest, Ollama required)

# PDF to LLM-ready markdown
mineru -p document.pdf -o output_dir                                            # MinerU (complex layouts, tables, formulas)
pandoc document.pdf -o document.md                                              # Pandoc (simple text PDFs, fastest)

# Invoice to structured JSON
document-extraction-helper.sh extract invoice.pdf --schema purchase-invoice --privacy local

# Batch image OCR
for img in ./images/*.png; do paddleocr-helper.sh ocr "$img"; done             # PaddleOCR (100+ languages, bounding boxes)
for img in ./images/*.png; do ollama run glm-ocr "Extract all text" --images "$img"; done  # GLM-OCR (simpler)

# Pipelines: image → PaddleOCR → raw text or ExtractThinker → structured JSON
#            PDF → MinerU → markdown → LLM
#            PDF → Docling → ExtractThinker → structured JSON → QuickFile
# PaddleOCR and Docling MCP servers plug into Claude Desktop / the agent framework.
```
