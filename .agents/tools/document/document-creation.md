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

# Document Creation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Convert between document formats and create documents from templates
- **Helper**: `scripts/document-creation-helper.sh`
- **Commands**: `convert`, `create`, `template`, `install`, `formats`, `status`
- **OCR**: Auto-detects scanned PDFs; supports Tesseract, EasyOCR, GLM-OCR, Vision LLM
- **Formats**: ODT, DOCX, PDF, MD, HTML, EPUB, PPTX, ODP, XLSX, ODS, RTF, CSV, TSV

**Quick start**:

```bash
# Check available tools
document-creation-helper.sh status

# Install dependencies (choose tier)
document-creation-helper.sh install --minimal   # pandoc + poppler
document-creation-helper.sh install --standard   # + odfpy, python-docx, openpyxl
document-creation-helper.sh install --full       # + LibreOffice headless

# Convert between formats
document-creation-helper.sh convert report.pdf --to odt
document-creation-helper.sh convert letter.odt --to pdf
document-creation-helper.sh convert notes.md --to docx

# Create from template
document-creation-helper.sh create template.odt --data fields.json --output letter.odt

# List supported conversions
document-creation-helper.sh formats

# Manage templates
document-creation-helper.sh template list
document-creation-helper.sh template draft --type letter --format odt
```

<!-- AI-CONTEXT-END -->

## Architecture

This agent unifies document format operations into a single decision tree. It does
not replace the specialist agents (MinerU for layout-aware PDF parsing, DocStrange
for structured data extraction, LibPDF for PDF form filling) -- it routes to them
when appropriate and handles everything else.

```text
Input (any format)
     |
  [Detect format]
     |
  [Select tool] -- preferred tool for this format pair
     |            \-- fallback if preferred unavailable or fails
  [Convert / Create]
     |
  [Validate output] -- file exists, non-empty, format-valid
     |
  Output (target format)
```

## Tool Selection Matrix

Each format pair has a preferred tool and fallback. The helper script checks
availability at runtime and selects automatically.

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
| ODT | DOCX | pandoc | LibreOffice headless | pandoc is lossless for text; LO better for complex layout |
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

### PDF Extraction (PDF as source)

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

## Tool Reference

### Tier 1: Minimal (pandoc + poppler)

Always available after `install --minimal`. Handles most text-based conversions.

- **pandoc**: Swiss-army knife. Reads: md, docx, odt, html, epub, rst, latex, pptx, xlsx, csv, tsv, rtf. Writes: md, docx, odt, html, epub, pdf (with engine), pptx, rst, latex.
- **poppler** (pdftotext, pdfimages, pdfinfo, pdftohtml): PDF text/image extraction, metadata.

### Tier 2: Standard (+ Python libraries)

Adds programmatic document creation and manipulation.

- **odfpy**: Create/edit ODT, ODS, ODP programmatically. Full control over styles, headers, footers, images, tables.
- **python-docx**: Create/edit DOCX programmatically. Paragraphs, tables, images, styles, headers/footers.
- **openpyxl**: Create/edit XLSX programmatically. Cells, formulas, charts, styles.

### Tier 3: Full (+ LibreOffice headless)

Highest fidelity for office format conversions. LibreOffice headless runs without GUI.

- **LibreOffice headless**: `soffice --headless --convert-to <format> <input>`. Handles complex layouts, embedded objects, macros. Faithful ODT/DOCX/XLSX/PPTX to PDF conversion.

### Specialist Tools (routed to, not owned)

These have their own agents. This agent routes to them when the task matches.

| Tool | Agent | When to route |
|------|-------|---------------|
| MinerU | `tools/conversion/mineru.md` | PDF with complex layout, tables, formulas, OCR |
| DocStrange | `tools/document/docstrange.md` | Structured data extraction from documents |
| Docling+ExtractThinker | `tools/document/document-extraction.md` | Schema-based extraction with PII redaction |
| LibPDF | `tools/pdf/overview.md` | PDF form filling, digital signatures |

### Advanced Conversion Providers

AI-powered conversion tools for enhanced quality and table preservation.

