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

**Related Agents**:
- `@code-standards` for linting agent markdown
- `aidevops/architecture.md` for framework structure
- `tools/browser/browser-automation.md` for agents needing browser capabilities (tool hierarchy: Playwright → Playwriter → Stagehand → DevTools)

**Git Workflow**:
- Branch strategy: `workflows/branch.md`
- Git operations: `tools/git.md`

**Testing**: Use OpenCode CLI to test config changes without restarting TUI:

```bash
opencode run "Test query" --agent Build+
```text

See `tools/opencode/opencode.md` for CLI testing patterns.

<!-- AI-CONTEXT-END -->

## Detailed Guidance

### Why This Matters

LLMs are stateless functions. AGENTS.md is the only file that goes into every conversation. This makes it the highest leverage point - for better or worse.

Research indicates:
- Frontier thinking models can follow ~150-200 instructions consistently
- Instruction-following quality degrades **uniformly** as count increases
- AI assistant system prompts already consume ~50 instructions
- The system may tell models to ignore AGENTS.md content deemed irrelevant

**Implication**: Every instruction in AGENTS.md must be universally applicable to ALL tasks.

### Main Agent vs Subagent Design

#### When to Design a Main Agent

Main agents are for high-level project orchestration:

- **Scope**: Broad domain (wordpress, seo, content, aidevops)
- **Role**: Coordinates subagents, makes strategic decisions
- **Context**: Needs awareness of multiple related concerns
- **Location**: Root of `.agent/` folder
- **Examples**: `seo.md`, `aidevops.md`, `build-plus.md`

**Main agent characteristics:**
- Calls subagents when specialized work needed
- Maintains project-level context
- Makes decisions about which tools/subagents to invoke
- Can run in parallel with other main agents (different projects)

#### When to Design a Subagent

Subagents are for focused, parallel execution:

- **Scope**: Specific tool, service, or task type
- **Role**: Execute focused operations independently
- **Context**: Minimal, task-specific only
- **Location**: Inside domain folders or `tools/`, `services/`, `workflows/`
- **Examples**: `tools/git/github-cli.md`, `services/hosting/hostinger.md`

**Subagent characteristics:**
- Can run in parallel without context conflicts
- Has specific MCP tools enabled (others disabled)
- Completes discrete tasks, returns results
- Doesn't need knowledge of other domains

#### Subagent YAML Frontmatter (Required)

Every subagent **must** include YAML frontmatter defining its tool permissions. Without explicit permissions, subagents default to read-only analysis mode, which causes confusion when agents recommend actions they cannot perform.

**Required frontmatter structure:**

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
```text

**Tool permission options:**

| Tool | Purpose | Risk Level |
|------|---------|------------|
| `read` | Read file contents | Low - passive observation |
| `glob` | Find files by pattern | Low - discovery only |
| `grep` | Search file contents | Low - discovery only |
| `webfetch` | Fetch URLs | Low - read-only external |
| `task` | Spawn subagents | Medium - delegates work |
| `edit` | Modify existing files | Medium - changes files |
| `write` | Create new files | Medium - adds files |
| `bash` | Execute commands | High - arbitrary execution |

**MCP tool patterns** (for agents needing specific MCP access):

```yaml
tools:
  context7_*: true              # Context7 documentation tools
  augment-context-engine_*: true # Augment codebase search
  wordpress-mcp_*: true         # WordPress MCP tools
```

**CRITICAL: MCP Placement Rule**

- **Enable MCPs in SUBAGENTS only** (files in subdirectories like `services/crm/`, `tools/wordpress/`)
- **NEVER enable MCPs in main agents** (`sales.md`, `marketing.md`, `seo.md`, etc.)
- Main agents reference subagents for MCP functionality
- This ensures MCPs only load when the specific subagent is invoked

```yaml
# CORRECT: MCP in subagent (services/crm/fluentcrm.md)
tools:
  fluentcrm_*: true

# WRONG: MCP in main agent (sales.md)
tools:
  fluentcrm_*: true  # DON'T DO THIS - use subagent reference instead
```

**MCP requirements with tool filtering** (documents intent for future `includeTools` support):

```yaml
---
description: Preview and screenshot local dev servers
mcp_requirements:
  chrome-devtools:
    tools: [navigate_page, take_screenshot, new_page, list_pages]
