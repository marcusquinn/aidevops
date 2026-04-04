---
description: Document creation from prompts, templates, source documents, and scanned images
mode: subagent
model: sonnet
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Document Creation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Convert between document formats and create documents from templates
- **Helper**: `scripts/document-creation-helper.sh`
- **Commands**: `convert`, `create`, `template`, `install`, `formats`, `status`
- **OCR**: Auto-detects scanned PDFs; supports Tesseract, EasyOCR, GLM-OCR, Vision LLM
- **Formats**: ODT, DOCX, PDF, MD, HTML, EPUB, PPTX, ODP, XLSX, ODS, RTF, CSV, TSV

```bash
document-creation-helper.sh status                                    # check tools
document-creation-helper.sh install --minimal                         # pandoc + poppler
document-creation-helper.sh install --standard                        # + odfpy, python-docx, openpyxl
document-creation-helper.sh install --full                            # + LibreOffice headless
document-creation-helper.sh convert report.pdf --to odt               # convert
document-creation-helper.sh create template.odt --data fields.json --output letter.odt
document-creation-helper.sh formats                                   # list supported conversions
document-creation-helper.sh template list
document-creation-helper.sh template draft --type letter --format odt
```

<!-- AI-CONTEXT-END -->

## Decision Tree

```text
1. What is the task?
   |
    +-- Convert format A to format B
    |   +-- Structured data extraction? → document-extraction.md or docstrange.md
    |   +-- PDF form filling or signing? → tools/pdf/overview.md (LibPDF)
    |   +-- PDF with complex layout to markdown? → tools/conversion/mineru.md
    |   +-- Scanned PDF or image with text? → OCR pipeline (auto-detect provider)
    |   +-- Otherwise: use tool selection matrix below
    |
    +-- Create document from template
    |   +-- Template supplied? → replace placeholders, save
    |   +-- No template? → offer to generate draft template
    |   +-- Complex/data-driven? → odfpy/python-docx programmatically
    |
    +-- Generate draft template
        +-- Collect: format, fields, header/footer, logo
        +-- Generate with odfpy/python-docx → user refines in editor
```

## Architecture

Unifies document format operations into a single decision tree. Routes to specialist agents (MinerU, DocStrange, LibPDF) when appropriate, handles everything else.

```text
Input → [Detect format] → [Select tool (preferred → fallback)] → [Convert/Create] → [Validate (exists, non-empty, valid format)] → Output
```

## Tool Selection Matrix

Format pairs with preferred tool and fallback. The helper checks availability at runtime.

### Text/Document Formats

| From | To | Preferred | Fallback | Notes |
|------|----|-----------|----------|-------|
| MD | ODT | pandoc | odfpy (programmatic) | pandoc preserves headings, lists, images |
| MD | DOCX | pandoc | -- | Excellent quality |
| MD | PDF | pandoc + LaTeX | pandoc + wkhtmltopdf, LibreOffice | Needs LaTeX or wkhtmltopdf for PDF engine |
| MD | HTML | pandoc | -- | Native strength |
| MD | EPUB | pandoc | -- | Native strength |
| MD | PPTX | pandoc | -- | Slide-per-heading |
| ODT | MD | pandoc | odfpy (extract XML) | Good quality |
| ODT | DOCX | pandoc | LibreOffice headless | pandoc lossless for text; LO better for complex layout |
| ODT | PDF | LibreOffice headless | pandoc + LaTeX | LO preserves headers/footers/images faithfully |
| ODT | HTML | pandoc | LibreOffice headless | |
| DOCX | MD | pandoc | -- | Excellent quality |
| DOCX | ODT | pandoc | LibreOffice headless | |
| DOCX | PDF | LibreOffice headless | pandoc + LaTeX | LO preserves layout |
| DOCX | HTML | pandoc | -- | |
| RTF | MD | pandoc | -- | |
| RTF | ODT | pandoc | LibreOffice headless | |
| HTML | MD | Reader-LM (Ollama) | pandoc | Reader-LM preserves tables better than pandoc |
| HTML | ODT | pandoc | LibreOffice headless | |
| HTML | DOCX | pandoc | -- | |
| HTML | PDF | pandoc | wkhtmltopdf, LibreOffice | |

### Email Formats