| Provider | Model | Install | Best For |
|----------|-------|---------|----------|
| Reader-LM | Jina, 1.5B | `ollama pull reader-lm` | HTML to markdown with table preservation |
| RolmOCR | Reducto, 7B | vLLM server with RolmOCR model | PDF page images to markdown with table preservation (GPU-accelerated) |

**Reader-LM** (Jina AI, 1.5B parameters):
- Runs locally via Ollama
- Converts HTML to markdown while preserving complex table structures
- Replaces pandoc for HTML->md when available
- Usage: `document-creation-helper.sh convert page.html --to md`

**RolmOCR** (Reducto, 7B parameters):
- Runs via vLLM server (requires GPU)
- Converts PDF page images to markdown with table preservation
- Replaces pdftotext for PDF->md when GPU available
- Requires vLLM server running on port 8000 with RolmOCR model
- Usage: `document-creation-helper.sh convert document.pdf --to md`

## Document Creation from Templates

### Template System

Templates are regular documents (ODT, DOCX, etc.) with placeholder markers.
The agent replaces markers with supplied data to produce finished documents.

**Placeholder syntax**: `{{field_name}}`

Example template fields:

```text
{{property_name}}       -- "The Bakehouse"
{{property_address}}    -- "Rue de la Vallee, St Mary, JE3 3DL"
{{date}}                -- "10th October 2025"
{{author}}              -- "Marcus Quinn"
{{listing_reference}}   -- "MY0128"
```

### Template Sources

1. **User-supplied** (preferred): Place templates in your project or provide a path.
   The agent uses them as-is, replacing only the placeholder fields.

2. **Draft templates**: When no template exists, the agent can generate a draft
   ODT/DOCX with placeholder fields, basic styles, headers/footers, and logo
   placement. The user then refines the layout in their preferred editor
   (LibreOffice, Affinity Publisher, Word) and saves it as the canonical template.

### Template Storage

```text
~/.aidevops/.agent-workspace/templates/
  documents/          # Document templates (ODT, DOCX)
  spreadsheets/       # Spreadsheet templates (ODS, XLSX)
  presentations/      # Presentation templates (ODP, PPTX)
```

Project-specific templates can live anywhere -- pass the path to the helper.

### Creating Documents from Templates

```bash
# From a template with JSON data
document-creation-helper.sh create template.odt \
  --data '{"property_name": "The Bakehouse", "date": "10th October 2025"}' \
  --output letter.odt

# From a template with a JSON file
document-creation-helper.sh create template.odt \
  --data fields.json \
  --output letter.odt

# Generate a draft template
document-creation-helper.sh template draft \
  --type letter \
  --format odt \
  --fields "property_name,property_address,date,author,listing_reference"
```

### Programmatic Creation (no template)

For fully programmatic document generation (e.g., reports from data), the agent
uses odfpy/python-docx directly. This is appropriate when:

- The document structure is data-driven (variable number of sections, images)
- No visual template exists yet
- Batch generation of many documents with different structures

```bash
# The helper delegates to a Python script for complex creation
document-creation-helper.sh create --script generate-report.py \
  --data project-data.json \
  --output report.odt
```

## Installation

```bash
# Check what's installed
document-creation-helper.sh status

# Minimal: pandoc + poppler (covers most text conversions)
document-creation-helper.sh install --minimal

# Standard: + odfpy, python-docx, openpyxl (programmatic creation)
document-creation-helper.sh install --standard

# Full: + LibreOffice headless (highest fidelity office conversions)
document-creation-helper.sh install --full

# Individual tools
document-creation-helper.sh install --tool pandoc
document-creation-helper.sh install --tool libreoffice
document-creation-helper.sh install --tool odfpy
document-creation-helper.sh install --tool python-docx
document-creation-helper.sh install --tool openpyxl
```

### Installation Details

**Tier 1 - Minimal**:

```bash
# macOS
brew install pandoc poppler

# Ubuntu/Debian
sudo apt install pandoc poppler-utils

# Windows
choco install pandoc
```

**Tier 2 - Standard** (Python venv at `~/.aidevops/.agent-workspace/python-env/document-creation/`):

