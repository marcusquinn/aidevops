<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# R2 Pattern: Multipart Upload with Progress

```typescript
const PART_SIZE = 5 * 1024 * 1024; // 5MB
const partCount = Math.ceil(file.size / PART_SIZE);
const multipart = await env.MY_BUCKET.createMultipartUpload(key, { httpMetadata: { contentType: file.type } });

const uploadedParts: R2UploadedPart[] = [];
try {
  for (let i = 0; i < partCount; i++) {
    const start = i * PART_SIZE;
    const part = await multipart.uploadPart(i + 1, file.slice(start, start + PART_SIZE));
    uploadedParts.push(part);
    onProgress?.(Math.round(((i + 1) / partCount) * 100));
  }
  return await multipart.complete(uploadedParts);
} catch (error) {
  await multipart.abort();
  throw error;
}
```