| From | To | Preferred | Fallback | Notes |
|------|----|-----------|----------|-------|
| EML | MD | email-to-markdown.py | -- | Parses MIME, converts HTML body, extracts attachments |
| MSG | MD | email-to-markdown.py | -- | Uses extract-msg, converts HTML body, extracts attachments |

Attachments extracted to `{filename}_attachments/`. Metadata (From, To, Subject, Date) in frontmatter. Dependencies: Python stdlib for `.eml`; `extract-msg` (auto-installed) for `.msg`.

**Thread reconstruction** (t1054.8):

```bash
email-batch-convert-helper.sh batch ./emails      # convert + reconstruct threads
email-batch-convert-helper.sh convert ./emails    # convert only
email-batch-convert-helper.sh threads ./emails    # reconstruct only
```

Thread metadata in frontmatter: `thread_id`, `thread_position`, `thread_length`. Output includes `thread-index.md` with emails grouped by thread and reply hierarchy.

### PDF Extraction

| From | To | Preferred | Fallback | Notes |
|------|----|-----------|----------|-------|
| PDF | MD | RolmOCR (GPU) | MinerU, pdftotext | RolmOCR for GPU-accelerated table preservation; MinerU for complex layouts; pdftotext for simple text |
| PDF | ODT | odfpy + pdftotext + pdfimages | pandoc (lossy) | Programmatic: extract text/images, build ODT |
| PDF | DOCX | LibreOffice headless | pandoc (lossy) | LO does reasonable PDF import |
| PDF | HTML | pandoc | pdftohtml (poppler) | |
| PDF | text | pdftotext (poppler) | pandoc | |

### Spreadsheet Formats

| From | To | Preferred | Fallback | Notes |
|------|----|-----------|----------|-------|
| XLSX | ODS | LibreOffice headless | openpyxl + odfpy | |
| XLSX | CSV | openpyxl | LibreOffice headless, pandoc | |
| XLSX | MD | pandoc | openpyxl (manual table) | |
| ODS | XLSX | LibreOffice headless | -- | |
| ODS | CSV | LibreOffice headless | odfpy (extract) | |
| CSV | XLSX | openpyxl | LibreOffice headless | |
| CSV | ODS | odfpy | LibreOffice headless | |

### Presentation Formats

| From | To | Preferred | Fallback | Notes |
|------|----|-----------|----------|-------|
| PPTX | ODP | LibreOffice headless | -- | |
| PPTX | PDF | LibreOffice headless | -- | |
| PPTX | MD | pandoc | -- | Extracts text per slide |
| ODP | PPTX | LibreOffice headless | -- | |
| ODP | PDF | LibreOffice headless | -- | |
| MD | PPTX | pandoc | -- | Heading-per-slide |

## OCR Support

**Auto-detection**: `pdftotext` returns empty or `pdffonts` shows no embedded fonts → trigger OCR.

| Provider | Install | Speed | Quality | Best For |
|----------|---------|-------|---------|----------|
| Tesseract | `brew install tesseract` | Fast | Good (printed text) | Batch processing, simple documents |
| EasyOCR | `pip install easyocr` | Medium | Good (80+ languages) | Multi-language documents |
| GLM-OCR | `ollama pull glm-ocr` | Slow | Very good | Privacy-sensitive, complex layouts |
| Vision LLM | API key required | Medium | Excellent | Photos, receipts, handwriting |

**Selection order** (auto mode): Tesseract → EasyOCR → GLM-OCR → Vision LLM

For screenshot/image input: keep as image, extract text (OCR), or both (image + text caption).

**Related OCR agents**: `tools/ocr/glm-ocr.md`, `tools/ocr/ocr-research.md`, `tools/document/document-extraction.md`, `tools/conversion/mineru.md`

## Document Creation from Templates

**Placeholder syntax**: `{{field_name}}`
**Template storage**: `~/.aidevops/.agent-workspace/templates/` (documents/, spreadsheets/, presentations/)

```bash
# From template with JSON data
document-creation-helper.sh create template.odt \
  --data '{"property_name": "The Bakehouse", "date": "10th October 2025"}' \
  --output letter.odt

# From template with data file
document-creation-helper.sh create template.odt --data fields.json --output letter.odt

# Generate a draft template
document-creation-helper.sh template draft \
  --type letter --format odt \
  --fields "property_name,property_address,date,author,listing_reference"

# Programmatic creation (data-driven structure, no template)
document-creation-helper.sh create --script generate-report.py \
  --data project-data.json --output report.odt
```

