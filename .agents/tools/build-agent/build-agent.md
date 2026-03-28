---
name: build-agent
description: Agent design and composition - creating efficient, token-optimized AI agents
mode: subagent
---

# Build-Agent - Composing Efficient AI Agents

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Budget**: ~50-100 instructions per agent; root AGENTS.md <150 lines, universally applicable only
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

- MCP tool patterns (subagents only): `context7_*: true`, `wordpress-mcp_*: true`. Path-based permissions → `opencode.json`.
- MCP tool filtering (future `includeTools` — 17k→1.5k token savings): `mcp_requirements: { chrome-devtools: { tools: [navigate_page, take_screenshot] } }`
- **Main-branch write restrictions** (`write/edit: true` on `main`/`master`): ALLOWED: `README.md`, `TODO.md`, `todo/PLANS.md`, `todo/tasks/*`. BLOCKED: all other files.
- **MCP config** (global disabled, per-agent enabled in `opencode.json`): `"mcp": { "hostinger-api": { "enabled": false } }` + `"agent": { "hostinger": { "tools": { "hostinger-api_*": true } } }`

## Architecture & References

- **Source of truth**: `.agents/` → deployed to `~/.aidevops/agents/` by `setup.sh`. Stubs: `.opencode/agent/` via `generate-opencode-agents.sh`.
- **Code refs**: search patterns, not line numbers. Hierarchy: function name → unique string → comment marker → broader pattern.
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

Main agent directories contain **strategy** knowledge — what needs doing and why. Cross-domain directories contain **execution** knowledge — how to do it with specific tools and services.

| Location | Contains | Nature |
|----------|----------|--------|
| `{agent}.md` + `{agent}/` | Domain strategy, methodology, audience knowledge | **What** to do |
| `tools/` | Browser, git, database, code review, deployment tools | **How** to do it |
| `services/` | Hosting, payments, communications, email providers | **How** to connect |
| `workflows/` | Git flow, release, PR review, pre-edit checks | **How** to process |

**Placement test:** "Would another agent use this independently without going through the owning agent?" Yes → `tools/`, `services/`, or `workflows/` (and `reference/` for operating rules). No → `{agent}/`.

### The `{name}.md` + `{name}/` Convention

Every agent or knowledge area follows the same pattern:

- **Single-file agent**: `{name}.md` at the appropriate level. No directory needed.
- **Multi-file agent**: `{name}.md` (entry point, always loaded) + `{name}/` (extended knowledge, loaded on demand).

The `.md` file is the entry point — it contains the agent persona, capabilities overview, and pointers to extended knowledge. The directory contains deeper reference material that's only loaded when a specific sub-topic is needed.

```text
# Single-file agent (fits in one file)
sales.md

# Multi-file agent (needs extended knowledge)
marketing-sales.md                        # Entry point — strategy, capabilities
marketing-sales/                          # Extended knowledge — loaded on demand
├── meta-ads.md                           # Meta Ads strategy and methodology
├── meta-ads-audiences.md                 # Audience targeting reference
├── meta-ads-campaigns.md                 # Campaign structure reference
├── direct-response-copy.md               # DR copy methodology
├── direct-response-copy-swipe-emails.md  # Email swipe file
├── cro.md                                # Conversion rate optimization
└── ad-creative.md                        # Ad creative methodology
```

### Flat Files with Descriptive Names (Prefer Over Nesting)

Inside agent directories, prefer flat files with prefix-based naming over nested subdirectories. File names provide sorting, grouping, hierarchy, and keyword discoverability.

```text
# Good: flat, discoverable, sortable
marketing-sales/
├── meta-ads.md
├── meta-ads-audiences.md
├── meta-ads-campaigns.md
├── meta-ads-creative.md
├── meta-ads-optimization.md
├── direct-response-copy.md
├── direct-response-copy-swipe-emails.md
└── direct-response-copy-templates.md

# Avoid: nested folders that hide content
marketing-sales/
├── meta-ads/
│   ├── audiences/
│   │   └── targeting.md
│   └── campaigns/
│       └── structure.md
└── direct-response-copy/
    └── swipe-file/
        └── emails/
            └── welcome.md
```

**Benefits of flat naming:**
- `ls marketing-sales/` shows everything at a glance
- `ls marketing-sales/meta-ads*` groups all Meta Ads knowledge
- `ls marketing-sales/*swipe*` finds all swipe files across sub-topics
- `rg --files -g "marketing-sales/meta-ads*"` loads all Meta Ads context
- Max depth is 2 levels from `.agents/` — never 5+

**When to use a subdirectory:** Only when a single prefix group exceeds ~20 files of reference material. Even then, one level max.

### Scripts: Flat by Design

Scripts live flat in `scripts/` because they're cross-domain — any agent can call any script. The prefix naming convention (`email-*`, `seo-*`, `browser-*`) provides grouping via filesystem sort and glob patterns.

- `*-helper.sh` = agent-callable utilities (agents run these)
- Other `.sh` = framework infrastructure (setup, deployment, CI)
- `scripts/commands/` = slash command documentation

Discovery: `ls scripts/email-*`, `rg --files -g "scripts/seo-*"`.

### Ingested Skills

