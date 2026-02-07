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

### [2026-02-07] Plugin System for Private Extension Repos

**Status:** Planning
**Estimate:** ~1d (ai:6h test:3h read:3h)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p024,Plugin System for Private Extension Repos,planning,0,5,,architecture|plugins|private-repos|extensibility,1d,6h,3h,3h,2026-02-07T00:00Z,
-->

#### Purpose

Create a plugin architecture for aidevops that allows private extension repos (`aidevops-pro`, `aidevops-anon`) to overlay additional agents and scripts onto the base framework. Plugins are git repos that extend aidevops without modifying the core, enabling tiered access (public/pro/private) and fast evolution of specialized features.

#### Context from Discussion

**Repos to support:**
- `~/Git/aidevops-pro` (github.com/marcusquinn/aidevops-pro) - Pro features
- `~/Git/aidevops-anon` (gitea.marcusquinn.com/marcus/aidevops-anon) - Anonymous/private features

**Key design decisions:**

1. **Namespaced directories** - Plugins get their own namespace to avoid clashes:
   ```
   ~/.aidevops/agents/
   ├── tools/              # Main repo
   ├── pro.md              # Plugin entry point (like wordpress.md)
   ├── pro/                # Plugin subagents
   │   ├── enterprise.md
   │   └── advanced.md
   └── scripts/
       └── pro-*.sh        # Prefixed scripts
   ```

2. **Plugin structure mirrors main** - Same `.agents/` pattern:
   ```
   ~/Git/aidevops-pro/
   ├── AGENTS.md           # Points to main framework
   ├── README.md
   ├── VERSION
   ├── .aidevops.json      # Plugin config with base_repo reference
   └── .agents/
       ├── pro.md          # Main plugin agent
       ├── pro/            # Subagents
       └── scripts/
           └── pro-*.sh    # Prefixed scripts
   ```

3. **Plugin AGENTS.md points to base** - Minimal, references main framework:
   ```markdown
   # aidevops-pro Plugin
   
   For framework documentation: `~/.aidevops/agents/AGENTS.md`
   For architecture: `~/.aidevops/agents/aidevops/architecture.md`
   
   ## Plugin Development
   This plugin deploys to `~/.aidevops/agents/pro/` (namespaced).
   ```

4. **`.aidevops.json` plugin config**:
   ```json
   {
     "version": "2.93.2",
     "features": ["planning"],
     "plugin": {
       "name": "pro",
       "base_repo": "~/Git/aidevops",
       "namespace": "pro"
     }
   }
   ```

5. **`aidevops update` deploys main + plugins** - Single command updates everything

**CI/CD for private repos (simplified):**
- No SonarCloud/Codacy/CodeRabbit (require public repos for free tier)
- Local-only: `linters-local.sh` (ShellCheck, Secretlint, Markdownlint)
- Minimal GHA: ShellCheck + Secretlint + Markdownlint only
- Gitea: Local linting only (or Gitea Actions if enabled)

**Development workflow:**
- Work in plugin repo directly (`~/Git/aidevops-pro/`)
- Run `aidevops update` to redeploy all (main + plugins)
- Plugin changes immediately visible in `~/.aidevops/agents/pro/`
- AI assistant reads plugin AGENTS.md which points to main framework docs

**Symlink option for rapid iteration:**
- `.plugin-dev/` in main repo (gitignored)
- Symlinks to plugin `.agents/` directories
- Useful when testing plugin content against main repo changes

#### Decision Log

- **Decision:** Namespaced directories (`pro.md` + `pro/`) not overlay
  **Rationale:** Overlay model causes collisions if main adds same path later. Namespace guarantees no conflicts.
  **Date:** 2026-02-07

- **Decision:** Plugin AGENTS.md points to main framework, not duplicates
  **Rationale:** Single source of truth for framework docs. Plugins only document their additions.
  **Date:** 2026-02-07

- **Decision:** Minimal CI for private repos (local linting only)
  **Rationale:** SonarCloud/Codacy/CodeRabbit require public repos for free tier. ShellCheck/Secretlint/Markdownlint work locally.
  **Date:** 2026-02-07

- **Decision:** `aidevops init` detects plugin repos via `.aidevops.json` plugin field
  **Rationale:** Consistent initialization, AI assistants know it's a plugin context.
  **Date:** 2026-02-07

<!--TOON:decisions[4]{id,plan_id,decision,rationale,date,impact}:
d056,p024,Namespaced directories not overlay,Overlay causes collisions if main adds same path later,2026-02-07,Architecture
d057,p024,Plugin AGENTS.md points to main framework,Single source of truth for framework docs,2026-02-07,Maintenance
d058,p024,Minimal CI for private repos,Cloud tools require public repos for free tier,2026-02-07,DevOps
d059,p024,aidevops init detects plugin repos,Consistent initialization and AI context,2026-02-07,UX
-->

#### Open Questions

1. **License** - Same MIT for plugins, or proprietary for pro/anon?
2. **Gitea Actions** - Is it enabled on gitea.marcusquinn.com, or local-only linting?
3. **Plugin order** - If multiple plugins, what's the deploy order? (alphabetical? config-defined?)
4. **Subagent index** - Should plugins add entries to main `subagent-index.toon` or have their own?

#### Progress

- [ ] (2026-02-07) Phase 1: Add plugin support to `.aidevops.json` schema ~1h (t136.1)
  - Add `plugin` field with `name`, `base_repo`, `namespace`
  - Update `aidevops init` to detect and configure plugin repos
  - Add `features: ["plugin"]` option
- [ ] (2026-02-07) Phase 2: Add `plugins.json` config and CLI commands ~2h (t136.2)
  - Create `~/.config/aidevops/plugins.json` schema
  - Add `aidevops plugin add/list/enable/disable/remove/update` commands
  - Support GitHub and Gitea URLs
- [ ] (2026-02-07) Phase 3: Extend `setup.sh` to deploy plugins ~2h (t136.3)
  - Add `deploy_plugins()` function after `deploy_aidevops_agents()`
  - Respect namespace (deploy to `~/.aidevops/agents/{namespace}/`)
  - Handle script prefix convention (`{namespace}-*.sh`)
- [ ] (2026-02-07) Phase 4: Create plugin template ~1h (t136.4)
  - `aidevops plugin create <name>` scaffolds structure
  - Template AGENTS.md, README.md, .aidevops.json, .github/workflows/ci.yml
  - Minimal GHA (ShellCheck + Secretlint + Markdownlint)
- [ ] (2026-02-07) Phase 5: Scaffold aidevops-pro and aidevops-anon repos ~2h (t136.5)
  - Create repos on GitHub and Gitea
  - Initialize with plugin template
  - Test full workflow: clone → init → update → verify deployment

<!--TOON:milestones[5]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m109,p024,Phase 1: Add plugin support to .aidevops.json schema,1h,,2026-02-07T00:00Z,,pending
m110,p024,Phase 2: Add plugins.json config and CLI commands,2h,,2026-02-07T00:00Z,,pending
m111,p024,Phase 3: Extend setup.sh to deploy plugins,2h,,2026-02-07T00:00Z,,pending
m112,p024,Phase 4: Create plugin template,1h,,2026-02-07T00:00Z,,pending
m113,p024,Phase 5: Scaffold aidevops-pro and aidevops-anon repos,2h,,2026-02-07T00:00Z,,pending
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

### [2026-02-07] Codebase Quality Hardening

**Status:** Planning
**Estimate:** ~3d (ai:1.5d test:1d read:0.5d)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p023,Codebase Quality Hardening,planning,0,14,,quality|hardening|shell|security|testing|ci,3d,1.5d,1d,0.5d,2026-02-07T00:00Z,
-->

#### Purpose