```bash
python3 -m venv ~/.aidevops/.agent-workspace/python-env/document-creation
source ~/.aidevops/.agent-workspace/python-env/document-creation/bin/activate
pip install odfpy python-docx openpyxl
```

**Tier 3 - Full**:

```bash
# macOS
brew install --cask libreoffice

# Ubuntu/Debian
sudo apt install libreoffice-core libreoffice-writer libreoffice-calc libreoffice-impress

# Verify headless mode
soffice --headless --version
```

## Usage Examples

### Format Conversion

```bash
# Simple conversions
document-creation-helper.sh convert report.md --to docx
document-creation-helper.sh convert letter.odt --to pdf
document-creation-helper.sh convert slides.pptx --to pdf
document-creation-helper.sh convert data.xlsx --to csv

# With options
document-creation-helper.sh convert report.md --to pdf --engine xelatex
document-creation-helper.sh convert letter.odt --to pdf --tool libreoffice
document-creation-helper.sh convert complex.pdf --to md --tool mineru

# Batch conversion
document-creation-helper.sh convert ./documents/*.docx --to pdf
document-creation-helper.sh convert ./reports/*.md --to odt

# Force a specific tool
document-creation-helper.sh convert file.odt --to pdf --tool pandoc
document-creation-helper.sh convert file.odt --to pdf --tool libreoffice
```

### PDF to ODT (layout-preserving)

This is a multi-step process handled automatically:

1. Extract text with `pdftotext -layout`
2. Extract images with `pdfimages`
3. Detect document structure (headings, paragraphs, captions)
4. Build ODT with odfpy (styles, headers/footers, embedded images)

```bash
# Automatic (uses best available tools)
document-creation-helper.sh convert report.pdf --to odt

# With a template (applies extracted content to template layout)
document-creation-helper.sh convert report.pdf --to odt --template company-template.odt
```

### Document Creation

```bash
# From template with inline data
document-creation-helper.sh create letter-template.odt \
  --data '{"recipient": "Planning Department", "date": "2025-10-11"}' \
  --output cover-letter.odt

# From template with data file
document-creation-helper.sh create invoice-template.xlsx \
  --data invoice-data.json \
  --output "Invoice-2025-001.xlsx"

# Generate a draft template for a new document type
document-creation-helper.sh template draft \
  --type report \
  --format odt \
  --fields "title,author,date,summary" \
  --header-logo logo.png \
  --footer-text "Company Name | confidential"
```

## Decision Tree

When asked to convert or create a document, follow this tree:

```text
1. What is the task?
   |
    +-- Convert format A to format B
    |   |
    |   +-- Is it structured data extraction? (invoice fields, receipt OCR)
    |   |   YES -> Route to document-extraction.md or docstrange.md
    |   |
    |   +-- Is it PDF form filling or signing?
    |   |   YES -> Route to tools/pdf/overview.md (LibPDF)
    |   |
    |   +-- Is it PDF with complex layout to markdown?
    |   |   YES -> Route to tools/conversion/mineru.md
    |   |
    |   +-- Is it a scanned PDF or image with text?
    |   |   YES -> OCR pipeline (auto-detect provider, extract text, then convert)
    |   |
    |   +-- Otherwise: use this agent's tool selection matrix
    |       Check preferred tool -> available? -> use it
    |       Not available? -> try fallback
    |       No fallback? -> suggest installation
   |
   +-- Create document from template
   |   |
   |   +-- Template supplied?
   |   |   YES -> Load template, replace placeholders, save
   |   |   NO  -> Offer to generate draft template
   |   |
   |   +-- Complex/data-driven structure?
   |       YES -> Use odfpy/python-docx programmatically
   |       NO  -> Template + placeholder replacement
   |
   +-- Generate draft template
       |
       +-- Collect: format, fields, header/footer, logo
       +-- Generate with odfpy/python-docx
       +-- Save to templates directory or specified path
       +-- User refines in their preferred editor
```

## OCR Support

For scanned PDFs and images containing text, OCR extracts the text content before
document creation or conversion can proceed.

### When OCR Is Needed

