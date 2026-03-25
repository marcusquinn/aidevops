---
name: build-agent
description: Agent design and composition - creating efficient, token-optimized AI agents
mode: subagent
---

# Build-Agent - Composing Efficient AI Agents

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Design, create, and improve AI agents for the aidevops framework
- **Pattern**: Main agents at root, subagents in folders
- **Budget**: ~50-100 instructions per agent (research-backed limit)

**Instruction Limits**: ~150-200 frontier models can follow; ~50 consumed by AI assistant system prompt; **your budget: ~50-100 max**.

**Token Efficiency**: Root AGENTS.md <150 lines, universally applicable only. Subagents: progressive disclosure. MCP servers: disabled globally, enabled per-agent. Code refs: use search patterns not `file:line`.

**Agent Hierarchy**: Main agents orchestrate and call subagents. Subagents execute focused tasks with minimal context.

**Subagents** (in this folder):

| Subagent | When to Read |
|----------|--------------|
| `agent-review.md` | Reviewing and improving existing agents |
| `agent-testing.md` | Testing agent behavior with isolated AI sessions |

**Related**: `@code-standards` for linting agent markdown, `aidevops/architecture.md` for framework structure.

**Testing**:

```bash
agent-test-helper.sh run my-tests   # Automated test suite
claude -p "Test query"              # Quick manual test
opencode run "Test query" --agent Build+
```

**After creating or promoting agents**: regenerate the subagent index:

```bash
~/.aidevops/agents/scripts/subagent-index-helper.sh generate
```

**Model tier in frontmatter**: use evidence, not just rules. Check pattern data with `/route "task description"` or `/patterns recommend "type"` before setting `model:`.

<!-- AI-CONTEXT-END -->

## Detailed Guidance

### Why This Matters

LLMs are stateless functions. AGENTS.md is the only file that goes into every conversation — the highest leverage point.

Research: frontier thinking models follow ~150-200 instructions consistently; quality degrades uniformly as count increases; AI assistant system prompts consume ~50 instructions. **Every instruction must be universally applicable to ALL tasks.**

### Main Agent vs Subagent Design

**Main agents** (root of `.agents/`): broad domain orchestration, coordinates subagents, maintains project-level context. Examples: `seo.md`, `build-plus.md`, `marketing.md`.

**Subagents** (inside domain folders or `tools/`, `services/`, `workflows/`): focused execution, minimal context, specific tools, can run in parallel. Examples: `tools/git/github-cli.md`, `services/hosting/hostinger.md`.

#### Subagent YAML Frontmatter (Required)

Every subagent **must** include YAML frontmatter. Without it, agents default to read-only mode.

```yaml
---
description: Brief description of agent purpose
mode: subagent
tools:
  read: true      # Read file contents
  write: false    # Create new files
  edit: false     # Modify existing files
  bash: false     # Execute shell commands
  glob: true      # Find files by pattern
  grep: true      # Search file contents
  webfetch: false # Fetch web content
  task: true      # Spawn subagents
---
```

| Tool | Risk Level |
|------|------------|
| `read`, `glob`, `grep`, `webfetch` | Low |
| `task`, `edit`, `write` | Medium |
| `bash` | High |

**MCP tool patterns**:

```yaml
tools:
  context7_*: true
  augment-context-engine_*: true
  wordpress-mcp_*: true
```

**CRITICAL: MCP Placement Rule** — Enable MCPs in **subagents only**, never in main agents. Main agents reference subagents for MCP functionality.

**MCP requirements** (documents intent for future `includeTools` support):

```yaml
---
mcp_requirements:
  chrome-devtools:
    tools: [navigate_page, take_screenshot]
  snyk:
    tools: [snyk_sca_scan]
---
```

**Main-branch write restrictions**: Subagents with `write: true`/`edit: true` invoked via Task tool must respect branch protection. On `main`/`master`: allowed: `README.md`, `TODO.md`, `todo/PLANS.md`, `todo/tasks/*`; blocked: all other files. State this explicitly in any subagent with `write: true`.

**Note on permissions**: Path-based restrictions are configured in `opencode.json`, not frontmatter.

#### Agent Directory Architecture

| Directory | Purpose |
|-----------|---------|
| `.agents/` | Source of truth, deployed to `~/.aidevops/agents/` by `setup.sh` |
| `.opencode/agent/` | Generated stubs for OpenCode |

#### Decision Framework

```text
Is this a broad domain or strategic concern?
  YES → Main Agent at root
  NO  ↓
Can this run independently without other domain knowledge?
  YES → Subagent in appropriate folder
  NO  ↓
Does this coordinate multiple tools/services?
  YES → Consider main agent or call existing subagents
  NO  → Subagent, or add to existing agent
```

