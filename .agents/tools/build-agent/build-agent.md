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

**Model tier**: Use `/route "task"` or `/patterns recommend "type"` before setting `model:` in frontmatter. Static rules (`haiku`→formatting, `sonnet`→code, `opus`→architecture) are starting points; pattern data overrides at >75% success, 3+ samples.

<!-- AI-CONTEXT-END -->

## Main Agent vs Subagent Design

| Aspect | Main Agent | Subagent |
|--------|-----------|----------|
| **Scope** | Broad domain | Specific tool/service/task |
| **Role** | Coordinates, strategic | Focused independent execution |
| **Location** | Root of `.agents/` | `tools/`, `services/`, `workflows/` |
| **MCP tools** | NEVER enable directly | Enable per-agent |

Broad/strategic → main agent. Independent, no cross-domain knowledge → subagent. Prefer calling existing agents over duplicating.

## Subagent YAML Frontmatter (Required)

Every subagent **must** include YAML frontmatter. Without it, agents default to read-only.

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

MCP tool patterns (subagents only — NEVER in main agents): `context7_*: true`, `wordpress-mcp_*: true`. Path-based permissions go in `opencode.json`, not frontmatter.

MCP requirements with tool filtering (future `includeTools` — enables 17k→1.5k token savings): `mcp_requirements: { chrome-devtools: { tools: [navigate_page, take_screenshot] } }`

**Main-branch write restrictions** (subagents with `write/edit: true` on `main`/`master`): ALLOWED: `README.md`, `TODO.md`, `todo/PLANS.md`, `todo/tasks/*`. BLOCKED: all other files. Add a "Write Restrictions" section to any writable subagent.

## MCP Configuration Pattern

Global disabled, per-agent enabled in `opencode.json`: `"mcp": { "hostinger-api": { "enabled": false } }` + `"agent": { "hostinger": { "tools": { "hostinger-api_*": true } } }`

## Agent Directory Architecture

`.agents/` → source of truth, deployed to `~/.aidevops/agents/` by `setup.sh`. `.opencode/agent/` → generated stubs by `generate-opencode-agents.sh`.

## Code References

Use search patterns, not line numbers (they drift): `Search for handle_api_error in hostinger-helper.sh; fallback: api_error or error handling`. Hierarchy: function/variable name → unique string literals → comment markers → broader pattern.

## Model Tier Selection

| Situation | Action |
|-----------|--------|
| >75% success, 3+ samples | Use pattern data (overrides static rule) |
| Sparse/inconclusive | Fall back to routing rules |
| Contradicts routing rules | Note conflict in agent docs |
| No data yet | Use routing rules, record outcomes |

Record: `/remember "SUCCESS/FAILURE: agent with model — reason"`. Frontmatter: `model: sonnet  # 87% success, 14 samples`. Full docs: `tools/context/model-routing.md`.

## Quality Checking: Linters First

Never send an LLM to do a linter's job. Order: (1) deterministic linters (ShellCheck, ESLint, Ruff/Pylint), (2) static analysis (SonarCloud, Codacy, Secretlint), (3) LLM review (CodeRabbit — architectural only). Prefer `bun`/`bunx` over `npm`/`npx`.

## Information Quality

Use primary sources over tutorials. Cross-reference, prefer recent, watch for vendor agendas.

| Domain | Primary Sources | Watch For |
|--------|-----------------|-----------|
| Code/DevOps | Official docs, RFCs, source code | Outdated tutorials, version drift |
| SEO | Webmaster tools, Search Console | Vendor claims, outdated tactics |
| Legal | Legislation, case law | Jurisdiction differences |
| Health | Peer-reviewed research | Commercial claims, fads |
| Marketing | Platform docs, first-party data | Vendor case studies |
| Accounting | Tax authority guidance | Jurisdiction-specific rules |
| Content | Style guides, brand guidelines | Subjective preferences as rules |

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

After writing any agent doc, do a second pass to tighten prose before committing. Every token in an agent doc is paid for on every load — verbose docs compound cost across hundreds of sessions.

**Technique:** Re-read the doc and compress every instruction to its minimum form while preserving all rules, constraints, and references. LLMs follow terse instructions equally well as verbose ones.

