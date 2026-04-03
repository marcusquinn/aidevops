---
description: PDF processing tools overview and selection guide
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# PDF Tools Overview

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: PDF processing - parsing, modification, form filling, signing
- **Primary Tool**: LibPDF (`@libpdf/core`) - TypeScript-native; only library with incremental saves that preserve signatures
- **Install**: `npm install @libpdf/core` | `bun add @libpdf/core` | `pnpm add @libpdf/core`
- **Docs**: https://libpdf.dev
- **Why not pdf-lib**: no incremental saves, no signatures, poor malformed-PDF handling
- **Why not pdf.js**: read-only (no modify/generate/sign)

**Tool Selection**:

| Task | Tool | Why |
|------|------|-----|
| Form filling | LibPDF | Native TypeScript, clean API |
| Digital signatures | LibPDF | PAdES B-B through B-LTA support |
| Parse/modify PDFs | LibPDF | Handles malformed documents gracefully |
| Generate new PDFs | LibPDF | pdf-lib-like API |
| Merge/split | LibPDF | Full page manipulation |
| Text extraction | LibPDF | With position information |
| PDF to markdown/JSON | MinerU | Layout-aware, OCR, formula support |
| Scanned PDF OCR | PaddleOCR | Scene text, 100+ languages, bounding boxes |
| Render to image | pdf.js | LibPDF doesn't render (yet) |

**Subagents**:

| File | Purpose |
|------|---------|
| `libpdf.md` | LibPDF library - form filling, signing, manipulation |
| `../conversion/mineru.md` | MinerU - PDF to markdown/JSON for LLM workflows |

<!-- AI-CONTEXT-END -->

## Related

- `../document/document-creation.md` - Unified document format conversion and creation
- `../ocr/overview.md` - OCR tool selection guide (PaddleOCR, GLM-OCR, MinerU)
- `../ocr/paddleocr.md` - PaddleOCR scene text OCR for scanned PDFs and images
- `../conversion/pandoc.md` - General document format conversion
- `../browser/playwright.md` - For PDF rendering/screenshots
