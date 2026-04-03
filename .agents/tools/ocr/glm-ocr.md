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

- **Purpose**: Local text extraction from documents, images, screenshots (no API keys)
- **Model**: `glm-ocr` via Ollama (~2GB) — [THUDM](https://github.com/THUDM) GLM-V architecture
- **Install**: `ollama pull glm-ocr` (requires Ollama: `brew install ollama` / `curl -fsSL https://ollama.com/install.sh | sh`)
- **Use when**: Quick OCR of screenshots, photos, scanned docs, receipts, forms — local, no cloud
- **Alternatives**: Structured extraction (tables, nested forms) → Unstract (`services/document-processing/unstract.md`) | Screen capture + GUI → Peekaboo (`tools/browser/peekaboo.md`) | Higher accuracy → GPT-4o / Claude vision APIs

<!-- AI-CONTEXT-END -->

## Usage

```bash
ollama run glm-ocr "Extract all text from this image" --images /path/to/document.png
base64 -i document.png | ollama run glm-ocr "Extract all text" --images -  # pipe in scripts
```

| Task | Prompt |
|------|--------|
| Full text | `"Extract all text from this image exactly as written"` |
| Table | `"Extract the table data as markdown"` |
| Form fields | `"List all form fields and their values"` |
| Receipt | `"Extract merchant, date, items, and total from this receipt"` |
| Handwriting | `"Transcribe the handwritten text"` |

## Workflow Patterns

```bash
# macOS screenshot → OCR
screencapture -i /tmp/capture.png && ollama run glm-ocr "Extract all text" --images /tmp/capture.png

# Batch directory
for img in ~/Documents/scans/*.png; do
  echo "=== $img ===" && ollama run glm-ocr "Extract all text" --images "$img"
done > extracted_text.txt

# PDF via ImageMagick
convert -density 300 document.pdf -quality 90 /tmp/page-%03d.png
for page in /tmp/page-*.png; do ollama run glm-ocr "Extract all text" --images "$page"; done

# Peekaboo (screen/window capture)
peekaboo image --mode screen --analyze "What text is visible?" --model ollama/glm-ocr
peekaboo image --mode window --app "Preview" --analyze "Extract document text" --model ollama/glm-ocr
```

## Model Comparison

| Model | Best For | Size | Notes |
|-------|----------|------|-------|
| **glm-ocr** | Document OCR, forms, tables | ~2GB local | Purpose-built; complex layouts, multi-column. No JSON output. Weak on low-quality images. |
| llava | General vision, scene understanding | ~4GB local | Better at general image understanding |
| GPT-4o | Complex reasoning + vision | Cloud | Higher accuracy, structured output |
| Claude 4 | Nuanced text understanding | Cloud | Best for reasoning about content |

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Model not found | `ollama pull glm-ocr` then `ollama list` to verify |
| Slow performance | Needs >=8GB RAM; process large batches sequentially |
| Poor OCR quality | Use >=150 DPI (300 for scans); crop to relevant area; try specific prompts |