Address findings from Claude Opus 4.6 full codebase review. Harden shell script quality, fix security issues, improve CI enforcement, and build test infrastructure. All tasks designed for autonomous `/runners` dispatch with non-destructive approach (archive, don't delete).

#### Context from Review

**Review corrections (verified against actual codebase):**
- Review claimed 168/170 scripts missing `set -e` -- actual count is **70/170** (100 already have it)
- Review claimed 17% shared-constants.sh adoption -- confirmed **29/170 scripts** source it
- Review claimed 95 scripts with blanket ShellCheck disable -- confirmed **95 scripts**
- Review claimed 12 dead fix scripts -- confirmed **12 scripts with 0 non-script references**, all only touched by `.agent->.agents` rename commit

**Rejected recommendation:**
- **#10 (organize scripts by domain subdirectories)** -- REJECTED. Scripts are intentionally cross-domain (e.g., `seo-export-helper.sh` used by SEO, git, and content workflows). Flat namespace with `{service}-helper.sh` naming convention is the design pattern. Subdirectories would create import path complexity and break existing references.

**Key design principles for all changes:**
1. Read existing code to understand intent before modifying
2. Non-destructive: archive, don't delete; preserve knowledge
3. Test for regressions after every change
4. Each subtask is self-contained for `/runners` dispatch
5. Respect existing patterns -- don't impose new conventions without understanding why current ones exist

#### Decision Log

- (2026-02-07) REJECTED script subdirectory organization -- cross-domain usage makes flat namespace correct
- (2026-02-07) Changed "remove dead scripts" to "archive non-destructively" -- scripts contain fix patterns that may be useful reference
- (2026-02-07) Corrected review's `set -e` count from 168 to 70 missing -- review overcounted significantly

#### Progress

- [ ] (2026-02-07) Phase 1 (P0-A): Add `set -euo pipefail` to 70 scripts ~4h (t135.1)
  - Audit each script for commands that intentionally return non-zero (grep no-match, diff, test)
  - Add `|| true` guards where needed before enabling strict mode
  - Add `set -euo pipefail` after shebang/shellcheck-disable line
  - Run `bash -n` syntax check + shellcheck on all modified scripts
  - Smoke test `help` command for each modified script
  - **Scripts without set -e:** 101domains-helper, add-missing-returns, agent-browser-helper, agno-setup, ampcode-cli, auto-version-bump, closte-helper, cloudron-helper, codacy-cli-chunked, codacy-cli, code-audit-helper, coderabbit-cli, coderabbit-pro-analysis, comprehensive-quality-fix, coolify-helper, crawl4ai-examples, crawl4ai-helper, dns-helper, domain-research-helper, dspy-helper, dspyground-helper, efficient-return-fix, find-missing-returns, fix-auth-headers, fix-common-strings, fix-content-type, fix-error-messages, fix-misplaced-returns, fix-remaining-literals, fix-return-statements, fix-s131-default-cases, fix-sc2155-simple, fix-shellcheck-critical, fix-string-literals, git-platforms-helper, hetzner-helper, hostinger-helper, linter-manager, localhost-helper, markdown-formatter, markdown-lint-fix, mass-fix-returns, monitor-code-review, pandoc-helper, peekaboo-helper, qlty-cli, quality-cli-manager, secretlint-helper, servers-helper, ses-helper, setup-linters-wizard, setup-local-api-keys, shared-constants, sonarscanner-cli, spaceship-helper, stagehand-helper, stagehand-python-helper, stagehand-python-setup, stagehand-setup, test-stagehand-both-integration, test-stagehand-integration, test-stagehand-python-integration, toon-helper, twilio-helper, vaultwarden-helper, version-manager, watercrawl-helper, webhosting-helper, webhosting-verify, wordpress-mcp-helper, yt-dlp-helper
- [ ] (2026-02-07) Phase 2 (P0-B): Replace blanket ShellCheck disables ~8h (t135.2)
  - Run shellcheck without blanket disable on each of 95 scripts
  - Categorize violations: genuine bugs vs intentional patterns
  - Fix SC2086 (unquoted vars) and SC2155 (declare/assign) where safe
  - Add targeted inline `# shellcheck disable=SCXXXX` with reason comments
  - Remove blanket disable line from each script
  - Verify zero violations with `linters-local.sh`
- [ ] (2026-02-07) Phase 3 (P0-C): SQLite WAL mode + busy_timeout ~2h (t135.3)
  - Read DB init in supervisor-helper.sh, memory-helper.sh, mail-helper.sh
  - Add `PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;` to init functions
  - Test concurrent access from parallel agent sessions
  - Currently: no WAL mode, no busy_timeout in any of the 3 SQLite-backed systems
- [ ] (2026-02-07) Phase 4 (P1-A): Fix corrupted JSON configs ~1h (t135.4)
  - `configs/pandoc-config.json` -- invalid control character at line 5 column 6
  - `configs/mcp-templates/chrome-devtools.json` -- shell code (`return 0`) appended after valid JSON at line 15
  - Add JSON validation step to CI workflow
- [ ] (2026-02-07) Phase 5 (P1-B): Remove tracked artifacts ~30m (t135.5)
  - `git rm --cached` 6 files: `.scannerwork/.sonar_lock`, `.scannerwork/report-task.txt`, `.playwright-cli/` (4 files)
  - Add `.playwright-cli/` to `.gitignore`
  - `.scannerwork/` already in `.gitignore` (just needs cache clearing)
- [ ] (2026-02-07) Phase 6 (P1-C): Fix CI code-quality.yml ~1h (t135.6)
  - Line 31: `.agent` typo (should be `.agents`)
  - References to non-existent `.agents/spec` and `docs/` directories
  - Add enforcement steps that actually fail the build on violations
- [ ] (2026-02-07) Phase 7 (P2-A): Eliminate eval in 4 scripts ~3h (t135.7)
  - `wp-helper.sh:240` -- `eval "$ssh_command"` (SSH command construction)
  - `coderabbit-cli.sh:322,365` -- `eval "$cmd"` (CLI command construction)
  - `codacy-cli.sh:260,315` -- `eval "$cmd"` (CLI command construction)
  - `pandoc-helper.sh:120` -- `eval "$pandoc_cmd"` (pandoc command construction)
  - Replace with array-based command construction (same pattern used in t105 for ampcode-cli.sh)
  - Read each context first to understand what's being constructed and why
- [ ] (2026-02-07) Phase 8 (P2-B): Increase shared-constants.sh adoption ~4h (t135.8)
  - Currently 29/170 scripts source shared-constants.sh (17%)
  - 431 duplicate print_info/error/success/warning definitions across scripts
  - Audit what shared-constants.sh provides vs what scripts duplicate
  - Create migration script, run in batches with regression testing
- [ ] (2026-02-07) Phase 9 (P2-C): Add trap cleanup for temp files ~1h (t135.9)
  - 14 mktemp usages in setup.sh, only 4 scripts total have trap cleanup
  - Add `trap 'rm -f "$tmpfile"' EXIT` patterns
  - Respect existing cleanup logic (don't double-cleanup)
- [ ] (2026-02-07) Phase 10 (P2-D): Fix package.json main field ~15m (t135.10)
  - `"main": "index.js"` but index.js doesn't exist
  - Determine if index.js is needed or remove main field
- [ ] (2026-02-07) Phase 11 (P2-E): Fix Homebrew formula ~2h (t135.11)
  - Frozen at v2.52.1 with `PLACEHOLDER_SHA256`
  - Current version is v2.104.0
  - Add formula version/SHA update to version-manager.sh release workflow
- [ ] (2026-02-07) Phase 12 (P3-A): Archive fix scripts non-destructively ~1h (t135.12)
  - 12 scripts with 0 references outside scripts/: add-missing-returns, comprehensive-quality-fix, efficient-return-fix, find-missing-returns, fix-common-strings, fix-misplaced-returns, fix-remaining-literals, fix-return-statements, fix-sc2155-simple, fix-shellcheck-critical, fix-string-literals, mass-fix-returns
  - All only touched by `.agent->.agents` rename commit (c91e0be)
  - Read each to document purpose and patterns (preserve knowledge)
  - Create `.agents/scripts/_archive/` with README (underscore prefix sorts to top of file lists)
  - Move (not delete) so git history and fix patterns are preserved
- [ ] (2026-02-07) Phase 13 (P3-B): Build test suite ~4h (t135.13)
  - Fix `tests/docker/run-tests.sh:5` path case (`git` vs `Git`)
  - Add help command smoke tests for all 170 scripts
  - Add unit tests for supervisor-helper.sh state machine
  - Add unit tests for memory-helper.sh and mail-helper.sh
- [ ] (2026-02-07) Phase 14 (P3-C): Standardize shebangs ~30m (t135.14)
  - Most use `#!/bin/bash`, supervisor-helper.sh uses `#!/usr/bin/env bash`
  - Standardize all to `#!/usr/bin/env bash` for portability

### [2026-02-06] Cross-Provider Model Routing with Fallbacks

**Status:** Planning
**Estimate:** ~1.5d (ai:8h test:4h read:2h)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p022,Cross-Provider Model Routing with Fallbacks,planning,0,8,,orchestration|multi-model|routing|fallback|opencode,1.5d,8h,4h,2h,2026-02-06T22:00Z,
-->

#### Purpose

Enable cross-provider model routing so that any aidevops session can dispatch tasks to the optimal model regardless of which provider the parent session runs on. A Claude session should be able to request a Gemini code review; a Gemini session should be able to escalate complex reasoning to Claude Opus. Models should fall back gracefully when unavailable, and the system should detect when provider/model names change upstream.

#### Context from Discussion

**Current state:**
- `model-routing.md` exists as a design doc with 5 tiers (haiku/flash/sonnet/pro/opus) and routing rules
- All 195 subagents have `model:` in YAML frontmatter, but it's advisory only
- `runner-helper.sh` supports `--model` but hardcodes `DEFAULT_MODEL` to a single Claude model
- No fallback, no availability checking, no quality-based escalation

**Key discovery (Context7 research):**
- OpenCode already supports per-agent model selection natively across 75+ providers
- The Task tool does NOT accept a model parameter -- by design
- Instead, each subagent definition in `opencode.json` can specify its own `model:` field
- The primary agent selects a model by choosing WHICH subagent to invoke
- Provider-level fallback is available via gateway providers (OpenRouter `allow_fallbacks`, Vercel AI Gateway `order`)
- No application-level automatic fallback exists in OpenCode itself

**Implication:** We don't need to patch the Task tool. We need to:
1. Define model-specific subagents in opencode.json (e.g., `gemini-reviewer`, `claude-auditor`)
2. Map our tier system to concrete agent definitions
3. Build fallback/escalation logic in supervisor-helper.sh
4. Periodically reconcile our model registry against upstream provider changes

#### Progress

- [ ] (2026-02-06) Phase 1: Define model-specific subagents in opencode.json ~2h (t132.1)
  - Create subagent definitions: gemini-reviewer, gemini-analyst, gpt-reviewer, claude-auditor, etc.
  - Map model-routing.md tiers to concrete agent definitions
  - Each agent gets appropriate tool permissions and instructions
  - Test cross-provider dispatch from Claude session to Gemini subagent
- [ ] (2026-02-06) Phase 2: Provider/model registry with periodic sync ~2h (t132.2)
  - Create model-registry-helper.sh
  - Scrape available models from OpenCode config / Models.dev / provider APIs
  - Compare against configured models in opencode.json and model-routing.md
  - Flag deprecated/renamed/unavailable models
  - Suggest new models worth adding (e.g., new Gemini/Claude/GPT releases)
  - Run on `aidevops update` and optionally via cron
  - Store registry in SQLite alongside memory/mail DBs
- [ ] (2026-02-06) Phase 3: Model availability checker ~2h (t132.3)
  - Probe provider endpoints before dispatch (lightweight health check)
  - Check API key validity, rate limits, model availability
  - Support: Anthropic, Google, OpenAI, local (Ollama)
  - Return latency estimate, cache results with short TTL
  - Integrate with registry (skip probing models already flagged unavailable)
- [ ] (2026-02-06) Phase 4: Fallback chain configuration ~2h (t132.4)
  - Define fallback chains: gemini-3-pro -> gemini-2.5-pro -> claude-sonnet-4 -> claude-haiku
  - Configurable per subagent (frontmatter `fallback:` field), per runner, and global default
  - Triggers: API error, timeout, rate limit, empty/malformed response
  - Gateway-level fallback via OpenRouter/Vercel for provider failures
  - Supervisor-level fallback via re-dispatch to different subagent for task failures
- [ ] (2026-02-06) Phase 5: Supervisor model resolution ~2h (t132.5)
  - supervisor-helper.sh reads `model:` from subagent frontmatter
  - Maps tier names to corresponding subagent definitions in opencode.json
  - Uses availability checker before dispatch
  - Falls back through chain by re-dispatching to different model-specific subagent
- [ ] (2026-02-06) Phase 6: Quality gate with model escalation ~3h (t132.6)
  - After task completion, evaluate output quality (heuristic + AI eval)
  - If unsatisfactory, re-dispatch to next tier up via higher-tier subagent
  - Criteria: empty output, error patterns, token-to-substance ratio, user-defined checks
  - Max escalation depth configurable (default: 2 levels)
- [ ] (2026-02-06) Phase 7: Runner and cron-helper multi-provider support ~2h (t132.7)
  - Extend --model flag to accept tier names (not just provider/model strings)
  - Add --provider flag for explicit provider selection
  - Support Gemini CLI, OpenCode server, Claude CLI as dispatch backends
  - Auto-detect available backends at startup
- [ ] (2026-02-06) Phase 8: Cross-model review workflow ~2h (t132.8)
  - Second-opinion pattern: dispatch same task to multiple models
  - Collect results, merge/diff findings
  - Use cases: code review, security audit, architecture review
  - Configurable via `review-models:` in task metadata or CLI flag

<!--TOON:milestones[8]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m101,p022,Phase 1: Define model-specific subagents in opencode.json,2h,,2026-02-06T22:00Z,,pending
m102,p022,Phase 2: Provider/model registry with periodic sync,2h,,2026-02-06T22:00Z,,pending
m103,p022,Phase 3: Model availability checker,2h,,2026-02-06T22:00Z,,pending
m104,p022,Phase 4: Fallback chain configuration,2h,,2026-02-06T22:00Z,,pending
m105,p022,Phase 5: Supervisor model resolution,2h,,2026-02-06T22:00Z,,pending
m106,p022,Phase 6: Quality gate with model escalation,3h,,2026-02-06T22:00Z,,pending
m107,p022,Phase 7: Runner and cron-helper multi-provider support,2h,,2026-02-06T22:00Z,,pending
m108,p022,Phase 8: Cross-model review workflow,2h,,2026-02-06T22:00Z,,pending
-->

#### Decision Log

- **Decision:** Use OpenCode per-agent model selection, not Task tool model parameter
  **Rationale:** OpenCode's architecture routes models via agent definitions, not per-call parameters. The Task tool selects a model by invoking a subagent that has that model configured. This is by design and works across 75+ providers.
  **Date:** 2026-02-06

- **Decision:** Periodic model registry sync rather than static configuration
  **Rationale:** Provider/model names are a moving target -- models get renamed (e.g., gemini-2.0-flash-001 -> gemini-2.0-flash), deprecated, or replaced by new versions. A registry that periodically reconciles against upstream prevents silent dispatch failures.
  **Date:** 2026-02-06

- **Decision:** Two-layer fallback (gateway + supervisor)
  **Rationale:** Gateway-level fallback (OpenRouter/Vercel) handles provider outages transparently. Supervisor-level fallback handles task-quality failures by re-dispatching to a different model-specific subagent. Neither layer alone covers both failure modes.
  **Date:** 2026-02-06

<!--TOON:decisions[3]{id,plan_id,decision,rationale,date,impact}:
d053,p022,Use OpenCode per-agent model selection not Task tool param,Architecture routes models via agent definitions across 75+ providers,2026-02-06,Architecture
d054,p022,Periodic model registry sync,Provider/model names change -- prevents silent dispatch failures,2026-02-06,Reliability
d055,p022,Two-layer fallback gateway + supervisor,Gateway handles provider outages and supervisor handles task-quality failures,2026-02-06,Architecture
-->

#### Surprises & Discoveries

- **Discovery:** OpenCode per-agent model selection already works but we never configured it
  **Evidence:** Context7 research confirmed `model:` field in agent JSON config is a first-class feature. Our opencode.json has no model fields on any agent definition despite having 12+ agents configured.
  **Impact:** Phase 1 is immediately actionable -- no upstream changes needed.
  **Date:** 2026-02-06

- **Discovery:** Duplicate TOON milestone IDs (m095-097) between p019 and p021
  **Evidence:** Both Voice Integration Pipeline (p019) and gopass Integration (p021) use m095-097.
  **Impact:** Need to renumber p021 milestones in a future cleanup. Using m101+ for this plan.
  **Date:** 2026-02-06

<!--TOON:discoveries[2]{id,plan_id,observation,evidence,impact,date}:
s015,p022,OpenCode per-agent model selection already works but unconfigured,Context7 confirmed model field is first-class feature,Phase 1 immediately actionable,2026-02-06
s016,p022,Duplicate TOON milestone IDs m095-097 between p019 and p021,Both plans use same IDs,Need renumbering cleanup,2026-02-06
-->

### [2026-02-06] gopass Integration & Credentials Rename

**Status:** Planning
**Estimate:** ~2d (ai:1d test:4h read:4h)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p021,gopass Integration & Credentials Rename,planning,0,3,,security|credentials|gopass|rename,2d,1d,4h,4h,2026-02-06T20:00Z,
-->

#### Purpose

Replace plaintext `mcp-env.sh` credential storage with gopass (GPG-encrypted, git-versioned, team-shareable). Build an AI-native wrapper (`aidevops secret`) that keeps secret values out of agent context windows via subprocess injection and output redaction. Rename `mcp-env.sh` to `credentials.sh` across the entire codebase for accuracy.

#### Context from Discussion

Evaluated 5 tools: gopass (6.7k stars, 8+ years, GPG/age, team-ready), psst (61 stars, AI-native but v0.3.0), mcp-secrets-vault (4 stars, env var wrapper), rsec (7 stars, cloud vaults only), cross-keychain (library, not CLI). gopass selected as primary for maturity, zero runtime deps, team sharing, and ecosystem (browser integration, git credentials, Kubernetes, Terraform). psst documented as alternative for solo devs who prefer simpler UX.

Key design decisions:
- gopass as encrypted backend, thin shell wrapper for AI-native features (subprocess injection + output redaction)
- Rename mcp-env.sh to credentials.sh (83 files, 261 references) with backward-compatible symlink
- credentials.sh kept as fallback for MCP server launching and non-gopass workflows
- Agent instructions mandate: never accept secrets in conversation context

#### Progress

- [ ] (2026-02-06) Part A: Rename mcp-env.sh to credentials.sh ~4.5h
  - 7 scripts: variable rename `MCP_ENV_FILE` to `CREDENTIALS_FILE`
  - ~18 scripts: path string updates
  - ~65 docs: path reference updates
  - setup.sh: migration logic + symlink
  - Verification: `rg 'mcp-env'` returns 0
- [ ] (2026-02-06) Part B: gopass integration + aidevops secret wrapper ~6h
  - gopass.md subagent documentation
  - secret-helper.sh (init, set, list, run, import-credentials)
  - Output redaction function
  - credential-helper.sh gopass detection
  - setup.sh gopass installation
  - api-keys tool update
- [ ] (2026-02-06) Part C: Agent instructions + documentation ~2h
  - AGENTS.md: mandatory "never accept secrets in context" rule
  - psst.md: documented alternative
  - Security docs update
  - Onboarding update

<!--TOON:milestones[3]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m095,p021,Part A: Rename mcp-env.sh to credentials.sh,4.5h,,2026-02-06T20:00Z,,pending
m096,p021,Part B: gopass integration + aidevops secret wrapper,6h,,2026-02-06T20:00Z,,pending
m097,p021,Part C: Agent instructions + documentation,2h,,2026-02-06T20:00Z,,pending
-->

#### Decision Log

- **Decision:** gopass over psst as primary secrets backend
  **Rationale:** 6.7k stars, 224 contributors, GPG/age encryption (audited), git-versioned, team-shareable, single Go binary (zero runtime deps), 8+ years production use. psst is v0.3.0 with 61 stars, Bun dependency, no team features, custom unaudited AES-256-GCM.
  **Date:** 2026-02-06

- **Decision:** Rename mcp-env.sh to credentials.sh
  **Rationale:** File stores credentials for agents, scripts, skills, MCP servers, and CLI tools -- not just MCP environment variables. "credentials.sh" is accurate and tool-agnostic.
  **Date:** 2026-02-06

- **Decision:** Keep credentials.sh as fallback alongside gopass
  **Rationale:** MCP server configs need env vars at launch time (can't wrap in subprocess). credentials.sh remains the backward-compatible bridge.
  **Date:** 2026-02-06

- **Decision:** Build thin shell wrapper, not fork psst
  **Rationale:** The AI-native gap (subprocess injection + output redaction) is ~50 lines of shell on top of gopass. The hard part (encryption, key management, team sharing, auditing) is what gopass already does.
  **Date:** 2026-02-06

<!--TOON:decisions[4]{id,plan_id,decision,rationale,date,impact}:
d028,p021,gopass over psst as primary,Mature GPG encryption + team sharing + zero deps vs immature AI-native tool,2026-02-06,high
d029,p021,Rename mcp-env.sh to credentials.sh,File stores credentials for all tools not just MCP,2026-02-06,medium
d030,p021,Keep credentials.sh as fallback,MCP server configs need env vars at launch time,2026-02-06,medium
d031,p021,Build thin shell wrapper not fork psst,AI-native gap is ~50 lines of shell on top of gopass,2026-02-06,high
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

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
- `.agents/scripts/qlty-cli.sh`
- `.agents/scripts/coderabbit-cli.sh`
- `.agents/scripts/dev-browser-helper.sh`

#### Progress

- [ ] (2026-02-03) Phase 1: Inventory all `curl|sh` usages and vendor verification options ~45m
- [ ] (2026-02-03) Phase 2: Replace with download → verify → execute flow ~2h
- [ ] (2026-02-03) Phase 3: Add fallback behavior and clear error messages ~45m
- [ ] (2026-02-03) Phase 4: Update docs/tests and verify behavior ~30m

<!--TOON:milestones[4]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m084,p016,Phase 1: Inventory curl|sh usages and verification options,45m,,2026-02-03T00:00Z,,pending
m085,p016,Phase 2: Replace with download-verify-execute flow,2h,,2026-02-03T00:00Z,,pending
m086,p016,Phase 3: Add fallback behavior and error messages,45m,,2026-02-03T00:00Z,,pending
m087,p016,Phase 4: Update docs/tests and verify behavior,30m,,2026-02-03T00:00Z,,pending
-->

#### Decision Log

(To be populated during implementation)

<!--TOON:decisions[0]{id,plan_id,decision,rationale,date,impact}:
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

### [2026-02-06] Autonomous Supervisor Loop

**Status:** Planning
**Estimate:** ~8h (ai:5h test:2h read:1h)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p018,Autonomous Supervisor Loop,planning,0,7,,orchestration|runners|autonomy,8h,5h,2h,1h,2026-02-06T04:00Z,
-->

#### Purpose

Build a stateless supervisor pulse that manages long-running parallel objectives from dispatch through completion. Ties together existing components (runners, worktrees, mail, memory, full-loop, cron, Matrix) into an autonomous system that evaluates outcomes, retries failures, escalates blockers, and learns from mistakes. Token-efficient: supervisor is bash + SQLite, AI only invoked for worker execution and ambiguous outcome evaluation.

#### Context from Discussion

Discovered during Tabby tab dispatch experiments that aidevops has all the worker components but no supervisor loop. The gap: nothing evaluates whether a dispatched task succeeded, retries on failure, or updates TODO.md on completion. This is the "brain stem" connecting the existing "limbs."

Key design decisions:
- Supervisor is stateless bash pulse (not a long-running AI session) for token efficiency
- State lives in SQLite (supervisor.db), not in-memory
- Workers are opencode run in isolated worktrees
- Evaluation uses cheap model (Sonnet) for ambiguous outcomes
- Cron-triggered (*/5 min) or fswatch on TODO.md

#### Progress

- [ ] (2026-02-06) Phase 1: SQLite schema and state machine (t128.1) ~1h
- [ ] (2026-02-06) Phase 2: Worker dispatch with worktree isolation (t128.2) ~1.5h
- [ ] (2026-02-06) Phase 3: Outcome evaluation and re-prompt cycle (t128.3) ~2h
- [ ] (2026-02-06) Phase 4: TODO.md auto-update on completion/failure (t128.4) ~1h
- [ ] (2026-02-06) Phase 5: Cron integration and auto-pickup (t128.5) ~30m
- [ ] (2026-02-06) Phase 6: Memory and self-assessment (t128.6) ~1h
- [ ] (2026-02-06) Phase 7: Integration test with t083-t094 batch (t128.7) ~1h

<!--TOON:milestones[7]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m088,p018,Phase 1: SQLite schema and state machine,1h,,2026-02-06T04:00Z,,pending
m089,p018,Phase 2: Worker dispatch with worktree isolation,1.5h,,2026-02-06T04:00Z,,pending
m090,p018,Phase 3: Outcome evaluation and re-prompt cycle,2h,,2026-02-06T04:00Z,,pending
m091,p018,Phase 4: TODO.md auto-update on completion/failure,1h,,2026-02-06T04:00Z,,pending
m092,p018,Phase 5: Cron integration and auto-pickup,30m,,2026-02-06T04:00Z,,pending
m093,p018,Phase 6: Memory and self-assessment,1h,,2026-02-06T04:00Z,,pending
m094,p018,Phase 7: Integration test with t083-t094 batch,1h,,2026-02-06T04:00Z,,pending
-->

#### Decision Log

- D1: Supervisor is bash + SQLite, not an AI session. Rationale: token efficiency - orchestration logic is deterministic, AI only needed for evaluation. (2026-02-06)
- D2: Workers use opencode run --format json, not TUI. Rationale: parseable output for outcome classification. Tabby visual mode is optional overlay. (2026-02-06)
- D3: Evaluation uses Sonnet, not Opus. Rationale: outcome classification is a simple task, ~5K tokens max. (2026-02-06)

<!--TOON:decisions[3]{id,plan_id,decision,rationale,date,impact}:
d018,p018,Supervisor is bash+SQLite not AI session,Token efficiency - orchestration is deterministic,2026-02-06,high
d019,p018,Workers use opencode run --format json,Parseable output for outcome classification,2026-02-06,high
d020,p018,Evaluation uses Sonnet not Opus,Outcome classification is simple ~5K tokens,2026-02-06,medium
-->

#### Surprises & Discoveries

- S1: opencode supports --prompt flag for TUI seeding and --session --continue for re-prompting existing sessions. Both confirmed working. (2026-02-06)
- S2: Tabby CLI supports `Tabby run <script>` and `Tabby profile <name>` but doesn't hot-reload config changes. (2026-02-06)
- S3: opencode run --format json streams structured events (step_start, text, tool_call, step_finish) with session IDs, enabling programmatic monitoring. (2026-02-06)

<!--TOON:discoveries[3]{id,plan_id,observation,evidence,impact,date}:
s018,p018,opencode --prompt and --session --continue both work,Tested in Tabby dispatch experiments,high,2026-02-06
s019,p018,Tabby CLI doesn't hot-reload config,New profiles not visible until restart,low,2026-02-06
s020,p018,opencode run --format json streams structured events,Captured step_start/text/step_finish with session IDs,high,2026-02-06
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
m088,p017,Phase 1: Trace token flow and storage paths,45m,,2026-02-03T00:00Z,,pending
m089,p017,Phase 2: Migrate to session/memory storage and update auth flow,1.5h,,2026-02-03T00:00Z,,pending
m090,p017,Phase 3: Add reset/clear UI flow and verify behavior,45m,,2026-02-03T00:00Z,,pending
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
**Architecture:** [.agents/build-mcp/aidevops-plugin.md](../.agents/build-mcp/aidevops-plugin.md)

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

<!--TOON:active_plans[15]{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p021,gopass Integration & Credentials Rename,planning,0,3,,security|credentials|gopass|rename,2d,1d,4h,4h,2026-02-06T20:00Z,
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
p018,MCP Auto-Installation in setup.sh,planning,0,4,,mcp|setup|installation,4h,2h,1h,1h,2026-02-05T03:00Z,
p019,Voice Integration Pipeline,planning,0,6,,voice|ai|pipecat|transcription|tts|stt|local|api,3d,1.5d,1d,0.5d,2026-02-05T00:00Z,
p020,SEO Tool Subagents Sprint,planning,0,3,,seo|tools|subagents|sprint,1.5d,1d,4h,2h,2026-02-05T00:00Z,
-->

### [2026-02-05] MCP Auto-Installation in setup.sh

**Status:** Planning
**Estimate:** ~4h (ai:2h test:1h read:1h)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p018,MCP Auto-Installation in setup.sh,planning,0,4,,mcp|setup|installation,4h,2h,1h,1h,2026-02-05T03:00Z,
-->

#### Purpose

Add automatic MCP installation/configuration to setup.sh so users get working MCPs out of the box. Currently many MCPs are configured but not installed, leading to "Disabled" status.

#### Context from Discussion

**MCP Categories:**

| Category | MCPs | Install Method | Auth |
|----------|------|----------------|------|
| **Remote (no install)** | context7, socket | Just enable | No |
| **Bun packages** | chrome-devtools, gsc | `bun install -g` | gsc needs OAuth |
| **Brew packages** | localwp | `brew install` | Needs Local WP app |
| **Docker** | MCP_DOCKER | Docker Desktop | No |
| **NPX** | sentry | `npx @sentry/mcp-server` | Access token |
| **NPM + Auth** | augment-context-engine | `npm install -g @augmentcode/auggie` | `auggie login` |
| **Custom** | amazon-order-history | Git clone + build | Amazon auth |

**Priority Order:**
1. Remote MCPs (context7, socket) - just enable, no install
2. Simple packages (chrome-devtools) - auto-install
3. Auth-required (gsc, sentry) - install + guide user to auth
4. App-dependent (localwp, MCP_DOCKER) - check prereqs, guide setup
5. Complex (augment, amazon) - document manual setup

#### Progress

- [ ] (2026-02-05) Phase 1: Enable remote MCPs (context7, socket) ~30m
  - Add to opencode.json with `enabled: true`
  - No installation needed
- [ ] (2026-02-05) Phase 2: Auto-install simple MCPs ~1h
  - chrome-devtools: `bun install -g chrome-devtools-mcp`
  - Add setup functions to setup.sh
- [ ] (2026-02-05) Phase 3: Auth-required MCPs ~1.5h
  - gsc: Install + OAuth setup guide
  - sentry: Install + token prompt
  - localwp: Check Local WP app, install MCP
  - MCP_DOCKER: Check Docker Desktop
- [ ] (2026-02-05) Phase 4: Documentation ~1h
  - Update subagent docs with install status
  - Add troubleshooting for common issues

<!--TOON:milestones[4]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m091,p018,Phase 1: Enable remote MCPs (context7 socket),30m,,2026-02-05T03:00Z,,pending
m092,p018,Phase 2: Auto-install simple MCPs (chrome-devtools),1h,,2026-02-05T03:00Z,,pending
m093,p018,Phase 3: Auth-required MCPs (gsc sentry localwp MCP_DOCKER),1.5h,,2026-02-05T03:00Z,,pending
m094,p018,Phase 4: Documentation updates,1h,,2026-02-05T03:00Z,,pending
-->

#### Decision Log

- **Decision:** Remote MCPs (context7, socket) should be enabled by default
  **Rationale:** No installation needed, free services, useful for all users
  **Date:** 2026-02-05

- **Decision:** Auth-required MCPs get installed but disabled until auth configured
  **Rationale:** Reduces friction; user can enable after setting up credentials
  **Date:** 2026-02-05

<!--TOON:decisions[2]{id,plan_id,decision,rationale,date,impact}:
d026,p018,Remote MCPs enabled by default,No install needed; free services; useful for all,2026-02-05,None
d027,p018,Auth-required MCPs installed but disabled,Reduces friction; enable after credentials,2026-02-05,None
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
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
| Medium | YAML frontmatter in source subagents | ~2h | Add frontmatter to all `.agents/**/*.md` for better progressive disclosure |
| Medium | Automatic session reflection | ~4h | Auto-distill sessions to memory on completion |
| Low | Cache-aware prompt structure | ~1h | Document stable-prefix patterns for better cache hits |
| Low | Tool description indexing | ~3h | Cursor-style MCP description sync for on-demand retrieval |
| Low | Memory consolidation | ~2h | Periodic reflection over memories to merge/prune |

#### Progress

- [ ] (2025-01-11) Phase 1: Add YAML frontmatter to source subagents ~2h
  - Add `description`, `triggers`, `tools` to all `.agents/**/*.md` files
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

**Problem:** Many people are creating and sharing Claude Code skills, OpenCode skills, and other AI assistant configurations. aidevops has its own superior `.agents/` folder structure. We need to rapidly import external skills, convert to aidevops format, handle conflicts intelligently, and track upstream for updates.

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
- Source of truth: `.agents/` (aidevops format)
- `setup.sh` generates symlinks to `~/.config/opencode/skills/`, `~/.codex/skills/`, `~/.claude/skills/`, `~/.config/amp/tools/`
- Nesting: Simple skills → single .md file; Complex skills → folder with subagents
- Tracking: `skill-sources.json` with upstream URL, version, last-checked

#### Progress

- [ ] (2026-01-21) Phase 1: Create skill-sources.json schema and registry ~2h
  - Define JSON schema for tracking upstream skills
  - Add existing humanise.md as first tracked skill
  - Create `.agents/configs/skill-sources.json`
- [ ] (2026-01-21) Phase 2: Create add-skill-helper.sh ~4h
  - Fetch via `npx skills add` or direct GitHub
  - Detect format (SKILL.md, AGENTS.md, .cursorrules, raw)
  - Extract metadata, instructions, resources
  - Check for conflicts with existing .agents/ files
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
  **Rationale:** Single source of truth; updates to .agents/ automatically reflected
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
| `.agents/configs/skill-sources.json` | Registry of imported skills with upstream tracking |
| `.agents/scripts/add-skill-helper.sh` | Fetch, analyse, convert, merge skills |
| `.agents/scripts/skill-update-helper.sh` | Check all tracked skills for updates |
| `.agents/scripts/commands/add-skill.md` | `/add-skill` command definition |
| `.agents/tools/build-agent/add-skill.md` | Subagent with conversion/merge logic |

#### Files to Update

| File | Changes |
|------|---------|
| `setup.sh` | Generate symlinks to all AI assistant skill locations |
| `generate-skills.sh` | Create SKILL.md stubs pointing to .agents/ source |
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
p011,Memory Auto-Capture,completed,5,5,,memory|automation|context,1d,6h,4h,2h,2026-01-11T12:00Z,2026-02-06T01:30Z
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

- [x] (2026-01-11) Phase 1: Research & Design ~2h actual:0h completed:2026-02-06
  - Capture triggers defined in AGENTS.md "Proactive Memory Triggers" (t052)
  - 11 memory types classified in memory-helper.sh
  - Privacy patterns documented; privacy-filter-helper.sh created (t117)
- [x] (2026-01-11) Phase 2: memory-helper.sh updates ~3.5h actual:30m completed:2026-02-06
  - Added `--auto`/`--auto-captured` flag to store command
  - Deduplication via `consolidate` command (t057)
  - Auto-capture statistics in `stats` output
  - `--auto-only`/`--manual-only` recall filters
  - `log` command for auto-capture review
  - DB migration adds `auto_captured` column to `learning_access`
- [x] (2026-01-11) Phase 3: AGENTS.md instructions ~2h actual:0h completed:2026-02-06
  - Proactive Memory Triggers section added (t052/198b5a8)
  - Auto-capture with --auto flag documented
  - Privacy exclusion patterns documented
- [x] (2026-01-11) Phase 4: /memory-log command ~2h actual:15m completed:2026-02-06
  - Created `scripts/commands/memory-log.md`
  - Shows recent auto-captures with filtering
  - Prune command already existed in memory-helper.sh
- [x] (2026-01-11) Phase 5: Privacy filters ~2.5h actual:15m completed:2026-02-06
  - `<private>` tag stripping in memory-helper.sh store
  - Secret pattern rejection (API keys, tokens, AWS keys, GitHub tokens)
  - privacy-filter-helper.sh available for comprehensive scanning (t117)

<!--TOON:milestones[5]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m053,p011,Phase 1: Research & Design,2h,0h,2026-01-11T12:00Z,2026-02-06,completed
m054,p011,Phase 2: memory-helper.sh updates,3.5h,30m,2026-01-11T12:00Z,2026-02-06,completed
m055,p011,Phase 3: AGENTS.md instructions,2h,0h,2026-01-11T12:00Z,2026-02-06,completed
m056,p011,Phase 4: /memory-log command,2h,15m,2026-01-11T12:00Z,2026-02-06,completed
m057,p011,Phase 5: Privacy filters,2.5h,15m,2026-01-11T12:00Z,2026-02-06,completed
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

**Status:** In Progress (Phase 4/5)
**Estimate:** ~3d (ai:1.5d test:1d read:0.5d)
**Source:** [alexfazio's X post on droids](https://gist.github.com/alexfazio/dcf2f253d346d8ed2702935b57184582)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p016,Parallel Agents & Headless Dispatch,in_progress,4,5,,agents|parallel|headless|dispatch|runners|memory,3d,1.5d,1d,0.5d,2026-02-03T00:00Z,2026-02-05T00:00Z
-->

#### Purpose

Document and implement patterns for running parallel OpenCode sessions locally, with optional Matrix chat integration. Inspired by alexfazio's "droids" architecture but adapted for local-first, low-complexity use.

**Naming decision:** Renamed from "droids" to "runners" to avoid conflict with Factory.ai's branded "Droids" product. "Runner" maps to the CI/CD mental model (named execution environments that pick up tasks).

**Key insight from source:** `opencode run "prompt"` enables headless dispatch without containers or hosting costs. `opencode run --attach` connects to a warm server for faster dispatch. Each session can have its own AGENTS.md and memory namespace.

**What we're NOT doing:**
- Fly.io Sprites or cloud hosting (overkill for local use)
- Containers (unnecessary complexity for trusted code)
- New orchestration frameworks (extend existing mailbox)

**What we ARE doing:**
- Document `opencode run` headless patterns and `opencode serve` server mode
- Create runner-helper.sh for namespaced agent dispatch
- Integrate with existing memory system (per-runner namespaces)
- Optional Matrix bot for chat-triggered dispatch
- Document model provider flexibility (any provider via `opencode auth login`)

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
├── runners/
│   ├── code-reviewer/
│   │   ├── AGENTS.md      # Runner personality/instructions
│   │   ├── config.json    # Runner configuration
│   │   ├── session.id     # Last session ID (for --continue)
│   │   └── runs/          # Run logs
│   └── seo-analyst/
│       ├── AGENTS.md
│       ├── config.json
│       └── runs/
```

**Key patterns from source post (adapted for OpenCode):**
1. `opencode run "prompt"` - headless dispatch
2. `opencode run --attach http://localhost:4096` - warm server dispatch
3. `opencode run -s $session_id` - session resumption
4. `opencode serve` - persistent server for parallel sessions
5. Self-editing AGENTS.md - agents that improve themselves
6. Chat-triggered dispatch - reduce friction vs terminal

**Model provider flexibility:**

```bash
# Configure via opencode auth login (interactive)
opencode auth login

# Or override per-dispatch
opencode run -m openrouter/anthropic/claude-sonnet-4-20250514 "task"
```

Users can choose any provider supported by OpenCode via `opencode auth login`.

#### Progress

- [x] (2026-02-05) Phase 1: Document headless dispatch patterns ~4h
  - Created `tools/ai-assistants/headless-dispatch.md`
  - Documented `opencode run` flags and `--format json` output
  - Documented session resumption with `-s` and `-c`
  - Documented `opencode serve` + `--attach` warm server pattern
  - Added SDK parallel dispatch examples
  - Added CI/CD integration (GitHub Actions)
- [x] (2026-02-05) Phase 2: Create runner-helper.sh ~4h
  - Namespaced agent dispatch with per-runner AGENTS.md
  - Commands: create, run, status, list, edit, logs, stop, destroy
  - Integration with `opencode run --attach` for warm server dispatch
  - Run logging and metadata tracking
- [x] (2026-02-05) Phase 3: Memory namespace integration ~3h
  - Added `--namespace/-n` flag to memory-helper.sh and memory-embeddings-helper.sh
  - Per-runner isolated DBs at `memory/namespaces/<name>/memory.db`
  - `--shared` flag on recall searches both namespace and global
  - `namespaces` command (list/prune/migrate)
- [x] (2026-02-06) Phase 4: Matrix bot integration (optional) ~6h
  - Created `scripts/matrix-dispatch-helper.sh` (setup, start, stop, map, test, logs)
  - Created `services/communications/matrix-bot.md` subagent documentation
  - Room-to-runner mapping with configurable bot prefix (`!ai`)
  - Node.js bot using `matrix-bot-sdk` with auto-join, typing indicators, reactions
  - Dispatch via `runner-helper.sh` with fallback to OpenCode HTTP API
  - Cloudron Synapse setup guide included
  - User allowlist, concurrency control, response truncation
- [x] (2026-02-05) Phase 5: Documentation & examples ~3h
  - Updated AGENTS.md with parallel agent guidance
  - Created example runners (code-reviewer, seo-analyst) in `tools/ai-assistants/runners/`
  - Documented when to use parallel vs sequential in headless-dispatch.md

<!--TOON:milestones[5]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m064,p016,Phase 1: Document headless dispatch patterns,4h,,2026-02-03T00:00Z,,pending
m065,p016,Phase 2: Create droid-helper.sh,4h,,2026-02-03T00:00Z,,pending
m066,p016,Phase 3: Memory namespace integration,3h,,2026-02-03T00:00Z,2026-02-05T00:00Z,completed
m067,p016,Phase 4: Matrix bot integration (optional),6h,,2026-02-03T00:00Z,2026-02-06T00:00Z,completed
m068,p016,Phase 5: Documentation & examples,3h,,2026-02-03T00:00Z,2026-02-05T00:00Z,completed
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

### [2026-02-04] Self-Improving Agent System

**Status:** Planning
**Estimate:** ~2d (ai:1d test:0.5d read:0.5d)
**Source:** Discussion on parallel agents, OpenCode server, and community contributions

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p017,Self-Improving Agent System,planning,0,6,,agents|self-improvement|automation|privacy|testing|opencode,2d,1d,0.5d,0.5d,2026-02-04T00:00Z,
-->

#### Purpose

Create a self-improving agent system that can review its own performance, refine agents based on learnings, test changes in isolated sessions, and contribute improvements back to the community with proper privacy filtering.

**Key capabilities:**
1. **Review** - Analyze memory for success/failure patterns, identify gaps
2. **Refine** - Generate and apply improvements to agents/scripts
3. **Test** - Validate changes in isolated OpenCode sessions
4. **PR** - Contribute improvements with privacy filtering for public repos

**Safety guardrails:**
- Worktree isolation for all changes
- Human approval required for PRs
- Mandatory privacy filter before public contributions
- Dry-run default (must explicitly enable PR creation)
- Scope limits (agents-only or scripts-only)
- Audit log to memory

#### Context from Discussion

**Architecture:**

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                        Self-Improvement Loop                             │
│                                                                          │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐          │
│  │  REVIEW  │───▶│  REFINE  │───▶│  TEST    │───▶│  PR      │          │
│  │          │    │          │    │          │    │          │          │
│  │ Memory   │    │ Edit     │    │ OpenCode │    │ Privacy  │          │
│  │ Patterns │    │ Agents   │    │ Sessions │    │ Filter   │          │
│  │ Failures │    │ Scripts  │    │ Validate │    │ gh CLI   │          │
│  └──────────┘    └──────────┘    └──────────┘    └──────────┘          │
│       ▲                                               │                  │
│       └───────────────────────────────────────────────┘                  │
│                         Iterate until quality gates pass                 │
└─────────────────────────────────────────────────────────────────────────┘
```

**What we already have:**
- `agent-review.md` - Manual review process
- `memory-helper.sh` - Pattern storage (SUCCESS/FAILURE types)
- `session-distill-helper.sh` - Extract learnings
- `secretlint` - Credential detection
- OpenCode server API - Isolated session testing

**Privacy filter components:**
1. Secretlint scan for credentials
2. Pattern-based redaction (emails, IPs, local URLs, home paths, API keys)
3. Project-specific patterns from `.aidevops/privacy-patterns.txt`
4. Dry-run review before PR creation

**Example workflow:**

```bash
# Agent notices repeated failure pattern
/remember type:FAILURE "ShellCheck SC2086 errors keep appearing in new scripts"

# Later, self-improvement runs
/self-improve --scope scripts --dry-run

# Output:
# === Self-Improvement Analysis ===
# 
# FAILURE patterns found: 3
# - SC2086 unquoted variables (5 occurrences)
# - SC2155 declare and assign separately (2 occurrences)
# - Missing 'local' in functions (3 occurrences)
#
# Proposed changes:
# 1. Update build-agent.md with ShellCheck reminder
# 2. Add pre-commit hook for ShellCheck
# 3. Create shellcheck-patterns.md subagent
#
# Test results: PASS (3/3 quality gates)
# Privacy filter: CLEAN (no secrets/PII detected)
#
# Run without --dry-run to create PR
```

#### Progress

- [ ] (2026-02-04) Phase 1: Review phase - pattern analysis ~1.5h
  - Query memory for FAILURE/SUCCESS patterns
  - Identify gaps (failures without solutions)
  - Check agent-review suggestions
  - Create self-improve-helper.sh with analyze command
- [ ] (2026-02-04) Phase 2: Refine phase - generate improvements ~2h
  - Generate improvement proposals from patterns
  - Edit agents/scripts in worktree
  - Run linters-local.sh for validation
  - Add refine command to self-improve-helper.sh
- [ ] (2026-02-04) Phase 3: Test phase - isolated sessions ~1.5h
  - Create OpenCode test session via API
  - Run test prompts against improved agents
  - Validate quality gates pass
  - Compare before/after behavior
  - Add test command to self-improve-helper.sh
- [ ] (2026-02-04) Phase 4: Privacy filter implementation ~3h
  - Create privacy-filter-helper.sh
  - Integrate secretlint for credential detection
  - Add pattern-based redaction (emails, IPs, paths, keys)
  - Support project-specific patterns
  - Dry-run review mode
- [ ] (2026-02-04) Phase 5: PR phase - community contributions ~1h
  - Run privacy filter (mandatory)
  - Show redacted diff for approval
  - Create PR with evidence from memory
  - Include test results and privacy attestation
  - Add pr command to self-improve-helper.sh
- [ ] (2026-02-04) Phase 6: Documentation & /self-improve command ~2h
  - Create tools/build-agent/self-improvement.md subagent
  - Create scripts/commands/self-improve.md
  - Update AGENTS.md with self-improvement guidance
  - Add examples and safety documentation

<!--TOON:milestones[6]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m069,p017,Phase 1: Review phase - pattern analysis,1.5h,,2026-02-04T00:00Z,,pending
m070,p017,Phase 2: Refine phase - generate improvements,2h,,2026-02-04T00:00Z,,pending
m071,p017,Phase 3: Test phase - isolated sessions,1.5h,,2026-02-04T00:00Z,,pending
m072,p017,Phase 4: Privacy filter implementation,3h,,2026-02-04T00:00Z,,pending
m073,p017,Phase 5: PR phase - community contributions,1h,,2026-02-04T00:00Z,,pending
m074,p017,Phase 6: Documentation & /self-improve command,2h,,2026-02-04T00:00Z,,pending
-->

#### Decision Log

- **Decision:** Use OpenCode server API for isolated testing
  **Rationale:** Provides session management, async prompts, and SSE events without spawning CLI processes
  **Date:** 2026-02-04

- **Decision:** Mandatory privacy filter before any public PR
  **Rationale:** Prevents accidental exposure of credentials, PII, or internal paths
  **Date:** 2026-02-04

- **Decision:** Dry-run default for self-improvement
  **Rationale:** Human must explicitly approve PR creation, prevents runaway automation
  **Date:** 2026-02-04

- **Decision:** Worktree isolation for all changes
  **Rationale:** Easy rollback, doesn't affect main branch until PR merged
  **Date:** 2026-02-04

<!--TOON:decisions[4]{id,plan_id,decision,rationale,date,impact}:
d043,p017,Use OpenCode server API for isolated testing,Provides session management and SSE events without CLI spawning,2026-02-04,Architecture
d044,p017,Mandatory privacy filter before any public PR,Prevents accidental exposure of credentials or PII,2026-02-04,Security
d045,p017,Dry-run default for self-improvement,Human must explicitly approve PR creation,2026-02-04,Safety
d046,p017,Worktree isolation for all changes,Easy rollback and doesn't affect main branch,2026-02-04,Safety
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

#### Files to Create

| File | Purpose | Phase |
|------|---------|-------|
| `scripts/self-improve-helper.sh` | Main self-improvement script | 1-5 |
| `scripts/privacy-filter-helper.sh` | Privacy filtering for PRs | 4 |
| `scripts/agent-test-helper.sh` | Agent testing framework | 3 |
| `scripts/commands/self-improve.md` | /self-improve command | 6 |
| `tools/build-agent/self-improvement.md` | Self-improvement subagent | 6 |
| `tools/security/privacy-filter.md` | Privacy filter documentation | 4 |

#### Files to Modify

| File | Changes | Phase |
|------|---------|-------|
| `memory-helper.sh` | Add pattern query helpers | 1 |
| `agent-review.md` | Link to self-improvement | 6 |
| `AGENTS.md` | Add self-improvement guidance | 6 |
| `subagent-index.toon` | Add new subagents | 6 |

#### Related Tasks

| Task | Description | Dependency |
|------|-------------|------------|
| t116 | Self-improving agent system (main task) | This plan |
| t117 | Privacy filter for public PRs | Blocks t116.4 |
| t118 | Agent testing framework | Related |
| t115 | OpenCode server documentation | Prerequisite knowledge |

---

### [2026-02-05] SEO Tool Subagents Sprint

**Status:** Planning
**Estimate:** ~1.5d (ai:1d test:4h read:2h)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p020,SEO Tool Subagents Sprint,planning,0,3,,seo|tools|subagents|sprint,1.5d,1d,4h,2h,2026-02-05T00:00Z,
-->

#### Purpose

Batch-create 12 SEO tool subagents (t083-t094) in a single sprint. All follow an identical pattern: create a markdown subagent with API docs, install commands, usage examples, and integration notes. The existing 16 SEO subagents in `seo/` provide perfect templates.

**Estimated total:** ~11.5h across 12 tasks, but parallelizable to ~4-5h actual since they follow the same pattern and an AI agent can generate multiple in a single session.

#### Context from Discussion

**Corrections identified during audit (2026-02-05):**

| Task | Issue | Fix |
|------|-------|-----|
| t084 Rich Results Test | Google deprecated the standalone API | Use URL-based testing only; document browser automation approach |
| t086 Screaming Frog | CLI requires paid license ($259/yr) | Document free tier limits (500 URLs); note license requirement |
| t088 Sitebulb | No public API or CLI exists | Change scope to "document manual workflow" or decline |
| t089 ContentKing | Acquired by Conductor in 2022 | Verify post-acquisition API status; may need different endpoint |
| t087 Semrush | API has pricing tiers | Document free tier (10 requests/day) and paid tiers |

#### Progress

- [ ] (2026-02-05) Phase 1: API-based subagents (7 tasks, ~6h) ~6h
  - t083 Bing Webmaster Tools - API key from Bing portal, URL submission, indexation, analytics
  - t084 Rich Results Test - URL-based testing (API deprecated), browser automation for validation
  - t085 Schema Validator - schema.org validator + Google structured data testing tool
  - t087 Semrush - API integration, note pricing tiers (free: 10 req/day)
  - t090 WebPageTest - API integration, differentiate from existing pagespeed.md
  - t092 Schema Markup - JSON-LD templates for Article, Product, FAQ, HowTo, Organization, LocalBusiness
  - t094 Analytics Tracking - GA4 setup, event tracking, UTM parameters, attribution

- [ ] (2026-02-05) Phase 2: Workflow-based subagents (3 tasks, ~4h) ~4h
  - t091 Programmatic SEO - Template engine decision, keyword clustering, internal linking automation
  - t093 Page CRO - A/B testing setup, CTA optimization, landing page best practices
  - t089 ContentKing/Conductor - Verify API status post-acquisition, real-time SEO monitoring

- [ ] (2026-02-05) Phase 3: Special cases + integration (2 tasks, ~2h) ~2h
  - t086 Screaming Frog - Document CLI with license requirement, free tier limits (500 URLs)
  - t088 Sitebulb - Document manual workflow only (no API/CLI exists), or decline
  - Update subagent-index.toon with all new subagents
  - Update seo.md main agent with references to new subagents

<!--TOON:milestones[3]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m101,p020,Phase 1: API-based subagents (7 tasks),6h,,2026-02-05T00:00Z,,pending
m102,p020,Phase 2: Workflow-based subagents (3 tasks),4h,,2026-02-05T00:00Z,,pending
m103,p020,Phase 3: Special cases + integration (2 tasks),2h,,2026-02-05T00:00Z,,pending
-->

#### Decision Log

- **Decision:** Batch all 12 SEO tasks into a single sprint
  **Rationale:** All follow identical subagent creation pattern; existing 16 SEO subagents provide templates. Parallelizable to ~4-5h actual.
  **Date:** 2026-02-05

- **Decision:** t088 (Sitebulb) scope changed to manual workflow documentation
  **Rationale:** Sitebulb has no public API or CLI. Desktop-only application.
  **Date:** 2026-02-05

<!--TOON:decisions[2]{id,plan_id,decision,rationale,date,impact}:
d051,p020,Batch all 12 SEO tasks into single sprint,Identical pattern; existing templates; parallelizable,2026-02-05,Efficiency
d052,p020,t088 Sitebulb scope changed to manual workflow,No public API or CLI exists,2026-02-05,Scope
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

#### Related Tasks

| Task | Description | Phase |
|------|-------------|-------|
| t083 | Bing Webmaster Tools | 1 |
| t084 | Rich Results Test | 1 |
| t085 | Schema Validator | 1 |
| t086 | Screaming Frog | 3 |
| t087 | Semrush | 1 |
| t088 | Sitebulb | 3 |
| t089 | ContentKing/Conductor | 2 |
| t090 | WebPageTest | 1 |
| t091 | Programmatic SEO | 2 |
| t092 | Schema Markup | 1 |
| t093 | Page CRO | 2 |
| t094 | Analytics Tracking | 1 |

---

### [2026-02-05] Voice Integration Pipeline

**Status:** Planning
**Estimate:** ~3d (ai:1.5d test:1d read:0.5d)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p019,Voice Integration Pipeline,planning,0,6,,voice|ai|pipecat|transcription|tts|stt|local|api,3d,1.5d,1d,0.5d,2026-02-05T00:00Z,
-->

#### Purpose

Create a comprehensive voice integration for aidevops supporting both local and cloud-based speech capabilities. This enables hands-free AI interaction via voice-to-text, text-to-speech, and full speech-to-speech conversation loops with OpenCode.

**Dual-track philosophy:** Every voice capability should have both a local option (privacy, offline, no cost) and an API option (higher quality, lower latency, easier setup). Users choose based on their needs.

**Key capabilities:**
1. **Transcription** (audio/video → text) - Local: Whisper/faster-whisper. API: Groq, ElevenLabs Scribe, Deepgram, Soniox
2. **TTS** (text → speech) - Local: Qwen3-TTS, Piper. API: Cartesia Sonic, ElevenLabs, OpenAI TTS
3. **STT** (realtime speech → text) - Local: Whisper.cpp. API: Soniox, Deepgram, Google
4. **S2S** (speech → speech, no intermediate text) - API: OpenAI Realtime, AWS Nova Sonic, Gemini Multimodal Live, Ultravox
5. **Voice agent pipeline** - Pipecat framework orchestrating STT+LLM+TTS or S2S
6. **Dispatch shortcuts** - macOS/iOS shortcuts for voice-triggered OpenCode commands

#### Context from Discussion

**Pipecat ecosystem (v0.0.101, 10.2k stars, Feb 2026):**
- Python framework for voice/multimodal AI agents
- 50+ service integrations (STT, TTS, LLM, S2S, transport)
- Daily.co WebRTC transport for real-time audio
- S2S support: OpenAI Realtime, AWS Nova Sonic, Gemini Multimodal Live, Grok Voice Agent, Ultravox
- Voice UI Kit for web-based voice interfaces

**Local model options:**
- **Qwen3-TTS** (0.6B/1.7B, Apache-2.0): 10 languages, voice clone/design, streaming, vLLM support
- **Piper** (MIT): Fast local TTS, many voices, low resource usage
- **Whisper Large v3 Turbo** (1.5GB): Best accuracy/speed tradeoff for local transcription
- **faster-whisper**: CTranslate2-optimized Whisper, 4x faster than original

**Task sequencing:**

| Phase | Tasks | Dependency | Rationale |
|-------|-------|------------|-----------|
| 1 | t072 Transcription | None | Foundation - most broadly useful |
| 2 | t071 TTS/STT Models | None (parallel with Phase 1) | Model catalog for other phases |
| 3 | t081 Local Pipecat | t071, t072 | Local voice agent pipeline |
| 4 | t080 NVIDIA Nemotron | t081 | Cloud voice agent with open models |
| 5 | t114 OpenCode bridge | t081 | Connect voice pipeline to AI |
| 6 | t112, t113 Shortcuts | t114 | Quick dispatch from desktop/mobile |

#### Progress

- [ ] (2026-02-05) Phase 1: Transcription subagent (t072) ~6h
  - Create `tools/voice/transcription.md` subagent
  - Create `scripts/transcription-helper.sh` (transcribe, models, configure)
  - Document local models: Whisper Large v3 Turbo (recommended), faster-whisper, NVIDIA Parakeet
  - Document cloud APIs: Groq Whisper, ElevenLabs Scribe v2, Deepgram Nova, Soniox
  - Support inputs: YouTube (yt-dlp), URLs, local audio/video files
  - Output formats: plain text, SRT, VTT

- [ ] (2026-02-05) Phase 2: Voice AI models catalog (t071) ~4h
  - Create `tools/voice/voice-models.md` subagent
  - Document TTS options: local (Qwen3-TTS, Piper) vs API (Cartesia Sonic, ElevenLabs, OpenAI)
  - Document STT options: local (Whisper.cpp, faster-whisper) vs API (Soniox, Deepgram)
  - Document S2S options: OpenAI Realtime, AWS Nova Sonic, Gemini Multimodal Live, Ultravox
  - Include model selection guide (quality vs speed vs cost vs privacy)
  - GPU requirements and benchmarks for local models

- [ ] (2026-02-05) Phase 3: Local Pipecat voice agent (t081) ~4h
  - Create `tools/voice/pipecat.md` subagent
  - Create `scripts/pipecat-helper.sh` (setup, start, stop, configure)
  - Document pipeline: Mic → STT → LLM → TTS → Speaker
  - Support both STT+LLM+TTS pipeline and S2S mode (OpenAI Realtime)
  - Configure local fallback: Whisper.cpp + llama.cpp + Piper for offline use
  - Configure cloud default: Soniox + OpenAI/Anthropic + Cartesia Sonic
  - Test on macOS using kwindla/macos-local-voice-agents as reference

- [ ] (2026-02-05) Phase 4: Cloud voice agents and S2S models (t080) ~6h
  - Extend pipecat.md with cloud S2S provider configurations
  - **S2S providers (no separate STT/TTS needed):** GPT-4o-Realtime (OpenAI), AWS Nova Sonic, Gemini Multimodal Live, Ultravox
  - **NVIDIA Nemotron:** Cloud-only via NVIDIA API (requires NVIDIA GPU for local; use cloud credits for low usage). Clone pipecat-ai/nemotron-january-2026 repo
  - **Local S2S alternative:** MiniCPM-o 4.5 (23k stars, Apache-2.0, 9B params) - runs on Mac via llama.cpp-omni, supports full-duplex voice+vision+text, WebRTC demo available. Also MiniCPM-o 2.6 for lighter-weight local use
  - Test voice pipeline with Daily.co WebRTC transport
  - Build customer service agent template with configurable personas
  - Document integration with OpenClaw for messaging platform voice calls

- [ ] (2026-02-05) Phase 5: OpenCode voice bridge (t114) ~4h
  - Create `tools/voice/pipecat-opencode.md` subagent
  - Pipeline: Mic → Soniox STT → OpenCode API → Cartesia TTS → Speaker
  - Use OpenCode server API for prompt submission and response streaming
  - Support session continuity (resume voice conversation)
  - Handle long responses (streaming TTS as text arrives)

- [ ] (2026-02-05) Phase 6: Voice dispatch shortcuts (t112, t113) ~2h
  - Create `tools/voice/voiceink-shortcut.md` (macOS)
  - Create `tools/voice/ios-shortcut.md` (iPhone)
  - macOS: VoiceInk transcription → Shortcut → HTTP POST to OpenCode → response
  - iOS: Dictate → HTTP POST to OpenCode (via Tailscale) → Speak response
  - Include AppleScript/Shortcuts app instructions

<!--TOON:milestones[6]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m095,p019,Phase 1: Transcription subagent (t072),6h,,2026-02-05T00:00Z,,pending
m096,p019,Phase 2: Voice AI models catalog (t071),4h,,2026-02-05T00:00Z,,pending
m097,p019,Phase 3: Local Pipecat voice agent (t081),4h,,2026-02-05T00:00Z,,pending
m098,p019,Phase 4: NVIDIA Nemotron voice agents (t080),6h,,2026-02-05T00:00Z,,pending
m099,p019,Phase 5: OpenCode voice bridge (t114),4h,,2026-02-05T00:00Z,,pending
m100,p019,Phase 6: Voice dispatch shortcuts (t112 t113),2h,,2026-02-05T00:00Z,,pending
-->

#### Decision Log

- **Decision:** Dual-track local + API for every capability
  **Rationale:** Privacy-sensitive users need local options; quality-focused users need cloud APIs. Both must be first-class.
  **Date:** 2026-02-05

- **Decision:** Pipecat as the orchestration framework
  **Rationale:** 10.2k stars, 50+ service integrations, Python, actively maintained, S2S support. No viable alternative at this scale.
  **Date:** 2026-02-05

- **Decision:** Whisper Large v3 Turbo as default local transcription model
  **Rationale:** Best accuracy/speed tradeoff (9.7 accuracy, 7.5 speed). Half the size of Large v3 (1.5GB vs 2.9GB) with near-identical accuracy.
  **Date:** 2026-02-05

- **Decision:** S2S as preferred mode when available
  **Rationale:** OpenAI Realtime, AWS Nova Sonic, and Gemini Multimodal Live provide lower latency and more natural conversation than STT+LLM+TTS pipeline. Fall back to pipeline when S2S unavailable.
  **Date:** 2026-02-05

<!--TOON:decisions[4]{id,plan_id,decision,rationale,date,impact}:
d047,p019,Dual-track local + API for every capability,Privacy-sensitive users need local; quality-focused need cloud,2026-02-05,Architecture
d048,p019,Pipecat as orchestration framework,10.2k stars 50+ integrations Python actively maintained,2026-02-05,Architecture
d049,p019,Whisper Large v3 Turbo as default local model,Best accuracy/speed tradeoff at half the size,2026-02-05,None
d050,p019,S2S as preferred mode when available,Lower latency and more natural than STT+LLM+TTS pipeline,2026-02-05,Architecture
-->

#### Surprises & Discoveries

- **Observation:** Pipecat v0.0.101 now supports 5 S2S providers natively
  **Evidence:** OpenAI Realtime, AWS Nova Sonic, Gemini Multimodal Live, Grok Voice Agent, Ultravox all documented in pipecat.ai/docs
  **Impact:** Simplifies t081 significantly - S2S may replace STT+LLM+TTS for cloud use
  **Date:** 2026-02-05

- **Observation:** MiniCPM-o 4.5 (23k stars, Apache-2.0) provides local full-duplex S2S on Mac
  **Evidence:** 9B param model runs via llama.cpp-omni with WebRTC demo. Supports simultaneous vision+audio+text. Approaches Gemini 2.5 Flash quality.
  **Impact:** Provides a strong local S2S alternative to cloud-only options. NVIDIA Nemotron requires NVIDIA GPU locally but MiniCPM-o runs on Mac/CPU.
  **Date:** 2026-02-05

- **Observation:** GPT-4o-Realtime is the most mature S2S option via Pipecat
  **Evidence:** First S2S provider supported by Pipecat, well-documented, lowest latency
  **Impact:** Recommended as default cloud S2S provider for Phase 4
  **Date:** 2026-02-05

<!--TOON:discoveries[3]{id,plan_id,observation,evidence,impact,date}:
disc006,p019,Pipecat v0.0.101 supports 5 S2S providers natively,All documented in pipecat.ai/docs,Simplifies t081 - S2S may replace STT+LLM+TTS for cloud,2026-02-05
disc007,p019,MiniCPM-o 4.5 provides local full-duplex S2S on Mac,9B params via llama.cpp-omni with WebRTC demo,Strong local S2S alternative - runs on Mac/CPU unlike Nemotron,2026-02-05
disc008,p019,GPT-4o-Realtime is most mature S2S option,First Pipecat S2S provider well-documented lowest latency,Recommended as default cloud S2S provider,2026-02-05
-->

#### Files to Create

| File | Purpose | Phase |
|------|---------|-------|
| `tools/voice/transcription.md` | Transcription subagent | 1 |
| `scripts/transcription-helper.sh` | Transcription CLI | 1 |
| `tools/voice/voice-models.md` | Voice AI model catalog | 2 |
| `tools/voice/pipecat.md` | Pipecat voice agent subagent | 3 |
| `scripts/pipecat-helper.sh` | Pipecat CLI | 3 |
| `tools/voice/pipecat-opencode.md` | OpenCode voice bridge | 5 |
| `tools/voice/voiceink-shortcut.md` | macOS voice shortcut | 6 |
| `tools/voice/ios-shortcut.md` | iPhone voice shortcut | 6 |

#### Files to Modify

| File | Changes | Phase |
|------|---------|-------|
| `subagent-index.toon` | Add voice subagents | 1-6 |
| `AGENTS.md` | Add voice integration to progressive disclosure table | 6 |
| `README.md` | Update Voice Integration section | 6 |

#### Related Tasks

| Task | Description | Phase |
|------|-------------|-------|
| t072 | Audio/Video Transcription subagent | 1 |
| t071 | Voice AI models catalog | 2 |
| t081 | Local Pipecat voice agent | 3 |
| t080 | NVIDIA Nemotron voice agents | 4 |
| t114 | Pipecat-OpenCode bridge | 5 |
| t112 | VoiceInk macOS shortcut | 6 |
| t113 | iPhone voice shortcut | 6 |
| t027 | hyprwhspr Linux STT (related) | - |

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
9,9,0,0,,
-->