**Calling other agents**: prefer calling existing agents over duplicating. Reference `@git-platforms` for Git operations, `@code-standards` for quality — don't copy their content.

### MCP Configuration Pattern

**Global disabled, per-agent enabled** in `opencode.json`:

```json
{
  "mcp": { "hostinger-api": { "enabled": false } },
  "agent": {
    "hostinger": { "tools": { "hostinger-api_*": true } }
  }
}
```

### Code References: Search Patterns over Line Numbers

Line numbers drift. Use search patterns:

```markdown
# Bad: .agents/scripts/hostinger-helper.sh:145
# Good: Search for `handle_api_error` in hostinger-helper.sh
```

### Model Tier Selection: Evidence-Based Routing

Static rules (`haiku` → formatting, `sonnet` → code, `opus` → architecture) are starting points. Pattern data overrides when >75% success rate, 3+ samples.

```bash
/route "write unit tests for a bash helper script"
/patterns recommend "code review"
```

| Situation | Action |
|-----------|--------|
| Pattern data: >75% success, 3+ samples | Use model from pattern data |
| Pattern data: sparse | Fall back to routing rules |
| No pattern data | Use routing rules, record outcomes |

Document evidence in frontmatter:

```yaml
model: sonnet  # pattern data: 87% success rate from 14 samples for shell-script tasks
```

Full docs: `tools/context/model-routing.md`, `scripts/commands/route.md`.

### Quality Checking: Linters First

**Never send an LLM to do a linter's job.**

1. **Deterministic linters** (fast, cheap): ShellCheck, ESLint, Ruff/Pylint — run first, automatically
2. **Static analysis** (comprehensive): SonarCloud, Codacy, Snyk, Secretlint — after linters pass
3. **LLM review** (expensive, slow): CodeRabbit — for architectural concerns only

Consider `bun`/`bunx` over `npm`/`npx` for performance. For Node.js helper scripts using globally installed packages, set `NODE_PATH` — see `tools/build-agent/node-helpers.md:13`.

### Information Quality

1. **Primary sources preferred**: official docs, API specs, first-hand data
2. **Cross-reference claims**: verify across multiple sources, note disagreements
3. **Bias awareness**: vendor docs promote their product; note commercial vs independent sources
4. **Fact-checking**: test commands before documenting, verify URLs, check version numbers

| Domain | Primary Sources | Watch For |
|--------|-----------------|-----------|
| Code/DevOps | Official docs, RFCs, source code | Outdated tutorials, version drift |
| SEO | Search Console data, Domain Rank, Search Volume | Vendor claims, outdated tactics |
| Legal | Legislation, case law, official guidance | Jurisdiction differences, dated info |
| Marketing | Platform official docs, first-party data | Vendor case studies, inflated metrics |
| Content | Style guides, readability, Plain English, first-person | Subjective preferences as rules |

### Agent Design Checklist

Before adding content to any agent file:

1. Does this subagent have YAML frontmatter?
2. Is this universally applicable (>80% of tasks)?
3. Could this be a pointer instead? (content exists elsewhere?)
4. Is this a code example? (authoritative? will it drift?)
5. What's the instruction count impact? (combine related, remove redundant)
6. Does this duplicate other agents? (`rg "pattern" .agents/` before adding)
7. Should another agent be called instead?
8. Are sources verified? (primary sources, cross-referenced, biases acknowledged)
9. Does the markdown pass linting? (MD025, MD022, MD031, MD012 — run `npx markdownlint-cli2 "path/to/file.md"`)

### Progressive Disclosure Pattern

```markdown
# Good: Pointers in AGENTS.md, details in subagents
## Subagent Index
- `tools/code-review/` - Quality standards, testing, linting
- `aidevops/architecture.md` - Schema and API patterns

Read subagents only when task requires them.
```

### Code Examples: When to Use

**Include when**: authoritative reference (no implementation elsewhere), security-critical template (must be followed exactly), command syntax reference (the example IS the documentation).

**Avoid when**: code exists in codebase (use search pattern reference), external library patterns (use Context7 MCP), will become outdated (point to maintained source).

### Self-Assessment Protocol

