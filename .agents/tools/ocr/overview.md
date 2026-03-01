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

- **Purpose**: Extract text from images, screenshots, photos, and documents
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

## When to Use Which Tool

The OCR domain in aidevops covers five distinct use cases. Each tool is a specialist — choosing the right one depends on your input type and desired output.

### Decision Flowchart

```text
What is your input?
  │
  ├─ Screenshot, photo, sign, UI capture
  │   └─ Need bounding boxes / positions?
  │       ├─ Yes → PaddleOCR (PP-OCRv5)
  │       └─ No, just text → PaddleOCR or GLM-OCR (if Ollama available)
  │
  ├─ PDF document
  │   ├─ Need markdown/JSON for LLM? → MinerU
  │   ├─ Need structured data (invoice, receipt)? → Docling + ExtractThinker
  │   ├─ Need to fill forms / sign? → LibPDF
  │   └─ Simple text extraction? → Pandoc (fastest) or LibPDF (with positions)
  │
  ├─ Scanned PDF (image-based)
  │   ├─ Layout matters → MinerU (built-in OCR, 109 languages)
  │   └─ Just need text → PaddleOCR or GLM-OCR
  │
  └─ Document image (photo of a page)
      ├─ Need structured JSON → Docling + ExtractThinker
      └─ Need raw text → PaddleOCR (best accuracy) or GLM-OCR (simplest)
```

### Detailed Comparison

| Feature | PaddleOCR | MinerU | Docling + ET | GLM-OCR | LibPDF |
|---------|-----------|--------|--------------|---------|--------|
| **Primary use** | Scene text OCR | PDF to markdown | Structured extraction | Quick local OCR | PDF manipulation |
| **Input types** | Any image | PDF only | PDF, DOCX, images | Any image | PDF only |
| **Output** | Text + bounding boxes | Markdown / JSON | Schema-mapped JSON | Plain text | Text + positions |
| **Scene text accuracy** | Excellent | N/A | Good (via OCR backend) | Good | N/A |
| **Document layout** | Basic | Excellent | Excellent | Basic | Text positions only |
| **Table extraction** | PP-StructureV3 | Yes (HTML) | Yes (structured) | Prompt-dependent | No |
| **Formula support** | No | LaTeX conversion | No | No | No |
| **Languages** | 100+ | 109 (OCR) | Depends on backend | Multi (via Ollama) | N/A |
| **Structured output** | Bounding boxes + text | Markdown / JSON | Pydantic models | Unstructured text | Raw text |
| **PII redaction** | No | No | Yes (Presidio) | No | No |
| **Local / private** | Yes | Yes | Yes (with Ollama) | Yes | Yes |
| **GPU required** | Optional (faster) | Optional | Optional | No (Ollama manages) | No |
| **MCP server** | Yes (native, 3.1.0+) | No | Docling has MCP | No | No |
| **Install size** | ~500MB (PaddlePaddle) | ~500MB+ | ~200MB (core) | ~2GB (model) | ~5MB (npm) |
| **Stars** | 71k | 53k | 52.7k (Docling) | N/A (Ollama model) | N/A |
| **License** | Apache-2.0 | AGPL-3.0 | MIT (Docling) | MIT (Ollama) | Commercial |

## Tool Profiles

### PaddleOCR — Scene Text Specialist

**Best for**: Screenshots, photos, UI captures, signs, varied lighting/angles, batch image OCR.

PaddleOCR (Baidu, 71k stars, Apache-2.0) is purpose-built for recognising text in arbitrary images — not just clean documents. PP-OCRv5 handles detection + recognition in 100+ languages with lightweight models that run on CPU or GPU.

**Strengths**:

- Best-in-class scene text accuracy (varied fonts, angles, lighting)
- Bounding box output for text localisation
- PP-StructureV3 for table/layout recognition
- PaddleOCR-VL (0.9B) for local document understanding
- Native MCP server for agent framework integration
- Active development (v3.4.0, Jan 2026)

**Weaknesses**:

- PaddlePaddle framework dependency (~500MB)
- Not designed for document-to-markdown conversion
- No built-in structured extraction (use with ExtractThinker for that)

**When NOT to use**: PDF-to-markdown (use MinerU), structured invoice extraction (use Docling + ExtractThinker), PDF form filling (use LibPDF).

See: `tools/ocr/paddleocr.md`

### MinerU — PDF-to-Markdown Specialist

**Best for**: Converting complex PDFs to LLM-ready markdown/JSON with layout preservation.

MinerU (OpenDataLab, 53k stars, AGPL-3.0) excels at preserving document structure — headings, tables, formulas, multi-column layouts, reading order. Built-in OCR handles scanned PDFs in 109 languages.

**Strengths**:

