<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Validation

```bash
# Google Rich Results Test (CLI)
curl -s "https://searchconsole.googleapis.com/v1/urlInspection/index:inspect" \
  -H "Authorization: Bearer $GSC_TOKEN" \
  -d '{"inspectionUrl":"https://example.com/cold-brew-guide","siteUrl":"https://example.com/"}'

# Schema.org local validator
npx schema-dts-gen --validate schema.json
```

Or use `seo/schema-validator.md` for local and bulk validation.
