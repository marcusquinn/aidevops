<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# R2 Patterns & Best Practices

Reference corpus for R2 storage code examples. Content moved into chapter files to keep the entry point short while preserving every example.

## Chapters

- [01-streaming-large-files.md](./r2-patterns/01-streaming-large-files.md) - Stream objects with `writeHttpMetadata` and ETag headers.
- [02-conditional-get.md](./r2-patterns/02-conditional-get.md) - Conditional GET returning 304 Not Modified via `onlyIf.etagDoesNotMatch`.
- [03-upload-with-validation.md](./r2-patterns/03-upload-with-validation.md) - Key sanitisation, content-type metadata, and upload response.
- [04-multipart-with-progress.md](./r2-patterns/04-multipart-with-progress.md) - 5MB-part multipart upload with progress callback and abort on error.
- [05-batch-delete.md](./r2-patterns/05-batch-delete.md) - Paginated prefix delete using `list` cursor loop.
- [06-checksum-validation.md](./r2-patterns/06-checksum-validation.md) - SHA-256 integrity on put and verify on retrieval.
- [07-storage-class-transitions.md](./r2-patterns/07-storage-class-transitions.md) - Storage class change via S3-compatible API (not Workers binding).
- [08-public-bucket-custom-domain.md](./r2-patterns/08-public-bucket-custom-domain.md) - CORS and long-lived cache headers for public bucket serving.

## Related

- [r2.md](./r2.md) - API overview, bindings, and core capabilities.
- [r2-gotchas.md](./r2-gotchas.md) - Common pitfalls and edge cases.

## Preservation Notes

- All original code blocks moved to the chapter files above.
- No examples were removed; this file is now the index for the same material.
