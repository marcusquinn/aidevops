---
name: build-agent
description: Agent design and composition - creating efficient, token-optimized AI agents
mode: subagent
---

# Build-Agent - Composing Efficient AI Agents

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Budget**: ~50-100 instructions per agent; root AGENTS.md universally applicable only
- **Subdivision**: Docs >~300 lines → split into entry point + sub-docs; don't cut to hit a line count
- **MCP servers**: Disabled globally, enabled per-agent
- **Code refs**: `rg "pattern"` search patterns, not `file:line` (line numbers drift)
- **Subagents**: `agent-review.md` (review), `agent-testing.md` (testing)
- **Related**: `@code-standards`, `.agents/aidevops/architecture.md`, `tools/browser/browser-automation.md`
- **After creating/promoting**: `~/.aidevops/agents/scripts/subagent-index-helper.sh generate`
- **Testing**: `agent-test-helper.sh run my-tests` or `claude -p "Test query"`
- **Model tier**: `/route "task"` or `/patterns recommend "type"`. Static: `haiku`→formatting, `sonnet`→code, `opus`→architecture. Pattern data overrides at >75% success, 3+ samples.

<!-- AI-CONTEXT-END -->

## Main Agent vs Subagent

| Aspect | Main Agent | Subagent |
|--------|-----------|----------|
| **Scope** | Broad domain | Specific tool/service/task |
| **Role** | Coordinates, strategic | Focused independent execution |
| **Location** | Root of `.agents/` | `tools/`, `services/`, `workflows/` |
| **MCP tools** | NEVER enable directly | Enable per-agent |

Broad/strategic → main agent. Independent, no cross-domain knowledge → subagent. Prefer calling existing agents over duplicating.

## Subagent YAML Frontmatter (Required)

Without frontmatter, agents default to read-only.

```yaml
---
description: Brief description of agent purpose
mode: subagent
tools:
  read: true      # Low risk
  write: false    # Medium risk - adds files
  edit: false     # Medium risk - changes files
  bash: false     # High risk - arbitrary execution
  glob: true      # Low risk
  grep: true      # Low risk
  webfetch: false # Low risk
  task: true      # Medium risk - delegates work
---
```

- **MCP tool patterns** (subagents only): `context7_*: true`, `wordpress-mcp_*: true`. Path-based → `opencode.json`.
- **MCP tool filtering** (future `includeTools` — 17k→1.5k token savings): `mcp_requirements: { chrome-devtools: { tools: [navigate_page, take_screenshot] } }`
- **Main-branch write restrictions**: ALLOWED: `README.md`, `TODO.md`, `todo/PLANS.md`, `todo/tasks/*`. BLOCKED: all other files.
- **MCP config** (global disabled, per-agent enabled): `"mcp": { "hostinger-api": { "enabled": false } }` + `"agent": { "hostinger": { "tools": { "hostinger-api_*": true } } }`
- **Source of truth**: `.agents/` → deployed to `~/.aidevops/agents/` by `setup.sh`. Stubs: `.opencode/agent/` via `generate-opencode-agents.sh`.
- **Deployment sync**: changes in `.agents/` require `./setup.sh`. Offer to run on create/rename/move/merge/delete.

## Folder Organization

```text
.agents/
├── AGENTS.md           # Entry point (ALLCAPS)
├── {agent}.md          # Main agents at root (lowercase, strategy/what)
├── {agent}/            # Extended knowledge for that agent (flat files)
├── tools/              # Cross-domain capabilities (how to do it)
├── services/           # External integrations (how to connect)
├── workflows/          # Process guides (how to process)
├── reference/          # Operating rules (how to operate)
├── scripts/            # Shared helper scripts (flat, cross-domain)
├── scripts/commands/   # Slash command definitions
├── configs/            # Configuration templates and schemas
├── bundles/            # Project-type presets
├── templates/          # Reusable templates
├── rules/              # Enforced constraints
├── tests/              # Agent test suites
├── custom/             # User's private agents (survives updates)
└── draft/              # R&D experimental (survives updates)
```

### Strategy vs Execution Split

| Location | Contains | Nature |
|----------|----------|--------|
| `{agent}.md` + `{agent}/` | Domain strategy, methodology, audience knowledge | **What** to do |
| `tools/` | Browser, git, database, code review, deployment tools | **How** to do it |
| `services/` | Hosting, payments, communications, email providers | **How** to connect |
| `workflows/` | Git flow, release, PR review, pre-edit checks | **How** to process |

**Placement test:** "Would another agent use this independently?" Yes → `tools/`/`services/`/`workflows/`/`reference/`. No → `{agent}/`.

### The `{name}.md` + `{name}/` Convention

- **Single-file**: `{name}.md` — no directory needed
- **Multi-file**: `{name}.md` (entry point, always loaded) + `{name}/` (extended knowledge, on demand)

Prefer flat files with prefix-based naming (`marketing-sales/meta-ads*.md` groups related files). Max depth: 2 levels from `.agents/`. Subdirectory only when a prefix group exceeds ~20 files.

### Scripts: Flat by Design

Scripts flat in `scripts/` — cross-domain, any agent can call any script. Prefix naming (`email-*`, `seo-*`) for grouping. `*-helper.sh` = agent-callable; other `.sh` = framework infra. `scripts/commands/` = slash commands.

### Ingested Skills

External skills retain `-skill` suffix (provenance marker for `skill-update-helper.sh`). Structure flattened on ingestion: `SKILL.md` → `{name}-skill.md`; `{name}-skill/references/*.md` → `{name}-skill/{topic}.md`; nested `CHEATSHEET/*.md` → `{name}-skill/cheatsheet-{topic}.md`. See `add-skill.md`.

