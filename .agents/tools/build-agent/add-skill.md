---
description: Import and convert external skills to aidevops format
mode: subagent
---

# Add Skill - External Skill Import System

Ingest skills from external sources (GitHub repos, ClawdHub registry) and transpose them to aidevops format while preserving all knowledge and handling conflicts intelligently.

## Quick Reference

| Command | Purpose |
|---------|---------|
| `/add-skill <url>` | Import skill from GitHub or ClawdHub |
| `/add-skill clawdhub:<slug>` | Import skill from ClawdHub registry |
| `/add-skill list` | List imported skills |
| `/add-skill check-updates` | Check for upstream changes |
| `/add-skill remove <name>` | Remove imported skill |

**Helper scripts:**
- `~/.aidevops/agents/scripts/add-skill-helper.sh` — Main import logic
- `~/.aidevops/agents/scripts/clawdhub-helper.sh` — ClawdHub browser-based fetcher

## Architecture

```text
External Skill (GitHub or ClawdHub)
        ↓
    Detect Source (GitHub URL / clawdhub: prefix / clawdhub.com URL)
        ↓
    Fetch & Detect Format
    ├── GitHub: git clone --depth 1
    └── ClawdHub: Playwright browser extraction (SPA)
        ↓
    Check Conflicts → Present Merge Options (if conflicts)
        ↓
    Transpose to aidevops Format → Place in .agents/ → Register in skill-sources.json
```

Ingested skills live in `.agents/` alongside all other knowledge — same naming, same discovery, same progressive disclosure. No symlinks to external runtime skill directories. The `.agents/` convention replaces the isolated `SKILL.md`-per-directory pattern used by other runtimes.

## Transposition Rules

Ingested skills retain the `-skill` suffix as a provenance marker — this enables `skill-update-helper.sh` to identify and check all ingested skills for upstream changes. The internal structure is flattened to match our `{name}.md` + `{name}/` convention.

**Entry point:** Upstream `SKILL.md` → `{name}-skill.md`

**Flatten nested directories** using prefix-based naming:

| Upstream path | Transposed path |
|---------------|-----------------|
| `SKILL.md` | `{name}-skill.md` |
| `references/SCHEMA.md` | `{name}-skill/schema.md` |
| `references/CHEATSHEET/01-schema.md` | `{name}-skill/cheatsheet-schema.md` |
| `rules/authentication.md` | `{name}-skill/rules-authentication.md` |

**Example (postgres-drizzle skill):**

```text
# Upstream                          # Transposed (aidevops format)
SKILL.md                            postgres-drizzle-skill.md
references/                         postgres-drizzle-skill/
├── SCHEMA.md                       ├── schema.md
├── QUERIES.md                      ├── queries.md
├── MIGRATIONS.md                   ├── migrations.md
├── CHEATSHEET/                     ├── cheatsheet.md
│   ├── 01-schema.md                ├── cheatsheet-schema.md
│   └── 02-relations.md             └── cheatsheet-relations.md
rules/authentication.md             rules-authentication.md
```

Max depth: 2 levels from parent directory. `-skill` suffix enables automated upstream update detection.

## Supported Input Formats

| Format | Source | Transposition |
|--------|--------|---------------|
| `SKILL.md` | OpenSkills/Claude Code | Preserve frontmatter, add `mode: subagent` + `imported_from: external`. Rename `SKILL.md` → `{name}-skill.md`. Flatten nested dirs. |
| `AGENTS.md` | aidevops/Windsurf | Direct copy, ensure `mode: subagent` is set. |
| `.cursorrules` | Cursor | Wrap in Markdown with generated frontmatter (`description`, `mode: subagent`, `imported_from: cursorrules`). |
| Raw Markdown | README.md, etc. | Copy as-is, add frontmatter if missing. Rename to `{name}-skill.md`. |

## Conflict Resolution

When importing a skill that conflicts with existing files, choose one of:

| Option | When to use | Action |
|--------|-------------|--------|
| **Merge** | Existing has custom additions; new skill adds complementary functionality | Keep existing frontmatter, append "## Imported Content" section, note in skill-sources.json |
| **Replace** | Existing is outdated or imported is more comprehensive | Backup existing to `.agents/.backup/`, replace, note in skill-sources.json |
| **Separate** | Both versions are valuable or serve different use cases | Prompt for new name, create independently |
| **Skip** | Existing is preferred or need to review first | Cancel import |

## Category Detection

The helper script analyzes skill content to determine placement. Patterns are ordered from specific to generic — earlier matches take precedence.

