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
- **Primary Tool**: LibPDF (`@libpdf/core`) - TypeScript-native, full-featured
- **Install**: `npm install @libpdf/core` | `bun add @libpdf/core` | `pnpm add @libpdf/core`
- **Docs**: https://libpdf.dev

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

## Why LibPDF Over Alternatives

| Feature | LibPDF | pdf-lib | pdf.js |
|---------|--------|---------|--------|
| Parse existing PDFs | Yes | Limited | Yes |
| Modify existing PDFs | Yes | Yes | No |
| Generate new PDFs | Yes | Yes | No |
| Incremental saves | Yes | No | No |
| Digital signatures | Yes | No | No |
| Encrypted PDFs | Yes | No | Yes |
| Form filling | Yes | Yes | No |
| Text extraction | Yes | No | Yes |
| Render to image | No | No | Yes |
| Malformed PDF handling | Excellent | Poor | Excellent |

LibPDF is preferred because it combines pdf-lib's API with pdf.js's parsing, is the only library with incremental saves that preserve signatures, and is TypeScript-native with minimal dependencies (Node.js, Bun, browsers).

## Related

- `libpdf.md` - Detailed LibPDF usage guide with code examples
- `../document/document-creation.md` - Unified document format conversion and creation
- `../conversion/mineru.md` - PDF to markdown/JSON (layout-aware, OCR)
- `../ocr/overview.md` - OCR tool selection guide (PaddleOCR, GLM-OCR, MinerU)
- `../ocr/paddleocr.md` - PaddleOCR scene text OCR for scanned PDFs and images
- `../conversion/pandoc.md` - General document format conversion
- `../browser/playwright.md` - For PDF rendering/screenshots
