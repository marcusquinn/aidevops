<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Troubleshooting & Best Practices

Reference index for Cloudflare + Pulumi troubleshooting. Detailed sections moved into chapter files so the entry doc stays short and scannable.

## Chapters

| Topic | Covers |
|-------|--------|
| [common-errors](./pulumi-gotchas/common-errors.md) | Frequent Pulumi + Cloudflare failures, causes, and fixes |
| [debugging](./pulumi-gotchas/debugging.md) | Verbose logging and state inspection commands |
| [best-practices](./pulumi-gotchas/best-practices.md) | Stack config, production protection, dependency ordering |
| [security](./pulumi-gotchas/security.md) | Secret handling, token scopes, state protection |
| [performance](./pulumi-gotchas/performance.md) | State-size and refresh guidance |
| [migration](./pulumi-gotchas/migration.md) | Importing existing resources and moving from Wrangler/Terraform |
| [ci-cd](./pulumi-gotchas/ci-cd.md) | Automation patterns for GitHub Actions and GitLab CI |
| [resources](./pulumi-gotchas/resources.md) | Primary docs and registry links |

## Related

- For multi-account providers, resource naming, and environment patterns, see [pulumi-patterns.md](./pulumi-patterns.md).