Use programmatic creation (odfpy/python-docx) when: document structure is data-driven, no visual template exists, or batch generation with different structures.

## Tool Tiers and Routing

| Tier | Install | Tools |
|------|---------|-------|
| 1: Minimal | `pandoc poppler` | pandoc (md/docx/odt/html/epub/rst/latex/pptx/xlsx/csv/tsv/rtf), poppler (pdftotext/pdfimages/pdfinfo/pdftohtml) |
| 2: Standard | + Python libs | odfpy (programmatic ODT/ODS/ODP), python-docx (programmatic DOCX), openpyxl (programmatic XLSX) |
| 3: Full | + LibreOffice | `soffice --headless --convert-to <format>` — highest fidelity for office conversions |

### Specialist Tools (routed to, not owned)

| Tool | Agent | When to route |
|------|-------|---------------|
| MinerU | `tools/conversion/mineru.md` | PDF with complex layout, tables, formulas, OCR |
| DocStrange | `tools/document/docstrange.md` | Structured data extraction from documents |
| Docling+ExtractThinker | `tools/document/document-extraction.md` | Schema-based extraction with PII redaction |
| LibPDF | `tools/pdf/overview.md` | PDF form filling, digital signatures |

### Advanced Conversion Providers

| Provider | Model | Install | Best For |
|----------|-------|---------|----------|
| Reader-LM | Jina, 1.5B | `ollama pull reader-lm` | HTML to markdown with table preservation |
| RolmOCR | Reducto, 7B | vLLM server with RolmOCR model | PDF page images to markdown with table preservation (GPU-accelerated) |

## Installation

```bash
# macOS
brew install pandoc poppler                                           # Tier 1
brew install --cask libreoffice                                       # Tier 3

# Ubuntu/Debian
sudo apt install pandoc poppler-utils                                 # Tier 1
sudo apt install libreoffice-core libreoffice-writer libreoffice-calc libreoffice-impress  # Tier 3

# Tier 2 (Python venv at ~/.aidevops/.agent-workspace/python-env/document-creation/)
python3 -m venv ~/.aidevops/.agent-workspace/python-env/document-creation
source ~/.aidevops/.agent-workspace/python-env/document-creation/bin/activate
pip install odfpy python-docx openpyxl

# Via helper (handles venv automatically)
document-creation-helper.sh install --tool easyocr
ollama pull glm-ocr                                                   # GLM-OCR
```

## Usage Examples

```bash
# Batch conversion
for f in ./documents/*.docx; do document-creation-helper.sh convert "$f" --to pdf; done

# Force a specific tool
document-creation-helper.sh convert file.odt --to pdf --tool libreoffice

# Email (extracts attachments automatically)
document-creation-helper.sh convert email.eml --to md

# PDF to ODT (multi-step: extract text+images, detect structure, build ODT)
document-creation-helper.sh convert report.pdf --to odt
document-creation-helper.sh convert report.pdf --to odt --template company-template.odt

# OCR
document-creation-helper.sh convert scanned.pdf --to odt --ocr tesseract
document-creation-helper.sh convert screenshot.png --to md --ocr auto
```

## Limitations

- **PDF to editable formats**: inherently lossy — text/images transfer well, exact positioning does not
- **Spreadsheet formulas**: may not survive conversion; values preserved, formulas need verification
- **Presentation animations/transitions**: lost in most conversions
- **Embedded fonts**: may not transfer; output uses fallback fonts if original unavailable
- **LibreOffice headless**: highest fidelity but large install (~500MB); pandoc used as fallback

## Related

- `tools/conversion/pandoc.md` - Pandoc details and advanced options
- `tools/conversion/mineru.md` - PDF to markdown (layout-aware, OCR)
- `tools/document/docstrange.md` - Structured data extraction
- `tools/document/document-extraction.md` - Docling+ExtractThinker+Presidio pipeline
- `tools/document/extraction-workflow.md` - Extraction tool selection guide
- `tools/pdf/overview.md` - PDF manipulation (form filling, signing)
- `scripts/document-creation-helper.sh` - CLI helper
