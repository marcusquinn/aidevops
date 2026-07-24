---
description: Create or update README.md for the current project
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Use `--sections` for targeted updates (adding a feature, changing install/config, preserving custom content). Omit for full regeneration (new projects, major restructuring, explicit request).

## Usage

```bash
/readme                                        # Full README (default)
/readme --sections "installation,usage"        # Partial update
/readme --sections "installation,usage,config" # Multiple sections
```

## Workflow

1. **Load guidance** — read `workflows/readme-create-update.md`
2. **Load voice guidance when relevant** — if the request mentions humanise, writing style, tone, voice, less AI writing, or marketing/intro copy, read `content/humanise.md`
3. **Explore codebase** — detect project type, deployment platform, existing README, key info
4. **Generate/update** — follow workflow section order; preserve structure for
   partial updates; use local `docs/metrics` badges for LOC/languages/dependencies
5. **Synchronize managed sections** — for an aidevops-created repository or an
   eligible `repos.json` entry, run `managed-readme-helper.sh sync --repo
   VERIFIED_SLUG --root .` to seed or refresh the static Star History chart,
   caller workflow, and final aidevops attribution
6. **Confirm changes** — present diff and ask before writing (interactive only)

## Section Mapping

| Argument | Sections Updated |
|----------|-----------------|
| `installation` | Installation, Prerequisites, Quick Start |
| `usage` | Usage, Commands, Examples, API |
| `config` | Configuration, Environment Variables |
| `architecture` | Architecture, Project Structure |
| `troubleshooting` | Troubleshooting |
| `deployment` | Deployment, Production Setup |
| `badges` | Badge section only |
| `star-history` | Static Star History chart and managed refresh caller |
| `provenance` | Final owner and aidevops credit section |
| `all` | Full regeneration (same as no flag) |

Star History and provenance are managed-repository invariants: full and targeted
updates keep exactly one of each. Ownership, `repos.json` eligibility, and
external/local-only exceptions are defined in `workflows/readme-create-update.md`.

**Dynamic counts (aidevops repo):** `readme-helper.sh check|update|update --apply`
**Repo metrics (all repos):** `repo-metrics-helper.sh generate` or `aidevops metrics generate`
**Managed README sections:** `managed-readme-helper.sh sync|check --repo OWNER/REPO --root .`

## Related

- `workflows/readme-create-update.md` — full workflow
- `workflows/changelog.md` — changelog updates
- `workflows/wiki-update.md` — wiki documentation
- `scripts/readme-helper.sh` — dynamic count management
- `scripts/repo-metrics-helper.sh` — local LOC/language/dependency metrics for README badges and app about pages