- Layout-aware parsing (multi-column, tables, formulas)
- Auto formula-to-LaTeX conversion
- Removes headers/footers/page numbers for semantic coherence
- Multiple backends (pipeline, hybrid, VLM) for accuracy/speed tradeoff
- JSON output with reading-order sorting

**Weaknesses**:

- PDF-only (no image/screenshot input)
- AGPL-3.0 license (copyleft)
- Larger resource requirements for hybrid/VLM backends

**When NOT to use**: Screenshot OCR (use PaddleOCR), structured data extraction with schemas (use Docling + ExtractThinker), simple text PDFs (use Pandoc).

See: `tools/conversion/mineru.md`

### Docling + ExtractThinker — Structured Extraction Pipeline

**Best for**: Extracting schema-validated JSON from invoices, receipts, contracts, forms.

Docling (IBM, 52.7k stars, MIT) parses document layout, then ExtractThinker uses LLMs with Pydantic schemas to extract structured data. Presidio adds optional PII redaction.

**Strengths**:

- Schema-mapped output (Pydantic models with field descriptions)
- Multi-format input (PDF, DOCX, PPTX, XLSX, HTML, images)
- Privacy modes (fully local via Ollama, edge via Cloudflare, cloud)
- PII detection and redaction (Presidio)
- UK VAT-aware schemas with QuickFile integration

**Weaknesses**:

- Requires LLM for extraction (API cost or local model)
- More complex setup (3 components)
- Slower than pure OCR for simple text extraction

**When NOT to use**: Simple text extraction from screenshots (use PaddleOCR or GLM-OCR), PDF-to-markdown for LLM context (use MinerU), PDF manipulation (use LibPDF).

See: `tools/document/document-extraction.md`, `tools/document/extraction-schemas.md`

### GLM-OCR — Quick Local OCR

**Best for**: Fast, private text extraction when Ollama is already available.

GLM-OCR (THUDM/Tsinghua, via Ollama) is a purpose-built OCR model that runs locally with no API keys. Simple to use — just `ollama run glm-ocr`.

**Strengths**:

- Zero-config (just `ollama pull glm-ocr`)
- Fully local, no API costs
- Good for documents, forms, tables
- Integrates with Peekaboo for screen capture + OCR

**Weaknesses**:

- No bounding box output (text only)
- No structured JSON output
- Less accurate than PaddleOCR on scene text
- Requires Ollama runtime (~2GB model)

**When NOT to use**: When you need bounding boxes (use PaddleOCR), structured extraction (use Docling + ExtractThinker), or maximum scene text accuracy (use PaddleOCR).

See: `tools/ocr/glm-ocr.md`

### LibPDF — PDF Text with Positions

**Best for**: Extracting text with coordinate positions from PDFs, form filling, digital signatures.

LibPDF is a TypeScript-native PDF library. Its OCR role is limited to text extraction with position information from text-based PDFs (not scanned/image PDFs).

**Strengths**:

- Text extraction with bounding box positions
- Form filling, digital signatures (PAdES)
- Handles malformed PDFs gracefully
- Lightweight (~5MB, no Python/GPU)

**Weaknesses**:

- PDF-only (no image input)
- Cannot OCR scanned/image-based PDFs
- No layout-aware markdown conversion

**When NOT to use**: Scanned PDFs (use MinerU), image OCR (use PaddleOCR), structured extraction (use Docling + ExtractThinker).

See: `tools/pdf/overview.md`, `tools/pdf/libpdf.md`

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
for img in ./images/*.png; do
  paddleocr-helper.sh ocr "$img"
done

# GLM-OCR (simpler, no bounding boxes)
for img in ./images/*.png; do
  ollama run glm-ocr "Extract all text" --images "$img"
done
```

## Integration Points

The OCR tools integrate with the broader aidevops pipeline:

```text
Image/Screenshot ──→ PaddleOCR ──→ Raw text ──→ LLM analysis
                                       │
                                       └──→ ExtractThinker ──→ Structured JSON

PDF ──→ MinerU ──→ Markdown ──→ LLM context window
    └──→ Docling ──→ ExtractThinker ──→ Structured JSON ──→ QuickFile

PaddleOCR MCP Server ──→ Claude Desktop / Agent framework
Docling MCP Server   ──→ Claude Desktop / Agent framework
```

## Related

- `tools/ocr/paddleocr.md` — PaddleOCR scene text OCR and MCP server
- `tools/ocr/glm-ocr.md` — GLM-OCR local OCR via Ollama
- `tools/ocr/ocr-research.md` — OCR research findings and pipeline design
- `tools/conversion/mineru.md` — MinerU PDF to markdown/JSON
- `tools/document/document-extraction.md` — Docling + ExtractThinker structured extraction
- `tools/document/extraction-schemas.md` — Pydantic extraction schemas
- `tools/pdf/overview.md` — LibPDF PDF manipulation
- `tools/conversion/pandoc.md` — General document format conversion
