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

### [2026-02-03] Install Script Integrity Hardening

**Status:** Planning
**Estimate:** ~4h (ai:2h test:1h read:1h)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p016,Install Script Integrity Hardening,planning,0,4,,security|supply-chain|setup,4h,2h,1h,1h,2026-02-03T00:00Z,
-->

#### Purpose

Eliminate `curl | sh` installs by downloading scripts to disk, verifying integrity (checksum or signature), and executing locally. This reduces supply-chain exposure in setup and helper scripts.

#### Context from Discussion

Targets include:
- `setup.sh` (multiple install blocks)
- `.agent/scripts/qlty-cli.sh`
- `.agent/scripts/coderabbit-cli.sh`
- `.agent/scripts/dev-browser-helper.sh`

#### Progress

- [ ] (2026-02-03) Phase 1: Inventory all `curl|sh` usages and vendor verification options ~45m
- [ ] (2026-02-03) Phase 2: Replace with download → verify → execute flow ~2h
- [ ] (2026-02-03) Phase 3: Add fallback behavior and clear error messages ~45m
- [ ] (2026-02-03) Phase 4: Update docs/tests and verify behavior ~30m

<!--TOON:milestones[4]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m064,p016,Phase 1: Inventory curl|sh usages and verification options,45m,,2026-02-03T00:00Z,,pending
m065,p016,Phase 2: Replace with download-verify-execute flow,2h,,2026-02-03T00:00Z,,pending
m066,p016,Phase 3: Add fallback behavior and error messages,45m,,2026-02-03T00:00Z,,pending
m067,p016,Phase 4: Update docs/tests and verify behavior,30m,,2026-02-03T00:00Z,,pending
-->

#### Decision Log

(To be populated during implementation)

<!--TOON:decisions[0]{id,plan_id,decision,rationale,date,impact}:
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

### [2026-02-03] Dashboard Token Storage Hardening

**Status:** Planning
**Estimate:** ~3h (ai:1.5h test:1h read:30m)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p017,Dashboard Token Storage Hardening,planning,0,3,,security|auth|dashboard,3h,1.5h,1h,30m,2026-02-03T00:00Z,
-->

#### Purpose

Replace persistent `localStorage` token usage with session/memory-based storage and add a clear/reset flow to reduce XSS exposure and leaked tokens on shared machines.

#### Context from Discussion

Current usage persists `dashboardToken` in `localStorage` in the MCP dashboard UI. Update to session-scoped storage and ensure logout/reset clears state.

#### Progress

- [ ] (2026-02-03) Phase 1: Trace token flow and identify all storage/read paths ~45m
- [ ] (2026-02-03) Phase 2: Migrate to session/memory storage and update auth flow ~1.5h
- [ ] (2026-02-03) Phase 3: Add reset/clear UI flow and verify behavior ~45m

<!--TOON:milestones[3]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m068,p017,Phase 1: Trace token flow and storage paths,45m,,2026-02-03T00:00Z,,pending
m069,p017,Phase 2: Migrate to session/memory storage and update auth flow,1.5h,,2026-02-03T00:00Z,,pending
m070,p017,Phase 3: Add reset/clear UI flow and verify behavior,45m,,2026-02-03T00:00Z,,pending
-->

#### Decision Log

(To be populated during implementation)

<!--TOON:decisions[0]{id,plan_id,decision,rationale,date,impact}:
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

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
- `accounts.md` - Main agent, add OCR as new capability
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

