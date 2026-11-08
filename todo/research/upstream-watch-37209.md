<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Upstream batch review 37209

Reviewed the revisions named in issue #37209, not an unbounded future tip.

| Source | Decision |
|--------|----------|
| `tddworks/asc-cli` v0.18.1..v0.18.9 | Document the Apache-2.0 license and recent feature areas. Retain installed-version checks and approval for account mutations. |
| `tddworks/asc-cli-skills` 6465c10..debe0d2 | Product experiments and first-time product submission guidance are already covered in the native guide; do not import skills automatically. |
| `rudrankriyam/app-store-connect-cli-skills` bd37209..266d7ad | Release, signing, analytics and catalog guidance has evolved for a separate community CLI, including 5.x changes. Do not apply its commands to tddworks' CLI or automatically import the skills. |
| `EvanBacon/serve-sim` fd545ed..0490304 | Document current reload, diagnostic, recording and exec security behavior; Node requirement remains >=20 at the reviewed revision. |
| `cloudron-base-image` 5.0.0..6.0.1 | Already adopted and digest-pinned in the native guide and packaging skill; Docker Hub confirms the 6.0.1 digest. Do not infer that every older deployment has migrated. |
| `cloudron-official-skills` fcea396..e8dfc1f | Adopt the backup/restore execution distinction and remove obsolete builder instructions. Existing reviewed image policy remains stricter than upstream; do not automatically permit new Python image pins. |
| `cloudron-packaging-community` 047e4b0..a07cbb4 | Current guide already covers the assessment changes and later formatting-only revision; the tip removes an outdated local reference, with no additional scoring change to adopt. |

Cloudron base and builder guidance is version-dependent; confirm the installed CLI and package requirements before operational changes. The serve-sim review is source-based, not a simulator runtime test.
