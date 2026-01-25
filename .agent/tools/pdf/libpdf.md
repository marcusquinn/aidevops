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
- **Install**: `npm install @libpdf/core` or `bun add @libpdf/core`
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
- No TrueType Collections (.ttc) - extract individual fonts first
- JBIG2/JPEG2000 passthrough only (preserved but not decoded)
- No certificate encryption (password encryption works)
- JavaScript actions ignored (form calculations not executed)

<!-- AI-CONTEXT-END -->

## Installation

```bash
# npm
npm install @libpdf/core

# bun
bun add @libpdf/core

# pnpm
pnpm add @libpdf/core
```

## Core Concepts

### Loading PDFs

```typescript
import { PDF } from '@libpdf/core';

// Load from bytes (Uint8Array, ArrayBuffer, Buffer)
const pdf = await PDF.load(bytes);

// Load encrypted PDF
const pdf = await PDF.load(bytes, { credentials: 'password' });

// Create new PDF
const pdf = PDF.create();
```

### Saving PDFs

```typescript
// Save (returns Uint8Array)
const output = await pdf.save();

// Incremental save (preserves signatures)
const output = await pdf.save({ incremental: true });
```

## Form Filling

### Get Form and Fields

```typescript
const pdf = await PDF.load(bytes);
const form = await pdf.getForm();

// Get all field names
const fieldNames = form.getFieldNames();

// Get specific field types
const textField = form.getTextField('name');
const checkbox = form.getCheckBox('agree');
const radio = form.getRadioGroup('gender');
const dropdown = form.getDropdown('country');
```

### Fill Form Fields

```typescript
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
```

### Flatten Form

```typescript
// Bake form fields into page content (non-editable)
form.flatten();
const flattened = await pdf.save();
```

## Digital Signatures

### Create Signer from P12/PFX

```typescript
import { PDF, P12Signer } from '@libpdf/core';

// Load certificate from P12/PFX file
const p12Bytes = await fs.readFile('certificate.p12');
const signer = await P12Signer.create(p12Bytes, 'certificate-password');
```

### Sign Document

```typescript
const pdf = await PDF.load(bytes);

// Basic signature
const { bytes: signed } = await pdf.sign({ signer });

// With options
const { bytes: signed } = await pdf.sign({
  signer,
  reason: 'I approve this document',
  location: 'New York, NY',
  contactInfo: 'jane@example.com',
});
```

### Visible Signature

```typescript
const { bytes: signed } = await pdf.sign({
  signer,
  reason: 'Approved',
  // Add visible signature on page 1
  appearance: {
    page: 0,
    rect: { x: 50, y: 50, width: 200, height: 50 },
  },
});
```

### PAdES Levels

```typescript
// B-B (Basic) - default
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

### Get Pages

```typescript
const pages = await pdf.getPages();
console.log(`${pages.length} pages`);

const firstPage = pages[0];
const { width, height } = firstPage.getSize();
```

### Add Pages

```typescript
// Add blank page
const page = pdf.addPage();

// Add page with size
const page = pdf.addPage({ size: 'letter' }); // or 'a4', 'legal', etc.
const page = pdf.addPage({ width: 612, height: 792 });

// Insert page at position
pdf.insertPage(0, page); // Insert at beginning
```

### Remove Pages

```typescript
pdf.removePage(0); // Remove first page
```

## Drawing on Pages

### Draw Text

```typescript
import { PDF, rgb, StandardFonts } from '@libpdf/core';

const pdf = PDF.create();
const page = pdf.addPage({ size: 'letter' });

// Embed font
const font = await pdf.embedFont(StandardFonts.Helvetica);

page.drawText('Hello, World!', {
  x: 50,
  y: 700,
  size: 24,
  font,
  color: rgb(0, 0, 0),
});
```

### Draw Shapes

```typescript
// Rectangle
page.drawRectangle({
  x: 50,
  y: 600,
  width: 200,
  height: 100,
  color: rgb(0.9, 0.9, 0.9),
  borderColor: rgb(0, 0, 0),
  borderWidth: 1,
});

// Line
page.drawLine({
  start: { x: 50, y: 500 },
  end: { x: 250, y: 500 },
  thickness: 2,
  color: rgb(0, 0, 0),
});

