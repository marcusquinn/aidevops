---
description: LibPDF - TypeScript PDF library for form filling, signing, and manipulation
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# LibPDF

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: PDF parsing, modification, form filling, digital signatures
- **Package**: `@libpdf/core`
- **Install**: `npm install @libpdf/core` | `bun add @libpdf/core` | `pnpm add @libpdf/core`
- **Docs**: https://libpdf.dev
- **GitHub**: https://github.com/LibPDF-js/core
- **License**: MIT (fontbox: Apache-2.0)

**Key Features**:
- Parse any PDF (graceful fallback for malformed documents)
- Incremental saves (preserve existing signatures)
- Digital signatures (PAdES B-B, B-T, B-LT, B-LTA)
- Form filling (text, checkbox, radio, dropdown, signature)
- Form flattening (bake fields into page content)
- Encryption (RC4, AES-128, AES-256)
- Merge and split documents
- Text extraction with position info
- Font embedding (TTF/OpenType with subsetting)
- Images (JPEG, PNG with alpha)

**Runtime**: Node.js 20+, Bun, modern browsers (Web Crypto)

**Known Limitations**:
- No signature verification (signing works, verification planned)
- No TrueType Collections (.ttc) — extract individual fonts first
- JBIG2/JPEG2000 passthrough only (preserved but not decoded)
- No certificate encryption (password encryption works)
- JavaScript actions ignored (form calculations not executed)

<!-- AI-CONTEXT-END -->

## Core Concepts

### Loading and Saving

```typescript
import { PDF } from '@libpdf/core';

// Load from bytes (Uint8Array, ArrayBuffer, Buffer)
const pdf = await PDF.load(bytes);

// Load encrypted PDF
const pdf = await PDF.load(bytes, { credentials: 'password' });

// Create new PDF
const pdf = PDF.create();

// Save (returns Uint8Array)
const output = await pdf.save();

// Incremental save (preserves signatures)
const output = await pdf.save({ incremental: true });
```

## Form Filling

```typescript
const pdf = await PDF.load(bytes);
const form = await pdf.getForm();

// Get fields
const fieldNames = form.getFieldNames();
const textField = form.getTextField('name');
const checkbox = form.getCheckBox('agree');
const radio = form.getRadioGroup('gender');
const dropdown = form.getDropdown('country');

// Fill individual fields
textField.setText('Jane Doe');
checkbox.check();
radio.select('female');
dropdown.select('United States');

// Or fill multiple fields at once
form.fill({
  name: 'Jane Doe',
  email: 'jane@example.com',
  agreed: true,
  gender: 'female',
  country: 'United States',
});

const filled = await pdf.save();

// Flatten (bake fields into page content, non-editable)
form.flatten();
const flattened = await pdf.save();
```

## Digital Signatures

### Create Signer and Sign

```typescript
import { PDF, P12Signer } from '@libpdf/core';
import { readFile } from 'fs/promises';

const p12Bytes = await readFile('certificate.p12');
const signer = await P12Signer.create(p12Bytes, 'certificate-password');

const pdf = await PDF.load(bytes);

// Basic signature
const { bytes: signed } = await pdf.sign({ signer });

// With metadata
const { bytes: signed } = await pdf.sign({
  signer,
  reason: 'I approve this document',
  location: 'New York, NY',
  contactInfo: 'jane@example.com',
});

// Visible signature
const { bytes: signed } = await pdf.sign({
  signer,
  reason: 'Approved',
  appearance: {
    page: 0,
    rect: { x: 50, y: 50, width: 200, height: 50 },
  },
});
```

### PAdES Levels

```typescript
// B-B (Basic) — default
const { bytes } = await pdf.sign({ signer });

// B-T (with timestamp)
const { bytes } = await pdf.sign({
  signer,
  timestampServer: 'http://timestamp.digicert.com',
});

// B-LT (Long-Term with revocation info)
const { bytes } = await pdf.sign({
  signer,
  timestampServer: 'http://timestamp.digicert.com',
  embedRevocationInfo: true,
});

// B-LTA (Long-Term Archival)
const { bytes } = await pdf.sign({
  signer,
  timestampServer: 'http://timestamp.digicert.com',
  embedRevocationInfo: true,
  archiveTimestamp: true,
});
```

## Page Manipulation

```typescript
// Get pages
const pages = await pdf.getPages();
const firstPage = pages[0];
const { width, height } = firstPage; // e.g., 612x792 for US Letter

// Add pages
const page = pdf.addPage();
const page = pdf.addPage({ size: 'letter' }); // or 'a4', 'legal', etc.
const page = pdf.addPage({ width: 612, height: 792 });
pdf.insertPage(0, page); // Insert at position

// Remove pages
pdf.removePage(0);
```

## Drawing on Pages