| Keywords | Category |
|----------|----------|
| deploy, vercel, coolify, docker, kubernetes | `tools/deployment/` |
| cloudflare workers, cloudflare pages, wrangler | `services/hosting/` |
| cloudflare, dns, hosting, domain | `services/hosting/` |
| proxmox, hypervisor, virtualization | `services/hosting/` |
| calendar, caldav, ical, scheduling | `tools/productivity/` |
| clean architecture, hexagonal, ddd, domain-driven, cqrs, event sourcing | `tools/architecture/` |
| feature-sliced, fsd architecture, slice organization | `tools/architecture/` |
| postgresql, postgres, drizzle, prisma, typeorm, sequelize, knex | `services/database/` |
| mermaid, flowchart, sequence diagram, ER diagram, UML | `tools/diagrams/` |
| javascript, typescript, es6, es2020–es2024, ecmascript | `tools/programming/` |
| browser, playwright, puppeteer | `tools/browser/` |
| seo, search ranking, keyword research | `seo/` |
| git, github, gitlab | `tools/git/` |
| code review, lint, quality | `tools/code-review/` |
| credential, secret, password | `tools/credentials/` |

Default: `tools/{skill-name}/`

## Update Tracking

### skill-sources.json Schema

```json
{
  "version": "1.0.0",
  "skills": [
    {
      "name": "cloudflare",
      "upstream_url": "https://github.com/dmmulroy/cloudflare-skill",
      "upstream_commit": "abc123def456...",
      "local_path": ".agents/services/hosting/cloudflare.md",
      "format_detected": "skill-md",
      "imported_at": "2026-01-21T00:00:00Z",
      "last_checked": "2026-01-21T00:00:00Z",
      "merge_strategy": "added|merged|replaced",
      "notes": "Optional notes about the import"
    }
  ]
}
```

### Update Detection

```bash
~/.aidevops/agents/scripts/add-skill-helper.sh check-updates
# UPDATE AVAILABLE: cloudflare
#   Current: abc123d  Latest: def456g
#   Run: add-skill-helper.sh add dmmulroy/cloudflare-skill --force
# Up to date: vercel-deploy
```

## Why Not Symlinks to Runtime Skill Directories

Other runtimes (Claude Code, Codex, Amp) have their own skill directories (`~/.claude/skills/`, etc.) using a `SKILL.md`-per-directory convention. Symlinks are no longer the approach because:

- **Isolated discovery**: Each runtime's skill directory is a silo — skills can't cross-reference each other or link to tools/services/workflows.
- **No naming convention**: One `SKILL.md` per directory — doesn't scale, can't sort/group/search by prefix.
- **Duplicate paths**: Symlinks create a parallel discovery path that diverges from `.agents/`.
- **No progressive disclosure**: `SKILL.md` is all-or-nothing; our `{name}-skill.md` + `{name}-skill/` loads the entry point first, extended knowledge on demand.

For runtimes that only support their own skill directories, `generate-skills.sh` can produce compatible output as a build step — but `.agents/` is the source of truth.

## Popular Skills to Import

### GitHub

| Skill | Repository | Description |
|-------|------------|-------------|
| Cloudflare | `dmmulroy/cloudflare-skill` | 60+ Cloudflare products |
| PDF | `anthropics/skills/pdf` | PDF manipulation toolkit |
| Vercel Deploy | `vercel-labs/agent-skills` | Instant Vercel deployments |
| Remotion | `remotion-dev/skills` | Video creation in React |
| Expo | `expo/skills` | React Native development |

Browse more at [skills.sh](https://skills.sh) leaderboard.

### ClawdHub

| Skill | Slug | Description |
|-------|------|-------------|
| CalDAV Calendar | `clawdhub:caldav-calendar` | CalDAV sync via vdirsyncer + khal |
| Proxmox Full | `clawdhub:proxmox-full` | Complete Proxmox VE management |

Browse more at [clawdhub.com](https://clawdhub.com) — vector search for agent skills.

## Troubleshooting

| Error | Fix |
|-------|-----|
| "Could not parse source URL" | Use: `owner/repo`, `owner/repo/subpath`, `https://github.com/owner/repo`, `clawdhub:slug`, or `https://clawdhub.com/owner/slug` |
| "Failed to clone repository" | Check internet, verify repo is public, or run `gh auth login` for private repos |
| "jq not found" | `brew install jq` (macOS) / `apt install jq` (Ubuntu/Debian) |
| Conflicts not detected | Helper checks exact path and directory match only — not semantic duplicates. Use `/add-skill list` to review. |

## Related

- `scripts/commands/add-skill.md` - Slash command definition
- `scripts/add-skill-helper.sh` - Main implementation
- `scripts/clawdhub-helper.sh` - ClawdHub browser-based fetcher
- `scripts/skill-update-helper.sh` - Automated update checking
- `scripts/generate-skills.sh` - Compatibility output for runtimes that only support SKILL.md directories
- `build-agent.md` - Agent design patterns (see "Folder Organization" for naming conventions)
