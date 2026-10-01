---
name: images
description: "Cloudflare images: product reference"
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare Images

Choose the image source and operation before selecting an API. Hosted-image management, remote URL transformations, and the Workers optimization binding have different contracts. Retrieve the documentation for the path the project uses.

| Task | Start here |
|------|------------|
| Optimize image bytes in a Worker or manage hosted images | [API selection](images.md) |
| Configure a binding, variants, or private delivery | [Configuration](images.md) |
| Accept client uploads, serve responsive images, watermark, or store results in R2 | [Patterns](images-patterns.md) |
| Diagnose failures, check limits, or investigate caching | [Troubleshooting](images-gotchas.md) |

For new work, inspect the project's installed Wrangler version, compatibility settings, existing image storage, and public/private access requirements. Read only the relevant linked pages and adapt them to the project; preserve existing conventions and verify behavior with representative images.