```typescript
import { PDF, rgb, StandardFonts, degrees } from '@libpdf/core';

const pdf = PDF.create();
const page = pdf.addPage({ size: 'letter' });
const font = await pdf.embedFont(StandardFonts.Helvetica);

// Text
page.drawText('Hello, World!', { x: 50, y: 700, size: 24, font, color: rgb(0, 0, 0) });

// Rectangle
page.drawRectangle({
  x: 50, y: 600, width: 200, height: 100,
  color: rgb(0.9, 0.9, 0.9),
  borderColor: rgb(0, 0, 0), borderWidth: 1,
});

// Line
page.drawLine({
  start: { x: 50, y: 500 }, end: { x: 250, y: 500 },
  thickness: 2, color: rgb(0, 0, 0),
});

// Circle
page.drawCircle({
  x: 150, y: 400, size: 50,
  color: rgb(0.8, 0.8, 1),
  borderColor: rgb(0, 0, 0.5), borderWidth: 1,
});

// Image
const imageBytes = await readFile('logo.png');
const image = await pdf.embedPng(imageBytes); // or embedJpg
page.drawImage(image, { x: 50, y: 650, width: 100, height: 50 });
```

## Merge and Split

```typescript
// Merge multiple PDFs
const merged = await PDF.merge([pdf1Bytes, pdf2Bytes, pdf3Bytes]);
const output = await merged.save();

// Extract pages to new document
const pdf = await PDF.load(bytes);
const newPdf = PDF.create();
const [page1, page2] = await newPdf.copyPagesFrom(pdf, [0, 1]);
newPdf.addPage(page1);
newPdf.addPage(page2);
const output = await newPdf.save();
```

## Text Extraction

```typescript
const pdf = await PDF.load(bytes);
for (const page of pdf.getPages()) {
  const result = page.extractText();
  console.log(result.text);
}
```

## Encryption

```typescript
// Decrypt on load
const pdf = await PDF.load(encryptedBytes, { credentials: 'password' });

// Encrypt on save
const output = await pdf.save({
  userPassword: 'user-password',
  ownerPassword: 'owner-password',
  permissions: {
    printing: 'highResolution',
    modifying: false,
    copying: true,
    annotating: true,
    fillingForms: true,
    contentAccessibility: true,
    documentAssembly: false,
  },
});
```

## Attachments

```typescript
// Embed file
const fileBytes = await readFile('data.csv');
await pdf.attach(fileBytes, 'data.csv', { mimeType: 'text/csv', description: 'Exported data' });

// Extract attachments
const attachments = await pdf.getAttachments();
for (const attachment of attachments) {
  const bytes = await attachment.getData();
  await writeFile(attachment.name, bytes);
}
```

## Error Handling

```typescript
import { PDF, PDFParseError, PDFEncryptionError } from '@libpdf/core';

try {
  const pdf = await PDF.load(bytes);
} catch (error) {
  if (error instanceof PDFEncryptionError) {
    const pdf = await PDF.load(bytes, { credentials: 'password' });
  } else if (error instanceof PDFParseError) {
    console.error('Failed to parse PDF:', error.message);
  }
}
```

## Common Patterns

### Fill and Sign Workflow

```typescript
import { PDF, P12Signer } from '@libpdf/core';

async function fillAndSign(
  pdfBytes: Uint8Array,
  formData: Record<string, string | boolean>,
  p12Bytes: Uint8Array,
  p12Password: string
): Promise<Uint8Array> {
  const pdf = await PDF.load(pdfBytes);
  const form = await pdf.getForm();
  form.fill(formData);
  const signer = await P12Signer.create(p12Bytes, p12Password);
  const { bytes } = await pdf.sign({ signer, reason: 'Document completed and signed' });
  return bytes;
}
```

### Add Watermark

```typescript
import { PDF, rgb, StandardFonts, degrees } from '@libpdf/core';

async function addWatermark(pdfBytes: Uint8Array, text: string): Promise<Uint8Array> {
  const pdf = await PDF.load(pdfBytes);
  const font = await pdf.embedFont(StandardFonts.HelveticaBold);
  for (const page of pdf.getPages()) {
    const { width, height } = page;
    page.drawText(text, {
      x: width / 2 - 100, y: height / 2,
      size: 50, font,
      color: rgb(0.8, 0.8, 0.8),
      rotate: degrees(45), opacity: 0.3,
    });
  }
  return await pdf.save();
}
```

### Batch Processing

```typescript
async function processPDFs(files: string[]): Promise<void> {
  for (const file of files) {
    const bytes = await readFile(file);
    const pdf = await PDF.load(bytes);
    const form = await pdf.getForm();
    form.fill({ processedDate: new Date().toISOString() });
    const output = await pdf.save();
    await writeFile(file.replace('.pdf', '-processed.pdf'), output);
  }
}
```

## Related

- `overview.md` — PDF tools selection guide
- `tools/browser/playwright.md` — For PDF rendering/screenshots
- `tools/code-review/code-standards.md` — TypeScript best practices