**What to compress:**
- "In order to achieve X, you should Y" → "Y"
- "It is important to note that X" → "X" (or drop if self-evident)
- Multi-sentence explanations of a single rule → single sentence
- Narrative context ("The reason this exists is because in March 2026...") → keep task ID, drop story
- Redundant examples that demonstrate the same point → keep one

**What to preserve (never compress):**
- Task IDs (`tNNN`), issue refs (`GH#NNN`), incident identifiers
- All rules and constraints — compress wording, not the rule itself
- File paths, command examples, code blocks
- Safety-critical detail (security, compatibility)

**Target:** Agent docs should read like reference cards, not tutorials. If a section reads like it's explaining a concept to a newcomer, tighten it — the reader is an LLM that already understands the concept.

**Evidence:** Terse pass on `build.txt` achieved 63% byte reduction with zero rule loss. `AGENTS.md` achieved 48%. See `tools/code-review/code-simplifier.md` "Prose tightening" for the full classification.

## Code Examples: When to Include

**Include**: authoritative reference with no implementation elsewhere; security-critical template; command syntax IS the documentation.

**Avoid**: code exists in codebase (use search pattern); external library (use Context7 MCP); will become outdated (point to source).

When a code example fails, trigger self-assessment: update if outdated, add conditions if context-dependent, check for duplicates.

## Self-Assessment Protocol

**Triggers**: Observable failure, user correction, contradiction with Context7/codebase, staleness.

**Process**: (1) Complete current task first. (2) Identify root cause. (3) `rg "pattern" .agents/` — list ALL files needing coordinated updates. (4) Propose with rationale and request permission: `"Agent Feedback: While [task], I noticed [issue] in .agents/[file].md. Related: [other-files]. Suggested: [change]. Update after completing?"`

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

## Agent File Structure

**Main agents** (no frontmatter): `# Name` → `<!-- AI-CONTEXT-START -->` Quick Reference `<!-- AI-CONTEXT-END -->` → Detailed Documentation.

**Subagents**: YAML frontmatter + content. Avoid hardcoded counts, version numbers, or dates that go stale.

## Folder Organization

```text
.agents/
├── AGENTS.md           # Entry point (ALLCAPS)
├── {domain}.md         # Main agents at root (lowercase)
├── {domain}/           # Subagents for that domain
├── tools/              # Cross-domain utilities
├── services/           # External integrations
├── workflows/          # Process guides
└── scripts/commands/   # Slash command definitions
```

Naming: lowercase with hyphens; ALLCAPS only for entry points. Main agents at root — tooling uses `find -mindepth 2` for subagent discovery.

## Slash Command Placement

**CRITICAL**: Never define slash commands inline in main agents. Generic → `scripts/commands/{command}.md`. Domain-specific → `{domain}/{subagent}.md`. Main agents only **reference** commands.

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

**Draft agents**: Place in `~/.aidevops/agents/draft/` with `status: draft` and `created` date. Promotion: log TODO (`- [ ] tXXX Review draft agent: {name} #agent-review`), then promote to `custom/` or `.agents/` via PR, or discard.

**Custom agents**: Never shared, never overwritten. Use for business-specific workflows (`custom/mycompany/`, `custom/clients/`).

**Shared agents**: Feature branch + PR when solving a general problem with no proprietary info.

**Orchestration agents**: Create drafts when identifying reusable patterns. After: log TODO, reference draft in Task calls, note in completion summary.

## Deployment Sync

Agent changes in `.agents/` require `cd ~/Git/aidevops && ./setup.sh`. Offer to run on create/rename/move/merge/delete.

## Cache-Aware Prompt Patterns

- **Stable prefix**: Variable content at end; dynamic content at start breaks cache
- **Instruction ordering**: Critical rules → frequent operations → edge cases (primacy effect)
- **AI-CONTEXT blocks**: Essential stable content first, detailed docs after
- **MCP tool definitions**: Minimize tool churn — changing tools between sessions causes cache misses

## Reviewing Existing Agents

See `agent-review.md` for systematic review (instruction budgets, universal applicability, duplicates, code examples, AI-CONTEXT blocks, stale content, MCP configuration).
