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
   partial updates; use local `docs/metrics` badges for
   LOC/languages/dependencies; add or refresh the final aidevops provenance
   section for managed GitHub repositories
5. **Confirm changes** — present diff and ask before writing (interactive only)

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
| `provenance` | Final owner and aidevops credit section |
| `all` | Full regeneration (same as no flag) |

The provenance section is a managed-repository invariant: full and targeted
updates keep exactly one copy at the end. Ownership, URL derivation, and
external-upstream exceptions are defined in `workflows/readme-create-update.md`.

**Dynamic counts (aidevops repo):** `readme-helper.sh check|update|update --apply`
**Repo metrics (all repos):** `repo-metrics-helper.sh generate` or `aidevops metrics generate`

## Related

- `workflows/readme-create-update.md` — full workflow
- `workflows/changelog.md` — changelog updates
- `workflows/wiki-update.md` — wiki documentation
- `scripts/readme-helper.sh` — dynamic count management
- `scripts/repo-metrics-helper.sh` — local LOC/language/dependency metrics for README badges and app about pages