// Circle
page.drawCircle({
  x: 150,
  y: 400,
  size: 50,
  color: rgb(0.8, 0.8, 1),
  borderColor: rgb(0, 0, 0.5),
  borderWidth: 1,
});
```

### Draw Images

```typescript
// Embed image
const imageBytes = await fs.readFile('logo.png');
const image = await pdf.embedPng(imageBytes);
// or: const image = await pdf.embedJpg(imageBytes);

// Draw on page
page.drawImage(image, {
  x: 50,
  y: 650,
  width: 100,
  height: 50,
});
```

## Merge and Split

### Merge PDFs

```typescript
import { PDF } from '@libpdf/core';

// Merge multiple PDFs
const merged = await PDF.merge([pdf1Bytes, pdf2Bytes, pdf3Bytes]);
const output = await merged.save();
```

### Extract Pages

```typescript
const pdf = await PDF.load(bytes);

// Copy pages to new document
const newPdf = PDF.create();
const [page1, page2] = await pdf.copyPages(pdf, [0, 1]);
newPdf.addPage(page1);
newPdf.addPage(page2);

const output = await newPdf.save();
```

## Text Extraction

```typescript
const pdf = await PDF.load(bytes);
const pages = await pdf.getPages();

for (const page of pages) {
  const text = await page.getTextContent();
  console.log(text);
}
```

## Encryption

### Decrypt on Load

```typescript
const pdf = await PDF.load(encryptedBytes, { credentials: 'password' });
```

### Encrypt on Save

```typescript
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

### Embed Files

```typescript
const fileBytes = await fs.readFile('data.csv');
await pdf.attach(fileBytes, 'data.csv', {
  mimeType: 'text/csv',
  description: 'Exported data',
});
```

### Extract Attachments

```typescript
const attachments = await pdf.getAttachments();
for (const attachment of attachments) {
  console.log(attachment.name);
  const bytes = await attachment.getData();
  await fs.writeFile(attachment.name, bytes);
}
```

## Error Handling

```typescript
import { PDF, PDFParseError, PDFEncryptionError } from '@libpdf/core';

try {
  const pdf = await PDF.load(bytes);
} catch (error) {
  if (error instanceof PDFEncryptionError) {
    // PDF is encrypted, need password
    const pdf = await PDF.load(bytes, { credentials: 'password' });
  } else if (error instanceof PDFParseError) {
    // PDF is corrupted or unsupported
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
  // Load PDF
  const pdf = await PDF.load(pdfBytes);
  
  // Fill form
  const form = await pdf.getForm();
  form.fill(formData);
  
  // Create signer
  const signer = await P12Signer.create(p12Bytes, p12Password);
  
  // Sign and return
  const { bytes } = await pdf.sign({
    signer,
    reason: 'Document completed and signed',
  });
  
  return bytes;
}
```

### Batch Processing

```typescript
import { PDF } from '@libpdf/core';

async function processPDFs(files: string[]): Promise<void> {
  for (const file of files) {
    const bytes = await fs.readFile(file);
    const pdf = await PDF.load(bytes);
    
    // Process...
    const form = await pdf.getForm();
    form.fill({ processedDate: new Date().toISOString() });
    
    const output = await pdf.save();
    await fs.writeFile(file.replace('.pdf', '-processed.pdf'), output);
  }
}
```

### Add Watermark

```typescript
import { PDF, rgb, StandardFonts, degrees } from '@libpdf/core';

async function addWatermark(pdfBytes: Uint8Array, text: string): Promise<Uint8Array> {
  const pdf = await PDF.load(pdfBytes);
  const font = await pdf.embedFont(StandardFonts.HelveticaBold);
  const pages = await pdf.getPages();
  
  for (const page of pages) {
    const { width, height } = page.getSize();
    
    page.drawText(text, {
      x: width / 2 - 100,
      y: height / 2,
      size: 50,
      font,
      color: rgb(0.8, 0.8, 0.8),
      rotate: degrees(45),
      opacity: 0.3,
    });
  }
  
  return await pdf.save();
}
```

## Related

- `overview.md` - PDF tools selection guide
- `tools/browser/playwright.md` - For PDF rendering/screenshots
- `tools/code-review/code-standards.md` - TypeScript best practices