---
```

This convention documents which specific tools an agent needs from an MCP server. Currently informational only - OpenCode doesn't yet support `includeTools` filtering (see [OpenCode #7399](https://github.com/anomalyco/opencode/issues/7399)). When supported, our agent generator can use this to configure filtered MCP access.

**Why document MCP requirements?**
- Prepares agents for future `includeTools` support
- Documents intent for humans reviewing agent design
- Enables token savings when OpenCode implements filtering (e.g., 17k → 1.5k tokens for chrome-devtools)
- Prior art: [Amp's lazy-load MCP with skills](https://ampcode.com/news/lazy-load-mcp-with-skills)

**Example: Read-only analysis agent**

```yaml
---
description: Analyzes agent files for quality issues
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: false
  task: true
---
```text

**Example: Write-capable task agent**

```yaml
---
description: Updates wiki documentation from agent changes
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---
```text

**Example: Agent with MCP access**

```yaml
---
description: WordPress development with MCP tools
mode: subagent
temperature: 0.2
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
  wordpress-mcp_*: true
  context7_*: true
---
```text

**Note on permissions**: Path-based permissions (e.g., restricting which files can be edited) are configured in `opencode.json` for OpenCode, not in markdown frontmatter. The frontmatter defines which tools are available; the JSON config defines granular restrictions.

**Why this matters:**
- Prevents confusion when agents recommend actions they cannot perform
- Makes agent capabilities explicit and predictable
- Enables safer parallel execution (read-only agents can't conflict)
- Documents intent for both humans and AI systems

#### Agent Directory Architecture

This repository has two agent directories with different purposes:

| Directory | Purpose | Used By |
|-----------|---------|---------|
| `.agent/` | Source of truth with full documentation | Deployed to `~/.aidevops/agents/` by `setup.sh` |
| `.opencode/agent/` | Generated stubs for OpenCode | OpenCode CLI (reads these directly) |

**How it works:**
1. `.agent/` contains the authoritative agent files with rich documentation
2. `setup.sh` deploys `.agent/` to `~/.aidevops/agents/`
3. `generate-opencode-agents.sh` creates minimal stubs in `~/.config/opencode/agent/` that reference the deployed files
4. OpenCode reads the stubs, which point to the full agent content

**Frontmatter in `.agent/` files** serves as:
- Documentation of intended permissions
- Reference for non-OpenCode AI assistants (Claude, Cursor, etc.)
- Template for what the generated stubs should enable

#### Decision Framework

```text
Is this a broad domain or strategic concern?
  YES → Main Agent at root
  NO  ↓

Can this run independently without needing other domain knowledge?
  YES → Subagent in appropriate folder
  NO  ↓

Does this coordinate multiple tools/services?
  YES → Consider if it should be main agent or call existing subagents
  NO  → Subagent, or add to existing agent
```text

#### Calling Other Agents

When designing an agent, prefer calling existing agents over duplicating:

```markdown
# Good: Reference existing capability
For Git operations, invoke `@git-platforms` subagent.
For code quality, invoke `@code-standards` subagent.

# Bad: Duplicate instructions
## Git Operations
[50 lines duplicating git-platforms.md content]
```text

### MCP Configuration Pattern

**Global disabled, per-agent enabled:**

```json
// In opencode.json
{
  "mcp": {
    "hostinger-api": { "enabled": false },
    "hetzner-*": { "enabled": false }
  },
  "tools": {
    "hostinger-api_*": false,
    "hetzner-*": false
  },
  "agent": {
    "hostinger": {
      "tools": { "hostinger-api_*": true }
    },
    "hetzner": {
      "tools": { "hetzner-*": true }
    }
  }
}
```text

**Why this matters:**
- Reduces context window usage (MCP tools add tokens)
- Prevents tool confusion (wrong MCP for task)
- Enables focused subagent execution
- Allows parallel subagents without conflicts

**When designing agents, specify:**
- Which MCPs should be enabled for this agent
- Which should remain disabled
- Any tools that need special permissions

### Code References: Search Patterns over Line Numbers

Line numbers drift as code changes. Use search patterns instead:

```markdown
# Bad (will drift)
See error handling at `.agent/scripts/hostinger-helper.sh:145`

# Good (stable)
Search for `handle_api_error` in `.agent/scripts/hostinger-helper.sh`