```text
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

<!--TOON:active_plans[12]{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p016,Install Script Integrity Hardening,planning,0,4,,security|supply-chain|setup,4h,2h,1h,1h,2026-02-03T00:00Z,
p017,Dashboard Token Storage Hardening,planning,0,3,,security|auth|dashboard,3h,1.5h,1h,30m,2026-02-03T00:00Z,
p001,aidevops-opencode Plugin,planning,0,4,,opencode|plugin,2d,1d,0.5d,0.5d,2025-12-21T01:50Z,
p002,Claude Code Destructive Command Hooks,planning,0,4,,claude|git|security,4h,2h,1h,1h,2025-12-21T12:00Z,
p003,Evaluate Merging build-agent and build-mcp into aidevops,planning,0,3,,architecture|agents,4h,2h,1h,1h,2025-12-21T14:00Z,
p004,OCR Invoice/Receipt Extraction Pipeline,planning,0,5,,accounting|ocr|automation,3d,1.5d,1d,0.5d,2025-12-21T22:00Z,
p005,Image SEO Enhancement with AI Vision,planning,0,4,,seo|images|ai|accessibility,6h,3h,2h,1h,2025-12-21T23:30Z,
p006,Uncloud Integration for aidevops,planning,0,4,,deployment|docker|orchestration,1d,4h,4h,2h,2025-12-21T04:00Z,
p007,SEO Machine Integration for aidevops,planning,0,5,,seo|content|agents,2d,1d,0.5d,0.5d,2025-12-21T15:00Z,
p008,Enhance Plan+ and Build+ with OpenCode's Latest Features,planning,0,4,,opencode|agents|enhancement,3h,1.5h,1h,30m,2025-12-21T04:30Z,
p010,Agent Design Pattern Improvements,planning,0,5,,architecture|agents|context|optimization,1d,6h,4h,2h,2025-01-11T00:00Z,
p011,Memory Auto-Capture,planning,0,5,,memory|automation|context,1d,6h,4h,2h,2026-01-11T12:00Z,
-->

### [2025-01-11] Agent Design Pattern Improvements

**Status:** Planning
**Estimate:** ~1d (ai:6h test:4h read:2h)
**Source:** [Lance Martin's "Effective Agent Design" (Jan 2025)](https://x.com/RLanceMartin/status/2009683038272401719)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p010,Agent Design Pattern Improvements,planning,0,5,,architecture|agents|context|optimization,1d,6h,4h,2h,2025-01-11T00:00Z,
-->

#### Purpose

Implement remaining agent design pattern improvements identified from Lance Martin's analysis of successful agents (Claude Code, Manus, Cursor). While aidevops already implements most patterns, these enhancements will further optimize context efficiency and enable automatic learning.

#### Context from Discussion

**What aidevops already does well:**
- Give agents a computer (filesystem + shell)
- Multi-layer action space (per-agent MCP filtering)
- Progressive disclosure (subagent tables, read-on-demand)
- Offload context to filesystem
- Ralph Loop (iterative execution)
- Memory system (/remember, /recall)

**Remaining opportunities:**

| Priority | Improvement | Estimate | Description |
|----------|-------------|----------|-------------|
| Medium | YAML frontmatter in source subagents | ~2h | Add frontmatter to all `.agent/**/*.md` for better progressive disclosure |
| Medium | Automatic session reflection | ~4h | Auto-distill sessions to memory on completion |
| Low | Cache-aware prompt structure | ~1h | Document stable-prefix patterns for better cache hits |
| Low | Tool description indexing | ~3h | Cursor-style MCP description sync for on-demand retrieval |
| Low | Memory consolidation | ~2h | Periodic reflection over memories to merge/prune |

#### Progress

- [ ] (2025-01-11) Phase 1: Add YAML frontmatter to source subagents ~2h
  - Add `description`, `triggers`, `tools` to all `.agent/**/*.md` files
  - Update `generate-opencode-agents.sh` to parse frontmatter
- [ ] (2025-01-11) Phase 2: Automatic session reflection ~4h
  - Create `session-distill-helper.sh` to extract learnings
  - Integrate with `/session-review` command
  - Auto-call `/remember` with distilled insights
- [ ] (2025-01-11) Phase 3: Cache-aware prompt documentation ~1h
  - Document stable-prefix patterns in `build-agent.md`
  - Add guidance for avoiding instruction reordering
- [ ] (2025-01-11) Phase 4: Tool description indexing ~3h
  - Create MCP description sync to `.agent-workspace/mcp-descriptions/`
  - Add search tool for on-demand MCP discovery
- [ ] (2025-01-11) Phase 5: Memory consolidation ~2h
  - Add `memory-helper.sh consolidate` command
  - Periodic reflection to merge similar memories
  - Prune stale or superseded entries

<!--TOON:milestones[5]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m048,p010,Phase 1: Add YAML frontmatter to source subagents,2h,,2025-01-11T00:00Z,,pending
m049,p010,Phase 2: Automatic session reflection,4h,,2025-01-11T00:00Z,,pending
m050,p010,Phase 3: Cache-aware prompt documentation,1h,,2025-01-11T00:00Z,,pending
m051,p010,Phase 4: Tool description indexing,3h,,2025-01-11T00:00Z,,pending
m052,p010,Phase 5: Memory consolidation,2h,,2025-01-11T00:00Z,,pending
-->

#### Decision Log

- **Decision:** Document patterns before implementing improvements
  **Rationale:** Establishes baseline, validates alignment, provides reference for future work
  **Date:** 2025-01-11

- **Decision:** Prioritize automatic session reflection over other improvements
  **Rationale:** Highest impact for continual learning; other patterns already well-implemented
  **Date:** 2025-01-11

<!--TOON:decisions[2]{id,plan_id,decision,rationale,date,impact}:
d017,p010,Document patterns before implementing improvements,Establishes baseline and validates alignment,2025-01-11,None
d018,p010,Prioritize automatic session reflection,Highest impact for continual learning,2025-01-11,None
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

### [2026-01-21] /add-skill System for External Skill Import

**Status:** Planning (Research Complete)
**Estimate:** ~2d (ai:1d test:0.5d read:0.5d)
**Branch:** `feature/add-skill-command` (worktree at `~/Git/aidevops.feature-add-skill-command/`)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p012,/add-skill System for External Skill Import,planning,0,6,,skills|agents|import|multi-assistant,2d,1d,0.5d,0.5d,2026-01-21T00:00Z,
-->

#### Purpose

Create a comprehensive skill import system that allows rapid adoption of external AI agent skills into aidevops, with upstream tracking for updates and multi-assistant compatibility.

**Problem:** Many people are creating and sharing Claude Code skills, OpenCode skills, and other AI assistant configurations. aidevops has its own superior `.agent/` folder structure. We need to rapidly import external skills, convert to aidevops format, handle conflicts intelligently, and track upstream for updates.

#### Research Completed (2026-01-21)

**AI Assistant Compatibility Matrix:**

| Assistant | Config Location | Skills Format | AGENTS.md | Pointer Support |
|-----------|----------------|---------------|-----------|-----------------|
| OpenCode | `.opencode/skills/` | SKILL.md | Yes | Yes (description) |
| Codex (OpenAI) | `.codex/skills/` | SKILL.md | Yes (hierarchical) | Yes |
| Claude Code | `.claude/skills/` | SKILL.md | Yes | Yes |
| Amp (Sourcegraph) | `.claude/skills/`, `~/.config/amp/tools/` | SKILL.md | Yes | Yes |
| Droid (Factory) | `.factory/droids/` | Markdown+YAML | Yes | Yes |
| Cursor | `.cursorrules` | Plain MD | No | Symlinks only |
| Windsurf | `.windsurf/rules/` | MD+frontmatter | Yes | Yes |
| Cline | `.clinerules/` | Markdown | No | Symlinks only |
| Continue | `config.yaml` | YAML rules | No | No |
| Aider | `.aider.conf.yml` | YAML+CONVENTIONS.md | No | Yes (read:) |
| Roo, Goose, Copilot, Gemini | SKILL.md | SKILL.md | Yes | Yes |

**Key Standards:**
- **agentskills.io specification**: Universal SKILL.md format with YAML frontmatter
- **skills.sh CLI**: `npx skills add <owner/repo>` - supports 17+ AI assistants
- **AGENTS.md hierarchical**: Codex, Amp, Droid, Windsurf support directory-scoped AGENTS.md

**Example Skills to Import:**
- `dmmulroy/cloudflare-skill` - 60+ Cloudflare products (conflicts with existing cloudflare.md)
- `remotion-dev/skills` - Video creation in React
- `vercel-labs/agent-skills` - React best practices
- `expo/skills` - React Native/Expo
- `anthropics/skills` - Official Anthropic skills
- `trailofbits/skills` - Security auditing

**Architecture Decision:**
- Source of truth: `.agent/` (aidevops format)
- `setup.sh` generates symlinks to `~/.config/opencode/skills/`, `~/.codex/skills/`, `~/.claude/skills/`, `~/.config/amp/tools/`
- Nesting: Simple skills → single .md file; Complex skills → folder with subagents
- Tracking: `skill-sources.json` with upstream URL, version, last-checked

#### Progress

- [ ] (2026-01-21) Phase 1: Create skill-sources.json schema and registry ~2h
  - Define JSON schema for tracking upstream skills
  - Add existing humanise.md as first tracked skill
  - Create `.agent/configs/skill-sources.json`
- [ ] (2026-01-21) Phase 2: Create add-skill-helper.sh ~4h
  - Fetch via `npx skills add` or direct GitHub
  - Detect format (SKILL.md, AGENTS.md, .cursorrules, raw)
  - Extract metadata, instructions, resources
  - Check for conflicts with existing .agent/ files
- [ ] (2026-01-21) Phase 3: Create /add-skill command ~2h
  - Create `scripts/commands/add-skill.md`
  - Present merge options when conflicts detected
  - Register in skill-sources.json after import
- [ ] (2026-01-21) Phase 4: Create add-skill.md subagent ~3h
  - Create `tools/build-agent/add-skill.md`
  - Conversion logic for different formats
  - Merge strategies (add/replace/separate)
  - Follow build-agent.md and agent-review.md guidance
- [ ] (2026-01-21) Phase 5: Create skill-update-helper.sh ~2h
  - Check all tracked skills for upstream updates
  - Compare commits/versions
  - Show diff and update options
- [ ] (2026-01-21) Phase 6: Update setup.sh for symlinks ~3h
  - Generate symlinks to all AI assistant skill locations
  - Update generate-skills.sh for SKILL.md stubs
  - Document in AGENTS.md

<!--TOON:milestones[6]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m058,p012,Phase 1: Create skill-sources.json schema and registry,2h,,2026-01-21T00:00Z,,pending
m059,p012,Phase 2: Create add-skill-helper.sh,4h,,2026-01-21T00:00Z,,pending
m060,p012,Phase 3: Create /add-skill command,2h,,2026-01-21T00:00Z,,pending
m061,p012,Phase 4: Create add-skill.md subagent,3h,,2026-01-21T00:00Z,,pending
m062,p012,Phase 5: Create skill-update-helper.sh,2h,,2026-01-21T00:00Z,,pending
m063,p012,Phase 6: Update setup.sh for symlinks,3h,,2026-01-21T00:00Z,,pending
-->

#### Decision Log

- **Decision:** Use symlinks by default, pointer fallback for Windows
  **Rationale:** Single source of truth; updates to .agent/ automatically reflected
  **Date:** 2026-01-21

- **Decision:** Use `npx skills add` as fetch mechanism when available
  **Rationale:** skills.sh is emerging standard; supports 17+ AI assistants
  **Date:** 2026-01-21

- **Decision:** Complex skills become folders with subagents
  **Rationale:** Follows aidevops nesting convention (parent.md + parent/)
  **Date:** 2026-01-21

- **Decision:** Merge conflicts require human decision (add/replace/separate/skip)
  **Rationale:** Preserves existing knowledge; prevents accidental overwrites
  **Date:** 2026-01-21

<!--TOON:decisions[4]{id,plan_id,decision,rationale,date,impact}:
d022,p012,Use symlinks by default pointer fallback for Windows,Single source of truth; auto-reflects updates,2026-01-21,None
d023,p012,Use npx skills add as fetch mechanism,skills.sh is emerging standard,2026-01-21,None
d024,p012,Complex skills become folders with subagents,Follows aidevops nesting convention,2026-01-21,None
d025,p012,Merge conflicts require human decision,Preserves existing knowledge,2026-01-21,None
-->

#### Files to Create

| File | Purpose |
|------|---------|
| `.agent/configs/skill-sources.json` | Registry of imported skills with upstream tracking |
| `.agent/scripts/add-skill-helper.sh` | Fetch, analyse, convert, merge skills |
| `.agent/scripts/skill-update-helper.sh` | Check all tracked skills for updates |
| `.agent/scripts/commands/add-skill.md` | `/add-skill` command definition |
| `.agent/tools/build-agent/add-skill.md` | Subagent with conversion/merge logic |

#### Files to Update

| File | Changes |
|------|---------|
| `setup.sh` | Generate symlinks to all AI assistant skill locations |
| `generate-skills.sh` | Create SKILL.md stubs pointing to .agent/ source |
| `AGENTS.md` | Document /add-skill command in quick reference |

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

---

### [2026-01-11] Memory Auto-Capture

**Status:** Planning
**Estimate:** ~1d (ai:6h test:4h read:2h)
**PRD:** [todo/tasks/prd-memory-auto-capture.md](tasks/prd-memory-auto-capture.md)
**Source:** [claude-mem](https://github.com/thedotmack/claude-mem) - inspiration for auto-capture patterns

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p011,Memory Auto-Capture,planning,0,5,,memory|automation|context,1d,6h,4h,2h,2026-01-11T12:00Z,
-->

#### Purpose

Add automatic memory capture to aidevops, inspired by claude-mem but tool-agnostic. Currently, memory requires manual `/remember` invocation. Auto-capture will:
- Capture working solutions, failed approaches, and decisions automatically
- Work across all AI tools (OpenCode, Cursor, Claude Code, Windsurf)
- Use progressive disclosure to minimize token usage
- Maintain minimal dependencies (bash + sqlite3)

#### Context from Discussion

**Why not use claude-mem as dependency:**
- Claude Code only (plugin architecture)
- Heavy dependencies (Bun, uv, Chroma, Node.js worker)
- AGPL license (viral, requires source disclosure)
- aidevops needs tool-agnostic solution

**What we'll implement:**
- Agent instructions for auto-capture (not lifecycle hooks)
- Semantic classification into memory types
- Deduplication via FTS5 similarity
- Privacy controls (`<private>` tags, .gitignore patterns)
- `/memory-log` command for reviewing captures

**Architecture decision:** Use agent instructions (Option A) rather than shell wrappers or file watchers. This works with any AI tool that reads AGENTS.md.

#### Progress

- [ ] (2026-01-11) Phase 1: Research & Design ~2h
  - Finalize capture triggers and thresholds
  - Design classification rules
  - Document privacy patterns
- [ ] (2026-01-11) Phase 2: memory-helper.sh updates ~3.5h
  - Add `--auto-captured` flag
  - Add deduplication logic
  - Add capture statistics
- [ ] (2026-01-11) Phase 3: AGENTS.md instructions ~2h
  - Add auto-capture instructions to AGENTS.md
  - Define when to capture (success, failure, decisions)
  - Add privacy exclusion patterns
- [ ] (2026-01-11) Phase 4: /memory-log command ~2h
  - Create `scripts/commands/memory-log.md`
  - Show recent auto-captures with filtering
  - Add prune command for cleanup
- [ ] (2026-01-11) Phase 5: Privacy filters ~2.5h
  - Integrate with .gitignore patterns
  - Add `<private>` tag support
  - Add secretlint pattern exclusions

<!--TOON:milestones[5]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m053,p011,Phase 1: Research & Design,2h,,2026-01-11T12:00Z,,pending
m054,p011,Phase 2: memory-helper.sh updates,3.5h,,2026-01-11T12:00Z,,pending
m055,p011,Phase 3: AGENTS.md instructions,2h,,2026-01-11T12:00Z,,pending
m056,p011,Phase 4: /memory-log command,2h,,2026-01-11T12:00Z,,pending
m057,p011,Phase 5: Privacy filters,2.5h,,2026-01-11T12:00Z,,pending
-->

#### Decision Log

- **Decision:** Use agent instructions instead of lifecycle hooks
  **Rationale:** Tool-agnostic; works with OpenCode, Cursor, Claude Code, Windsurf without plugins
  **Date:** 2026-01-11

- **Decision:** Keep FTS5 for search, no vector embeddings
  **Rationale:** Minimal dependencies; FTS5 is sufficient for keyword search; semantic search adds complexity
  **Date:** 2026-01-11

- **Decision:** Implement ourselves rather than depend on claude-mem
  **Rationale:** claude-mem is Claude Code-only; aidevops needs multi-tool support
  **Date:** 2026-01-11

<!--TOON:decisions[3]{id,plan_id,decision,rationale,date,impact}:
d019,p011,Use agent instructions instead of lifecycle hooks,Tool-agnostic; works with all AI tools,2026-01-11,None
d020,p011,Keep FTS5 for search no vector embeddings,Minimal dependencies; FTS5 sufficient,2026-01-11,None
d021,p011,Implement ourselves rather than depend on claude-mem,claude-mem is Claude Code-only,2026-01-11,None
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

### [2026-01-23] Multi-Agent Orchestration & Token Efficiency

**Status:** Planning
**Estimate:** ~5d (ai:3d test:1d read:1d)
**Source:** [steveyegge/gastown](https://github.com/steveyegge/gastown) (inspiration, not wholesale adoption)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p013,Multi-Agent Orchestration & Token Efficiency,planning,0,8,,orchestration|tokens|agents|mailbox|toon|compaction,5d,3d,1d,1d,2026-01-23T00:00Z,
-->

#### Purpose

Evolve aidevops from single-session workflows to scalable multi-agent orchestration with:
- Inter-agent communication (TOON mailbox with lifecycle cleanup)
- Token-efficient AGENTS.md (lossless compression, ~60% reduction)
- Custom system prompt (eliminates harness tool preference conflicts)
- Compaction-surviving rules (OpenCode plugin hook)
- Stateless coordinator pattern (never hits context limits)
- Agent specialization with model routing
- TUI dashboard for zero-token monitoring
- User feedback loop pipeline for continuous improvement

**Key principles (user preferences):**
- Shell scripts over compiled binaries (transparency, editability)
- TOON format for structured data (token efficiency)
- TUI over web UI for visualization
- Lossless compression only (no knowledge/detail removed)
- Sessions must complete within context before compaction
- Memory system as long-term brain
- Specialized agents/models per task type
- Extend existing systems, don't re-implement

**Inspiration from Gas Town (cherry-picked, not wholesale):**
- Mailbox pattern for inter-agent communication
- Convoy concept for grouping related tasks
- Stateless coordinator (but NOT persistent Mayor - avoids context bloat)
- Agent registry with identity
- Formulas for repeatable workflows

**What we already have (extend, don't rebuild):**
- Worktrees: `worktree-helper.sh`, `wt` (Worktrunk)
- Task tracking: Beads + TODO.md + PLANS.md
- Iterative loops: Ralph Loop v2 + Full Loop
- Session management: `session-manager.md`, handoff pattern
- Memory: SQLite FTS5 (`memory-helper.sh`)
- Context guardrails: `context-guardrails.md`
- Re-anchor system: `loop-common.sh` (fresh context per iteration)
- TUI viewers: `beads_viewer`, `bdui`, `perles`

#### Context from Discussion

**The harness conflict problem:**
- OpenCode's anthropic-auth plugin enables `claude-code-20250219` beta flag
- This activates Claude Code's system prompt which says "use specialized tools"
- Our AGENTS.md says "NEVER use mcp_glob, use git ls-files/fd/rg instead"
- After compaction, the system prompt wins (negative constraints lost first)
- Solution: Custom `prompt` field replaces default system prompt entirely

**The compaction problem:**
- Sessions routinely hit 200K tokens with multiple compactions
- Critical rules (tool preferences, git check) lost after compaction
- OpenCode's `experimental.session.compacting` hook can inject rules
- Solution: aidevops plugin injects critical rules into every compaction

**Token efficiency analysis (current AGENTS.md):**
- 778 lines (~10K tokens) loaded every session
- Violates "50-100 instructions" principle from build-agent.md
- ~360 lines are duplicated content (already in subagents)
- ~41 lines of tables convertible to TOON (~50% savings)
- Target: ~300 lines (~3.5K tokens) with zero content loss

**Multi-agent scaling design:**
- Coordinator is STATELESS (pulse, not persistent) - reads state, dispatches, exits
- Workers are Ralph Loops with mailbox awareness
- Mailbox is TOON files with archive→remember→prune lifecycle
- Memory is the only persistent brain (everything else ephemeral)
- TUI dashboard reads files directly (zero AI token cost)

#### Decision Log

- **Decision:** Shell scripts for orchestration, not Go binary
  **Rationale:** Transparency, editability, no compile step; bottleneck is model inference not script speed
  **Date:** 2026-01-23

- **Decision:** Stateless coordinator (pulse) not persistent Mayor
  **Rationale:** Persistent coordinator accumulates context → compaction → drift. Stateless reads files, dispatches, exits (~20K tokens per pulse)
  **Date:** 2026-01-23

- **Decision:** TOON format for mailbox messages
  **Rationale:** 40-60% token savings vs JSON; human-readable; schema-aware
  **Date:** 2026-01-23

- **Decision:** Custom system prompt via OpenCode `prompt` field
  **Rationale:** Eliminates harness conflict entirely; our rules become highest priority
  **Date:** 2026-01-23

- **Decision:** Compaction plugin to preserve critical rules
  **Rationale:** Rules lost after compaction can be re-injected via `experimental.session.compacting` hook
  **Date:** 2026-01-23

- **Decision:** Lossless AGENTS.md compression (structural, not content removal)
  **Rationale:** User preference - all session learnings and detail must be preserved
  **Date:** 2026-01-23

- **Decision:** TUI for monitoring, not web UI
  **Rationale:** User preference; zero AI token cost; extend existing bdui/beads_viewer ecosystem
  **Date:** 2026-01-23

- **Decision:** Archive→remember→prune lifecycle for mailbox
  **Rationale:** Nothing lost (memory captures notable outcomes); context stays lean
  **Date:** 2026-01-23

- **Decision:** Model routing via subagent YAML frontmatter
  **Rationale:** Cheap models (Haiku) for routing/triage; capable models (Sonnet) for code; zero overhead
  **Date:** 2026-01-23

<!--TOON:decisions[9]{id,plan_id,decision,rationale,date,impact}:
d026,p013,Shell scripts for orchestration not Go binary,Transparency editability no compile step,2026-01-23,None
d027,p013,Stateless coordinator not persistent Mayor,Persistent coordinator accumulates context and drifts,2026-01-23,Architecture
d028,p013,TOON format for mailbox messages,40-60% token savings vs JSON,2026-01-23,None
d029,p013,Custom system prompt via OpenCode prompt field,Eliminates harness conflict entirely,2026-01-23,Architecture
d030,p013,Compaction plugin to preserve critical rules,Rules re-injected after every compaction,2026-01-23,Architecture
d031,p013,Lossless AGENTS.md compression,All session learnings and detail preserved,2026-01-23,None
d032,p013,TUI for monitoring not web UI,Zero AI token cost; extend existing ecosystem,2026-01-23,None
d033,p013,Archive-remember-prune lifecycle for mailbox,Nothing lost; context stays lean,2026-01-23,None
d034,p013,Model routing via subagent YAML frontmatter,Cheap models for routing; capable for code,2026-01-23,None
-->

#### Progress

- [ ] (2026-01-23) Phase 1: Custom System Prompt ~2h
  - Create `prompts/build.txt` with tool preferences and context rules
  - Update `opencode.json` to use `"prompt": "{file:./prompts/build.txt}"`
  - Move file discovery rules from AGENTS.md to system prompt
  - Move context budget rules to system prompt
  - Move security rules to system prompt
  - Test: verify tool preferences are enforced (glob never used)
  - **Session budget: ~40K tokens (small, focused)**

- [ ] (2026-01-23) Phase 2: Compaction Plugin ~4h
  - Create `opencode-aidevops-plugin/` package (TypeScript)
  - Implement `experimental.session.compacting` hook
  - Inject: tool preferences, git check trigger, context budget, security rules
  - Inject: current agent state from registry.toon (if exists)
  - Inject: guardrails from loop state (if exists)
  - Inject: relevant memories via memory-helper.sh recall
  - Test: verify rules survive compaction in long session
  - **Session budget: ~60K tokens (plugin dev + testing)**

- [ ] (2026-01-23) Phase 3: Lossless AGENTS.md Compression ~3h
  - Create `subagent-index.toon` (replaces 41-line markdown table)
  - Move pre-edit git check detail to `workflows/pre-edit.md` (keep 20-line trigger)
  - Remove duplicated content (planning, memory, quality, session sections)
  - Convert remaining markdown tables to TOON inline
  - Verify: every line removed exists in a subagent or system prompt
  - Update progressive disclosure instruction to reference index
  - Target: 778 lines → ~300 lines (~3.5K tokens)
  - **Session budget: ~50K tokens (careful restructuring)**

- [ ] (2026-01-23) Phase 4: TOON Mailbox System ~4h
  - Create `mail-helper.sh` with send|check|archive|prune|status|watch commands
  - Define message format (TOON): id, from, to, type, priority, convoy, timestamp, payload
  - Create directory structure: `~/.aidevops/.agent-workspace/mail/{inbox,outbox,archive}/`
  - Implement cleanup lifecycle: read→archive, 7-day prune, remember-before-prune
  - Create `registry.toon` format for active agent tracking
  - Test: send/receive between two terminal sessions
  - **Session budget: ~60K tokens (new script + testing)**

- [ ] (2026-01-23) Phase 5: Agent Registry & Worker Mailbox Awareness ~3h
  - Extend `worktree-sessions.sh` with agent identity (id, role, status)
  - Add mailbox check to Ralph Loop startup (read inbox before re-anchor)
  - Add status report to Ralph Loop completion (write outbox on finish)
  - Update `loop-common.sh` re-anchor to include pending messages
  - Create agent registration on worktree creation
  - Create agent deregistration on worktree cleanup
  - **Session budget: ~50K tokens (extending existing scripts)**

- [ ] (2026-01-23) Phase 6: Stateless Coordinator ~4h
  - Create `coordinator-helper.sh` (pulse script, not persistent)
  - Reads: registry.toon + outbox/*.toon + TODO.md
  - Writes: inbox/*.toon (dispatch instructions)
  - Stores: /remember (notable outcomes from worker reports)
  - Trigger: manual, cron, or fswatch on outbox/
  - Context budget per pulse: ~20K tokens (reads state, dispatches, exits)
  - Convoy grouping: bundle related beads for batch assignment
  - **Session budget: ~60K tokens (new orchestration logic)**

- [ ] (2026-01-23) Phase 7: Model Routing ~2h
  - Add `model:` field to subagent YAML frontmatter
  - Define model tiers: haiku (triage/routing), sonnet (code/review), opus (architecture)
  - Update `generate-opencode-agents.sh` to set model per agent
  - Create routing table in subagent-index.toon
  - Update coordinator to dispatch with model preference
  - **Session budget: ~30K tokens (config changes)**

- [ ] (2026-01-23) Phase 8: TUI Dashboard ~6h
  - Extend bdui or create new React/Ink TUI app
  - Display: agent registry (status, branch, last-seen)
  - Display: convoy progress (beads complete/total)
  - Display: mailbox status (unread count per agent)
  - Display: memory stats (entry count, last distill)
  - Reads: registry.toon, inbox/, outbox/, beads DB, memory.db
  - Zero AI token cost (separate process, reads files directly)
  - **Session budget: ~80K tokens (new TUI app)**

<!--TOON:milestones[8]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m064,p013,Phase 1: Custom System Prompt,2h,,2026-01-23T00:00Z,,pending
m065,p013,Phase 2: Compaction Plugin,4h,,2026-01-23T00:00Z,,pending
m066,p013,Phase 3: Lossless AGENTS.md Compression,3h,,2026-01-23T00:00Z,,pending
m067,p013,Phase 4: TOON Mailbox System,4h,,2026-01-23T00:00Z,,pending
m068,p013,Phase 5: Agent Registry & Worker Mailbox Awareness,3h,,2026-01-23T00:00Z,,pending
m069,p013,Phase 6: Stateless Coordinator,4h,,2026-01-23T00:00Z,,pending
m070,p013,Phase 7: Model Routing,2h,,2026-01-23T00:00Z,,pending
m071,p013,Phase 8: TUI Dashboard,6h,,2026-01-23T00:00Z,,pending
-->

#### Surprises & Discoveries

- **Observation:** OpenCode's `prompt` field completely replaces default system prompt
  **Evidence:** Context7 docs show `"prompt": "{file:./prompts/build.txt}"` on build agent
  **Impact:** Eliminates harness conflict entirely - our rules become highest priority
  **Date:** 2026-01-23

- **Observation:** OpenCode has `experimental.session.compacting` plugin hook
  **Evidence:** Context7 docs show output.context.push() and output.prompt replacement
  **Impact:** Critical rules can survive every compaction - solves instruction drift
  **Date:** 2026-01-23

- **Observation:** Anthropic auth plugin's `claude-code-20250219` beta flag activates Claude Code system prompt
  **Evidence:** Plugin code adds beta flag to anthropic-beta header
  **Impact:** This is root cause of tool preference conflicts (glob vs git ls-files)
  **Date:** 2026-01-23

- **Observation:** Gas Town uses same Beads ecosystem we already integrate
  **Evidence:** `.beads/` directory, `bd` CLI, convoy concept built on beads
  **Impact:** Validates our architecture; convoy is just a grouping layer on existing beads
  **Date:** 2026-01-23

<!--TOON:discoveries[4]{id,plan_id,observation,evidence,impact,date}:
disc002,p013,OpenCode prompt field replaces default system prompt,Context7 docs show file reference syntax,Eliminates harness conflict,2026-01-23
disc003,p013,OpenCode has experimental.session.compacting hook,Context7 docs show context injection,Rules survive compaction,2026-01-23
disc004,p013,Anthropic auth beta flag activates Claude Code prompt,Plugin code adds claude-code-20250219,Root cause of tool preference conflicts,2026-01-23
disc005,p013,Gas Town uses same Beads ecosystem,beads directory and bd CLI in gastown repo,Validates our architecture,2026-01-23
-->

#### Files to Create

| File | Purpose | Phase |
|------|---------|-------|
| `prompts/build.txt` | Custom system prompt (tool prefs, context budget, security) | 1 |
| `opencode-aidevops-plugin/index.ts` | Compaction hook plugin | 2 |
| `opencode-aidevops-plugin/package.json` | Plugin package manifest | 2 |
| `subagent-index.toon` | Compressed subagent discovery index | 3 |
| `workflows/pre-edit.md` | Detailed pre-edit git check (moved from AGENTS.md) | 3 |
| `scripts/mail-helper.sh` | Mailbox send/check/archive/prune/status/watch | 4 |
| `scripts/coordinator-helper.sh` | Stateless coordinator pulse script | 6 |
| TUI app (bdui extension or new) | Agent/convoy/mailbox dashboard | 8 |

#### Files to Modify

| File | Changes | Phase |
|------|---------|-------|
| `opencode.json` | Add `"prompt": "{file:./prompts/build.txt}"` to build agent | 1 |
| `AGENTS.md` | Compress to ~300 lines (pointers only, TOON tables) | 3 |
| `scripts/loop-common.sh` | Add mailbox check to re-anchor, status report on completion | 5 |
| `scripts/worktree-sessions.sh` | Add agent identity and registration | 5 |
| `scripts/ralph-loop-helper.sh` | Add mailbox awareness to worker startup/completion | 5 |
| `scripts/generate-opencode-agents.sh` | Add model routing from frontmatter | 7 |

#### User Feedback Loop (Future Phase 9+)

Once phases 1-8 are complete, the orchestration layer enables:

```text
User Feedback (email, form, GitHub issue)
    → Feedback Processor (Haiku - categorize, extract actionable items)
    → Triage Agent (Haiku - priority, route to correct domain)
    → Coordinator pulse (Sonnet - plan response, create convoy)
    → Worker(s) (Sonnet - implement fix/feature via Ralph Loop)
    → PR → Review → Merge → Deploy (Full Loop)
    → Notify user (automated via mail-helper.sh)
    → /remember outcome (Memory captures pattern for future)