Skills imported from external sources (GitHub, ClawdHub) retain the `-skill` suffix as a provenance marker. This enables `skill-update-helper.sh` to identify and check all ingested skills for upstream changes.

**Transposition on ingestion:** External skill structure is flattened to match our convention:

| Upstream format | aidevops format |
|-----------------|-----------------|
| `SKILL.md` (entry point) | `{name}-skill.md` (named entry point) |
| `{name}-skill/references/*.md` | `{name}-skill/{topic}.md` (flat) |
| `{name}-skill/rules/*.md` | `{name}-skill/rules-{topic}.md` (flat) |
| Nested `references/CHEATSHEET/*.md` | `{name}-skill/cheatsheet-{topic}.md` (flat) |

The `-skill` suffix distinguishes ingested knowledge from native agents. See `add-skill.md` for full ingestion workflow.

### Naming Conventions

- **Files**: lowercase with hyphens (`kebab-case`). ALLCAPS only for entry points (`AGENTS.md`).
- **Scripts**: `[domain]-[function]-helper.sh` for agent-callable, plain `[name].sh` for framework infra.
- **Python scripts**: `snake_case` (Python convention) — exception to kebab-case rule.
- **Subagent discovery**: Tooling uses `find -mindepth 2` to discover subagents (skips root-level main agents).
- **File structure** — main agents: `# Name` → `<!-- AI-CONTEXT-START -->` Quick Reference `<!-- AI-CONTEXT-END -->` → Detailed docs. Subagents: YAML frontmatter + content.
- **Slash commands**: NEVER define inline in main agents. Generic → `scripts/commands/{command}.md`. Domain-specific → `{domain}/{subagent}.md`.

## Model Tier Selection

| Situation | Action |
|-----------|--------|
| >75% success, 3+ samples | Use pattern data (overrides static rule) |
| Sparse/inconclusive | Fall back to routing rules |
| Contradicts routing rules | Note conflict in agent docs |
| No data yet | Use routing rules, record outcomes |

Record: `/remember "SUCCESS/FAILURE: agent with model — reason"`. Frontmatter: `model: sonnet  # 87% success, 14 samples`. Full docs: `tools/context/model-routing.md`.

## Quality Checking

Linter order: (1) deterministic (ShellCheck, ESLint, Ruff/Pylint), (2) static analysis (SonarCloud, Secretlint), (3) LLM review (CodeRabbit — architectural only). Prefer `bun`/`bunx` over `npm`/`npx`. Never send an LLM to do a linter's job.

**Information sources**: Prefer official docs, RFCs, source code, first-party data. Watch for outdated tutorials, vendor claims, jurisdiction differences, and commercial bias across all domains.

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

Every token in an agent doc is paid for on every load. Compress before committing.

**Compress:** verbose phrasing → direct rule; narrative context → keep task ID, drop story; redundant examples → keep one; multi-sentence explanations of one rule → single sentence.

**Preserve (never compress):** task IDs (`tNNN`), issue refs (`GH#NNN`), all rules/constraints, file paths, command examples, code blocks, safety-critical detail.

Target: reference cards, not tutorials. Evidence: terse pass on `build.txt` achieved 63% byte reduction with zero rule loss. See `tools/code-review/code-simplifier.md` "Prose tightening".

## Code Examples: When to Include

**Include**: authoritative reference with no implementation elsewhere; security-critical template; command syntax IS the documentation.

**Avoid**: code exists in codebase (use search pattern); external library (use Context7 MCP); will become outdated (point to source).

When a code example fails: update if outdated, add conditions if context-dependent, check for duplicates.

## Self-Assessment Protocol

**Triggers**: Observable failure, user correction, contradiction with Context7/codebase, staleness.

**Process**: (1) Complete current task. (2) Identify root cause. (3) `rg "pattern" .agents/` — list ALL files needing coordinated updates. (4) Propose: `"Agent Feedback: While [task], I noticed [issue] in .agents/[file].md. Related: [other-files]. Suggested: [change]. Update after completing?"`

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

**When creating an agent, ask the user:**

```text
1. Draft  - Experimental (draft/)
2. Custom - Private, stays on your machine (custom/)
3. Sourced - In a private Git repo (custom/<source>/)
4. Shared - Add to aidevops for everyone (PR to .agents/)
```

- **Draft**: `~/.aidevops/agents/draft/` with `status: draft` + `created` date. Promotion: log TODO → promote to `custom/` or `.agents/` via PR, or discard.
- **Custom**: Never shared, never overwritten (`custom/mycompany/`, `custom/clients/`).
- **Shared**: Feature branch + PR. No proprietary info.
- **Orchestration agents**: Create drafts for reusable patterns. Log TODO, reference draft in Task calls, note in completion summary.

## Cache-Aware Prompt Patterns

- **Stable prefix**: Variable content at end; dynamic content at start breaks cache
- **Instruction ordering**: Critical rules → frequent operations → edge cases (primacy effect)
- **AI-CONTEXT blocks**: Essential stable content first, detailed docs after
- **MCP tool definitions**: Minimize tool churn — changing tools between sessions causes cache misses

## Reviewing Existing Agents

See `agent-review.md` for systematic review (instruction budgets, universal applicability, duplicates, code examples, AI-CONTEXT blocks, stale content, MCP configuration).
