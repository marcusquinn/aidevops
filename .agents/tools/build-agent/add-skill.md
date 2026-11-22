---
description: Import and convert external skills to aidevops format
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Add Skill - External Skill Import System

Ingest skills from external sources (GitHub repos, ClawdHub registry) and transpose them to aidevops format while preserving all knowledge and handling conflicts.

## Quick Reference

| Command | Purpose |
|---------|---------|
| `/add-skill <url>` | Import from GitHub or ClawdHub |
| `/add-skill clawdhub:<slug>` | Import from ClawdHub registry |
| `/add-skill list` | List imported skills |
| `/add-skill check-updates` | Check for upstream changes |
| `/add-skill remove <name>` | Remove imported skill |

**Helpers:** `add-skill-helper.sh` (main import), `clawdhub-helper.sh` (ClawdHub browser fetcher)

## Architecture

```text
External Skill → Detect Source → Fetch & Detect Format → Check Conflicts → Transpose → Place in .agents/ → Register in skill-sources.json
```

- **GitHub:** `git clone --depth 1` | **ClawdHub:** Playwright browser extraction (SPA)
- Ingested skills live in `.agents/` — same naming, discovery, and progressive disclosure as native agents. No symlinks to runtime skill directories.

## Transposition Rules

`-skill` suffix is a provenance marker enabling `skill-update-helper.sh` to detect upstream changes. Structure flattened to `{name}-skill.md` + `{name}-skill/` convention.

**Entry point:** Upstream `SKILL.md` → `{name}-skill.md`

**Flatten nested dirs** with prefix-based naming:

| Upstream path | Transposed path |
|---------------|-----------------|
| `SKILL.md` | `{name}-skill.md` |
| `references/SCHEMA.md` | `{name}-skill/schema.md` |
| `references/CHEATSHEET/01-schema.md` | `{name}-skill/cheatsheet-schema.md` |
| `rules/authentication.md` | `{name}-skill/rules-authentication.md` |

Max depth: 2 levels.

## Supported Input Formats

| Format | Source | Transposition |
|--------|--------|---------------|
| `SKILL.md` | OpenSkills/Claude Code | Preserve frontmatter, add `mode: subagent` + `imported_from: external`. Rename → `{name}-skill.md`. Flatten nested dirs. |
| `AGENTS.md` | aidevops/Windsurf | Direct copy, ensure `mode: subagent`. |
| `.cursorrules` | Cursor | Wrap in Markdown with generated frontmatter (`description`, `mode: subagent`, `imported_from: cursorrules`). |
| Raw Markdown | README.md, etc. | Copy as-is, add frontmatter if missing. Rename → `{name}-skill.md`. |

## Content Review

After the security scan, review each staged file before promotion into agent discovery. Use “Staging and Promotion” below: the helper installs and registers files before returning, so waiting until setup does not isolate unreviewed content. This is an agent review, not a helper/scanner change; `--skip-security` bypasses only the security scan.

Check:

1. **Vendor and affiliate bias:** default routing to one paid tool; “use whenever connected” or “cheapest/only option” claims; referral links/codes; pricing/credit claims and inconsistent cost figures. Check README, licence and author links for ownership of promoted tools.
2. **Unsupported claims:** ranking/performance claims without primary sources, survey opinion presented as confirmed fact, correlation presented as causation, or invented thresholds.
3. **Policy violations:** tactics contrary to the platform’s published guidelines, such as review gating; verify against those guidelines.
4. **Conflicts:** name each conflicting aidevops file and keep our guidance unless the import supplies primary evidence supporting a change.
5. **Staleness:** deprecated features, APIs or roles; verify current primary documentation before retaining them.

Assign one verdict per file:

| Verdict | Action |
|---------|--------|
| **ADOPT** | Retain as-is when the checks pass and the content adds value. |
| **ADAPT** | Keep only vetted material; correct or remove problematic guidance before use. |
| **SKIP** | Omit redundant, irrelevant or obsolete material with no useful addition. |
| **REJECT** | Exclude content whose misleading or policy-violating guidance cannot be safely retained. |

When checks 1–3 find problems, prefer extracting vetted workflows into native agents over wholesale import. Do not activate SKIP/REJECT files. Record per-file verdicts, reasons, evidence, conflicting paths and adaptations in the import’s existing `skill-sources.json` `notes` field.

### Staging and Promotion

