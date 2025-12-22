# Execution Plans

Complex, multi-session work requiring research, design decisions, and detailed tracking.

Based on [OpenAI's PLANS.md](https://cookbook.openai.com/articles/codex_exec_plans) and [plan.md](https://github.com/Digital-Tvilling/plan.md), with TOON-enhanced parsing.

<!--TOON:meta{version,format,updated}:
1.0,plans-md+toon,2025-12-20T00:00:00Z
-->

## Format

Each plan includes:
- **Status**: Planning / In Progress (Phase X/Y) / Blocked / Completed
- **Time Estimate**: `~2w (ai:1w test:0.5w read:0.5w)`
- **Timestamps**: `logged:`, `started:`, `completed:`
- **Progress**: Timestamped checkboxes with estimates and actuals
- **Decision Log**: Key decisions with rationale
- **Surprises & Discoveries**: Unexpected findings
- **Outcomes & Retrospective**: Results and lessons (when complete)

## Active Plans

### [2025-12-21] aidevops-opencode Plugin

**Status:** Planning
**Estimate:** ~2d (ai:1d test:0.5d read:0.5d)
**Architecture:** [.agent/build-mcp/aidevops-plugin.md](../.agent/build-mcp/aidevops-plugin.md)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p001,aidevops-opencode Plugin,planning,0,4,,opencode|plugin,2d,1d,0.5d,0.5d,2025-12-21T01:50Z,
-->

#### Purpose

Create an optional OpenCode plugin that provides native integration for aidevops. This enables lifecycle hooks (pre-commit quality checks), dynamic agent loading, and cleaner npm-based installation for OpenCode users who want tighter integration.

#### Context from Discussion

**Key decisions:**
- Plugin is **optional enhancement**, not replacement for current multi-tool approach
- aidevops remains compatible with Claude, Cursor, Windsurf, etc.
- Plugin loads agents from `~/.aidevops/agents/` at runtime
- Should detect and complement oh-my-opencode if both installed

**Architecture (from aidevops-plugin.md):**
- Agent loader from `~/.aidevops/agents/`
- MCP registration programmatically
- Pre-commit quality hooks (ShellCheck)
- aidevops CLI exposed as tool

**When to build:**
- When OpenCode becomes dominant enough
- When users request native plugin experience
- When hooks become essential (quality gates)

#### Progress

- [ ] (2025-12-21) Phase 1: Core plugin structure + agent loader ~4h
- [ ] (2025-12-21) Phase 2: MCP registration ~2h
- [ ] (2025-12-21) Phase 3: Quality hooks (pre-commit) ~3h
- [ ] (2025-12-21) Phase 4: oh-my-opencode compatibility ~2h

<!--TOON:milestones[4]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m001,p001,Phase 1: Core plugin structure + agent loader,4h,,2025-12-21T00:00Z,,pending
m002,p001,Phase 2: MCP registration,2h,,2025-12-21T00:00Z,,pending
m003,p001,Phase 3: Quality hooks (pre-commit),3h,,2025-12-21T00:00Z,,pending
m004,p001,Phase 4: oh-my-opencode compatibility,2h,,2025-12-21T00:00Z,,pending
-->

#### Decision Log

- **Decision:** Keep as optional plugin, not replace current approach
  **Rationale:** aidevops must remain multi-tool compatible (Claude, Cursor, etc.)
  **Date:** 2025-12-21

<!--TOON:decisions[1]{id,plan_id,decision,rationale,date,impact}:
d001,p001,Keep as optional plugin,aidevops must remain multi-tool compatible,2025-12-21,None - additive feature
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

### [2025-12-21] Claude Code Destructive Command Hooks

**Status:** Planning
**Estimate:** ~4h (ai:2h test:1h read:1h)
**Source:** [Dicklesworthstone's guide](https://github.com/Dicklesworthstone/misc_coding_agent_tips_and_scripts/blob/main/DESTRUCTIVE_GIT_COMMAND_CLAUDE_HOOKS_SETUP.md)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p002,Claude Code Destructive Command Hooks,planning,0,4,,claude|git|security,4h,2h,1h,1h,2025-12-21T12:00Z,
-->

#### Purpose

Implement Claude Code PreToolUse hooks to mechanically block destructive git and filesystem commands. Instructions in AGENTS.md don't prevent execution - this provides enforcement at the tool level.

**Problem:** On Dec 17, 2025, an AI agent ran `git checkout --` on files with hours of uncommitted work, destroying it instantly. AGENTS.md forbade this, but instructions alone don't prevent accidents.

**Solution:** Python hook script that intercepts Bash commands before execution and blocks dangerous patterns.

#### Context from Discussion

**Commands to block:**
- `git checkout -- <files>` - discards uncommitted changes
- `git restore <files>` - same as checkout (newer syntax)
- `git reset --hard` - destroys all uncommitted changes
- `git clean -f` - removes untracked files permanently
- `git push --force` / `-f` - destroys remote history
- `git branch -D` - force-deletes without merge check
- `rm -rf` (non-temp paths) - recursive deletion
- `git stash drop/clear` - permanently deletes stashes

**Safe patterns (allowlisted):**
- `git checkout -b <branch>` - creates new branch
- `git restore --staged` - only unstages, doesn't discard
- `git clean -n` / `--dry-run` - preview only
- `rm -rf /tmp/...`, `/var/tmp/...`, `$TMPDIR/...` - temp dirs

**Key decisions:**
- Adapt for aidevops: install to `~/.aidevops/hooks/` not `.claude/hooks/`
- Support both Claude Code and OpenCode (if hooks compatible)
- Add installer to `setup.sh` for automatic deployment
- Document in `workflows/git-workflow.md`

#### Progress

- [ ] (2025-12-21) Phase 1: Create git_safety_guard.py adapted for aidevops ~1h
- [ ] (2025-12-21) Phase 2: Create installer script with global/project options ~1h
- [ ] (2025-12-21) Phase 3: Integrate into setup.sh ~30m
- [ ] (2025-12-21) Phase 4: Document in workflows and test ~1.5h

<!--TOON:milestones[4]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m005,p002,Phase 1: Create git_safety_guard.py adapted for aidevops,1h,,2025-12-21T12:00Z,,pending
m006,p002,Phase 2: Create installer script with global/project options,1h,,2025-12-21T12:00Z,,pending
m007,p002,Phase 3: Integrate into setup.sh,30m,,2025-12-21T12:00Z,,pending
m008,p002,Phase 4: Document in workflows and test,1.5h,,2025-12-21T12:00Z,,pending
-->

#### Decision Log

- **Decision:** Install hooks to `~/.aidevops/hooks/` by default
  **Rationale:** Consistent with aidevops directory structure, global protection
  **Date:** 2025-12-21

- **Decision:** Keep original Python implementation (not Bash)
  **Rationale:** JSON parsing is cleaner in Python, original is well-tested
  **Date:** 2025-12-21

<!--TOON:decisions[2]{id,plan_id,decision,rationale,date,impact}:
d002,p002,Install hooks to ~/.aidevops/hooks/,Consistent with aidevops directory structure,2025-12-21,None
d003,p002,Keep original Python implementation,JSON parsing cleaner in Python - original well-tested,2025-12-21,None
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

### [2025-12-21] Evaluate Merging build-agent and build-mcp into aidevops

**Status:** Planning
**Estimate:** ~4h (ai:2h test:1h read:1h)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p003,Evaluate Merging build-agent and build-mcp into aidevops,planning,0,3,,architecture|agents,4h,2h,1h,1h,2025-12-21T14:00Z,
-->

#### Purpose

Evaluate whether `build-agent.md` and `build-mcp.md` should be merged into `aidevops.md`. When enhancing aidevops, we often build agents and MCPs - these are tightly coupled activities that may benefit from consolidation.

#### Context from Discussion

**Current structure:**
- `build-agent.md` - Agent design, ~50-100 instruction budget, subagent: `agent-review.md`
- `build-mcp.md` - MCP development (TypeScript/Bun/Elysia), subagents: server-patterns, transports, deployment, api-wrapper
- `aidevops.md` - Framework operations, already references build-agent as "Related Main Agent"
- All three are `mode: subagent` - called from aidevops context

**Options to evaluate:**
1. **Merge fully** - Combine into aidevops.md with expanded subagent folders
2. **Keep separate but link better** - Improve cross-references, keep modularity
3. **Hybrid** - Move build-agent into aidevops/, keep build-mcp separate (MCP is more specialized)

**Key considerations:**
- Token efficiency: Fewer main agents = less context switching
- Modularity: build-mcp has specialized TypeScript/Bun stack knowledge
- User mental model: Are these distinct domains or one "framework development" domain?
- Progressive disclosure: Current structure already uses subagent pattern

#### Progress

- [ ] (2025-12-21) Phase 1: Analyze usage patterns and cross-references ~1h
- [ ] (2025-12-21) Phase 2: Design merged/improved structure ~1.5h
- [ ] (2025-12-21) Phase 3: Implement chosen approach and test ~1.5h

<!--TOON:milestones[3]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m009,p003,Phase 1: Analyze usage patterns and cross-references,1h,,2025-12-21T14:00Z,,pending
m010,p003,Phase 2: Design merged/improved structure,1.5h,,2025-12-21T14:00Z,,pending
m011,p003,Phase 3: Implement chosen approach and test,1.5h,,2025-12-21T14:00Z,,pending
-->

#### Decision Log

(To be populated during analysis)

<!--TOON:decisions[0]{id,plan_id,decision,rationale,date,impact}:
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

### [2025-12-21] OCR Invoice/Receipt Extraction Pipeline

**Status:** Planning
**Estimate:** ~3d (ai:1.5d test:1d read:0.5d)
**Source:** [pontusab's X post](https://x.com/pontusab/status/2002345525174284449)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p004,OCR Invoice/Receipt Extraction Pipeline,planning,0,5,,accounting|ocr|automation,3d,1.5d,1d,0.5d,2025-12-21T22:00Z,
-->

#### Purpose

Add OCR extraction capabilities to the accounting agent for automated invoice and receipt processing. This enables:
- Scanning/photographing paper receipts and invoices
- Automatic extraction of vendor, amount, date, VAT, line items
- Integration with QuickFile for expense recording and purchase invoice creation
- Reducing manual data entry for accounting workflows

#### Context from Discussion

**Reference:** @pontusab's OCR extraction pipeline approach (X post - details to be added when available)

**Integration points:**
- `accounting.md` - Main agent, add OCR as new capability
- `services/accounting/quickfile.md` - Target for extracted data (purchases, expenses)
- `tools/browser/` - Potential for receipt image capture workflows

**Key considerations:**
- OCR accuracy requirements for financial data
- Multi-currency and VAT handling
- Receipt image storage and retention
- Privacy/security of financial documents
- Batch processing vs real-time extraction

#### Progress

- [ ] (2025-12-21) Phase 1: Research OCR approaches and @pontusab's implementation ~4h
- [ ] (2025-12-21) Phase 2: Design extraction schema (vendor, amount, date, VAT, items) ~4h
- [ ] (2025-12-21) Phase 3: Implement OCR extraction pipeline ~8h
- [ ] (2025-12-21) Phase 4: QuickFile integration (purchases/expenses) ~4h
- [ ] (2025-12-21) Phase 5: Testing with various invoice/receipt formats ~4h

<!--TOON:milestones[5]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m012,p004,Phase 1: Research OCR approaches and @pontusab's implementation,4h,,2025-12-21T22:00Z,,pending
m013,p004,Phase 2: Design extraction schema (vendor; amount; date; VAT; items),4h,,2025-12-21T22:00Z,,pending
m014,p004,Phase 3: Implement OCR extraction pipeline,8h,,2025-12-21T22:00Z,,pending
m015,p004,Phase 4: QuickFile integration (purchases/expenses),4h,,2025-12-21T22:00Z,,pending
m016,p004,Phase 5: Testing with various invoice/receipt formats,4h,,2025-12-21T22:00Z,,pending
-->

#### Decision Log

(To be populated during implementation)

<!--TOON:decisions[0]{id,plan_id,decision,rationale,date,impact}:
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

### [2025-12-21] Image SEO Enhancement with AI Vision

**Status:** Planning
**Estimate:** ~6h (ai:3h test:2h read:1h)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p005,Image SEO Enhancement with AI Vision,planning,0,4,,seo|images|ai|accessibility,6h,3h,2h,1h,2025-12-21T23:30Z,
-->

### [2025-12-21] Uncloud Integration for aidevops

**Status:** Planning
**Estimate:** ~1d (ai:4h test:4h read:2h)
**Source:** [psviderski/uncloud](https://github.com/psviderski/uncloud)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p006,Uncloud Integration for aidevops,planning,0,4,,deployment|docker|orchestration,1d,4h,4h,2h,2025-12-21T04:00Z,
-->

#### Purpose

Add Uncloud as a deployment provider option in aidevops. Uncloud is a lightweight container orchestration tool that enables multi-machine Docker deployments without complex Kubernetes infrastructure. It aligns with aidevops philosophy of simplicity and developer experience.

**Why Uncloud:**
- Docker Compose format (familiar, no new DSL)
- WireGuard mesh networking (zero-config, secure)
- No control plane (decentralized, fewer failure points)
- CLI-based with Docker-like commands (`uc run`, `uc deploy`, `uc ls`)
- Self-hosted, Apache 2.0 licensed
- Complements Coolify (PaaS) and Vercel (serverless) as infrastructure-level orchestration

#### Context from Discussion

**Key capabilities identified:**
- Deploy anywhere: cloud VMs, bare metal, hybrid
- Zero-downtime rolling deployments
- Built-in Caddy reverse proxy with auto HTTPS
- Service discovery via internal DNS
- Managed DNS subdomain (*.uncld.dev) for quick access
- Direct image push to machines without registry (Unregistry)

**Integration architecture:**
- `tools/deployment/uncloud.md` - Main subagent (alongside coolify.md, vercel.md)
- `tools/deployment/uncloud-setup.md` - Installation and machine setup
- `scripts/uncloud-helper.sh` - CLI wrapper for common operations
- `configs/uncloud-config.json.txt` - Configuration template

**Comparison with existing providers:**

| Provider | Type | Best For |
|----------|------|----------|
| Coolify | Self-hosted PaaS | Single-server apps, managed experience |
| Vercel | Serverless | Static sites, JAMstack, Next.js |
| Uncloud | Multi-machine orchestration | Cross-server deployments, Docker clusters |

#### Progress

- [ ] (2025-12-21) Phase 1: Create uncloud.md subagent with Quick Reference ~2h
- [ ] (2025-12-21) Phase 2: Create uncloud-helper.sh script ~2h
- [ ] (2025-12-21) Phase 3: Create uncloud-config.json.txt template ~1h
- [ ] (2025-12-21) Phase 4: Update deployment docs and test workflows ~3h

<!--TOON:milestones[4]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m021,p006,Phase 1: Create uncloud.md subagent with Quick Reference,2h,,2025-12-21T04:00Z,,pending
m022,p006,Phase 2: Create uncloud-helper.sh script,2h,,2025-12-21T04:00Z,,pending
m023,p006,Phase 3: Create uncloud-config.json.txt template,1h,,2025-12-21T04:00Z,,pending
m024,p006,Phase 4: Update deployment docs and test workflows,3h,,2025-12-21T04:00Z,,pending
-->

#### Decision Log

- **Decision:** Place in tools/deployment/ alongside Coolify and Vercel
  **Rationale:** Uncloud is a deployment tool, not a hosting provider (like Hetzner/Hostinger)
  **Date:** 2025-12-21

- **Decision:** Focus on CLI integration, not MCP server initially
  **Rationale:** Uncloud is pre-production; CLI wrapper provides immediate value without MCP complexity
  **Date:** 2025-12-21

<!--TOON:decisions[2]{id,plan_id,decision,rationale,date,impact}:
d006,p006,Place in tools/deployment/ alongside Coolify and Vercel,Uncloud is a deployment tool not a hosting provider,2025-12-21,None
d007,p006,Focus on CLI integration not MCP server initially,Uncloud is pre-production; CLI wrapper provides immediate value,2025-12-21,None
-->

#### Surprises & Discoveries

(To be populated during implementation)

#### Purpose

Add AI-powered image SEO capabilities to the SEO agent. Use Moondream.ai vision model to analyze images and generate SEO-optimized filenames, alt text, and tags for better search visibility and accessibility. Include image upscaling for quality enhancement when needed.

#### Context from Discussion

**Architecture:**
- `seo/moondream.md` - Moondream.ai vision API integration subagent
- `seo/image-seo.md` - Image SEO orchestrator (coordinates moondream + upscale)
- `seo/upscale.md` - Image upscaling services (API provider TBD after research)

**Integration points:**
- Update `seo.md` main agent to reference image-seo capabilities
- `image-seo.md` can call both `moondream.md` and `upscale.md` as needed
- Workflow: analyze image → generate names/tags → optionally upscale

**Key capabilities:**
- SEO-friendly filename generation from image content
- Alt text generation for accessibility (WCAG compliance)
- Tag/keyword extraction for image metadata
- Quality upscaling before publishing (optional)

**Research needed:**
- Moondream.ai API documentation and integration patterns
- Best upscaling API services (candidates: Replicate, DeepAI, Let's Enhance, etc.)

#### Progress

- [ ] (2025-12-21) Phase 1: Research Moondream.ai API and create moondream.md subagent ~1.5h
- [ ] (2025-12-21) Phase 2: Create image-seo.md orchestrator subagent ~1.5h
- [ ] (2025-12-21) Phase 3: Research upscaling APIs and create upscale.md subagent ~1.5h
- [ ] (2025-12-21) Phase 4: Update seo.md and test integration ~1.5h

<!--TOON:milestones[4]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m017,p005,Phase 1: Research Moondream.ai API and create moondream.md subagent,1.5h,,2025-12-21T23:30Z,,pending
m018,p005,Phase 2: Create image-seo.md orchestrator subagent,1.5h,,2025-12-21T23:30Z,,pending
m019,p005,Phase 3: Research upscaling APIs and create upscale.md subagent,1.5h,,2025-12-21T23:30Z,,pending
m020,p005,Phase 4: Update seo.md and test integration,1.5h,,2025-12-21T23:30Z,,pending
-->

#### Decision Log

- **Decision:** Create three separate subagents (moondream, image-seo, upscale)
  **Rationale:** Separation of concerns - moondream for vision, upscale for quality, image-seo as orchestrator
  **Date:** 2025-12-21

- **Decision:** image-seo.md orchestrates moondream and upscale
  **Rationale:** Single entry point for image optimization, can selectively call subagents as needed
  **Date:** 2025-12-21

<!--TOON:decisions[2]{id,plan_id,decision,rationale,date,impact}:
d004,p005,Create three separate subagents (moondream; image-seo; upscale),Separation of concerns - moondream for vision; upscale for quality; image-seo as orchestrator,2025-12-21,None
d005,p005,image-seo.md orchestrates moondream and upscale,Single entry point for image optimization; can selectively call subagents,2025-12-21,None
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

### [2025-12-21] SEO Machine Integration for aidevops

**Status:** Planning
**Estimate:** ~2d (ai:1d test:0.5d read:0.5d)
**Source:** [TheCraigHewitt/seomachine](https://github.com/TheCraigHewitt/seomachine)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p007,SEO Machine Integration for aidevops,planning,0,5,,seo|content|agents,2d,1d,0.5d,0.5d,2025-12-21T15:00Z,
-->

#### Purpose

Fork and adapt SEO Machine capabilities into aidevops to add comprehensive SEO content creation workflows. SEO Machine is a Claude Code workspace with specialized agents and Python analysis modules that fill significant gaps in aidevops content capabilities.

**What SEO Machine provides:**
- 6 custom commands (`/research`, `/write`, `/rewrite`, `/analyze-existing`, `/optimize`, `/performance-review`)
- 7 specialized agents (content-analyzer, seo-optimizer, meta-creator, internal-linker, keyword-mapper, editor, performance)
- 5 Python analysis modules (search intent, keyword density, readability, content length, SEO quality rating)
- Context-driven system (brand voice, style guide, examples, internal links map)

**Why fork vs integrate:**
- SEO Machine is Claude Code-specific (`.claude/` structure)
- aidevops needs multi-tool compatibility (OpenCode, Cursor, Windsurf, etc.)
- Can leverage existing aidevops SEO tools (DataForSEO, GSC, E-E-A-T, site-crawler)
- Opportunity to improve with aidevops patterns (subagent architecture, TOON, scripts)

#### Context from Discussion

**Gap analysis - what aidevops gains:**

| Capability | SEO Machine | aidevops Current | Action |
|------------|-------------|------------------|--------|
| Content Writing | `/write` command | Basic `content.md` | Add writing workflow |
| Content Optimization | `/optimize` with scoring | Missing | Add optimization agents |
| Readability Scoring | Python (Flesch, etc.) | Missing | Port to scripts/ |
| Keyword Density | Python analyzer | Missing | Port to scripts/ |
| Search Intent | Python classifier | Missing | Port to scripts/ |
| Content Length Comparison | SERP competitor analysis | Missing | Port to scripts/ |
| SEO Quality Rating | 0-100 scoring | Missing | Port to scripts/ |
| Brand Voice/Context | Context files system | Missing | Add context management |
| Internal Linking | Agent + map file | Missing | Add linking strategy |
| Meta Creator | Dedicated agent | Missing | Add meta generation |
| Editor (Human Voice) | Dedicated agent | Missing | Add humanization |
| E-E-A-T Analysis | Not mentioned | ✅ `eeat-score.md` | Keep existing |
| Site Crawling | Not mentioned | ✅ `site-crawler.md` | Keep existing |
| Keyword Research | DataForSEO | ✅ DataForSEO, Serper, GSC | Keep existing |

**Architecture decisions:**
- Adapt agents to aidevops subagent pattern under `seo/` and `content/`
- Port Python modules to `~/.aidevops/agents/scripts/seo-*.py`
- Create context system compatible with multi-project use
- Integrate with existing `content.md` main agent

#### Progress

- [ ] (2025-12-21) Phase 1: Port Python analysis modules to scripts/ ~4h
  - `seo-readability.py` - Flesch scores, sentence analysis
  - `seo-keyword-density.py` - Keyword analysis, clustering
  - `seo-search-intent.py` - Intent classification
  - `seo-content-length.py` - SERP competitor comparison
  - `seo-quality-rater.py` - 0-100 SEO scoring
- [ ] (2025-12-21) Phase 2: Create content writing subagents ~4h
  - `content/seo-writer.md` - SEO-optimized content creation
  - `content/meta-creator.md` - Meta title/description generation
  - `content/editor.md` - Human voice optimization
  - `content/internal-linker.md` - Internal linking strategy
- [ ] (2025-12-21) Phase 3: Create SEO analysis subagents ~3h
  - `seo/content-analyzer.md` - Comprehensive content analysis
  - `seo/seo-optimizer.md` - On-page SEO recommendations
  - `seo/keyword-mapper.md` - Keyword placement analysis
- [ ] (2025-12-21) Phase 4: Add context management system ~3h
  - Context file templates (brand-voice, style-guide, internal-links-map)
  - Per-project context in `.aidevops/context/`
  - Integration with content agents
- [ ] (2025-12-21) Phase 5: Update main agents and test ~2h
  - Update `content.md` with new capabilities
  - Update `seo.md` with content analysis
  - Integration testing

<!--TOON:milestones[5]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m025,p007,Phase 1: Port Python analysis modules to scripts/,4h,,2025-12-21T15:00Z,,pending
m026,p007,Phase 2: Create content writing subagents,4h,,2025-12-21T15:00Z,,pending
m027,p007,Phase 3: Create SEO analysis subagents,3h,,2025-12-21T15:00Z,,pending
m028,p007,Phase 4: Add context management system,3h,,2025-12-21T15:00Z,,pending
m029,p007,Phase 5: Update main agents and test,2h,,2025-12-21T15:00Z,,pending
-->

#### Decision Log

- **Decision:** Fork and adapt rather than integrate directly
  **Rationale:** SEO Machine is Claude Code-specific; aidevops needs multi-tool compatibility
  **Date:** 2025-12-21

- **Decision:** Port Python modules to scripts/ rather than keeping as separate package
  **Rationale:** Consistent with aidevops pattern; scripts are self-contained and portable
  **Date:** 2025-12-21

- **Decision:** Split agents between content/ and seo/ folders
  **Rationale:** Writing/editing belongs in content domain; analysis belongs in SEO domain
  **Date:** 2025-12-21

<!--TOON:decisions[3]{id,plan_id,decision,rationale,date,impact}:
d008,p007,Fork and adapt rather than integrate directly,SEO Machine is Claude Code-specific; aidevops needs multi-tool compatibility,2025-12-21,None
d009,p007,Port Python modules to scripts/,Consistent with aidevops pattern; scripts are self-contained and portable,2025-12-21,None
d010,p007,Split agents between content/ and seo/ folders,Writing/editing belongs in content domain; analysis belongs in SEO domain,2025-12-21,None
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

### [2025-12-21] Enhance Plan+ and Build+ with OpenCode's Latest Features

**Status:** Planning
**Estimate:** ~3h (ai:1.5h test:1h read:30m)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p008,Enhance Plan+ and Build+ with OpenCode's Latest Features,planning,0,4,,opencode|agents|enhancement,3h,1.5h,1h,30m,2025-12-21T04:30Z,
-->

#### Purpose

Apply OpenCode's latest agent configuration features to our Build+ and Plan+ agents, and configure agent ordering so our enhanced agents appear first in the Tab-cycled list (displacing OpenCode's default build/plan agents).

#### Context from Discussion

**Research findings from OpenCode docs (2025-12-21):**

| Feature | OpenCode Latest | Our Current State | Action |
|---------|-----------------|-------------------|--------|
| `disable` option | Supports `"disable": true` per agent | Not using | Disable built-in `build` and `plan` |
| `default_agent` | Supports `"default_agent": "Build+"` | Not set | Set Build+ as default |
| `maxSteps` | Cost control for expensive ops | Not configured | Consider adding for subagents |
| Granular bash permissions | `"git status": "allow"` patterns | Plan+ denies all bash | Allow read-only git commands |
| Agent ordering | JSON key order determines Tab order | Build+ first | Already correct |

**Key decisions:**
- Disable OpenCode's default `build` and `plan` agents so only our Build+ and Plan+ appear
- Set `default_agent` to `Build+` for consistent startup behavior
- Add granular bash permissions to Plan+ allowing read-only git commands (`git status`, `git log*`, `git diff`, `git branch`)
- Update `generate-opencode-agents.sh` to apply these settings automatically

**Granular bash permissions for Plan+ (read-only git):**

```json
"permission": {
  "edit": "deny",
  "write": "deny",
  "bash": {
    "git status": "allow",
    "git log*": "allow",
    "git diff*": "allow",
    "git branch*": "allow",
    "git show*": "allow",
    "*": "deny"
  }
}
```

#### Progress

- [ ] (2025-12-21) Phase 1: Add `disable: true` for built-in build/plan agents ~30m
- [ ] (2025-12-21) Phase 2: Set `default_agent` to Build+ ~15m
- [ ] (2025-12-21) Phase 3: Add granular bash permissions to Plan+ ~45m
- [ ] (2025-12-21) Phase 4: Update generate-opencode-agents.sh and test ~1.5h

<!--TOON:milestones[4]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m030,p008,Phase 1: Add disable:true for built-in build/plan agents,30m,,2025-12-21T04:30Z,,pending
m031,p008,Phase 2: Set default_agent to Build+,15m,,2025-12-21T04:30Z,,pending
m032,p008,Phase 3: Add granular bash permissions to Plan+,45m,,2025-12-21T04:30Z,,pending
m033,p008,Phase 4: Update generate-opencode-agents.sh and test,1.5h,,2025-12-21T04:30Z,,pending
-->

#### Decision Log

- **Decision:** Disable OpenCode's default build/plan rather than rename our agents
  **Rationale:** Keeps our naming (Build+, Plan+) which indicates enhanced versions; cleaner than competing names
  **Date:** 2025-12-21

- **Decision:** Allow read-only git commands in Plan+ via granular bash permissions
  **Rationale:** Plan+ needs to inspect git state (status, log, diff) for planning without modification risk
  **Date:** 2025-12-21

<!--TOON:decisions[2]{id,plan_id,decision,rationale,date,impact}:
d011,p008,Disable OpenCode's default build/plan rather than rename our agents,Keeps our naming (Build+ Plan+) which indicates enhanced versions,2025-12-21,None
d012,p008,Allow read-only git commands in Plan+ via granular bash permissions,Plan+ needs to inspect git state for planning without modification risk,2025-12-21,None
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

### [2025-12-21] Beads Integration for aidevops Tasks & Plans

**Status:** Completed
**Estimate:** ~2d (ai:1d test:0.5d read:0.5d)
**Actual:** ~1.5d
**Source:** [steveyegge/beads](https://github.com/steveyegge/beads)
**Completed:** 2025-12-22

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started,completed}:
p009,Beads Integration for aidevops Tasks & Plans,completed,3,3,,beads|tasks|sync|planning,2d,1d,0.5d,0.5d,2025-12-21T16:00Z,2025-12-21T16:00Z,2025-12-22T00:00Z
-->

#### Purpose

Integrate Beads task management concepts and bi-directional sync into aidevops Tasks & Plans system. This provides:
- Dependency graph awareness (blocked-by, blocks, parent-child)
- Hierarchical task IDs with sub-sub-task support (t001.1.1)
- Automatic "ready" detection for unblocked tasks
- Rich UI ecosystem (beads_viewer, beads-ui, bdui, perles, beads.el)
- Graph analytics (PageRank, betweenness, critical path)

**Key decision:** Keep aidevops markdown as source of truth, sync bi-directionally to Beads for visualization and graph features. Include Beads as default with aidevops (not optional).

#### Context from Discussion

**Ecosystem reviewed:**
- `steveyegge/beads` - Core CLI, Go, SQLite + JSONL, MCP server
- `Dicklesworthstone/beads_viewer` - Advanced TUI with graph analytics
- `mantoni/beads-ui` - Web UI with live updates
- `ctietze/beads.el` - Emacs client
- `assimelha/bdui` - React/Ink TUI
- `zjrosen/perles` - BQL query language TUI

**What aidevops gains:**
- Dependency graph (blocks, parent-child, discovered-from)
- Hash-based IDs for conflict-free merging
- `bd ready` for unblocked task detection
- Graph visualization via beads_viewer
- MCP server for Claude Desktop

**What aidevops keeps:**
- Time tracking with breakdown (`~4h (ai:2h test:1h)`)
- Decision logs and retrospectives
- TOON machine-readable blocks
- Human-readable markdown
- Multi-tool compatibility

**Sync architecture:**

```
TODO.md ←→ beads-sync-helper.sh ←→ .beads/beads.db
PLANS.md ←→ (command-led sync) ←→ .beads/issues.jsonl
```

**Sync guarantees:**
- Command-led only (no automatic sync to prevent race conditions)
- Lock file during sync operations
- Checksum verification before/after
- Conflict detection with manual resolution
- Audit log of all sync operations

#### Progress

- [x] (2025-12-21 16:00Z) Phase 1: Enhanced TODO.md format ~4h actual:3h
  - [x] 1.1 Add `blocked-by:` and `blocks:` syntax
  - [x] 1.2 Add hierarchical IDs (t001.1.1 for sub-sub-tasks)
  - [x] 1.3 Update TOON dependencies block schema
  - [x] 1.4 Add `/ready` command to show unblocked tasks
  - [x] 1.5 Update workflows/plans.md documentation
- [x] (2025-12-21) Phase 2: Bi-directional sync script ~8h actual:6h
  - [x] 2.1 Create beads-sync-helper.sh with lock file
  - [x] 2.2 Implement TODO.md → Beads sync
  - [x] 2.3 Implement Beads → TODO.md sync
  - [x] 2.4 Add checksum verification
  - [x] 2.5 Add conflict detection and resolution
  - [x] 2.6 Add audit logging
  - [x] 2.7 Comprehensive testing (race conditions, edge cases)
- [x] (2025-12-21) Phase 3: Default installation ~4h actual:3h
  - [x] 3.1 Add Beads installation to setup.sh
  - [x] 3.2 Add `aidevops init beads` feature
  - [x] 3.3 Create tools/task-management/beads.md subagent
  - [x] 3.4 Update AGENTS.md with Beads integration docs

<!--TOON:milestones[14]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m034,p009,Phase 1: Enhanced TODO.md format,4h,3h,2025-12-21T16:00Z,2025-12-22T00:00Z,done
m035,p009,1.1 Add blocked-by and blocks syntax,1h,1h,2025-12-21T16:00Z,2025-12-22T00:00Z,done
m036,p009,1.2 Add hierarchical IDs (t001.1.1),1h,1h,2025-12-21T16:00Z,2025-12-22T00:00Z,done
m037,p009,1.3 Update TOON dependencies block schema,30m,30m,2025-12-21T16:00Z,2025-12-22T00:00Z,done
m038,p009,1.4 Add /ready command,1h,1h,2025-12-21T16:00Z,2025-12-22T00:00Z,done
m039,p009,1.5 Update workflows/plans.md documentation,30m,30m,2025-12-21T16:00Z,2025-12-22T00:00Z,done
m040,p009,Phase 2: Bi-directional sync script,8h,6h,2025-12-21T16:00Z,2025-12-22T00:00Z,done
m041,p009,2.1-2.6 Sync implementation,6h,5h,2025-12-21T16:00Z,2025-12-22T00:00Z,done
m042,p009,2.7 Comprehensive testing,2h,1h,2025-12-21T16:00Z,2025-12-22T00:00Z,done
m043,p009,Phase 3: Default installation,4h,3h,2025-12-21T16:00Z,2025-12-22T00:00Z,done
m044,p009,3.1 Add Beads to setup.sh,1h,45m,2025-12-21T16:00Z,2025-12-22T00:00Z,done
m045,p009,3.2 Add aidevops init beads,1h,45m,2025-12-21T16:00Z,2025-12-22T00:00Z,done
m046,p009,3.3 Create beads.md subagent,1h,45m,2025-12-21T16:00Z,2025-12-22T00:00Z,done
m047,p009,3.4 Update AGENTS.md,1h,45m,2025-12-21T16:00Z,2025-12-22T00:00Z,done
-->

#### Decision Log

- **Decision:** Keep aidevops markdown as source of truth, Beads as sync target
  **Rationale:** Markdown is portable, human-readable, works without CLI; Beads provides graph features
  **Date:** 2025-12-21

- **Decision:** Command-led sync only (no automatic)
  **Rationale:** Prevents race conditions, ensures data integrity, user controls when sync happens
  **Date:** 2025-12-21

- **Decision:** Include Beads as default with aidevops (not optional)
  **Rationale:** Graph features are valuable enough to justify default installation
  **Date:** 2025-12-21

- **Decision:** Support sub-sub-tasks (t001.1.1)
  **Rationale:** Complex projects need deeper hierarchy than just parent-child
  **Date:** 2025-12-21

<!--TOON:decisions[4]{id,plan_id,decision,rationale,date,impact}:
d013,p009,Keep aidevops markdown as source of truth,Markdown is portable and human-readable; Beads provides graph features,2025-12-21,None
d014,p009,Command-led sync only (no automatic),Prevents race conditions and ensures data integrity,2025-12-21,None
d015,p009,Include Beads as default with aidevops,Graph features valuable enough to justify default installation,2025-12-21,None
d016,p009,Support sub-sub-tasks (t001.1.1),Complex projects need deeper hierarchy than just parent-child,2025-12-21,None
-->

#### Surprises & Discoveries

- **Observation:** Implementation was faster than estimated (~1.5d vs ~2d)
  **Evidence:** All core functionality already existed, just needed documentation updates
  **Impact:** Positive - ready for production use
  **Date:** 2025-12-22

<!--TOON:discoveries[1]{id,plan_id,observation,evidence,impact,date}:
disc001,p009,Implementation faster than estimated,All core functionality already existed,Positive - ready for production,2025-12-22
-->

#### Outcomes & Retrospective

**What was delivered:**
- `beads-sync-helper.sh` (597 lines) - bi-directional sync with lock file, checksums, conflict detection
- `todo-ready.sh` - show tasks with no open blockers
- `beads.md` subagent (289 lines) - comprehensive documentation
- `blocked-by:` and `blocks:` syntax in TODO.md
- Hierarchical task IDs (t001.1.1)
- TOON dependencies block schema
- Beads CLI installation in setup.sh
- AGENTS.md integration docs

**What went well:**
- Core sync script is robust with proper locking and checksums
- Documentation is comprehensive with install commands for all UI repos
- Integration with existing TODO.md format is seamless

**What could improve:**
- Beads UI repos (beads_viewer, beads-ui, bdui, perles) are documented but not auto-installed
- Could add optional UI installation to setup.sh

**Time Summary:**
- Estimated: 2d
- Actual: 1.5d
- Variance: -25% (faster)
- Lead time: 1 day (logged to completed)

<!--TOON:retrospective{plan_id,delivered,went_well,improve,est,actual,variance_pct,lead_time_days}:
p009,beads-sync-helper.sh; todo-ready.sh; beads.md subagent; blocked-by/blocks syntax; hierarchical IDs; TOON schema; setup.sh integration; AGENTS.md docs,Robust sync script; comprehensive docs; seamless integration,Add optional UI installation to setup.sh,2d,1.5d,-25,1
-->

<!--TOON:active_plans[8]{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p001,aidevops-opencode Plugin,planning,0,4,,opencode|plugin,2d,1d,0.5d,0.5d,2025-12-21T01:50Z,
p002,Claude Code Destructive Command Hooks,planning,0,4,,claude|git|security,4h,2h,1h,1h,2025-12-21T12:00Z,
p003,Evaluate Merging build-agent and build-mcp into aidevops,planning,0,3,,architecture|agents,4h,2h,1h,1h,2025-12-21T14:00Z,
p004,OCR Invoice/Receipt Extraction Pipeline,planning,0,5,,accounting|ocr|automation,3d,1.5d,1d,0.5d,2025-12-21T22:00Z,
p005,Image SEO Enhancement with AI Vision,planning,0,4,,seo|images|ai|accessibility,6h,3h,2h,1h,2025-12-21T23:30Z,
p006,Uncloud Integration for aidevops,planning,0,4,,deployment|docker|orchestration,1d,4h,4h,2h,2025-12-21T04:00Z,
p007,SEO Machine Integration for aidevops,planning,0,5,,seo|content|agents,2d,1d,0.5d,0.5d,2025-12-21T15:00Z,
p008,Enhance Plan+ and Build+ with OpenCode's Latest Features,planning,0,4,,opencode|agents|enhancement,3h,1.5h,1h,30m,2025-12-21T04:30Z,
-->

## Completed Plans

### [2025-12-21] Beads Integration for aidevops Tasks & Plans ✓

See [Active Plans > Beads Integration](#2025-12-21-beads-integration-for-aidevops-tasks--plans) for full details.

**Summary:** Integrated Beads task management with bi-directional sync, dependency tracking, and graph visualization.
**Estimate:** 2d | **Actual:** 1.5d | **Variance:** -25%

<!--TOON:completed_plans[1]{id,title,owner,tags,est,actual,logged,started,completed,lead_time_days}:
p009,Beads Integration for aidevops Tasks & Plans,,beads|tasks|sync|planning,2d,1.5d,2025-12-21T16:00Z,2025-12-21T16:00Z,2025-12-22T00:00Z,1
-->

## Archived Plans

<!-- Plans that were abandoned or superseded -->

<!--TOON:archived_plans[0]{id,title,reason,logged,archived}:
-->

---

## Plan Template

Copy this template when creating a new plan:

```markdown
### [YYYY-MM-DD] Plan Title

**Status:** Planning
**Owner:** @username
**Tags:** #tag1 #tag2
**Estimate:** ~Xd (ai:Xd test:Xd read:Xd)
**PRD:** [todo/tasks/prd-{slug}.md](tasks/prd-{slug}.md)
**Tasks:** [todo/tasks/tasks-{slug}.md](tasks/tasks-{slug}.md)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p00X,Plan Title,planning,0,N,username,tag1|tag2,Xd,Xd,Xd,Xd,YYYY-MM-DDTHH:MMZ,
-->

#### Purpose

Brief description of why this work matters and what problem it solves.

#### Progress

- [ ] (YYYY-MM-DD HH:MMZ) Phase 1: Description ~Xh
- [ ] (YYYY-MM-DD HH:MMZ) Phase 2: Description ~Xh

<!--TOON:milestones[N]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m001,p00X,Phase 1: Description,Xh,,YYYY-MM-DDTHH:MMZ,,pending
-->

#### Decision Log

- **Decision:** What was decided
  **Rationale:** Why this choice was made
  **Date:** YYYY-MM-DD
  **Impact:** Effect on timeline/scope

<!--TOON:decisions[0]{id,plan_id,decision,rationale,date,impact}:
-->

#### Surprises & Discoveries

- **Observation:** What was unexpected
  **Evidence:** How we know this
  **Impact:** How it affects the plan

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

#### Time Tracking

| Phase | Estimated | Actual | Variance |
|-------|-----------|--------|----------|
| Phase 1 | Xh | - | - |
| Phase 2 | Xh | - | - |
| **Total** | **Xh** | **-** | **-** |

<!--TOON:time_tracking{plan_id,total_est,total_actual,variance_pct}:
p00X,Xh,,
-->
```

### Completing a Plan

When a plan is complete, add this section and move to Completed Plans:

```markdown
#### Outcomes & Retrospective

**What was delivered:**
- Deliverable 1
- Deliverable 2

**What went well:**
- Success 1
- Success 2

**What could improve:**
- Learning 1
- Learning 2

**Time Summary:**
- Estimated: Xd
- Actual: Xd
- Variance: ±X%
- Lead time: X days (logged to completed)

<!--TOON:retrospective{plan_id,delivered,went_well,improve,est,actual,variance_pct,lead_time_days}:
p00X,Deliverable 1; Deliverable 2,Success 1; Success 2,Learning 1; Learning 2,Xd,Xd,X,X
-->
```

---

## Analytics

<!--TOON:analytics{total_plans,active,completed,archived,avg_lead_time_days,avg_variance_pct}:
8,8,0,0,,
-->
