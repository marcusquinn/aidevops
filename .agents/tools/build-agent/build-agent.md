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

**Instruction Limits**:
- ~150-200: frontier models can follow
- ~50: consumed by AI assistant system prompt
- **Your budget**: ~50-100 instructions max

**Token Efficiency**:
- Root AGENTS.md: <150 lines, universally applicable only
- Subagents: Progressive disclosure (read when needed)
- MCP servers: Disabled globally, enabled per-agent
- Code refs: Use search patterns (`rg "pattern"`) not `file:line`

**Agent Hierarchy**:
- **Main Agents**: Orchestration, call subagents when needed
- **Subagents**: Focused execution, minimal context, specific tools

**Subagents** (in this folder):

| Subagent | When to Read |
|----------|--------------|
| `agent-review.md` | Reviewing and improving existing agents |
| `agent-testing.md` | Testing agent behavior with isolated AI sessions |

**Related Agents**:
- `@code-standards` for linting agent markdown
- `aidevops/architecture.md` for framework structure
- `tools/browser/browser-automation.md` for agents needing browser capabilities (tool hierarchy: Playwright → Playwriter → Stagehand → DevTools)

**Git Workflow**:
- Branch strategy: `workflows/branch.md`
- Git operations: `tools/git.md`

**Testing**: Use `agent-test-helper.sh` for automated testing, or CLI for quick manual tests:

```bash
# Automated test suite
agent-test-helper.sh run my-tests

# Quick manual test
claude -p "Test query"
opencode run "Test query" --agent Build+
```

See `agent-testing.md` for the full testing framework.

**After creating or promoting agents**: Regenerate the subagent index:

```bash
~/.aidevops/agents/scripts/subagent-index-helper.sh generate
```

**Model tier in frontmatter**: Use evidence, not just rules. Before setting `model:`, check pattern data:

```bash
/route "task description"    # rules + pattern history combined
/patterns recommend "type"   # data-driven tier recommendation
```

Static rules (`haiku` → formatting, `sonnet` → code, `opus` → architecture) are starting points. Pattern data overrides when >75% success rate with 3+ samples. See "Model Tier Selection" section below.

<!-- AI-CONTEXT-END -->

## Detailed Guidance

### Why This Matters

LLMs are stateless — AGENTS.md is the only file in every conversation, making it the highest-leverage point. Research shows instruction-following degrades uniformly as count increases, and the system may ignore AGENTS.md content deemed irrelevant. Every instruction must be universally applicable.

### Main Agent vs Subagent Design

| Aspect | Main Agent | Subagent |
|--------|-----------|----------|
| **Scope** | Broad domain (wordpress, seo, content) | Specific tool, service, or task type |
| **Role** | Coordinates subagents, strategic decisions | Focused independent execution |
| **Context** | Multi-concern awareness | Minimal, task-specific only |
| **Location** | Root of `.agents/` | Inside `tools/`, `services/`, `workflows/`, or domain folders |
| **Examples** | `seo.md`, `build-plus.md` | `tools/git/github-cli.md`, `services/hosting/hostinger.md` |
| **MCP tools** | NEVER enable directly | Enable per-agent (reduces context) |
| **Parallelism** | Can run alongside other main agents | Can run in parallel without conflicts |

**Decision flow**: Broad domain or strategic? → Main agent at root. Independent without cross-domain knowledge? → Subagent. Coordinates multiple tools/services? → Consider main agent or call existing subagents.

**Prefer calling existing agents over duplicating**: Reference `@git-platforms` for Git operations rather than inlining 50 lines of git instructions.

### Subagent YAML Frontmatter (Required)

Every subagent **must** include YAML frontmatter defining tool permissions. Without it, agents default to read-only, causing confusion when they recommend actions they cannot perform.

**Template** (copy and adjust `true`/`false` per agent):

