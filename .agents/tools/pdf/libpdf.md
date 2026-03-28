---
description: LibPDF - TypeScript PDF library for form filling, signing, and manipulation
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  webfetch: true
---

# LibPDF

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Package**: `@libpdf/core` — `npm install @libpdf/core` | `bun add @libpdf/core`
- **Docs**: https://libpdf.dev | **GitHub**: https://github.com/LibPDF-js/core
- **License**: MIT (fontbox: Apache-2.0) | **Runtime**: Node.js 20+, Bun, modern browsers

**Features**: PDF parse (graceful fallback), incremental saves, digital signatures (PAdES B-B/T/LT/LTA), form fill/flatten, encryption (RC4/AES-128/AES-256), merge/split, text extraction, font embedding (TTF/OpenType), images (JPEG/PNG).

**Known Limitations**:
- No signature verification (planned) | No TrueType Collections (.ttc)
- JBIG2/JPEG2000 passthrough only | No certificate encryption | JavaScript actions ignored

<!-- AI-CONTEXT-END -->

## Loading and Saving

```typescript
import { PDF } from '@libpdf/core';

const pdf = await PDF.load(bytes);                              // Uint8Array, ArrayBuffer, Buffer
const pdf = await PDF.load(bytes, { credentials: 'password' }); // encrypted
const pdf = PDF.create();                                       // new document

const output = await pdf.save();                               // returns Uint8Array
const output = await pdf.save({ incremental: true });          // preserves signatures
```

## Form Filling

```typescript
const form = await pdf.getForm();

// Fill multiple fields at once (preferred)
form.fill({
  name: 'Jane Doe',
  email: 'jane@example.com',
  agreed: true,        // checkbox
  gender: 'female',   // radio group
  country: 'United States', // dropdown
});

// Or access individual fields
form.getTextField('name').setText('Jane Doe');
form.getCheckBox('agree').check();
form.getRadioGroup('gender').select('female');
form.getDropdown('country').select('United States');

form.flatten(); // bake fields into page content (non-editable)
const output = await pdf.save();
```

## Digital Signatures

```typescript
import { PDF, P12Signer } from '@libpdf/core';

const signer = await P12Signer.create(p12Bytes, 'certificate-password');
const pdf = await PDF.load(bytes);

const { bytes: signed } = await pdf.sign({
  signer,
  reason: 'I approve this document',
  location: 'New York, NY',
  contactInfo: 'jane@example.com',
  appearance: { page: 0, rect: { x: 50, y: 50, width: 200, height: 50 } }, // visible
});
```

**PAdES Levels** (add options progressively):

| Level | Options |
|-------|---------|
| B-B (Basic, default) | `{ signer }` |
| B-T (Timestamp) | `+ timestampServer: 'http://timestamp.digicert.com'` |
| B-LT (Long-Term) | `+ embedRevocationInfo: true` |
| B-LTA (Archival) | `+ archiveTimestamp: true` |

## Page Manipulation

```typescript
const pages = await pdf.getPages();
const { width, height } = pages[0]; // e.g., 612×792 for US Letter

const page = pdf.addPage({ size: 'letter' }); // 'a4', 'legal', or { width, height }
pdf.insertPage(0, page);
pdf.removePage(0);
```

## Drawing on Pages

```typescript
import { rgb, StandardFonts, degrees } from '@libpdf/core';

const page = pdf.addPage({ size: 'letter' });
const font = await pdf.embedFont(StandardFonts.Helvetica);

page.drawText('Hello, World!', { x: 50, y: 700, size: 24, font, color: rgb(0, 0, 0) });
page.drawRectangle({ x: 50, y: 600, width: 200, height: 100, color: rgb(0.9, 0.9, 0.9), borderColor: rgb(0, 0, 0), borderWidth: 1 });
page.drawLine({ start: { x: 50, y: 500 }, end: { x: 250, y: 500 }, thickness: 2, color: rgb(0, 0, 0) });
page.drawCircle({ x: 150, y: 400, size: 50, color: rgb(0.8, 0.8, 1), borderColor: rgb(0, 0, 0.5), borderWidth: 1 });

const image = await pdf.embedPng(imageBytes); // or embedJpg
page.drawImage(image, { x: 50, y: 650, width: 100, height: 50 });
```

## Merge and Split

```typescript
const merged = await PDF.merge([pdf1Bytes, pdf2Bytes, pdf3Bytes]);

// Extract pages into new doc
const newPdf = PDF.create();
const [page1, page2] = await newPdf.copyPagesFrom(pdf, [0, 1]);
newPdf.addPage(page1);
newPdf.addPage(page2);
```

## Text Extraction

```typescript
for (const page of pdf.getPages()) {
  const { text } = page.extractText();
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
    printing: 'highResolution', modifying: false, copying: true,
    annotating: true, fillingForms: true, contentAccessibility: true, documentAssembly: false,
  },
});
```

## Attachments

```typescript
await pdf.attach(fileBytes, 'data.csv', { mimeType: 'text/csv', description: 'Exported data' });

const attachments = await pdf.getAttachments();
for (const a of attachments) {
  await writeFile(a.name, await a.getData());
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

### Fill and Sign

```typescript
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
async function addWatermark(pdfBytes: Uint8Array, text: string): Promise<Uint8Array> {
  const pdf = await PDF.load(pdfBytes);
  const font = await pdf.embedFont(StandardFonts.HelveticaBold);
  for (const page of pdf.getPages()) {
    const { width, height } = page;
    page.drawText(text, {
      x: width / 2 - 100, y: height / 2, size: 50, font,
      color: rgb(0.8, 0.8, 0.8), rotate: degrees(45), opacity: 0.3,
    });
  }
  return pdf.save();
}
```

## Related

- `overview.md` — PDF tools selection guide
- `tools/browser/playwright.md` — PDF rendering/screenshots
- `tools/code-review/code-standards.md` — TypeScript best practices