# Better (with fallback)
Search for `handle_api_error` in hostinger-helper.sh.
If not found, search for `api_error` or `error handling` patterns.
```text

**Search pattern hierarchy:**
1. Function/variable name (most specific)
2. Unique string literals in the code
3. Comment markers (e.g., `# ERROR HANDLING SECTION`)
4. Broader pattern search if specific not found

### Quality Checking: Linters First

**Never send an LLM to do a linter's job.**

Preference order for code quality:

1. **Deterministic linters** (fast, cheap, consistent)
   - ShellCheck for bash
   - ESLint for JavaScript
   - Ruff/Pylint for Python
   - Run these FIRST, automatically

2. **Static analysis tools** (comprehensive, still fast)
   - SonarCloud, Codacy, CodeFactor
   - Security scanners (Snyk, Secretlint)
   - Run after linters pass

3. **LLM review** (expensive, slow, variable)
   - CodeRabbit, AI-assisted review
   - Use for architectural concerns
   - Use when deterministic tools insufficient

**In agent instructions:**

```markdown
# Good
Run ShellCheck before committing. Use `@code-standards` for comprehensive analysis.

# Bad
Ask the AI to check your code formatting and style.
```text

**Consider bun for performance:**
Where agents reference `npm` or `npx`, consider if `bun` would be faster:
- `bun` is significantly faster for package operations
- Compatible with most npm packages
- Prefer `bunx` over `npx` for one-off executions

### Information Quality (All Domains)

Agent instructions must be accurate. Apply these standards:

#### Source Evaluation

1. **Primary sources preferred**
   - Official documentation over blog posts
   - API specs over tutorials
   - First-hand data over summaries

2. **Cross-reference claims**
   - Verify facts across multiple sources
   - Note when sources disagree
   - Prefer recent over dated sources

3. **Bias awareness**
   - Consider source's agenda (vendor docs promote their product)
   - Note commercial vs independent sources
   - Acknowledge limitations of any source

4. **Fact-checking**
   - Commands should be tested before documenting
   - URLs should be verified accessible
   - Version numbers should be current

#### Domain-Specific Considerations

| Domain | Primary Sources | Watch For |
|--------|-----------------|-----------|
| **Code/DevOps** | Official docs, RFCs, source code | Outdated tutorials, version drift |
| **SEO** | SERPsWebmaster tools, Search Console data, Domain Rank, Search Volume, Link Juice, Topical Relevance, Entity Authority | SEO vendor claims, outdated tactics, Google FUD |
| **Legal** | Legislation, case law, official guidance | Jurisdiction differences, dated info |
| **Health** | Peer-reviewed research, official health bodies, practicing researchers | Commercial health claims, fads, conflicted interests |
| **Marketing** | Platform official docs, first-party data, clickbait effectiveness, integrity | Vendor case studies, inflated metrics, conflicted interests |
| **Accounting** | Tax authority guidance, accounting standards, meaningful chart of accounts, clear audit trails for events, reasons, and changes | Jurisdiction-specific rules |
| **Content** | Style guides, brand guidelines, readability, tone of voice, shorter sentences, one sentence per paragraph for online content, Plain English, personal experience, first-person voice unless otherwise appropriate, references, quotes, citations, facts, supporting data, observations | Subjective preferences as rules, bias, lack of references and citations, opinions |

### Agent Design Checklist

Before adding content to any agent file:

1. **Does this subagent have YAML frontmatter?**
   - All subagents require tool permission declarations
   - Without frontmatter, agents default to read-only
   - See "Subagent YAML Frontmatter" section for template

2. **Is this universally applicable?**
   - Will this instruction be relevant to >80% of tasks for this agent?
   - If not, move to a more specific subagent

3. **Could this be a pointer instead?**
   - Does the content exist elsewhere?
   - Use search patterns to reference codebase
   - Use Context7 MCP for external library documentation

4. **Is this a code example?**
   - Is it authoritative (the reference implementation)?
   - Will it drift from actual implementation?
   - For security patterns: include placeholders, note secure storage

5. **What's the instruction count impact?**
   - Each bullet point, rule, or directive counts
   - Combine related instructions where possible
   - Remove redundant or obvious instructions

6. **Does this duplicate other agents?**
   - Search: `rg "pattern" .agent/` before adding
   - Check for conflicting guidance across files
   - Single source of truth for each concept

7. **Should another agent be called instead?**
   - Does an existing agent handle this?
   - Would calling it and improving its instructions be more efficient than duplicating?

8. **Are sources verified?**
   - Primary sources used?
   - Facts cross-referenced?
   - Biases acknowledged?