```yaml
---
description: Brief description of agent purpose
mode: subagent
tools:
  read: true      # Low risk - passive observation
  write: false    # Medium risk - adds files
  edit: false     # Medium risk - changes files
  bash: false     # High risk - arbitrary execution
  glob: true      # Low risk - discovery only
  grep: true      # Low risk - discovery only
  webfetch: false # Low risk - read-only external
  task: true      # Medium risk - delegates work
---
```

**MCP tool patterns** (subagents only — NEVER in main agents):

```yaml
tools:
  context7_*: true              # Context7 documentation tools
  wordpress-mcp_*: true         # WordPress MCP tools
```

Main agents reference subagents for MCP functionality. This ensures MCPs only load when the specific subagent is invoked.

**MCP requirements with tool filtering** (documents intent for future `includeTools` support — see [OpenCode #7399](https://github.com/anomalyco/opencode/issues/7399)):

```yaml
---
description: Preview and screenshot local dev servers
mcp_requirements:
  chrome-devtools:
    tools: [navigate_page, take_screenshot, new_page, list_pages]
  snyk:
    tools: [snyk_sca_scan]
---
```

This prepares agents for future filtering, documents intent for reviewers, and enables token savings (e.g., 17k → 1.5k tokens for chrome-devtools). Prior art: [Amp's lazy-load MCP with skills](https://ampcode.com/news/lazy-load-mcp-with-skills).

**Path-based permissions** (e.g., restricting which files can be edited) are configured in `opencode.json`, not in markdown frontmatter.

**Main-branch write restrictions**: Subagents with `write: true` / `edit: true` invoked via Task tool on `main`/`master`:

- **ALLOWED**: `README.md`, `TODO.md`, `todo/PLANS.md`, `todo/tasks/*`
- **BLOCKED**: All other files
- **WORKTREE**: Unrestricted writes to worktree paths

Subagents cannot run `pre-edit-check.sh` (many lack `bash: true`), so add a "Write Restrictions" section to any writable subagent.

### MCP Configuration Pattern

Global disabled, per-agent enabled in `opencode.json`:

```json
{
  "mcp": {
    "hostinger-api": { "enabled": false },
    "hetzner-*": { "enabled": false }
  },
  "agent": {
    "hostinger": { "tools": { "hostinger-api_*": true } },
    "hetzner": { "tools": { "hetzner-*": true } }
  }
}
```

This reduces context window usage, prevents tool confusion, and enables focused parallel execution.

### Agent Directory Architecture

| Directory | Purpose |
|-----------|---------|
| `.agents/` | Source of truth — deployed to `~/.aidevops/agents/` by `setup.sh` |
| `.opencode/agent/` | Generated stubs for OpenCode (created by `generate-opencode-agents.sh`) |

Flow: `.agents/` → `setup.sh` deploys → `generate-opencode-agents.sh` creates stubs → OpenCode reads stubs pointing to full content.

### Code References: Search Patterns over Line Numbers

Line numbers drift. Use search patterns:

```markdown
# Bad (drifts)
See `.agents/scripts/hostinger-helper.sh:145`

# Good (stable)
Search for `handle_api_error` in hostinger-helper.sh

# Better (with fallback)
Search for `handle_api_error` in hostinger-helper.sh.
If not found, search for `api_error` or `error handling` patterns.
```

**Hierarchy**: Function/variable name → unique string literals → comment markers → broader pattern.

### Model Tier Selection: Evidence-Based Routing

Static rules are starting points; pattern data overrides when evidence is strong (>75% success, 3+ samples).

```bash
/patterns suggest "shell script agent"   # data-driven suggestion
/patterns recommend "code review"        # tier recommendation
/route "write unit tests for bash"       # rules + pattern history
```

| Situation | Action |
|-----------|--------|
| Pattern data: >75% success, 3+ samples | Use pattern data (overrides static rule) |
| Sparse or inconclusive | Fall back to routing rules |
| Contradicts routing rules | Note conflict, explain in agent docs |
| No data yet | Use routing rules, record outcomes |

**Record outcomes** via memory:

```bash
/remember "SUCCESS: shell script agent with sonnet — prompt-repeat pattern resolved ambiguous instructions"
/remember "FAILURE: architecture design with sonnet — needed opus, missed cross-service dependency trade-offs"
```

**In frontmatter**, document evidence: `model: sonnet  # pattern data: 87% success from 14 samples`.

Static rules are guesses; pattern data is empirical evidence from your actual workload. Full docs: `tools/context/model-routing.md`, `memory/README.md` "Pattern Tracking", `scripts/commands/route.md`.

### Quality Checking: Linters First

**Never send an LLM to do a linter's job.** Preference order:

1. **Deterministic linters** (fast, cheap, consistent): ShellCheck, ESLint, Ruff/Pylint
2. **Static analysis** (comprehensive): SonarCloud, Codacy, Secretlint
3. **LLM review** (expensive, variable): CodeRabbit — use for architectural concerns only

**Performance**: Prefer `bun`/`bunx` over `npm`/`npx` where compatible.

**Node.js helpers**: If using `node -e` with global packages, set `NODE_PATH` near script top. See `tools/build-agent/node-helpers.md:13`.

### Information Quality

Agent instructions must be accurate:

- **Primary sources preferred**: Official docs over blog posts, API specs over tutorials
- **Cross-reference claims**: Verify across sources, note disagreements, prefer recent
- **Bias awareness**: Consider vendor agendas, note commercial vs independent
- **Fact-check**: Test commands, verify URLs, confirm version numbers

| Domain | Primary Sources | Watch For |
|--------|-----------------|-----------|
| **Code/DevOps** | Official docs, RFCs, source code | Outdated tutorials, version drift |
| **SEO** | Webmaster tools, Search Console, Domain Rank | SEO vendor claims, outdated tactics |
| **Legal** | Legislation, case law, official guidance | Jurisdiction differences, dated info |
| **Health** | Peer-reviewed research, official health bodies | Commercial claims, fads |
| **Marketing** | Platform docs, first-party data | Vendor case studies, inflated metrics |
| **Accounting** | Tax authority guidance, accounting standards | Jurisdiction-specific rules |
| **Content** | Style guides, brand guidelines, Plain English | Subjective preferences as rules, lack of citations |

### Agent Design Checklist

Before adding content to any agent file:

1. **YAML frontmatter?** All subagents require tool permission declarations
2. **Universally applicable?** Relevant to >80% of tasks? If not → more specific subagent
3. **Pointer instead?** Content exists elsewhere? Use `rg "pattern"` reference or Context7 MCP
4. **Code example?** Is it authoritative? Will it drift? Security patterns: placeholders, note storage
5. **Instruction count?** Each bullet/rule/directive counts — combine related, remove redundant
6. **Duplicates?** `rg "pattern" .agents/` before adding — single source of truth
7. **Existing agent?** Would calling and improving it be more efficient than duplicating?
8. **Sources verified?** Primary sources, cross-referenced, biases acknowledged?
9. **Markdown linting?** Single H1 (MD025), blank lines around headings (MD022) and code blocks (MD031), no consecutive blanks (MD012). Run `npx markdownlint-cli2 "path/to/file.md"`

### Progressive Disclosure Pattern

```markdown
# Bad: Everything in AGENTS.md
## Database Schema Guidelines
[50 lines of schema rules...]

# Good: Pointers in AGENTS.md, details in subagents
## Subagent Index
- `tools/code-review/` - Quality standards, testing, linting
- `aidevops/architecture.md` - Schema and API patterns

Read subagents only when task requires them.
```

### Code Examples: When to Include

**Include when**: (1) authoritative reference with no implementation elsewhere, (2) security-critical template that must be followed exactly, (3) command syntax IS the documentation.

**Avoid when**: (1) code exists in codebase — use search pattern reference, (2) external library — use Context7 MCP for current docs, (3) will become outdated — point to maintained source.

**Testing**: When a code example fails during use, trigger self-assessment — update if outdated, add conditions if context-dependent, fix and check for duplicates if wrong.

### Self-Assessment Protocol

**Triggers**: Observable failure (API changed, paths don't exist), user correction, contradiction with Context7/codebase, staleness (version mismatch, deprecated APIs).

**Process**:

1. **Complete current task first** — never abandon user's goal
2. **Identify root cause**: Which instruction? Single-point or systemic?
3. **Duplicate check** (CRITICAL): `rg "pattern" .agents/` — list ALL files needing coordinated updates
4. **Propose improvement** with rationale, flag conflicts
5. **Request permission**:

```text
> Agent Feedback: While [task], I noticed [issue] in
> `.agents/[file].md`. Related instructions also exist in
> `[other-files]`. Suggested improvement: [change].
> Should I update these after completing your request?
```

Review this protocol itself when false positives/negatives occur or user feedback indicates it's too aggressive/passive.

### Tool Selection Checklist

| Task | Preferred | Avoid | Why |
|------|-----------|-------|-----|
| Find files | `git ls-files` / `fd` | `mcp_glob` | CLI 10x faster |
| Search contents | `rg` (ripgrep) | `mcp_grep` | More powerful |
| Read files | `mcp_read` | `cat` via bash | Better error handling |
| Edit files | `mcp_edit` | `sed` via bash | Safer, atomic |
| Web content | `mcp_webfetch` | `curl` via bash | Handles redirects |
| Remote repo | `mcp_webfetch` README first | `npx repomix --remote` | Prevents context overload |
| Interactive CLIs | Bash directly | N/A | Full PTY |
| Parallel AI dispatch | OpenCode server API | Multiple TUI instances | Headless, programmatic |

**Self-checks**: "Is there a faster CLI alternative?" and "Could this return >50K tokens?" See `tools/context/context-guardrails.md`.

### Agent File Structure Convention

**Main agents** (no frontmatter):

```markdown
# Agent Name - Brief Purpose

<!-- AI-CONTEXT-START -->
## Quick Reference
[Condensed, universally-applicable content]
<!-- AI-CONTEXT-END -->

## Detailed Documentation
[Verbose content, examples, edge cases — read when needed]
```

**Subagents**: YAML frontmatter (see "Subagent YAML Frontmatter" section) + content.

**Avoid**: Hardcoded counts that change, specific version numbers unless critical, dates that go stale.

### Folder Organization

```text
.agents/
├── AGENTS.md                 # Entry point (ALLCAPS - special root file)
├── {domain}.md               # Main agents at root (lowercase)
├── {domain}/                 # Subagents for that domain
│   └── {subagent}.md         # Specialized guidance (lowercase)
├── tools/                    # Cross-domain utilities
├── services/                 # External integrations
├── workflows/                # Process guides
└── scripts/
    └── commands/             # Slash command definitions
```

**Naming**: Main agents lowercase with hyphens (`build-mcp.md`). ALLCAPS only for entry points (`AGENTS.md`). Pattern: `{domain}.md` + `{domain}/` folder. Main agents at root (not inside folders) — tooling uses `find -mindepth 2` for subagent discovery.

### Slash Command Placement

**CRITICAL**: Never define slash commands inline in main agents.

| Command Type | Location | Example |
|--------------|----------|---------|
| Generic (cross-domain) | `scripts/commands/{command}.md` | `/save-todo`, `/remember` |
| Domain-specific | `{domain}/{subagent}.md` | `/keyword-research` in `seo/keyword-research.md` |

Main agents only **reference** commands — they list available commands but never contain the implementation. This keeps main agents under budget, enables reuse, and allows targeted loading.

### Agent Lifecycle Tiers

| Tier | Location | Survives `setup.sh` | Git Tracked | Purpose |
|------|----------|---------------------|-------------|---------|
| **Draft** | `~/.aidevops/agents/draft/` | Yes | No | R&D, experimental, auto-created by orchestration |
| **Custom** | `~/.aidevops/agents/custom/` | Yes | No | User's permanent private agents |
| **Sourced** | `~/.aidevops/agents/custom/<source>/` | Yes | In private repo | Agents synced from private Git repos |
| **Shared** | `.agents/` in repo | Yes (deployed) | Yes | Open-source, submitted via PR |

**When creating an agent, ask the user:**

```text
Where should this agent live?
1. Draft  - Experimental, for review later (draft/)
2. Custom - Private, stays on your machine (custom/)
3. Sourced - In a private Git repo, synced via agent-sources (custom/<source>/)
4. Shared - Add to aidevops for everyone (PR to .agents/)
```

#### Draft Agents

Created during R&D, orchestration, or exploratory work. Intentionally rough.

**When to create**: Orchestration needs reusable subagent, exploring new domain, Task tool prompt being duplicated across invocations.

**Conventions**: Place in `~/.aidevops/agents/draft/`, include `status: draft` and `created` date, use `draft/{domain}-{purpose}.md`.

```yaml
---
description: Experimental agent for X
mode: subagent
status: draft
created: 2026-02-07
tools:
  read: true
  bash: false
  glob: true
  grep: true
---
```

**Promotion**: Log a TODO (`- [ ] tXXX Review draft agent: {name} #agent-review`), then: promote to `custom/`, promote to `.agents/` via PR, or discard.

#### Custom (Private) Agents

User's permanent private agents — never shared, never overwritten by `setup.sh`. Use for business-specific workflows, personal preferences, client-specific agents, proprietary knowledge. Follow same structure as shared agents. Organize with subdirectories if needed: `custom/mycompany/`, `custom/clients/`.

#### Shared Agents

Live in `.agents/`, distributed via `setup.sh`. Share when the agent solves a general problem, follows conventions, and contains no proprietary info. Submit via feature branch + PR.

#### Orchestration Agents Creating Drafts

Orchestration agents **can and should** create draft agents when they identify reusable patterns — this is how the framework evolves.

**When**: Subtask needs reusable domain instructions, parallel workers need shared context, complex workflow should be captured, same Task tool prompt duplicated across invocations.

**After creating a draft**:

1. Log TODO: `- [ ] tXXX Review draft agent: {name} #agent-review`
2. Reference draft in subsequent Task calls instead of repeating instructions
3. Note draft's existence in completion summary

### Deployment Sync

Agent changes in `.agents/` require `setup.sh` to deploy to `~/.aidevops/agents/`:

```bash
cd ~/Git/aidevops && ./setup.sh
```

Offer to run when creating, renaming, moving, merging, or deleting agents. See `aidevops/setup.md`.

### Cache-Aware Prompt Patterns

LLM providers cache prompt prefixes to reduce cost/latency. Maximize cache hits:

**Stable prefix**: Keep prompt beginnings stable across calls. Variable content (user messages) goes at the end. Dynamic content at the start (timestamps, version numbers) breaks the cache.

**Instruction ordering — primacy effect**: LLMs weight earlier instructions more heavily. Order by importance:

1. **Critical rules** (security, safety, core workflow) — top
2. **Frequent operations** (common tasks, standard patterns) — middle
3. **Edge cases and reference** (rare scenarios, examples) — bottom

Never reorder instructions between calls (causes cache misses).

**AI-CONTEXT blocks** support this: essential stable content first (`<!-- AI-CONTEXT-START -->`), detailed docs after.

**MCP tool definitions**: Minimize tool churn — keep stable tool sets per agent. Dynamically changing tools between sessions cause cache misses.

**Measuring effectiveness**: Monitor API cache hit rates. High hits indicate stable prefixes, consistent tool configs, and effective progressive disclosure.

### Reviewing Existing Agents

See `build-agent/agent-review.md` for systematic review sessions. It covers instruction budgets, universal applicability, duplicates, code examples, AI-CONTEXT blocks, stale content, and MCP configuration.