1. Create a fresh task-owned staging directory under the approved temporary workspace, outside `.agents/`, `~/.aidevops/agents/` and all runtime skill discovery directories. Verify its parent and set `staging_dir` to its absolute path. Keep the intended destination root separate. For an existing import, copy only its current target, companion resource directory and registry entry into staging, preserving relative layout and rewriting the staged entry’s `local_path` to the staged target; this preserves conflict handling without touching the live copy.
2. Run the helper with `AIDEVOPS_AGENTS_DIR="$staging_dir"`. Its converted targets, companion resources and `configs/skill-sources.json` must all remain in staging. Do not load, execute, link or generate runtime skills from staged content. A helper success or security-scan pass is not content approval.
3. Review every imported file, including companion resources. For **SKIP/REJECT**, remove the staged target and its companion resource directory and delete the staged registry entry. `AIDEVOPS_AGENTS_DIR="$staging_dir" ~/.aidevops/agents/scripts/add-skill-helper.sh remove <name>` removes all three for a whole-skill rejection; verify the registered path is inside staging first. For a rejected individual resource in an otherwise accepted skill, remove that resource and record its verdict in the retained entry’s `notes`. Keep whole-skill rejection evidence in the task record, not a live import entry. Leave any previously installed version unchanged.
4. For **ADAPT/ADOPT**, finalize vetted content and resources and update the staged entry’s `notes` with per-file verdicts, evidence and adaptations. Re-read all retained files and validate registry JSON before promotion. If review is incomplete or fails, stop with the import isolated; do not promote it.
5. Promote only accepted targets and resources to the intended agents root, using the chosen conflict strategy and preserving existing content before replacement. Merge only accepted registry entries into that root’s `configs/skill-sources.json`, rewriting `local_path` to each final absolute target path and retaining reviewed `notes` and upstream tracking fields. Do not overwrite the destination registry with the staging registry or copy the entire staging tree. Verify final paths, content, resources and notes, and confirm no SKIP/REJECT or unreviewed material entered discovery before setup or use. Clean up only task-owned staging artifacts.

## Conflict Resolution

| Option | When | Action |
|--------|------|--------|
| **Merge** | Existing has custom additions | Keep frontmatter, append "## Imported Content", note in skill-sources.json |
| **Replace** | Existing outdated | Backup to `.agents/.backup/`, replace, note in skill-sources.json |
| **Separate** | Both valuable | Prompt for new name, create independently |
| **Skip** | Existing preferred | Cancel import |

## Category Detection

Helper analyzes content for placement. Earlier matches take precedence.

| Keywords | Category |
|----------|----------|
| deploy, vercel, coolify, docker, kubernetes | `tools/deployment/` |
| cloudflare (workers/pages/wrangler/dns/hosting) | `services/hosting/` |
| proxmox, hypervisor, virtualization | `services/hosting/` |
| calendar, caldav, ical, scheduling | `tools/productivity/` |
| clean architecture, hexagonal, ddd, cqrs, event sourcing, feature-sliced | `tools/architecture/` |
| postgresql, drizzle, prisma, typeorm, sequelize, knex | `services/database/` |
| mermaid, flowchart, sequence/ER diagram, UML | `tools/diagrams/` |
| javascript, typescript, ecmascript | `tools/programming/` |
| browser, playwright, puppeteer | `tools/browser/` |
| seo, search ranking, keyword research | `seo/` |
| git, github, gitlab | `tools/git/` |
| code review, lint, quality | `tools/code-review/` |
| credential, secret, password | `tools/credentials/` |

Default: `tools/{skill-name}/`

## Update Tracking

**skill-sources.json** stores per-skill: `name`, `upstream_url`, `upstream_commit`, `local_path`, `format_detected`, `imported_at`, `last_checked`, `merge_strategy` (`added|merged|replaced`), `notes`. Schema version: `1.0.0`.

```bash
add-skill-helper.sh check-updates
# UPDATE AVAILABLE: cloudflare — Current: abc123d  Latest: def456g
#   Run: add-skill-helper.sh add dmmulroy/cloudflare-skill --force
```

## Why Not Symlinks

Runtime skill directories (`~/.claude/skills/`, etc.) are silos — no cross-referencing, no prefix naming, no progressive disclosure. Symlinks create divergent discovery paths. `generate-skills.sh` produces compatible output for SKILL.md-only runtimes — `.agents/` remains source of truth.

## Popular Skills

**GitHub:** `dmmulroy/cloudflare-skill` (60+ CF products), `anthropics/skills/pdf`, `vercel-labs/agent-skills`, `remotion-dev/skills`, `expo/skills`. Browse: [skills.sh](https://skills.sh)

**ClawdHub:** `clawdhub:caldav-calendar` (CalDAV sync), `clawdhub:proxmox-full` (Proxmox VE). Browse: [clawdhub.com](https://clawdhub.com)

## Troubleshooting

| Error | Fix |
|-------|-----|
| "Could not parse source URL" | Use: `owner/repo`, `https://github.com/owner/repo`, `clawdhub:slug`, or `https://clawdhub.com/owner/slug` |
| "Failed to clone repository" | Check internet, verify public, or `gh auth login` for private repos |
| "jq not found" | `brew install jq` / `apt install jq` |
| Conflicts not detected | Helper checks exact path match only. Use `/add-skill list` to review. |

## Related

`scripts/commands/add-skill.md` (slash command) · `scripts/add-skill-helper.sh` (main impl) · `scripts/clawdhub-helper.sh` (ClawdHub fetcher) · `scripts/skill-update-helper.sh` (update checking) · `scripts/generate-skills.sh` (SKILL.md compat) · `build-agent.md` (naming conventions)