- **Scanned PDFs**: Pages are images, not selectable text. `pdftotext` returns empty output.
- **Photos of documents**: Camera captures of letters, forms, signs.
- **Screenshots with text**: UI captures where text needs extracting.

### Auto-Detection

The helper script detects scanned PDFs automatically:

1. Run `pdftotext` on the input -- if output is empty or near-empty, pages are likely scanned images
2. Run `pdffonts` -- if no fonts are embedded, the PDF contains only images
3. If both checks indicate image-only content, trigger OCR pipeline

### OCR Provider Routing

| Provider | Install | Speed | Quality | Best For |
|----------|---------|-------|---------|----------|
| Tesseract | `brew install tesseract` | Fast | Good (printed text) | Batch processing, simple documents |
| EasyOCR | `pip install easyocr` | Medium | Good (80+ languages) | Multi-language documents |
| GLM-OCR | `ollama pull glm-ocr` | Slow | Very good | Privacy-sensitive, complex layouts |
| Vision LLM | API key required | Medium | Excellent | Photos, receipts, handwriting |

**Selection order** (auto mode): Tesseract -> EasyOCR -> GLM-OCR -> Vision LLM

The helper picks the first available provider. Use `--ocr <provider>` to force a specific one.

### Usage

```bash
# Auto-detect and OCR if needed
document-creation-helper.sh convert scanned-report.pdf --to odt

# Force OCR with specific provider
document-creation-helper.sh convert scanned.pdf --to odt --ocr tesseract
document-creation-helper.sh convert photo.jpg --to odt --ocr glm-ocr

# OCR a screenshot -- extract text as quoted block
document-creation-helper.sh convert screenshot.png --to md --ocr auto

# Check OCR tool availability
document-creation-helper.sh status
```

### Screenshot Text Extraction

When the input is a screenshot or image (PNG, JPG, TIFF), the agent offers three options:

1. **Keep as image** -- embed the screenshot in the output document as-is
2. **Extract text** -- OCR the image and insert the text content
3. **Both** -- embed the image with the extracted text as a caption or adjacent paragraph

### OCR Installation

```bash
# Tesseract (recommended first install -- fast, reliable for printed text)
brew install tesseract                    # macOS
sudo apt install tesseract-ocr            # Ubuntu/Debian

# EasyOCR (Python, 80+ languages)
document-creation-helper.sh install --tool easyocr

# GLM-OCR (local AI via Ollama, no API keys)
ollama pull glm-ocr

# All OCR tools at once
document-creation-helper.sh install --ocr
```

### Related OCR Agents

- `tools/ocr/glm-ocr.md` -- Local OCR via Ollama
- `tools/ocr/ocr-research.md` -- OCR approach comparison and research
- `tools/document/document-extraction.md` -- Structured data extraction (Docling + ExtractThinker)
- `tools/conversion/mineru.md` -- MinerU (layout-aware PDF parsing with built-in OCR)

## Limitations

- **PDF to editable formats** is inherently lossy. PDFs use absolute positioning;
  flow-based formats (ODT, DOCX) use relative layout. Text content and images
  transfer well; exact positioning does not.
- **Spreadsheet formulas** may not survive format conversion (XLSX to ODS and back).
  Values are preserved; formulas may need manual verification.
- **Presentation animations and transitions** are lost in most conversions.
- **Embedded fonts** may not transfer between formats. The output may use
  fallback fonts if the original font is unavailable.
- **LibreOffice headless** produces the highest fidelity but is a large install (~500MB).
  The helper script works without it, using pandoc as fallback.

## Related

- `tools/conversion/pandoc.md` - Pandoc details and advanced options
- `tools/conversion/mineru.md` - PDF to markdown (layout-aware, OCR)
- `tools/document/docstrange.md` - Structured data extraction
- `tools/document/document-extraction.md` - Docling+ExtractThinker+Presidio pipeline
- `tools/document/extraction-workflow.md` - Extraction tool selection guide
- `tools/pdf/overview.md` - PDF manipulation (form filling, signing)
- `scripts/document-creation-helper.sh` - CLI helper
