---
description: Vercel Agent Skills - community skill packages for AI coding agents
mode: subagent
tools:
  read: true
  bash: true
---

# Vercel Agent Skills

Use this doc for community [Agent Skills](https://agentskills.io/) from `vercel-labs/agent-skills`. For full Vercel CLI workflows, use `vercel.md`.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Repo**: [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills)
- **Format**: [Agent Skills](https://agentskills.io/) (SKILL.md standard)
- **Install**: `npx skills add vercel-labs/agent-skills`
- **Registry**: [skills.sh](https://skills.sh/vercel-labs/agent-skills)
- **Related**: `vercel.md` (CLI deployment), `add-skill.md` (import system)

<!-- AI-CONTEXT-END -->

## Available Skills

| Skill | Use when | Notes |
|-------|----------|-------|
| `vercel-deploy-claimable` | "Deploy my app", "Push this live" | Primary skill; instant deploy without auth |
| `react-best-practices` | Writing/reviewing React or Next.js code | 40+ rules across 8 categories |
| `web-design-guidelines` | "Review my UI", "Check accessibility" | 100+ rules across 11 areas |
| `react-native-guidelines` | Building React Native or Expo apps | 16 rules across 7 sections |
| `composition-patterns` | Refactoring components with boolean props | Compound component patterns |

## Primary Skill: `vercel-deploy-claimable`

Deploys without Vercel auth by returning a live preview URL plus a claim URL.

1. Packages the project as a tarball (excluding `node_modules`, `.git`)
2. Detects the framework from `package.json` when present
3. Uploads to deployment service
4. Returns preview URL (live site) + claim URL (transfer ownership)

Framework detection covers 40+ frameworks, including Next.js, Remix, Astro, Vite, SvelteKit, Nuxt, Angular, Gatsby, Hono, Express, NestJS, Fastify, and Storybook. Static HTML projects without `package.json` also work.

## When to Use What

| Need | Use |
|------|-----|
| Full Vercel CLI (teams, env vars, domains) | `vercel.md` |
| Quick deploy without auth | `vercel-deploy-claimable` |
| Import any community skill | `/add-skill <source>` |
| Create aidevops-compatible SKILL.md | `scripts/generate-skills.sh` |

## SKILL.md Layout

Each skill directory contains:

```text
skill-name/
  SKILL.md       # Instructions for the agent (required)
  scripts/       # Helper scripts for automation (optional)
  references/    # Supporting documentation (optional)
```

Minimal frontmatter:

```yaml
---
name: skill-name
description: One sentence describing when to use this skill
metadata:
  author: author-name
  version: "1.0.0"
---
```

The body should cover how the skill works, usage examples, expected output, and troubleshooting.

## Install

```bash
npx skills add vercel-labs/agent-skills          # Native CLI
aidevops skill add vercel-labs/agent-skills       # aidevops (preferred)
/add-skill vercel-labs/agent-skills --name vercel-deploy  # With custom name
```

Installed skills are auto-detected. Relevant requests trigger them automatically (for example, "deploy my app" → `vercel-deploy`).

## aidevops Import Flow

`add-skill-helper.sh` imports Agent Skills by:

1. Clones the repo (`git clone --depth 1`)
2. Detects SKILL.md format, converts frontmatter to aidevops style
3. Places in `.agents/tools/deployment/` (or category-appropriate directory)
4. Registers in `.agents/configs/skill-sources.json` for update tracking
5. `setup.sh` creates symlinks to all AI assistant skill directories

Imported skills get a `-skill` suffix (for example `vercel-deploy-skill.md`) to distinguish them from native subagents. See `tools/build-agent/add-skill.md`.