### Naming Conventions

- **Files**: lowercase-hyphens (`kebab-case`). ALLCAPS for entry points only. Python: `snake_case`.
- **Scripts**: `[domain]-[function]-helper.sh` (agent-callable), `[name].sh` (framework infra).
- **Subagent discovery**: `find -mindepth 2` skips root-level main agents.
- **File structure** — main agents: `# Name` → AI-CONTEXT Quick Reference → docs. Subagents: YAML frontmatter + content.
- **Slash commands**: NEVER define inline in main agents. Generic → `scripts/commands/{command}.md`. Domain-specific → `{domain}/{subagent}.md`.

## Model Tier Selection

| Situation | Action |
|-----------|--------|
| >75% success, 3+ samples | Use pattern data (overrides static rule) |
| Insufficient data | Use routing rules, record outcomes |
| Contradicts routing rules | Note conflict in agent docs |

Record: `/remember "SUCCESS/FAILURE: agent with model — reason"`. Frontmatter: `model: sonnet  # 87% success, 14 samples`. Full docs: `tools/context/model-routing.md`.

## Quality Checking

Linter order: (1) deterministic (ShellCheck, ESLint, Ruff/Pylint), (2) static analysis (SonarCloud, Secretlint), (3) LLM review (CodeRabbit — architectural only). Prefer `bun`/`bunx` over `npm`/`npx`. Never send an LLM to do a linter's job.

**Sources:** Prefer official docs, RFCs, source code, first-party data. Watch for outdated tutorials, vendor claims, jurisdiction differences, commercial bias.

## Agent Design Checklist

1. **YAML frontmatter?** All subagents require it
2. **Universally applicable?** >80% of tasks? If not → more specific subagent
3. **Pointer instead?** Use `rg "pattern"` or Context7 MCP if content exists elsewhere
4. **Code example?** Authoritative? Will it drift? Security: placeholders only
5. **Instruction count?** Combine related, remove redundant
6. **Duplicates?** `rg "pattern" .agents/` before adding
7. **Existing agent?** Call and improve vs duplicate?
8. **Sources verified?** Primary, cross-referenced
9. **Markdown linting?** MD025/MD022/MD031/MD012. Run `bunx markdownlint-cli2 "path/to/file.md"`
10. **Terse pass done?** See below

## Post-Creation Terse Pass (MANDATORY)

Every token costs on every load. Compress before committing.

**Compress:** verbose phrasing → direct rule; narrative → keep task ID, drop story; redundant examples → keep one; multi-sentence rule → single sentence.

**Preserve:** task IDs (`tNNN`), issue refs (`GH#NNN`), all rules/constraints, file paths, command examples, code blocks, safety-critical detail.

Target: reference cards, not tutorials. Evidence: 63% byte reduction on `build.txt` with zero rule loss. See `tools/code-review/code-simplifier.md` "Prose tightening".

## Code Examples: When to Include

**Include:** authoritative with no implementation elsewhere; security-critical template; command syntax IS the doc. **Avoid:** exists in codebase (use search pattern); external library (Context7 MCP); will drift (point to source).

## Self-Assessment Protocol

**Triggers**: Observable failure, user correction, contradiction with Context7/codebase, staleness.

**Process**: (1) Complete current task. (2) Identify root cause. (3) `rg "pattern" .agents/` — list ALL files needing coordinated updates. (4) Propose fix with evidence, ask user to confirm before applying.

## Tool Selection

| Task | Preferred | Avoid |
|------|-----------|-------|
| Find files | `git ls-files` / `fd` | `mcp_glob` |
| Search contents | `rg` | `mcp_grep` |
| Read/Edit files | `mcp_read` / `mcp_edit` | `cat`/`sed` via bash |
| Web content | `mcp_webfetch` | `curl` via bash |
| Remote repo | `mcp_webfetch` README first | `npx repomix --remote` |
| Parallel AI dispatch | OpenCode server API | Multiple TUI instances |

Self-checks: "Faster CLI alternative?" and "Could this return >50K tokens?" See `tools/context/context-guardrails.md`.

## Agent Lifecycle Tiers

| Tier | Location | Survives `setup.sh` | Git Tracked | Purpose |
|------|----------|---------------------|-------------|---------|
| **Draft** | `~/.aidevops/agents/draft/` | Yes | No | R&D, experimental |
| **Custom** | `~/.aidevops/agents/custom/` | Yes | No | User's private agents |
| **Sourced** | `~/.aidevops/agents/custom/<source>/` | Yes | In private repo | Synced from private Git repos |
| **Shared** | `.agents/` in repo | Yes (deployed) | Yes | Open-source, submitted via PR |

Ask user which tier: Draft (experimental), Custom (private), Sourced (private Git repo), or Shared (PR to `.agents/`). Draft: `status: draft` + `created` date, promote via PR or discard. Custom: never shared/overwritten. Shared: feature branch + PR, no proprietary info. Orchestration agents: draft reusable patterns, log TODO, reference in Task calls.

## Cache-Aware Prompt Patterns

Stable prefix (variable content at end), critical rules first (primacy effect), AI-CONTEXT blocks for essential stable content, minimize MCP tool churn between sessions.

## Reviewing Existing Agents

See `agent-review.md` for systematic review (instruction budgets, universal applicability, duplicates, code examples, AI-CONTEXT blocks, stale content, MCP configuration).
