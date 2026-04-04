---
description: PDF processing tools overview and selection guide
mode: subagent
tools:
  read: true
  grep: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# PDF Tools Overview

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Primary Tool**: LibPDF (`@libpdf/core`) — TypeScript-native; only library with incremental saves that preserve signatures
- **Install**: `npm install @libpdf/core` | `bun add @libpdf/core` | `pnpm add @libpdf/core`
- **Docs**: https://libpdf.dev
- **Why not pdf-lib**: no incremental saves, no signatures, poor malformed-PDF handling
- **Why not pdf.js**: read-only (no modify/generate/sign)

**Tool Selection**:

| Task | Tool | Notes |
|------|------|-------|
| Form filling | LibPDF | Native TypeScript, clean API |
| Digital signatures | LibPDF | PAdES B-B through B-LTA |
| Parse/modify/generate | LibPDF | Handles malformed docs; pdf-lib-like API |
| Merge/split/extract text | LibPDF | Full page manipulation; positional text |
| PDF to markdown/JSON | MinerU | Layout-aware, OCR, formula support |
| Scanned PDF OCR | PaddleOCR | 100+ languages, bounding boxes |
| Render to image | pdf.js | LibPDF doesn't render (yet) |

**Subagents**: `libpdf.md` · `../conversion/mineru.md` · `../ocr/paddleocr.md`

<!-- AI-CONTEXT-END -->

## Related

- `../document/document-creation.md` - Unified document format conversion and creation
- `../ocr/overview.md` - OCR tool selection (PaddleOCR, GLM-OCR, MinerU)
- `../conversion/pandoc.md` - General document format conversion
- `../browser/playwright.md` - PDF rendering/screenshots
