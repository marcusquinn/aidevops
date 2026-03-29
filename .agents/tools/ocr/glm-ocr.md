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
- **Install**: `ollama pull glm-ocr` (~2GB, requires Ollama: `brew install ollama`)
- **Source**: [THUDM](https://github.com/THUDM) (Tsinghua University) GLM-V architecture — [Ollama page](https://ollama.com/library/glm-ocr)

**When to use**: Quick text extraction from screenshots, photos, scanned documents, receipts, invoices, forms — locally, no cloud, no API costs.

**When to use alternatives**:

- Complex structured extraction (tables, nested forms) → Unstract (`services/document-processing/unstract.md`)
- Screen capture + GUI automation → Peekaboo with `--model ollama/glm-ocr` (`tools/browser/peekaboo.md`)
- Cloud-based with higher accuracy → GPT-4o or Claude vision APIs

<!-- AI-CONTEXT-END -->

## Usage

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

### Screenshot OCR (macOS)

```bash
screencapture -i /tmp/capture.png && ollama run glm-ocr "Extract all text" --images /tmp/capture.png
```

### Batch Processing

```bash
for img in ~/Documents/scans/*.png; do
  echo "=== $img ==="
  ollama run glm-ocr "Extract all text" --images "$img"
done > extracted_text.txt
```

### PDF to Text (requires ImageMagick)

```bash
convert -density 300 document.pdf -quality 90 /tmp/page-%03d.png
for page in /tmp/page-*.png; do
  ollama run glm-ocr "Extract all text" --images "$page"
done
```

### With Peekaboo (Screen/Window Capture)

```bash
# Screen capture + OCR
peekaboo image --mode screen --analyze "What text is visible?" --model ollama/glm-ocr

# Window capture + OCR
peekaboo image --mode window --app "Preview" --analyze "Extract document text" --model ollama/glm-ocr
```

## Model Comparison

| Model | Best For | Size | Speed | Local | Notes |
|-------|----------|------|-------|-------|-------|
| **glm-ocr** | Document OCR, forms, tables | ~2GB | Fast | Yes | Purpose-built for OCR; handles complex layouts, multi-column text. No structured JSON output. |
| llava | General vision, scene understanding | ~4GB | Medium | Yes | Better at general image understanding |
| GPT-4o | Complex reasoning + vision | Cloud | Fast | No | Higher accuracy, structured output |
| Claude 4 | Nuanced text understanding | Cloud | Fast | No | Best for reasoning about document content |

**Limitations**: Less capable at general image understanding; may struggle with very low quality images; no structured JSON output (use Unstract for that).

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Model not found | `ollama pull glm-ocr` then `ollama list` to verify |
| Slow performance | Needs ≥8GB RAM; process large batches sequentially |
| Poor OCR quality | Use ≥150 DPI (300 for scans); crop to relevant area; try specific prompts |