**Triggers**: observable failure (command syntax fails, paths don't exist, auth patterns broken), user correction, contradiction detection (Context7 differs from agent, codebase patterns differ), staleness indicators.

**Process**:
1. Complete current task first
2. Identify root cause (which instruction caused the issue?)
3. Duplicate/conflict check: `rg "pattern" .agents/`
4. Propose improvement with rationale and list of files needing coordinated updates
5. Request permission: "Agent Feedback: While [task], I noticed [issue] in `.agents/[file].md`. Suggested improvement: [change]. Should I update these?"

### Tool Selection Checklist

| Task | Preferred | Avoid |
|------|-----------|-------|
| Find files by pattern | `git ls-files` or `fd` | `mcp_glob` |
| Search file contents | `rg` (ripgrep) | `mcp_grep` |
| Read file contents | `mcp_read` | `cat` via bash |
| Edit files | `mcp_edit` | `sed` via bash |
| Web content | `mcp_webfetch` | `curl` via bash |
| Remote repo research | `mcp_webfetch` README first | `npx repomix --remote` |
| Parallel AI dispatch | OpenCode server API | Multiple TUI instances |

Before any MCP tool: "Is there a faster CLI alternative?" Before context-heavy operations: "Could this return >50K tokens?" See `tools/context/context-guardrails.md`.

### Agent File Structure Convention

**Main agents** (no frontmatter required):

```markdown
# Agent Name - Brief Purpose

<!-- AI-CONTEXT-START -->
## Quick Reference
[Condensed, universally-applicable content]
<!-- AI-CONTEXT-END -->

## Detailed Documentation
[Verbose content, examples, edge cases — read when needed]
```

**Subagents** (YAML frontmatter required):

```markdown
---
description: Brief description
mode: subagent
tools:
  read: true
  ...
---

# Subagent Name - Brief Purpose
[Content...]
```

**Avoid in agents**: hardcoded counts that change, specific version numbers unless critical, dates that will become stale.

### Folder Organization

```text
.agents/
├── AGENTS.md                 # Entry point
├── {domain}.md               # Main agents at root
├── {domain}/                 # Subagents for that domain
├── tools/                    # Cross-domain utilities
├── services/                 # External integrations
├── workflows/                # Process guides
└── scripts/
    └── commands/             # Slash command definitions
```

### Slash Command Placement

**CRITICAL**: Never define slash commands inline in main agents.

| Command Type | Location |
|--------------|----------|
| Generic (cross-domain) | `scripts/commands/{command}.md` |
| Domain-specific | `{domain}/{subagent}.md` |

Main agents only reference commands — never contain implementation.

**Naming conventions**: main agents lowercase with hyphens at root (`build-mcp.md`); subagents lowercase with hyphens in folders (`build-mcp/deployment.md`); special files ALLCAPS (`AGENTS.md`).

### Agent Lifecycle Tiers

| Tier | Location | Survives `setup.sh` | Git Tracked | Purpose |
|------|----------|---------------------|-------------|---------|
| **Draft** | `~/.aidevops/agents/draft/` | Yes | No | R&D, experimental |
| **Custom** | `~/.aidevops/agents/custom/` | Yes | No | User's permanent private agents |
| **Sourced** | `~/.aidevops/agents/custom/<source>/` | Yes | In private repo | Synced from private Git repos |
| **Shared** | `.agents/` in repo | Yes (deployed) | Yes | Open-source, submitted via PR |

When creating an agent, ask the user which tier: Draft (experimental), Custom (private), Sourced (private repo), or Shared (PR to `.agents/`).

**Draft agents**: created during R&D or orchestration. Place in `~/.aidevops/agents/draft/` with `status: draft` and `created` date in frontmatter. After proving useful, log a TODO for review and promote to Custom or Shared.

**Orchestration agents creating drafts**: when a subtask requires reusable domain-specific instructions, create a draft agent, log a TODO item, and reference the draft in subsequent Task tool calls.

**Shared agents**: follow the Agent Design Checklist, submit via PR to aidevops repository.

### Deployment Sync

Agent changes in `.agents/` require `setup.sh` to deploy:

```bash
cd ~/Git/aidevops && ./setup.sh
```

Offer to run when: creating new agents, renaming/moving agents, merging/deleting agents, modifying content users need immediately.

### Cache-Aware Prompt Patterns

**Stable Prefix Pattern**: keep beginning of prompts stable across calls — AGENTS.md and subagent content are cached; user messages are not. Never reorder instructions between calls (causes cache miss).

**Instruction Ordering — Primacy Effect**: order by importance — critical rules first, frequent operations middle, edge cases and reference last.

**Avoid Dynamic Prefixes**: don't put variable content (timestamps, version numbers) at the start of agent files.

**AI-CONTEXT Blocks**: put stable, essential content first (always cached); detailed docs after (may be truncated, but prefix cached).

**MCP Tool Definitions**: minimize tool churn — stable tool sets per agent maximize cache hits.

### Reviewing Existing Agents

See `build-agent/agent-review.md` for systematic review sessions covering instruction budgets, universal applicability, duplicates, code examples, AI-CONTEXT blocks, stale content, and MCP configuration.
