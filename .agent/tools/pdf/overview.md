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
- **Install**: `npm install @libpdf/core` or `bun add @libpdf/core`
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
| Render to image | pdf.js | LibPDF doesn't render (yet) |

**Subagents**:

| File | Purpose |
|------|---------|
| `libpdf.md` | LibPDF library - form filling, signing, manipulation |

<!-- AI-CONTEXT-END -->

## When to Use PDF Tools

Use PDF tools when you need to:

1. **Fill PDF forms** - Text fields, checkboxes, radio buttons, dropdowns
2. **Sign documents** - Digital signatures with certificates (PAdES)
3. **Modify existing PDFs** - Add content, merge pages, extract pages
4. **Generate new PDFs** - Create documents from scratch
5. **Extract content** - Text extraction with positioning
6. **Handle encrypted PDFs** - Decrypt password-protected documents

## Tool Comparison

### LibPDF vs Alternatives

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

**LibPDF** is the recommended choice for most PDF tasks because:
- Combines best features of pdf-lib (API) and pdf.js (parsing)
- Only library with incremental saves that preserve signatures
- TypeScript-native with minimal dependencies
- Works in Node.js, Bun, and browsers

## Installation

```bash
# npm
npm install @libpdf/core

# bun
bun add @libpdf/core

# pnpm
pnpm add @libpdf/core
```

## Quick Examples

### Load and Inspect PDF

```typescript
import { PDF } from '@libpdf/core';

const pdf = await PDF.load(bytes);
const pages = await pdf.getPages();
console.log(`${pages.length} pages`);
```

### Fill a Form

```typescript
const pdf = await PDF.load(bytes);
const form = await pdf.getForm();

form.fill({
  name: 'Jane Doe',
  email: 'jane@example.com',
  agreed: true,
});

const filled = await pdf.save();
```

### Sign a Document

```typescript
import { PDF, P12Signer } from '@libpdf/core';
import { readFileSync } from 'fs';

const pdfBytes = readFileSync('document.pdf');
const p12Bytes = readFileSync('certificate.p12');

const pdf = await PDF.load(pdfBytes);
const signer = await P12Signer.create(p12Bytes, 'password');

const { bytes: signed } = await pdf.sign({
  signer,
  reason: 'I approve this document',
});
```

## Related

- `libpdf.md` - Detailed LibPDF usage guide
- `tools/browser/playwright.md` - For PDF rendering/screenshots
