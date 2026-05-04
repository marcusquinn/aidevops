---
description: Manage optional Open Design peripheral integration and local preview workflow
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Open Design Peripheral

Arguments: $ARGUMENTS

## Workflow

Open Design is an optional companion studio, not an aidevops dependency. Keep aidevops `.agents/` and Google `DESIGN.md` canonical.

| Argument | Action |
|----------|--------|
| empty / `help` | Show this command and key examples |
| `status` | `open-design-helper.sh status` |
| `install` | Print safe optional install commands |
| `install --execute` | Clone/update Open Design under the peripheral directory and install deps |
| `start` | Start Open Design with its normal local dev command |
| `start --https-local open-design` | Start via `localdev-helper.sh` for `https://open-design.local` |
| `skills` | Show aidevops ingestion recommendations |
| `route <artifact brief>` | Recommend aidevops-native vs Open Design workflow |

## Examples

```bash
open-design-helper.sh status
open-design-helper.sh install
open-design-helper.sh install --execute
open-design-helper.sh start --https-local open-design
```

## Rules

- Do not symlink Open Design skills into aidevops as a source of truth.
- Ingest selected skills through `tools/build-agent/build-agent.md` and `tools/build-agent/add-skill.md` methodology.
- Convert design systems to Google `DESIGN.md` and lint before reuse.
- Verify generated artifacts with aidevops UI/email/video checks before shipping.

## Related

- `tools/design/open-design.md`
- `tools/design/open-design-ingestion.md`
- `services/hosting/local-hosting.md`
- `workflows/ui-verification.md`
