---
description: GLM-OCR - Local OCR via Ollama for document text extraction
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

# GLM-OCR - Local Document OCR

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Extract text from documents, images, screenshots using local AI
- **Model**: `glm-ocr` via Ollama (no API keys required)
- **Install**: `ollama pull glm-ocr`
- **Source**: THUDM (Tsinghua University) GLM-V architecture
- **Ollama**: <https://ollama.com/library/glm-ocr>

**When to use GLM-OCR**:

- Quick text extraction from screenshots, photos, scanned documents
- Processing receipts, invoices, forms locally (no cloud)
- Batch OCR of image files
- Privacy-sensitive documents that cannot leave your machine

**When to use alternatives**:

- Complex structured extraction (tables, nested forms) - Use Unstract
- Screen capture + GUI automation - Use Peekaboo with `--model ollama/glm-ocr`
- Cloud-based with higher accuracy - Use GPT-4o or Claude vision APIs

<!-- AI-CONTEXT-END -->

## Installation

```bash
# Install Ollama (if not already installed)
brew install ollama

# Pull GLM-OCR model (~2GB)
ollama pull glm-ocr

# Verify installation
ollama list | grep glm-ocr
```

## Basic Usage

### Extract Text from Image

```bash
# Single image OCR
ollama run glm-ocr "Extract all text from this image" --images /path/to/document.png

# With base64 encoding (for scripts)
base64 -i document.png | ollama run glm-ocr "Extract all text" --images -
```

### Common Prompts

| Task | Prompt |
|------|--------|
| Full text extraction | `"Extract all text from this image exactly as written"` |
| Table extraction | `"Extract the table data as markdown"` |
| Form fields | `"List all form fields and their values"` |
| Receipt parsing | `"Extract merchant, date, items, and total from this receipt"` |
| Handwriting | `"Transcribe the handwritten text"` |

## Workflow Patterns

### Screenshot OCR

```bash
# macOS: Capture screen region and OCR
screencapture -i /tmp/capture.png && ollama run glm-ocr "Extract all text" --images /tmp/capture.png
```

### Batch Processing

```bash
# Process all images in a directory
for img in ~/Documents/scans/*.png; do
  echo "=== $img ==="
  ollama run glm-ocr "Extract all text" --images "$img"
done > extracted_text.txt
```

### PDF to Text (via ImageMagick)

```bash
# Convert PDF pages to images, then OCR
convert -density 300 document.pdf -quality 90 /tmp/page-%03d.png

for page in /tmp/page-*.png; do
  ollama run glm-ocr "Extract all text" --images "$page"
done
```

### With Peekaboo (Screen Capture)

```bash
# Capture window and OCR in one command
peekaboo image --mode window --app Preview --analyze "Extract all text from this document" --model ollama/glm-ocr
```

## Model Comparison

| Model | Best For | Size | Speed | Local |
|-------|----------|------|-------|-------|
| **glm-ocr** | Document OCR, forms, tables | ~2GB | Fast | Yes |
| llava | General vision, scene understanding | ~4GB | Medium | Yes |
| GPT-4o | Complex reasoning + vision | Cloud | Fast | No |
| Claude 4 | Nuanced text understanding | Cloud | Fast | No |

**GLM-OCR advantages**:

- Purpose-built for OCR (not general vision)
- Handles complex document layouts
- Works with tables, forms, multi-column text
- Fully local - no data leaves your machine
- No API costs

**GLM-OCR limitations**:

- Less capable at general image understanding
- May struggle with very low quality images
- No structured JSON output (use Unstract for that)

## Integration with aidevops

### With Unstract (Structured Extraction)

For complex documents requiring structured JSON output:

```bash
# GLM-OCR: Quick text dump
ollama run glm-ocr "Extract all text" --images invoice.png

# Unstract: Structured extraction with schema
# See services/document-processing/unstract.md
```

### With Peekaboo (GUI Automation)

GLM-OCR is available as a Peekaboo vision provider:

```bash
# Screen capture + OCR
peekaboo image --mode screen --analyze "What text is visible?" --model ollama/glm-ocr

# Window capture + OCR
peekaboo image --mode window --app "Preview" --analyze "Extract document text" --model ollama/glm-ocr
```

## Troubleshooting

### Model Not Found

```bash
# Re-pull the model
ollama pull glm-ocr

# Check Ollama is running
ollama list
```

### Slow Performance

```bash
# Check available memory (model needs ~4GB RAM)
vm_stat | head -5

# For large batches, process sequentially to avoid memory pressure
```

### Poor OCR Quality

- Ensure image resolution is at least 150 DPI
- For scanned documents, use 300 DPI
- Crop to relevant area before OCR
- Try different prompts (be specific about expected content)

## Resources

- **Ollama Model**: <https://ollama.com/library/glm-ocr>
- **THUDM (creators)**: <https://github.com/THUDM>
- **Peekaboo integration**: `tools/browser/peekaboo.md`
- **Structured extraction**: `services/document-processing/unstract.md`