9. **Does the markdown pass linting?**
   - Single H1 heading per file (MD025)
   - Blank lines around headings (MD022)
   - Blank lines around code blocks (MD031)
   - No multiple consecutive blank lines (MD012)
   - Run `npx markdownlint-cli2 "path/to/file.md"` to verify

### Progressive Disclosure Pattern

Instead of putting everything in AGENTS.md:

```markdown
# Bad: Everything in AGENTS.md
## Database Schema Guidelines
[50 lines of schema rules...]

## API Design Patterns  
[40 lines of API rules...]

## Testing Requirements
[30 lines of testing rules...]
```text

```markdown
# Good: Pointers in AGENTS.md, details in subagents
## Subagent Index
- `tools/code-review/` - Quality standards, testing, linting
- `aidevops/architecture.md` - Schema and API patterns

Read subagents only when task requires them.
```text

### Code Examples: When to Use

**Include code examples when:**

1. **It's the authoritative reference** - No implementation exists elsewhere

   ```bash
   # Pattern for credential storage (authoritative)
   # Store actual values in ~/.config/aidevops/mcp-env.sh
   export SERVICE_API_KEY="${SERVICE_API_KEY:-}"
   ```

2. **Security-critical template** - Must be followed exactly

   ```bash
   # Correct: Placeholder for secret
   curl -H "Authorization: Bearer ${API_TOKEN}" ...
   
   # Wrong: Actual secret in example
   curl -H "Authorization: Bearer sk-abc123..." ...
   ```

3. **Command syntax reference** - The example IS the documentation

   ```bash
   .agent/scripts/[service]-helper.sh [command] [account] [target]
   ```

**Avoid code examples when:**

1. **Code exists in codebase** - Use search pattern reference

   ```markdown
   # Bad
   Here's how to handle errors:
   [20 lines of error handling code]
   
   # Good
   Search for `handle_api_error` in service-helper.sh for error handling pattern.
   ```

2. **External library patterns** - Use Context7 MCP

   ```markdown
   # Bad
   Here's the React Query pattern:
   [code that may be outdated]
   
   # Good
   Use Context7 MCP to fetch current React Query documentation
   ```

3. **Will become outdated** - Point to maintained source

   ```markdown
   # Bad
   Current API endpoint: https://api.service.com/v2/...
   
   # Good
   See `configs/service-config.json.txt` for current endpoints
   ```

### Testing Code Examples

When code examples are used during a task:

1. **Test the example** - Does it produce expected results?
2. **If failure** - Trigger self-assessment
3. **Evaluate cause**:
   - Example outdated? Update or add version note
   - Context different? Add clarifying conditions
   - Example wrong? Fix and check for duplicates

### Self-Assessment Protocol

#### Triggers

1. **Observable Failure**
   - Command syntax fails (API changed)
   - Paths/URLs don't exist (infrastructure changed)
   - Auth patterns don't work (security model changed)

2. **User Correction**
   - Immediate trigger for self-assessment
   - Analyze which instruction led to incorrect response
   - Consider if correction applies to other contexts

3. **Contradiction Detection**
   - Context7 MCP documentation differs from agent
   - Codebase patterns differ from instructions
   - User requirements conflict with instructions

4. **Staleness Indicators**
   - Version numbers don't match installed versions
   - Deprecated APIs/tools referenced
   - "Last updated" significantly old

#### Process

1. **Complete current task first** - Never abandon user's goal

2. **Identify root cause**:
   - Which specific instruction led to the issue?
   - Is this a single-point fix or systemic pattern?

3. **Duplicate/Conflict Check** (CRITICAL):

   ```bash
   # Search for similar instructions
   rg "pattern" .agent/
   
   # Check files that might have parallel instructions
   # Note potential conflicts if change is made
   ```

4. **Propose improvement**:
   - Specific change with rationale
   - List ALL files that may need coordinated updates
   - Flag if change might conflict with other agents

5. **Request permission**:

   ```text
   > Agent Feedback: While [task], I noticed [issue] in 
   > `.agent/[file].md`. Related instructions also exist in 
   > `[other-files]`. Suggested improvement: [change]. 
   > Should I update these after completing your request?
   ```

#### Self-Assessment of Self-Assessment

This protocol should also be reviewed when:
- False positives occur (unnecessary suggestions)
- False negatives occur (missed opportunities)
- User feedback indicates protocol is too aggressive/passive
- Duplicate detection fails to catch conflicts