```

This reuses all infrastructure from phases 1-8 and adds only an ingestion pipeline.

---

### [2026-01-25] Document Extraction Subagent & Workflow

**Status:** Planning
**Estimate:** ~3h (ai:1h test:2h)
**PRD:** [todo/tasks/prd-document-extraction.md](tasks/prd-document-extraction.md)
**Source:** [On-Premise Document Intelligence Stack](https://pub.towardsai.net/building-an-on-premise-document-intelligence-stack-with-docling-ollama-phi-4-extractthinker-6ab60b495751)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,logged,started}:
p014,Document Extraction Subagent & Workflow,planning,0,2,,document-extraction|docling|extractthinker|presidio|pii|local-llm|privacy,3h,1h,2h,2026-01-25T01:00Z,
-->

#### Purpose

Create a comprehensive document extraction capability in aidevops that:
1. Supports fully local/on-premise processing for sensitive documents (GDPR/HIPAA compliance)
2. Integrates PII detection and anonymization (Microsoft Presidio)
3. Uses advanced document parsing (Docling) for layout understanding
4. Provides LLM-powered extraction (ExtractThinker) with contract-based schemas
5. Supports multiple LLM backends (Ollama local, Cloudflare Workers AI, cloud APIs)

**Key components:**
- **Docling** (51k stars): Parse PDF, DOCX, PPTX, XLSX, HTML, images with layout understanding
- **ExtractThinker** (1.5k stars): LLM-powered extraction with Pydantic contracts
- **Presidio** (6.7k stars): PII detection and anonymization (Microsoft)
- **Local LLMs**: Ollama (Phi-4, Llama 3.x, Qwen 2.5) or Cloudflare Workers AI

**Pipeline flow:**

```text
Document → Docling (parse) → Presidio (PII scan) → ExtractThinker (extract) → Structured JSON
```

**Relationship to existing Unstract subagent:**
- Unstract = cloud/self-hosted platform with visual Prompt Studio
- This = code-first, fully local, privacy-preserving alternative
- Both can coexist - Unstract for complex workflows, this for quick local extraction

#### Context from Discussion

**Why build this:**
- Existing Unstract integration requires Docker and platform setup
- Need lightweight, code-first extraction for quick tasks
- Privacy requirements demand fully local processing option
- PII detection should happen BEFORE any cloud API calls

**Technology choices:**

| Component | Tool | Why |
|-----------|------|-----|
| Document Parsing | Docling | Best layout understanding, 51k stars, LF AI project |
| LLM Extraction | ExtractThinker | ORM-style contracts, multi-loader support |
| PII Detection | Presidio | Microsoft-backed, extensible, MIT license |
| Local LLM | Ollama | Easy setup, wide model support |
| Cloud LLM (private) | Cloudflare Workers AI | Data doesn't leave Cloudflare, no logging |

**Architecture:**

```text
tools/document-extraction/
├── document-extraction.md      # Main orchestrator subagent
├── docling.md                  # Document parsing subagent
├── extractthinker.md           # LLM extraction subagent
├── presidio.md                 # PII detection/anonymization subagent
├── local-llm.md                # Local LLM configuration subagent
└── contracts/                  # Example extraction contracts
    ├── invoice.md
    ├── receipt.md
    ├── driver-license.md
    └── contract.md

