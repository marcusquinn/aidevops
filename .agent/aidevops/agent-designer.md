# Agent Designer - Composing Efficient AI Agents

<!-- AI-CONTEXT-START -->

## Quick Reference

**Instruction Limits** (research-backed):
- ~150-200 discrete instructions: frontier thinking models can follow
- ~50 instructions: consumed by AI assistant harness system prompt
- **Budget for AGENTS.md**: ~50-100 instructions max (leaving room for user messages)
- Instruction-following degrades uniformly as count increases (not just "later" ones)

**Token Efficiency Rules**:
- Root AGENTS.md: <150 lines, universally applicable only
- Subagents: Progressive disclosure (read only when task requires)
- MCP servers: Disabled globally, enabled per-agent to keep context lean
- Code references: Use search patterns (e.g., `rg "function_name"`) not `file:line` (drifts)

**Agent Hierarchy**:
- **Main Agents**: High-level orchestration, call subagents when needed
- **Subagents**: Focused parallel execution, minimal context, specific tools
- Decision: If task can run independently without conflicting context → subagent

**Quality Preferences**:
1. Linters first (deterministic, fast, cheap)
2. Static analysis second
3. LLM review last (expensive, slow, variable)

**Information Quality** (all domains):
- Primary sources over secondary
- Cross-reference claims across sources
- Note source biases and agendas
- Fact-check before including in agents

**Self-Assessment Triggers**:
1. Observable failure (commands fail, paths don't exist)
2. User correction (immediate trigger)
3. Contradiction with authoritative docs
4. Staleness indicators (version mismatches, deprecated APIs)

<!-- AI-CONTEXT-END -->

## Detailed Guidance

### Why This Matters

LLMs are stateless functions. AGENTS.md is the only file that goes into every conversation. This makes it the highest leverage point - for better or worse.

Research indicates:
- Frontier thinking models can follow ~150-200 instructions consistently
- Instruction-following quality degrades **uniformly** as count increases
- Claude Code's system prompt already consumes ~50 instructions
- The system may tell models to ignore AGENTS.md content deemed irrelevant

**Implication**: Every instruction in AGENTS.md must be universally applicable to ALL tasks.

### Main Agent vs Subagent Design

#### When to Design a Main Agent

Main agents are for high-level project orchestration:

- **Scope**: Broad domain (wordpress, seo, content, aidevops)
- **Role**: Coordinates subagents, makes strategic decisions
- **Context**: Needs awareness of multiple related concerns
- **Location**: Root of `.agent/` folder
- **Examples**: `wordpress.md`, `seo.md`, `aidevops.md`, `build-plus.md`

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

#### Decision Framework

```
Is this a broad domain or strategic concern?
  YES → Main Agent at root
  NO  ↓

Can this run independently without needing other domain knowledge?
  YES → Subagent in appropriate folder
  NO  ↓

Does this coordinate multiple tools/services?
  YES → Consider if it should be main agent or call existing subagents
  NO  → Subagent, or add to existing agent
```

#### Calling Other Agents

When designing an agent, prefer calling existing agents over duplicating:

```markdown
# Good: Reference existing capability
For Git operations, invoke `@git-platforms` subagent.
For code quality, invoke `@code-quality` subagent.

# Bad: Duplicate instructions
## Git Operations
[50 lines duplicating git-platforms.md content]
```

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
```

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
```

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
Run ShellCheck before committing. Use `@code-quality` for comprehensive analysis.

# Bad
Ask the AI to check your code formatting and style.
```

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

1. **Is this universally applicable?**
   - Will this instruction be relevant to >80% of tasks for this agent?
   - If not, move to a more specific subagent

2. **Could this be a pointer instead?**
   - Does the content exist elsewhere?
   - Use search patterns to reference codebase
   - Use Context7 MCP for external library documentation

3. **Is this a code example?**
   - Is it authoritative (the reference implementation)?
   - Will it drift from actual implementation?
   - For security patterns: include placeholders, note secure storage

4. **What's the instruction count impact?**
   - Each bullet point, rule, or directive counts
   - Combine related instructions where possible
   - Remove redundant or obvious instructions

5. **Does this duplicate other agents?**
   - Search: `rg "pattern" .agent/` before adding
   - Check for conflicting guidance across files
   - Single source of truth for each concept

6. **Should another agent be called instead?**
   - Does an existing agent handle this?
   - Would calling it and improving its instructions be more efficient than duplicating?

7. **Are sources verified?**
   - Primary sources used?
   - Facts cross-referenced?
   - Biases acknowledged?

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
```

```markdown
# Good: Pointers in AGENTS.md, details in subagents
## Subagent Index
- `tools/code-review/` - Quality standards, testing, linting
- `aidevops/architecture.md` - Schema and API patterns

Read subagents only when task requires them.
```

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
   ```
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

### Agent File Structure Convention

All agent files should follow this structure:

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
```

**Avoid in agents:**
- Hardcoded counts that change (e.g., "29+ services")
- Specific version numbers unless critical
- Dates that will become stale

### Folder Organization

```
.agent/
├── AGENTS.md                 # Entry point for users
├── {domain}.md               # Main agents at root
├── {domain}/                 # Subagents for that domain
├── tools/                    # Cross-domain utilities
│   ├── {category}/           # Grouped by function
├── services/                 # External integrations
│   ├── {category}/           # Grouped by type
└── workflows/                # Process guides
```

**Naming conventions:**
- Lowercase with hyphens: `code-review.md`, `context-builder.md`
- Main agent matches folder name: `wordpress.md` + `wordpress/`
- Descriptive but concise names

### Reviewing Existing Agents

When reviewing agents for improvement:

1. **Count instructions** - Is it over budget?
2. **Check universal applicability** - Task-specific content?
3. **Find duplicates** - Same guidance elsewhere?
4. **Verify code examples** - Still accurate? Authoritative?
5. **Test AI-CONTEXT block** - Does condensed version capture essentials?
6. **Check for stale numbers** - Hardcoded counts, versions, dates?
7. **Verify sources** - Primary sources? Cross-referenced?
8. **MCP configuration** - Appropriate tools enabled/disabled?

Use `@agent-review` subagent for systematic review sessions.