### Tool Selection Checklist

Before using tools, verify you're using the optimal choice:

| Task | Preferred Tool | Avoid | Why |
|------|---------------|-------|-----|
| Find files by pattern | `git ls-files` or `fd` | `mcp_glob` | CLI is 10x faster |
| Search file contents | `rg` (ripgrep) | `mcp_grep` | CLI is more powerful |
| Read file contents | `mcp_read` | `cat` via bash | Better error handling |
| Edit files | `mcp_edit` | `sed` via bash | Safer, atomic |
| Web content | `mcp_webfetch` | `curl` via bash | Handles redirects |
| Remote repo research | `mcp_webfetch` README first | `npx repomix --remote` | Prevents context overload |
| Interactive CLIs | Bash directly | N/A | Full PTY - run vim, psql, ssh, htop |
| Parallel AI dispatch | OpenCode server API | Multiple TUI instances | Headless, programmatic |

**Self-check prompt**: Before calling any MCP tool, ask:
> "Is there a faster CLI alternative I should use via Bash?"

**Context budget check**: Before context-heavy operations, ask:
> "Could this return >50K tokens? Have I checked the size first?"

See `tools/context/context-guardrails.md` for detailed guardrails.

### Agent File Structure Convention

All agent files should follow this structure:

**Main agents** (no frontmatter required):

```markdown
# Agent Name - Brief Purpose

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: One-line description
- **Key Info**: Essential facts only (avoid numbers that change)
- **Commands**: Primary commands if applicable

[Condensed, universally-applicable content]

<!-- AI-CONTEXT-END -->

## Detailed Documentation

[Verbose human-readable content, examples, edge cases]
[Read only when specific details needed]
```text

**Subagents** (YAML frontmatter required):

```markdown
---
description: Brief description of agent purpose
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Subagent Name - Brief Purpose

[Subagent content...]
```text

See "Subagent YAML Frontmatter" section for full permission options.

**Avoid in agents:**
- Hardcoded counts that change (e.g., "29+ services")
- Specific version numbers unless critical
- Dates that will become stale

### Folder Organization

```text
.agent/
├── AGENTS.md                 # Entry point (ALLCAPS - special root file)
├── {domain}.md               # Main agents at root (lowercase)
├── {domain}/                 # Subagents for that domain
│   ├── {subagent}.md         # Specialized guidance (lowercase)
├── tools/                    # Cross-domain utilities
│   ├── {category}/           # Grouped by function
├── services/                 # External integrations
│   ├── {category}/           # Grouped by type
├── workflows/                # Process guides
└── scripts/
    └── commands/             # Slash command definitions
```text

### Slash Command Placement

**CRITICAL**: Never define slash commands inline in main agents.

| Command Type | Location | Example |
|--------------|----------|---------|
| Generic (cross-domain) | `scripts/commands/{command}.md` | `/save-todo`, `/remember`, `/code-simplifier` |
| Domain-specific | `{domain}/{subagent}.md` | `/keyword-research` in `seo/keyword-research.md` |

**Main agents only reference commands** - they list available commands but never contain the implementation:

```markdown
# Good: Reference in main agent (seo.md)
**Commands**: `/keyword-research`, `/autocomplete-research`

# Bad: Implementation in main agent
## /keyword-research Command
[50 lines of command implementation...]
```text

**Why this matters:**
- Keeps main agents under instruction budget
- Enables command reuse across agents
- Allows targeted reading (only load command when invoked)
- Prevents duplication when multiple agents use same command

**Naming conventions:**

- **Main agents**: Lowercase with hyphens at root (`build-mcp.md`, `seo.md`)
- **Subagents**: Lowercase with hyphens in folders (`build-mcp/deployment.md`)
- **Special files**: ALLCAPS for entry points only (`AGENTS.md`, `README.md`)
- **Pattern**: Main agent matches folder name: `{domain}.md` + `{domain}/`

**Why lowercase for main agents (not ALLCAPS)?**

- Location (root vs folder) already distinguishes main from subagents
- ALLCAPS causes cross-platform issues (Linux is case-sensitive)
- Matches common framework conventions (OpenCode, Cursor, Continue)
- `ls .agent/*.md` instantly shows all main agents

**Why main agents stay at root (not inside folders)?**