scripts/
├── document-extraction-helper.sh  # CLI wrapper
├── docling-helper.sh              # Docling operations
├── presidio-helper.sh             # PII operations
└── extractthinker-helper.sh       # Extraction operations
```

#### Progress

- [ ] (2026-01-25) Phase 1: Research & Environment Setup ~4h
  - Create Python venv at `~/.aidevops/.agent-workspace/python-env/document-extraction/`
  - Install dependencies: docling, extract-thinker, presidio-analyzer, presidio-anonymizer
  - Test basic imports and verify versions
  - Document hardware requirements and compatibility

- [ ] (2026-01-25) Phase 2: Docling Subagent ~5.5h
  - Create `tools/document-extraction/docling.md` subagent
  - Create `scripts/docling-helper.sh` with commands: parse, convert, ocr, info
  - Support formats: PDF, DOCX, PPTX, XLSX, HTML, PNG, JPEG, TIFF
  - Export to: Markdown, JSON, DocTags
  - Test with sample documents (invoice, receipt, contract)

- [ ] (2026-01-25) Phase 3: Presidio Subagent (PII) ~5.5h
  - Create `tools/document-extraction/presidio.md` subagent
  - Create `scripts/presidio-helper.sh` with commands: analyze, anonymize, deanonymize, entities
  - Support entities: names, SSN, credit cards, phone, email, addresses, etc.
  - Support operators: redact, replace, hash, encrypt, mask
  - Add custom recognizer examples for domain-specific PII
  - Test with PII-laden sample documents

- [ ] (2026-01-25) Phase 4: ExtractThinker Subagent ~7.5h
  - Create `tools/document-extraction/extractthinker.md` subagent
  - Create `scripts/extractthinker-helper.sh` with commands: extract, classify, batch
  - Create example contracts in `contracts/` folder
  - Support document loaders: DocumentLoaderDocling, DocumentLoaderPyPdf
  - Support LLM backends: Ollama, OpenAI, Anthropic, Azure
  - Implement splitting strategies: lazy, eager
  - Implement pagination for small context windows
  - Test extraction accuracy on sample documents

- [ ] (2026-01-25) Phase 5: Local LLM Subagent ~3.5h
  - Create `tools/document-extraction/local-llm.md` subagent
  - Document Ollama setup and model recommendations
  - Document Cloudflare Workers AI setup (privacy-preserving cloud)
  - Create model selection guide (text vs vision, context window, speed)
  - Test with Phi-4, Llama 3.x, Moondream (vision)

- [ ] (2026-01-25) Phase 6: Orchestrator & Main Script ~8h
  - Create `tools/document-extraction/document-extraction.md` main subagent
  - Create `scripts/document-extraction-helper.sh` with commands:
    - `extract <file> <contract>` - Full pipeline
    - `extract --local <file> <contract>` - Force local LLM
    - `extract --no-pii <file> <contract>` - Skip PII scan
    - `batch <folder> <contract>` - Batch processing
    - `pii-scan <file>` - PII detection only
    - `parse <file>` - Document parsing only
    - `models` - List available LLM backends
    - `contracts` - List available contracts
  - Implement configurable pipeline stages
  - Add progress tracking for batch operations
  - Add error handling and retry logic

- [ ] (2026-01-25) Phase 7: Integration Testing ~4h
  - Test full pipeline with various document types
  - Test PII detection accuracy (target: >98% recall)
  - Test extraction accuracy (target: >95% on invoices)
  - Test local-only mode (no network calls)
  - Test batch processing performance
  - Document known limitations

- [ ] (2026-01-25) Phase 8: Documentation & Integration ~3h
  - Update `subagent-index.toon` with new subagents
  - Add to AGENTS.md progressive disclosure table
  - Create usage examples in subagent docs
  - Document relationship with existing Unstract subagent
  - Add to setup.sh (optional Python env setup)

<!--TOON:milestones[8]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m072,p014,Phase 1: Research & Environment Setup,4h,,2026-01-25T01:00Z,,pending
m073,p014,Phase 2: Docling Subagent,5.5h,,2026-01-25T01:00Z,,pending
m074,p014,Phase 3: Presidio Subagent (PII),5.5h,,2026-01-25T01:00Z,,pending
m075,p014,Phase 4: ExtractThinker Subagent,7.5h,,2026-01-25T01:00Z,,pending
m076,p014,Phase 5: Local LLM Subagent,3.5h,,2026-01-25T01:00Z,,pending
m077,p014,Phase 6: Orchestrator & Main Script,8h,,2026-01-25T01:00Z,,pending
m078,p014,Phase 7: Integration Testing,4h,,2026-01-25T01:00Z,,pending
m079,p014,Phase 8: Documentation & Integration,3h,,2026-01-25T01:00Z,,pending
-->

#### Decision Log

- **Decision:** Create separate subagent ecosystem rather than extending Unstract
  **Rationale:** Unstract is a platform (Docker, UI, API); this is code-first for quick local extraction
  **Date:** 2026-01-25

- **Decision:** Use Docling over MarkItDown for document parsing
  **Rationale:** Docling has superior layout understanding, multi-OCR support, 51k stars, LF AI project
  **Date:** 2026-01-25

- **Decision:** Presidio for PII detection over custom regex
  **Rationale:** Microsoft-backed, extensible, supports 50+ entity types, MIT license
  **Date:** 2026-01-25

- **Decision:** ExtractThinker over direct LLM calls
  **Rationale:** ORM-style contracts, handles pagination/splitting, supports multiple loaders
  **Date:** 2026-01-25

- **Decision:** Python venv in agent-workspace rather than global install
  **Rationale:** Isolation prevents dependency conflicts; easy cleanup; reproducible
  **Date:** 2026-01-25

- **Decision:** Cloudflare Workers AI as privacy-preserving cloud option
  **Rationale:** Data processed at edge, no logging, GDPR-friendly alternative to OpenAI
  **Date:** 2026-01-25

<!--TOON:decisions[6]{id,plan_id,decision,rationale,date,impact}:
d035,p014,Create separate subagent ecosystem rather than extending Unstract,Unstract is a platform; this is code-first for quick local extraction,2026-01-25,Architecture
d036,p014,Use Docling over MarkItDown for document parsing,Superior layout understanding; 51k stars; LF AI project,2026-01-25,None
d037,p014,Presidio for PII detection over custom regex,Microsoft-backed; extensible; 50+ entity types,2026-01-25,None
d038,p014,ExtractThinker over direct LLM calls,ORM-style contracts; handles pagination/splitting,2026-01-25,None
d039,p014,Python venv in agent-workspace,Isolation prevents conflicts; easy cleanup,2026-01-25,None
d040,p014,Cloudflare Workers AI as privacy-preserving cloud,Data at edge; no logging; GDPR-friendly,2026-01-25,None
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

#### Files to Create

| File | Purpose | Phase |
|------|---------|-------|
| `tools/document-extraction/document-extraction.md` | Main orchestrator subagent | 6 |
| `tools/document-extraction/docling.md` | Document parsing subagent | 2 |
| `tools/document-extraction/extractthinker.md` | LLM extraction subagent | 4 |
| `tools/document-extraction/presidio.md` | PII detection/anonymization subagent | 3 |
| `tools/document-extraction/local-llm.md` | Local LLM configuration subagent | 5 |
| `tools/document-extraction/contracts/invoice.md` | Invoice extraction contract | 4 |
| `tools/document-extraction/contracts/receipt.md` | Receipt extraction contract | 4 |
| `tools/document-extraction/contracts/driver-license.md` | ID extraction contract | 4 |
| `tools/document-extraction/contracts/contract.md` | Legal contract extraction | 4 |
| `scripts/document-extraction-helper.sh` | Main CLI wrapper | 6 |
| `scripts/docling-helper.sh` | Docling operations | 2 |
| `scripts/presidio-helper.sh` | PII operations | 3 |
| `scripts/extractthinker-helper.sh` | Extraction operations | 4 |

#### Files to Modify

| File | Changes | Phase |
|------|---------|-------|
| `subagent-index.toon` | Add document-extraction subagents | 8 |
| `AGENTS.md` | Add to progressive disclosure table | 8 |
| `setup.sh` | Add optional Python env setup | 8 |

---

### [2026-01-31] Claude-Flow Inspirations - Selective Feature Adoption

**Status:** Planning
**Estimate:** ~3d (ai:2d test:0.5d read:0.5d)
**Source:** [ruvnet/claude-flow](https://github.com/ruvnet/claude-flow) - Analysis of v3 features

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p015,Claude-Flow Inspirations - Selective Feature Adoption,planning,0,4,,memory|embeddings|routing|optimization|learning,3d,2d,0.5d,0.5d,2026-01-31T00:00Z,
-->

#### Purpose

Selectively adopt high-value concepts from Claude-Flow v3 while maintaining aidevops' lightweight, shell-script-based philosophy. Claude-Flow is a heavy orchestration platform (~340MB, TypeScript) - we cherry-pick concepts, not implementation.

**What Claude-Flow does well:**
- HNSW vector memory (150x-12,500x faster semantic search)
- 3-tier cost-aware routing (WASM → Haiku → Opus)
- Self-learning routing (SONA neural architecture)
- Swarm consensus (Byzantine fault-tolerant coordination)

**What aidevops already has:**
- SQLite FTS5 memory (fast keyword search)
- Task tool with model parameter
- Session distillation for pattern capture
- Inter-agent mailbox (TOON-based)

**Philosophy:** Borrow concepts, keep lightweight. No 340MB dependencies.

#### Context from Discussion

**Analysis summary (2026-01-31):**

| Feature | Claude-Flow | aidevops Current | Adoption Priority |
|---------|-------------|------------------|-------------------|
| Vector memory | HNSW (semantic) | FTS5 (keyword) | Medium |
| Cost routing | 3-tier automatic | Manual model param | High |
| Self-learning | SONA neural | Manual patterns | Medium |
| Swarm consensus | Byzantine/Raft | Mailbox async | Low |
| WASM transforms | Agent Booster | N/A | Low |

**Key decisions:**
- **Vector memory**: Add optional HNSW alongside FTS5, not replace
- **Cost routing**: Add model hints to Task tool, document routing guidance
- **Self-learning**: Track success patterns in memory, surface in `/recall`
- **Swarm consensus**: Skip - aidevops philosophy is simpler async coordination
- **WASM transforms**: Skip - Edit tool is already fast enough

#### Progress

- [ ] (2026-01-31) Phase 1: Cost-Aware Model Routing ~4h
  - Document model tier guidance in `tools/context/model-routing.md`
  - Define task complexity → model mapping (simple→haiku, code→sonnet, architecture→opus)
  - Add `model:` field to subagent YAML frontmatter (extend existing)
  - Update Task tool documentation with model parameter best practices
  - Create `/route` command to suggest optimal model for a task description
  - **Deliverable:** Agents can specify preferred model tier, users get routing guidance

- [ ] (2026-01-31) Phase 2: Semantic Memory with Embeddings ~8h
  - Research lightweight embedding options (all-MiniLM-L6-v2 via ONNX, ~90MB)
  - Create `memory-embeddings-helper.sh` for vector operations
  - Add optional HNSW index to `~/.aidevops/.agent-workspace/memory/`
  - Extend `memory-helper.sh` with `--semantic` flag for similarity search
  - Keep FTS5 as default, embeddings as opt-in enhancement
  - Add `/recall --similar "query"` for semantic search
  - **Deliverable:** Semantic memory search without heavy dependencies

- [ ] (2026-01-31) Phase 3: Success Pattern Tracking ~6h
  - Extend memory types with `SUCCESS_PATTERN` and `FAILURE_PATTERN`
  - Auto-tag memories with task type, model used, outcome
  - Create `pattern-tracker-helper.sh` to analyze memory for patterns
  - Add `/patterns` command to show what works for different task types
  - Surface relevant patterns in `/recall` results
  - **Deliverable:** System learns which approaches work over time

- [ ] (2026-01-31) Phase 4: Documentation & Integration ~6h
  - Create `aidevops/claude-flow-comparison.md` documenting differences
  - Update `memory/README.md` with semantic search docs
  - Update `AGENTS.md` with model routing guidance
  - Add to `subagent-index.toon`
  - Test full workflow: store pattern → recall semantically → route optimally
  - **Deliverable:** Complete documentation, tested integration

<!--TOON:milestones[4]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m080,p015,Phase 1: Cost-Aware Model Routing,4h,,2026-01-31T00:00Z,,pending
m081,p015,Phase 2: Semantic Memory with Embeddings,8h,,2026-01-31T00:00Z,,pending
m082,p015,Phase 3: Success Pattern Tracking,6h,,2026-01-31T00:00Z,,pending
m083,p015,Phase 4: Documentation & Integration,6h,,2026-01-31T00:00Z,,pending
-->

#### Decision Log

- **Decision:** Cherry-pick concepts, not implementation
  **Rationale:** Claude-Flow is 340MB TypeScript; aidevops is lightweight shell scripts. Different philosophies.
  **Date:** 2026-01-31

- **Decision:** Keep FTS5 as default, embeddings as opt-in
  **Rationale:** FTS5 is fast, zero dependencies, works for most cases. Embeddings add ~90MB.
  **Date:** 2026-01-31

- **Decision:** Skip swarm consensus and WASM transforms
  **Rationale:** aidevops uses simpler async mailbox; Edit tool is already fast enough.
  **Date:** 2026-01-31

- **Decision:** Use all-MiniLM-L6-v2 via ONNX for embeddings
  **Rationale:** Small (~90MB), fast, no Python required, good quality for code/text.
  **Date:** 2026-01-31

<!--TOON:decisions[4]{id,plan_id,decision,rationale,date,impact}:
d035,p015,Cherry-pick concepts not implementation,Claude-Flow is 340MB TypeScript; aidevops is lightweight shell,2026-01-31,Architecture
d036,p015,Keep FTS5 as default embeddings as opt-in,FTS5 is fast zero dependencies works for most cases,2026-01-31,None
d037,p015,Skip swarm consensus and WASM transforms,aidevops uses simpler async mailbox; Edit tool fast enough,2026-01-31,None
d038,p015,Use all-MiniLM-L6-v2 via ONNX for embeddings,Small fast no Python required good quality,2026-01-31,None
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

#### Files to Create

| File | Purpose | Phase |
|------|---------|-------|
| `tools/context/model-routing.md` | Model tier guidance and routing logic | 1 |
| `scripts/commands/route.md` | `/route` command for model suggestions | 1 |
| `scripts/memory-embeddings-helper.sh` | Vector embedding operations | 2 |
| `scripts/pattern-tracker-helper.sh` | Success/failure pattern analysis | 3 |
| `scripts/commands/patterns.md` | `/patterns` command definition | 3 |
| `aidevops/claude-flow-comparison.md` | Feature comparison documentation | 4 |

#### Files to Modify

| File | Changes | Phase |
|------|---------|-------|
| Subagent YAML frontmatter | Add `model:` field where appropriate | 1 |
| `scripts/memory-helper.sh` | Add `--semantic` flag, pattern types | 2, 3 |
| `memory/README.md` | Document semantic search, patterns | 4 |
| `AGENTS.md` | Add model routing guidance | 4 |
| `subagent-index.toon` | Add new subagents | 4 |

---

### [2026-02-03] Parallel Agents & Headless Dispatch

**Status:** Planning
**Estimate:** ~3d (ai:1.5d test:1d read:0.5d)
**Source:** [alexfazio's X post on droids](https://gist.github.com/alexfazio/dcf2f253d346d8ed2702935b57184582)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p016,Parallel Agents & Headless Dispatch,planning,0,5,,agents|parallel|headless|dispatch|matrix|memory,3d,1.5d,1d,0.5d,2026-02-03T00:00Z,
-->

#### Purpose

Document and implement patterns for running parallel Claude Code sessions locally, with optional Matrix chat integration. Inspired by alexfazio's "droids" architecture but adapted for local-first, low-complexity use.

**Key insight from source:** `claude -p "prompt" --output-format stream-json` enables headless dispatch without containers or hosting costs. Each session can have its own AGENTS.md and memory namespace.

**What we're NOT doing:**
- Fly.io Sprites or cloud hosting (overkill for local use)
- Containers (unnecessary complexity for trusted code)
- New orchestration frameworks (extend existing mailbox)

**What we ARE doing:**
- Document `claude -p` headless patterns
- Create droid-helper.sh for namespaced agent dispatch
- Integrate with existing memory system (per-agent namespaces)
- Optional Matrix bot for chat-triggered dispatch
- Document model provider flexibility (any OpenAI-compatible endpoint)

#### Context from Discussion

**Complexity/Maintenance/Context Analysis:**

| Approach | Complexity | Maintenance | Context Hazard | User Attention |
|----------|------------|-------------|----------------|----------------|
| Fly.io Sprites | High | High | Low (isolated) | High (new concepts) |
| Local containers | Medium | Medium | Low (isolated) | Medium |
| Local parallel sessions | Low | Low | Medium (shared fs) | Low |
| Matrix bot + local claude | Medium | Low | Low (per-room) | Medium (initial setup) |

**Decision:** Start with local parallel sessions. Add Matrix bot if chat-triggered UX is desired. Skip containers unless isolation is required.

**Architecture:**

```text
~/.aidevops/.agent-workspace/
├── droids/
│   ├── code-reviewer/
│   │   ├── AGENTS.md      # Agent personality/instructions
│   │   └── memory.db      # Agent-specific memories (optional)
│   └── seo-analyst/
│       ├── AGENTS.md
│       └── memory.db
```

**Key patterns from source post:**
1. `claude -p --output-format stream-json` - headless dispatch
2. `--resume $session_id` - deterministic session mapping
3. Self-editing AGENTS.md - agents that improve themselves
4. Chat-triggered dispatch - reduce friction vs terminal

**Model provider flexibility:**

```bash
# Any OpenAI-compatible endpoint works
export ANTHROPIC_BASE_URL="https://your-provider/v1"
export ANTHROPIC_API_KEY="your-key"
```

Users can choose: local (ollama, llama.cpp), cloud (together.ai, openrouter, groq), or self-hosted.

#### Progress

- [ ] (2026-02-03) Phase 1: Document headless dispatch patterns ~4h
  - Create `tools/ai-assistants/headless-dispatch.md`
  - Document `claude -p` flags and streaming JSON format
  - Document session resumption with `--resume`
  - Add model provider configuration examples
- [ ] (2026-02-03) Phase 2: Create droid-helper.sh ~4h
  - Namespaced agent dispatch with per-droid AGENTS.md
  - Deterministic session IDs per droid
  - Integration with existing memory system
  - Support for parallel execution
- [ ] (2026-02-03) Phase 3: Memory namespace integration ~3h
  - Extend memory-helper.sh with `--namespace` flag
  - Per-droid memory isolation (optional)
  - Shared memory access when needed
- [ ] (2026-02-03) Phase 4: Matrix bot integration (optional) ~6h
  - Document Matrix bot setup on Cloudron
  - Create matrix-dispatch-helper.sh
  - Room-to-droid mapping
  - Message → claude -p → response flow
- [ ] (2026-02-03) Phase 5: Documentation & examples ~3h
  - Update AGENTS.md with parallel agent guidance
  - Create example droids (code-reviewer, seo-analyst)
  - Document when to use parallel vs sequential

<!--TOON:milestones[5]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m064,p016,Phase 1: Document headless dispatch patterns,4h,,2026-02-03T00:00Z,,pending
m065,p016,Phase 2: Create droid-helper.sh,4h,,2026-02-03T00:00Z,,pending
m066,p016,Phase 3: Memory namespace integration,3h,,2026-02-03T00:00Z,,pending
m067,p016,Phase 4: Matrix bot integration (optional),6h,,2026-02-03T00:00Z,,pending
m068,p016,Phase 5: Documentation & examples,3h,,2026-02-03T00:00Z,,pending
-->

#### Decision Log

- **Decision:** Local parallel sessions over containers/cloud
  **Rationale:** Zero hosting cost, shared filesystem, no sync needed, existing credentials work
  **Date:** 2026-02-03

- **Decision:** Extend existing memory system with namespaces
  **Rationale:** Reuse proven SQLite FTS5 infrastructure, avoid new dependencies
  **Date:** 2026-02-03

- **Decision:** Matrix over Discord/Slack for chat integration
  **Rationale:** Self-hosted on Cloudron, no platform risk, already in user's stack
  **Date:** 2026-02-03

- **Decision:** Document model providers generically, not specific versions
  **Rationale:** Models evolve quickly (minimax, kimi, qwen, deepseek, etc.), keep options open
  **Date:** 2026-02-03

<!--TOON:decisions[4]{id,plan_id,decision,rationale,date,impact}:
d039,p016,Local parallel sessions over containers/cloud,Zero hosting cost shared filesystem no sync needed,2026-02-03,Architecture
d040,p016,Extend existing memory system with namespaces,Reuse proven SQLite FTS5 infrastructure,2026-02-03,None
d041,p016,Matrix over Discord/Slack for chat integration,Self-hosted on Cloudron no platform risk,2026-02-03,None
d042,p016,Document model providers generically,Models evolve quickly keep options open,2026-02-03,None
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

#### Files to Create

| File | Purpose | Phase |
|------|---------|-------|
| `tools/ai-assistants/headless-dispatch.md` | Document `claude -p` patterns | 1 |
| `scripts/droid-helper.sh` | Namespaced agent dispatch | 2 |
| `scripts/matrix-dispatch-helper.sh` | Matrix bot integration | 4 |
| Example droids in `.agent-workspace/droids/` | Reference implementations | 5 |

#### Files to Modify

| File | Changes | Phase |
|------|---------|-------|
| `scripts/memory-helper.sh` | Add `--namespace` flag | 3 |
| `memory/README.md` | Document namespace feature | 3 |
| `AGENTS.md` | Add parallel agent guidance | 5 |
| `subagent-index.toon` | Add new subagents | 5 |

---

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
