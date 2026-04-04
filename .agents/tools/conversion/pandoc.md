---
description: Pandoc document format conversion
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

# Pandoc Document Conversion

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Convert documents to markdown for AI processing
- **Install**: `brew install pandoc poppler` (macOS) or `apt install pandoc poppler-utils`
- **Helper**: `.agents/scripts/pandoc-helper.sh`
- **Commands**: `convert [file]` | `batch [dir] [output] [pattern]` | `formats` | `detect [file]`
- **Supported**: DOCX, PDF, HTML, EPUB, ODT, RTF, LaTeX, JSON, CSV, RST, Org-mode
- **Output**: Markdown with ATX headers, no line wrapping, preserved structure

<!-- AI-CONTEXT-END -->

## Installation

```bash
# macOS
brew install pandoc poppler

# Ubuntu/Debian
sudo apt update
sudo apt install pandoc poppler-utils

# CentOS/RHEL
sudo yum install pandoc poppler-utils

# Windows
choco install pandoc    # Chocolatey
scoop install pandoc    # Scoop
```

Verify: `pandoc --version` and `pdftotext -v` (PDF support).

## Usage

### Single file

```bash
# Basic conversion (auto-detects format)
bash .agents/scripts/pandoc-helper.sh convert document.docx

# Custom output name
bash .agents/scripts/pandoc-helper.sh convert report.pdf analysis.md

# Specify format and extra pandoc options
bash .agents/scripts/pandoc-helper.sh convert file.html output.md html "--extract-media=./images"
```

### Batch conversion

```bash
# All Word documents in a directory
bash .agents/scripts/pandoc-helper.sh batch ./documents ./markdown "*.docx"

# All supported formats
bash .agents/scripts/pandoc-helper.sh batch ./input ./output "*"

# Multiple format pattern
bash .agents/scripts/pandoc-helper.sh batch ./reports ./markdown "*.{pdf,docx,html}"
```

### Format detection and options

```bash
# Auto-detect file format
bash .agents/scripts/pandoc-helper.sh detect unknown_file.ext

# List all supported formats
bash .agents/scripts/pandoc-helper.sh formats

# Extract images/media
bash .agents/scripts/pandoc-helper.sh convert document.docx output.md docx "--extract-media=./media"

# Include table of contents
bash .agents/scripts/pandoc-helper.sh convert document.html output.md html "--toc"

# Standalone document
bash .agents/scripts/pandoc-helper.sh convert document.rst output.md rst "--standalone"

# Custom metadata
bash .agents/scripts/pandoc-helper.sh convert document.tex output.md latex "--metadata title='My Document'"
```

## Supported Formats

| Category | Extensions |
|----------|-----------|
| Documents | `.docx`, `.doc`, `.pdf` (requires pdftotext), `.odt`, `.rtf`, `.tex`/`.latex` |
| Web/eBook | `.html`/`.htm`, `.epub`, `.mediawiki`, `.twiki` |
| Data | `.json`, `.csv`, `.tsv`, `.xml` |
| Markup | `.rst`, `.org`, `.textile`, `.opml` |
| Presentations | `.pptx`/`.ppt` (limited), `.xlsx`/`.xls` (limited -- basic tables only) |

## Default Settings

- **Output**: Markdown with ATX headers (`# ## ###`)
- **Line wrapping**: None (preserves formatting)
- **Media extraction**: Automatic for supported formats
- **Structure**: Maintains document hierarchy
- **Metadata**: Includes source file information

The helper script validates output, shows a 10-line preview, reports file size/line count, and provides clear error messages on failure.

## Troubleshooting

### PDF conversion

For complex PDFs (multi-column, tables, formulas, scanned documents), use MinerU instead -- see `mineru.md`.

```bash
# Install PDF support
brew install poppler          # macOS
sudo apt install poppler-utils # Ubuntu
```

### Encoding issues

```bash
pandoc -f html -t markdown --from=html+smart input.html -o output.md
```

### Large files

```bash
pandoc --verbose input.pdf -o output.md
```

### Format-specific notes

- **PDF**: Quality depends on source document structure
- **PowerPoint**: Best for text content; limited layout support
- **Excel**: Basic table conversion only
- **HTML**: May need cleanup for complex layouts
- **Word**: Generally excellent conversion quality

---

**See also**: `tools/document/document-creation.md` -- unified document creation agent that routes to pandoc, LibreOffice, odfpy, and other tools based on format pair and availability.