- Tooling uses `find -mindepth 2` to discover subagents
- Quick visibility: main agents visible without opening folders
- Clear mental model: "main file + supporting folder"
- OpenCode expects main agents at predictable paths

**Main agent → subagent relationship:**

Main agents provide overview and point to subagents for details (progressive disclosure):

```markdown
**Subagents** (`build-mcp/`):
| Subagent | When to Read |
|----------|--------------|
| `deployment.md` | Adding MCP to AI assistants |
| `server-patterns.md` | Registering tools, resources |
```text

### Deployment Sync

Agent changes in `.agent/` require `setup.sh` to deploy to `~/.aidevops/agents/`:

```bash
cd ~/Git/aidevops && ./setup.sh
```text

**Offer to run setup.sh when:**
- Creating new agents
- Renaming or moving agents
- Merging or deleting agents
- Modifying agent content users need immediately

See `aidevops/setup.md` for deployment details.

### Cache-Aware Prompt Patterns

LLM providers implement prompt caching to reduce costs and latency. Anthropic's prompt caching, for example, caches the first N tokens of a prompt and reuses them across calls. To maximize cache hits:

**Stable Prefix Pattern**

Keep the beginning of your prompts stable across calls:

```text
# Good: Stable prefix, variable suffix
[AGENTS.md content - stable]     ← Cached
[Subagent content - stable]      ← Cached  
[User message - variable]        ← Not cached

# Bad: Variable content early
[Dynamic timestamp]              ← Breaks cache
[AGENTS.md content]              ← Not cached (prefix changed)
```

**Instruction Ordering**

Never reorder instructions between calls:

```markdown
# Good: Consistent order
1. Security rules
2. Code standards
3. Output format

# Bad: Reordering based on task
# Call 1: Security, Code, Output
# Call 2: Code, Security, Output  ← Cache miss
```

**Avoid Dynamic Prefixes**

Don't put variable content at the start of agent files:

```markdown
# Bad: Dynamic content at top
Last updated: 2025-01-21  ← Changes daily, breaks cache
Version: 2.41.0           ← Changes on release

# Good: Static content at top
# Agent Name - Purpose
[Static instructions...]

<!-- Dynamic content at end if needed -->
```

**AI-CONTEXT Blocks**

The `<!-- AI-CONTEXT-START -->` pattern helps by:
1. Putting essential, stable content first
2. Detailed docs after (may be truncated, but prefix cached)

```markdown
<!-- AI-CONTEXT-START -->
[Stable, essential content - always cached]
<!-- AI-CONTEXT-END -->

## Detailed Documentation
[Less critical, may vary - cache still benefits from prefix]
```

**MCP Tool Definitions**

MCP tools are injected into prompts. Minimize tool churn:

```json
// Good: Stable tool set per agent
"SEO": { "tools": { "dataforseo_*": true, "serper_*": true } }

// Bad: Dynamically changing tools
// Session 1: dataforseo_*, serper_*
// Session 2: dataforseo_*, gsc_*  ← Different tools, cache miss
```

**Measuring Cache Effectiveness**

Monitor your API usage for cache hit rates. High cache hits indicate:
- Stable instruction prefixes
- Consistent tool configurations
- Effective progressive disclosure (subagents loaded only when needed)

### Reviewing Existing Agents

See `build-agent/agent-review.md` for systematic review sessions. It covers instruction budgets, universal applicability, duplicates, code examples, AI-CONTEXT blocks, stale content, and MCP configuration.

## Oh-My-OpenCode Integration

When oh-my-opencode is installed, leverage these specialized agents for enhanced agent development:

| OmO Agent | When to Use | Example |
|-----------|-------------|---------|
| `@oracle` | Agent architecture review, design decisions | "Ask @oracle to review this agent's instruction structure" |
| `@librarian` | Find agent design patterns, AGENTS.md examples | "Ask @librarian for examples of well-structured AI agents" |
| `@document-writer` | Agent documentation, clear instructions | "Ask @document-writer to improve this agent's clarity" |

**Agent Design Workflow Enhancement**:

```text
1. Design → Build-Agent creates structure
2. Review → @oracle validates architecture
3. Examples → @librarian finds similar patterns
4. Polish → @document-writer improves clarity
5. Test → Deploy and validate
```text

**Note**: These agents require [oh-my-opencode](https://github.com/code-yeongyu/oh-my-opencode) plugin.
See `tools/opencode/oh-my-opencode.md` for installation.
