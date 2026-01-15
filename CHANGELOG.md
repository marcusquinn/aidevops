# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.55.2] - 2026-01-15

### Fixed

- suppress jq output in plugin array checks
## [2.55.1] - 2026-01-14

### Fixed

- suppress jq output in plugin array checks
## [2.55.0] - 2026-01-14

### Added

- add Peekaboo MCP server integration for macOS GUI automation (#91)
- add macos-automator MCP for AppleScript automation (#89)
- add sweet-cookie documentation for cookie extraction (#90)

### Changed

- Documentation: add && aidevops update to npm/bun/brew install commands (#87)

## [2.54.2] - 2026-01-14

### Fixed

- resolve next.js security vulnerability CVE-2025-66478 (#79)

## [2.54.1] - 2026-01-14

### Fixed

- include aidevops.sh in version updates (#78)

## [2.54.0] - 2026-01-14

### Added

- add subagent filtering via frontmatter (#75)

### Changed

- Documentation: add troubleshooting section with support links to QuickFile agent (#76)
- Documentation: add upgrade-planning and update-tools to CLI commands
- Documentation: add Bun as installation option

### Fixed

- add SonarCloud exclusions for shell code smell rules (#77)

## [2.53.3] - 2026-01-13

### Changed

- Documentation: use aidevops.sh/install URL
- Documentation: use aidevops.sh URL for direct install option
- Documentation: update README with npm/Homebrew install, repo tracking, v2.53.2

## [2.53.0] - 2026-01-13

### Added

- add frontend debugging guide with browser verification patterns (#69)

## [2.52.1] - 2026-01-13

### Fixed

- correct onboarding command path to root agent location (#72)
- use prefix increment to avoid set -e exit on zero (#70)

## [2.52.0] - 2026-01-13

### Added

- add upgrade-planning command (#68)

### Changed

- Documentation: update CHANGELOG.md for v2.52.0 release

## [2.52.0] - 2026-01-13

### Added

- add `aidevops upgrade-planning` command to upgrade TODO.md/PLANS.md to latest TOON-enhanced templates
- add protected branch check to `init` and `upgrade-planning` with worktree creation option
- preserve existing tasks when upgrading planning files with automatic backup

### Fixed

- fix awk frontmatter stripping logic for template processing
- fix BSD/macOS sed compatibility for JSON updates (use awk for portable newlines)

## [2.51.1] - 2026-01-12

### Changed

- Documentation: update CHANGELOG.md for v2.51.1 release

## [2.51.1] - 2026-01-12

### Added

- Loop state migration in setup.sh from `.claude/` to `.agent/loop-state/` (#67)

## [2.51.0] - 2026-01-12

### Added

- add FluentCRM MCP integration for sales and marketing (#64)
- migrate loop state to .agent/loop-state and enhance re-anchor (#65)

### Changed

- Documentation: update CHANGELOG.md for v2.51.0 release
- Documentation: add individual network request throttling to Chrome DevTools (#66)
- Documentation: change governing law to Jersey
- Documentation: add TERMS.md with liability disclaimers

### Fixed

- add missing return statements to shell functions (S7682) (#63)

## [2.51.0] - 2026-01-12

### Added

- FluentCRM MCP integration for sales and marketing automation (#64)
- Ralph loop guardrails system - failures become actionable "signs" (#65)
- Single-task extraction in re-anchor prompts (Loom's "pin" concept) (#65)
- Linkage section in plans-template.md for spec-as-lookup-table pattern (#65)

### Changed

- Loop state directory migrated from `.claude/` to `.agent/loop-state/` (backward compatible) (#65)
- Ralph loop documentation updated with context pollution prevention philosophy (#65)
- Chrome DevTools docs: add individual network request throttling (#66)
- Linter thresholds improved and preflight issues fixed (#62)
- Legal: change governing law to Jersey, add TERMS.md (#62)

### Fixed

- Add missing return statements to shell functions (SonarCloud S7682) (#63)

## [2.50.0] - 2026-01-12

### Added

- add GSC sitemap submission via Playwright automation (#60)
- add agent-browser support for headless browser automation CLI (#59)

### Changed

- Documentation: update browser-automation guide with agent-browser as default (#61)

## [2.49.0] - 2026-01-11

### Added

- add tool update checking to setup.sh and aidevops CLI (#56)
- add OpenProse DSL for multi-agent orchestration (#57)

### Changed

- Documentation: note that OpenProse telemetry is disabled by default in aidevops (#58)
- Documentation: add Twilio and Telfon to README service coverage

## [2.47.0] - 2026-01-11

### Added

- add summarize and bird CLI subagents (t034, t035) (#40)

### Changed

- Documentation: add agent design patterns documentation and improvement plan (#39)

### Fixed

- prevent removal of unpushed branches and uncommitted changes (#42)

## [2.46.0] - 2026-01-11

### Added

- implement v2 architecture with fresh context per iteration (#38)

## [2.45.0] - 2026-01-11

### Added

- add /session-review and /full-loop commands for comprehensive AI workflow (#33)
- add code-simplifier subagent and enforce worktree-first workflow (#34)
- add cross-session memory system with SQLite FTS5 (#32)

### Changed

- Documentation: update CHANGELOG.md for v2.45.0 release
- Documentation: add latest capabilities to README
- Documentation: improve agent instructions based on session review (#31)

### Fixed

- add missing default cases to case statements (#35)

## [2.45.0] - 2026-01-11

### Added

- Cross-session memory system with SQLite FTS5 (`/remember`, `/recall`) (#32)
- Code-simplifier subagent and `/code-simplifier` command (#34)
- `/session-review` and `/full-loop` commands for comprehensive AI workflow (#33)
- Multi-worktree awareness for Ralph loops (`status --all`, parallel warnings)
- Auto-discovery for OpenCode commands from `scripts/commands/*.md` (#37)

### Fixed

- SonarCloud S131 violations - add missing default cases to case statements (#35)

### Changed

- Enforce worktree-first workflow - main repo stays on `main` branch
- Documentation: add multi-worktree section to ralph-loop.md

## [2.44.0] - 2026-01-11

### Added

- add session mapping script and improve pre-edit check (#29)

### Fixed

- resolve postflight ShellCheck and return statement issues (#30)

## [2.43.0] - 2026-01-10

### Added

- add session management and parallel work spawning (#26)
- add interactive mode with step-by-step confirmation (#23)

### Changed

- Documentation: add session management section to README
- Documentation: add line break before tagline
- Documentation: make aidevops bold links to aidevops.sh in prose
- Documentation: add tagline to philosophy section
- Documentation: add philosophy section explaining git-first workflow approach
- Documentation: add OpenCode Anthropic OAuth plugin section to README (#24)

## [2.42.2] - 2026-01-09

### Added

- add opencode-anthropic-auth plugin integration

### Changed

- Documentation: improve AGENTS.md progressive disclosure with descriptive hints (#22)

## [2.42.1] - 2026-01-09

### Changed

- Version bump and maintenance updates

## [2.41.2] - 2025-12-23

### Fixed

- enforce git workflow with pre-edit-check script

## [2.41.1] - 2025-12-23

### Changed

- Version bump and maintenance updates

## [2.41.0] - 2025-12-22

### Added

- inherit OpenCode prompts for Build+ and Plan+ agents (#7)

### Changed

- Refactor: demote build-agent and build-mcp to tools/ subagents

## [2.40.10] - 2025-12-22

### Changed

- Documentation: add comprehensive docstrings to opencode-github-setup-helper.sh
- Documentation: add t022 to Done with time logged

### Fixed

- update .coderabbit.yaml to match v2 schema
- handle git command exceptions in session-rename tool

## [2.40.7] - 2025-12-22

### Changed

- Refactor: move wordpress from root to tools/wordpress
- Documentation: add t021 for auto-marking tasks complete in release workflow
- Documentation: mark t011 as completed in TODO.md

## [2.40.6] - 2025-12-22

### Changed

- Refactor: demote wordpress.md from main agent to subagent

## [2.40.5] - 2025-12-22

### Changed

- Documentation: strengthen git workflow instructions with numbered options

## [2.40.4] - 2025-12-22

### Changed

- Documentation: clarify setup.sh step applies only to aidevops repo
- Documentation: add mandatory setup.sh step to release workflow

### Fixed

- auto-add ~/.local/bin to PATH during installation

## [2.40.3] - 2025-12-22

### Changed

- Version bump and maintenance updates

## [2.40.2] - 2025-12-22

### Added

- add parallel session workflow with branch-synced session naming (#6)
- add OpenCode GitHub/GitLab integration support (#5)

### Changed

- Documentation: update changelog for v2.40.2

## [2.40.2] - 2025-12-22

### Added

- Parallel session workflow with branch-synced session naming
- `/sync-branch` and `/rename` commands for OpenCode session management
- `session-rename` custom tool to update session titles via API
- Branch merge workflow in release.md for merging work branches
- Verb prefix guidance for branch naming (add-, improve-, fix-, remove-)

## [2.40.1] - 2025-12-22

### Changed

- Documentation: add Beads viewer installation and usage instructions

## [2.40.0] - 2025-12-22

### Added

- add backup rotation with per-type organization

### Fixed

- include marketplace.json in version commit staging

## [2.39.1] - 2025-12-21

### Added

- integrate Beads task graph visualization

### Changed

- Documentation: add Beads integration to README and templates

### Fixed

- correct Beads CLI command names in documentation

## [2.39.0] - 2025-12-21

### Added

- integrate Beads task graph visualization

### Fixed

- correct Beads CLI command names in documentation

## [2.38.1] - 2025-12-21

### Changed

- Version bump and maintenance updates

## [2.38.0] - 2025-12-21

### Added

- add persistent browser profile support

### Changed

- Documentation: add agent architecture evaluation tasks

### Fixed

- add branch check to Critical Rules for enforcement

## [2.37.3] - 2025-12-21

### Added

- add Oh-My-OpenCode Sisyphus agents after WordPress in Tab order

### Changed

- Refactor: use minimal AGENTS.md files in database directories
- Documentation: add critical rule to re-read files before editing

### Fixed

- add language specifiers to code blocks (MD040) and blank lines around fences (MD031)
- add missing return statements to 3 scripts
- swap Build+ before Plan+ in Tab order
- add mode: subagent to all agent files for OpenCode compatibility

## [2.37.2] - 2025-12-21

### Changed

- Refactor: simplify planning UX with auto-detection

## [2.37.0] - 2025-12-20

### Added

- add Agent Skills compatibility with SKILL.md generation
- add declarative database schema workflow with aidevops init database

### Fixed

- prevent postflight workflow circular dependency

## [2.36.1] - 2025-12-20

### Added

- add declarative database schema workflow with aidevops init database

### Fixed

- prevent postflight workflow circular dependency

## [2.36.0] - 2025-12-20

### Added

- add declarative database schema workflow with aidevops init database

## [2.35.3] - 2025-12-20

### Added

- add interactive setup wizard for new users

### Changed

- Documentation: add aidevops init, time tracking, and /log-time-spent to README

### Fixed

- change onboarding.md mode from 'agent' to 'subagent'

## [2.35.2] - 2025-12-20

### Added

- add interactive setup wizard for new users

### Changed

- Documentation: add aidevops init, time tracking, and /log-time-spent to README

## [2.35.1] - 2025-12-20

### Added

- add interactive setup wizard for new users

### Changed

- Documentation: add aidevops init, time tracking, and /log-time-spent to README

## [2.35.0] - 2025-12-20

### Added

- add interactive setup wizard for new users

### Changed

- Documentation: add aidevops init, time tracking, and /log-time-spent to README

## [2.34.1] - 2025-12-20

### Changed

- Documentation: add aidevops init, time tracking, and /log-time-spent to README

## [2.34.0] - 2025-12-20

### Added

- add TODO.md planning system with time tracking
- add domain-research subagent with THC and Reconeer APIs
- add TODO.md and planning workflow for task tracking
- add shadcn/ui MCP support for component browsing and installation

### Changed

- Documentation: update README with recent features

## [2.33.0] - 2025-12-18

### Added

- add domain-research subagent with THC and Reconeer APIs
- add TODO.md and planning workflow for task tracking
- add shadcn/ui MCP support for component browsing and installation

## [2.32.0] - 2025-12-18

### Added

- add TODO.md and planning workflow for task tracking
- add shadcn/ui MCP support for component browsing and installation

## [2.31.0] - 2025-12-18

### Added

- add shadcn/ui MCP support for component browsing and installation

## [2.30.0] - 2025-12-18

### Added

- add oh-my-opencode integration with cross-agent references

### Changed

- Documentation: update CHANGELOG.md with comprehensive v2.29.0 release notes

## [2.29.0] - 2025-12-18

### Added

- **OpenCode Antigravity OAuth Plugin** - Auto-install/update during setup
  - Enables Google OAuth authentication for premium model access
  - Available models: gemini-3-pro-high, claude-opus-4-5-thinking, claude-sonnet-4-5-thinking
  - Multi-account load balancing for rate limit distribution and failover
  - Documentation in README.md, aidevops.md, and opencode.md
  - See: https://github.com/NoeFabris/opencode-antigravity-auth
- **GSC User Helper Script** - New `gsc-add-user-helper.sh` for bulk adding users to Google Search Console properties
- **Site Crawler v2.0.0** - Major rewrite of `site-crawler-helper.sh` (~1,000 lines added)
  - Enhanced crawling capabilities
  - Improved SEO analysis features
- **Playwright Bulk Setup** - Improved browser automation documentation in `google-search-console.md` (+148 lines)

### Changed

- Updated `build-agent.md` with browser automation reference
- Enhanced `google-search-console.md` with comprehensive Playwright setup guidance

## [2.28.0] - 2025-12-16

### Added

- add site crawler and content quality scoring agents for SEO auditing

## [2.27.4] - 2025-12-15

### Changed

- Documentation: add MCP config validation errors, WordPress plugin workflow, SCF subagent
- Documentation: fix duplicate changelog entry for v2.27.3

### Fixed

- resolve ShellCheck SC2129 and SC2086 in fix-s131-default-cases.sh

## [2.27.3] - 2025-12-13

### Fixed

- Add retry loop for website docs push race condition (3 attempts with backoff)
- Add retry pattern to sync-wiki.yml workflow

### Added

- Document git push retry pattern in github-actions.md design patterns

## [2.27.2] - 2025-12-13

### Changed

- Documentation: add changelog for v2.27.2
- Documentation: update AGENTS.md with complete SonarCloud exclusion patterns
- Documentation: add SonarCloud security hotspot guidance to prevent recurring issues
- Documentation: fix changelog formatting for v2.27.1

### Fixed

- add *-verify.sh to SonarCloud exclusions
- add S6506 (HTTPS not enforced) to SonarCloud exclusions
- auto-exclude S5332 security hotspots via sonar-project.properties
- resolve code-review-monitoring workflow failures
- resolve SonarCloud critical issues and website docs push conflict

## [2.27.2] - 2025-12-13

### Fixed

- Auto-exclude SonarCloud security hotspots (S5332, S6506) via sonar-project.properties
- Resolve code-review-monitoring workflow failures (SARIF upload, git push race)
- Resolve SonarCloud S131 critical issues (missing default cases)
- Fix website docs workflow push conflicts

### Added

- S131 default case fixer script for future use (`fix-s131-default-cases.sh`)
- SonarCloud security hotspot guidance in AGENTS.md and code-standards.md

## [2.27.1] - 2025-12-13

### Changed

- Performance: use Bun in GitHub Actions for faster CI (~3x faster installs)
- Refactor: prefer Bun over Node.js/npm across local scripts

## [2.27.0] - 2025-12-13

### Added

- add browser tools auto-setup (Bun, dev-browser, Playwriter)
- add dev-browser stateful browser automation support
- add Playwriter MCP to setup auto-configuration
- add Playwriter MCP browser automation support

## [2.26.0] - 2025-12-13

### Added

- add SQL migrations workflow with best practices

## [2.25.0] - 2025-12-13

### Added

- auto-discover primary agents from .agent/*.md files
- add comprehensive git workflow with branch safety and preflight checks

### Changed

- Documentation: add framework internals trigger to progressive disclosure

## [2.24.0] - 2025-12-09

### Added

- add uncommitted changes check before release
- complete osgrep integration with self-testing improvements

## [2.23.1] - 2025-12-09

### Changed

- Documentation: remove ClearSERP references from changelog

## [2.23.0] - 2025-12-09

### Added

- add Google Search Console and Bing Webmaster Tools integration
- add strategic keyword research system
- enable context7 MCP for SEO agent

### Changed

- Documentation: update keyword research documentation
- Documentation: add changelog entry for SEO context7
- Documentation: add changelog entry for new subagents
- Documentation: add new subagents and /list-keys command to README
- Documentation: add changelog entry for README updates
- Documentation: add DataForSEO and Serper MCPs to README

### Fixed

- resolve changelog update regex and restore CHANGELOG.md

## [2.22.0] - 2025-12-07

### Added

- add strategic keyword research system
- enable context7 MCP for SEO agent

### Changed

- Documentation: add changelog entry for SEO context7
- Documentation: add changelog entry for new subagents
- Documentation: add new subagents and /list-keys command to README
- Documentation: add changelog entry for README updates
- Documentation: add DataForSEO and Serper MCPs to README

### Fixed

- resolve changelog update regex and restore CHANGELOG.md

## [2.21.0] - 2025-12-07

### Added

- **Keyword Research System** - Strategic keyword research with SERP weakness detection
  - New `keyword-research.md` subagent with comprehensive documentation
  - New `keyword-research-helper.sh` script (~1000 lines, bash 3.2 compatible)
  - 6 research modes: keyword expansion, autocomplete, domain research, competitor research, keyword gap, extended SERP analysis
  - 17 SERP weakness detection categories across domain/authority, technical, content, and SERP composition
  - KeywordScore algorithm (0-100) based on weakness count, volume, and difficulty
  - Multi-provider support: DataForSEO (primary), Serper (autocomplete), Ahrefs (domain ratings)
  - Locale support with saved preferences (US/UK/CA/AU/DE/FR/ES)
  - Output formats: Markdown tables (TUI) and CSV export to ~/Downloads
- **New OpenCode Slash Commands** - 3 new SEO workflow commands
  - `/keyword-research` - Seed keyword expansion with volume, CPC, difficulty
  - `/autocomplete-research` - Google autocomplete long-tail discovery
  - `/keyword-research-extended` - Full SERP analysis with weakness detection
- **OpenCode CLI Testing Reference** - Added to main agents (build-agent, build-mcp, build-plus, aidevops, seo)
  - Pattern: `opencode run "Test query" --agent [agent-name]`
  - New `opencode-test-helper.sh` script for testing MCP and agent configurations

### Changed

- Updated `seo.md` with keyword research subagent references
- Updated `generate-opencode-commands.sh` with 3 new SEO commands (18 total)
- Updated README with keyword research section and SEO workflow commands

### Fixed

- Added missing return statements to API functions in `keyword-research-helper.sh`
- Added missing return statements to print functions in `opencode-test-helper.sh`

## [2.20.5] - 2025-12-07

### Added

- enable context7 MCP for SEO agent

### Changed

- Documentation: add changelog entry for SEO context7
- Documentation: add changelog entry for new subagents
- Documentation: add new subagents and /list-keys command to README
- Documentation: add changelog entry for README updates
- Documentation: add DataForSEO and Serper MCPs to README

### Fixed

- resolve changelog update regex and restore CHANGELOG.md

## [2.20.4] - 2025-12-07

### Changed

- Documentation: add changelog entry for new subagents
- Documentation: add new subagents and /list-keys command to README
- Documentation: add changelog entry for README updates
- Documentation: add DataForSEO and Serper MCPs to README

### Fixed

- resolve changelog update regex and restore CHANGELOG.md

## [2.20.3] - 2025-12-07

### Changed

- Documentation: add changelog entry for README updates
- Documentation: add DataForSEO and Serper MCPs to README

### Fixed

- resolve changelog update regex and restore CHANGELOG.md

## [2.20.2] - 2025-12-07

### Fixed

- resolve changelog update regex and restore CHANGELOG.md

## [2.19.13] - 2025-12-06

### Security

- **SonarCloud Security Hotspots Resolved** - Fixed 9 of 10 security hotspots
  - Added `--proto '=https'` to curl commands to enforce HTTPS and prevent protocol downgrade attacks
  - Added `--ignore-scripts` to npm install commands to prevent execution of postinstall scripts
  - Files fixed: aidevops-update-check.sh, codacy-cli.sh, qlty-cli.sh, linter-manager.sh, markdown-lint-fix.sh, setup-mcp-integrations.sh
  - 1 hotspot acknowledged as safe (localhost-helper.sh http:// for local dev when SSL disabled)

## [2.19.12] - 2025-12-06

### Fixed

- Version bump release (no functional changes)

## [2.19.11] - 2025-12-06

### Added

- **Session Greeting with Version Check** - AI assistants now greet with aidevops version at session start
  - Automatic version check via `aidevops-update-check.sh` script
  - Update notification when new version available
  - Clickable URL format: "Hi! We're running https://aidevops.sh v{version}"

### Changed

- **OpenCode AGENTS.md Instructions** - Strengthened version check compliance
  - Changed from "MANDATORY" to "CRITICAL - DO THIS FIRST"
  - Explicit Bash tool specification to prevent webfetch errors
  - Added `instructions` field to opencode.json for reliable loading

### Fixed

- **TypeError on Session Start** - Fixed `undefined is not an object (evaluating 'response.headers')` error
  - Caused by ambiguous "silently run" instruction interpreted as webfetch
  - Now explicitly specifies Bash tool for version check script
- **Local Linter False Positives** - Improved accuracy of linters-local.sh
  - Return statement check now recognizes `return $var` and `return $((expr))` patterns
  - Positional parameter check excludes multi-line awk scripts, heredocs, and comments
  - Reduced false positives from 15 to 0
- **SonarCloud S131 Violations** - Added default cases to case statements
  - version-manager.sh, postflight-check.sh, generate-opencode-agents.sh
- **SonarCloud S7682 and S7679 Issues** - Resolved return statement and positional parameter violations

## [2.17.1] - 2025-12-06

### Changed

- Removed AI tool symlink directories and files that caused duplicate `@` references in OpenCode
- Updated .gitignore to ignore tool-specific symlinks (.ai, .kiro, .continue, .cursorrules, .windsurfrules, .continuerules, .claude/, .codex/, .cursor/, .factory/)
- Added "AI Tool Configuration" section to AGENTS.md documenting canonical agent location (~/.aidevops/agents/)

## [2.17.0] - 2025-12-06

### Added

- **linters-local.sh Script** - New local quality check script for offline linting
  - ShellCheck, secretlint, and pattern-based checks
  - No external service dependencies required
- **code-standards.md** - Consolidated code review guidance and quality standards
- **code-audit-remote.md Workflow** - Remote repository audit workflow
  - CodeRabbit, Codacy, and SonarCloud integration
- **pr.md Workflow** - Unified PR orchestrator (renamed from pull-request.md)
- **Stagehand Python MCP Templates** - New templates for Python-based browser automation
  - `stagehand-both.json` - Combined TypeScript and Python configuration
  - `stagehand-python.json` - Python-only configuration

### Changed

- **changelog.md Workflow** - Improved entry writing guidance and formatting
- **Consolidated Code Review Agents** - Merged code-quality.md into code-standards.md
- **Renamed pull-request.md to pr.md** - Shorter, consistent naming
- **Updated Workflow Agents** - Enhanced branch, preflight, postflight, release workflows
- **Cross-Reference Updates** - Updated ~40 agent files with new paths

### Removed

- **quality-check.sh** - Replaced by linters-local.sh
- **code-quality.md** - Consolidated into code-standards.md
- **code-review.md Workflow** - Consolidated into code-audit-remote.md

## [2.16.0] - 2025-12-06

### Added

- **Unified PR Command** - New `/pr` command orchestrating all quality checks
  - Combines linters-local, code-audit-remote, and code-standards checks
  - Intent vs reality analysis for comprehensive PR validation
- **Local Linting Command** - New `/linters-local` command for fast, offline linting
  - ShellCheck, secretlint, and pattern checks
  - No external service dependencies
- **Remote Audit Command** - New `/code-audit-remote` command for remote auditing
  - CodeRabbit, Codacy, and SonarCloud integration
- **Code Standards Command** - New `/code-standards` command for quality standards checking
- **New Scripts and Workflows**:
  - `linters-local.sh` - Local linting script (replaces quality-check.sh)
  - `workflows/pr.md` - Unified PR orchestrator workflow
  - `workflows/code-audit-remote.md` - Remote auditing workflow
  - `tools/code-review/code-standards.md` - Quality standards reference

### Changed

- **Renamed Scripts and Workflows** - Clarified naming for local vs remote operations
  - `quality-check.sh` → `linters-local.sh` (clarifies local-only scope)
  - `workflows/code-review.md` → `workflows/code-audit-remote.md` (clarifies remote services)
  - `tools/code-review/code-quality.md` → `tools/code-review/code-standards.md` (clarifies reference purpose)
  - `workflows/pull-request.md` → `workflows/pr.md` (now orchestrates all checks)
  - `@code-quality` subagent → `@code-standards`
- **Updated Documentation** - Comprehensive cross-reference updates
  - Updated `generate-opencode-commands.sh` with new command structure
  - Updated AGENTS.md with new quality workflow documentation
  - Updated README.md with new commands and workflow
  - Updated cross-references across ~40 agent files

### Removed

- `quality-check.sh` - Replaced by `linters-local.sh`
- `workflows/code-review.md` - Replaced by `workflows/code-audit-remote.md`
- `workflows/pull-request.md` - Replaced by `workflows/pr.md`
- `tools/code-review/code-quality.md` - Replaced by `tools/code-review/code-standards.md`

## [2.15.0] - 2025-12-06

### Added

- **OpenCode Commands Generation** - New `generate-opencode-commands.sh` script
  - Creates 13 workflow slash commands for OpenCode: `/agent-review`, `/preflight`, `/postflight`, `/release`, `/version-bump`, `/changelog`, `/code-audit-remote`, `/linters-local`, `/feature`, `/bugfix`, `/hotfix`, `/context`, `/pr`
  - Commands deployed to `~/.config/opencode/commands/` directory
  - Integrated into `setup.sh` for automatic deployment during installation

## [2.14.0] - 2025-12-06

### Added

- **Conversation Starter Workflow** - New `workflows/conversation-starter.md` for Plan+ and Build+
  - Unified prompts for git repository context (12 workflow options)
  - Remote services menu for non-git contexts (9 service integrations)
  - Automatic subagent context loading based on user selection

### Changed

- **Plan+ Agent Refactored** - Aligned with upstream OpenCode Plan prompts
  - 5-phase planning workflow: Understand, Investigate, Synthesize, Finalize, Handoff
  - Parallel explore agents support (1-3 agents in single message)
  - Reduced AI-CONTEXT from 100 to 49 lines (within instruction budget)
  - Added context tools table (osgrep, Augment, context-builder, Context7)

- **Build+ Agent Refactored** - Aligned with upstream OpenCode Build prompt (beast.txt)
  - Reduced AI-CONTEXT from 119 to 55 lines (within instruction budget)
  - Added context tools and quality integration tables
  - Preserved all 9 workflow steps with enhanced guidance
  - Added file reading best practices section

## [2.13.0] - 2025-12-06

### Added

- **One-liner Install Command** - Universal install/update via curl
  - `bash <(curl -fsSL https://raw.githubusercontent.com/marcusquinn/aidevops/main/setup.sh)`
  - Auto-detects curl execution, clones repo to ~/Git/aidevops
  - Re-executes local setup.sh after cloning for full setup
- **Global `aidevops` CLI Command** - New CLI installed to /usr/local/bin/aidevops
  - `aidevops status` - Comprehensive installation status check
  - `aidevops update` - Update to latest version
  - `aidevops uninstall` - Clean removal with prompts
  - `aidevops version` - Version info with update check
  - `aidevops help` - Usage information
- **Interactive Setup Prompts** - Enhanced setup.sh with optional installations
  - Required dependencies (jq, curl, ssh) via detected package manager
  - Optional dependencies (sshpass)
  - Recommended tools (Tabby terminal, Zed editor)
  - OpenCode extension for Zed
  - Git CLI tools (gh, glab)
  - SSH key generation
  - Shell aliases
- **Multi-Platform Package Manager Support** - Auto-detects brew, apt, dnf, yum, pacman, apk
- **Multi-Shell Support** - Detects and configures bash, zsh, fish, ksh with correct rc files
- **CLI Reference Documentation** - New `.wiki/CLI-Reference.md` with complete CLI docs

### Changed

- **setup.sh** - Major refactor with bootstrap_repo(), install_aidevops_cli(), setup_recommended_tools()
- **README.md** - Updated Quick Start section with one-liner install
- **Getting-Started.md** - Comprehensive installation guide update
- **Home.md** - Updated with new install method

## [2.12.0] - 2025-12-05

### Added

- **YAML Frontmatter with Tool Permissions** - Added to ~120 subagent files
  - Standardized tool permission declarations across all subagents
  - Enables OpenCode to enforce tool access controls per agent
- **Agent Directory Architecture Documentation** - Documented `.agent/` vs `.opencode/agent/` structure
  - Clarified deployment paths and directory purposes

### Changed

- **OpenCode Frontmatter Format** - Updated `build-agent.md` with correct format
  - Removed invalid `list` tool references from frontmatter
  - Removed invalid `permission` blocks from frontmatter
  - Aligned with OpenCode configuration validation requirements

### Removed

- **Duplicate Wiki File** - Removed `Workflow-Guides.md` (duplicate of `Workflows-Guide.md`)

### Fixed

- **OpenCode Config Validation Errors** - Fixed frontmatter format issues
  - Corrected tool permission syntax across subagent files
  - Resolved validation errors preventing agent loading

## [2.11.0] - 2025-12-05

### Added

- **osgrep Local Semantic Search** - New tool integration for 100% private semantic code search
  - Documentation in `.agent/tools/context/osgrep.md`
  - Config templates for osgrep MCP integration
  - Updated setup.sh and scripts for osgrep CLI support
  - GitHub issue comments submitted (#58, #26) for upstream bug tracking

## [2.10.0] - 2025-12-05

### Added

- **Conversation Starter Prompts** - Plan+ and Build+ agents now offer guided workflow selection
  - Git repository context: Workflow menu (Feature, Bug Fix, Hotfix, Refactor, PR, Release, etc.)
  - Non-git context: Remote services menu (101domains, Closte, Cloudflare, Hetzner, etc.)
  - Automatic subagent context loading based on user selection
- **Workflow Subagents** - Three new workflow subagents for release lifecycle
  - `workflows/preflight.md` - Pre-release quality checks (ShellCheck, Secretlint, SonarCloud)
  - `workflows/pull-request.md` - PR/MR workflow for GitHub, GitLab, and Gitea
  - `workflows/postflight.md` - Post-release CI/CD verification and rollback procedures
- **Preflight Integration** - Automatic quality gates before version bumping
  - New `--skip-preflight` flag for emergency releases
  - Phased checks: instant blocking, fast blocking, medium, slow advisory

### Changed

- **Enhanced Branch Lifecycle** - Expanded `workflows/branch.md` from 7 to 11 stages
  - New stages: Preflight, Version, Postflight
  - Subagent references at each lifecycle stage
  - Visual workflow chain diagram

## [2.9.0] - 2025-12-05

### Added

- **Branch Workflow System** - New `workflows/branch.md` with 6 branch type subagents
  - Feature, bugfix, hotfix, refactor, chore, experiment branch workflows
  - Standardized naming conventions and merge strategies
- **Setup.sh --clean Flag** - Remove stale deployed files during setup
  - New `verify-mirrors.sh` script for checking agent directory mirrors
- **Git Safety Practices** - Added to all build agents
  - Pre-destructive operation stash guidance
  - Protection for uncommitted and untracked files
- **Changelog Workflow** - New `workflows/changelog.md` subagent
  - Changelog validation in version-manager.sh
  - `changelog-check` and `changelog-preview` commands
  - Enforced changelog updates before releases

### Changed

- **Restructured Git Tools** - `tools/git.md` reorganized with platform CLI subagents
  - GitHub, GitLab, and Gitea CLI helpers as dedicated subagents
  - New `git/authentication.md` and `git/security.md` subagents
- **Consolidated Security Documentation** - Scripts security merged into `aidevops/security.md`
- **Separated Version Workflows** - Split into `version-bump.md` and `release.md` for clarity

### Removed

- Redundant `workflows/README.md` (content merged into main workflow docs)
- `release-improvements.md` (consolidated into release.md)

## [2.8.1] - 2025-12-04

### Added

- **OpenCode Tools** - Custom tool definitions for OpenCode AI assistant
- **MCP Testing Infrastructure** - Docker-based testing for MCP servers

### Changed

- Minor documentation updates and quality improvements

## [2.8.0] - 2025-12-04

### Added

- **Build-Agent** - New main agent for composing efficient AI agents
  - Promoted from `agent-designer.md` to main agent status
  - Comprehensive guidance on instruction budgets and agent design
- **Build-MCP** - New main agent for MCP server development
  - TypeScript + Bun + ElysiaJS stack guidance
  - Tool, resource, and prompt registration patterns

### Changed

- **Agent Naming Conventions** - Documented in `agent-designer.md`
- Reduced instruction count in agent-designer.md for efficiency
- Updated README with Build-Agent and Build-MCP in main agents table

## [2.7.4] - 2025-12-04

### Fixed

- **Outscraper API URL Correction** - Fixed base URL from `api.outscraper.cloud` to `api.app.outscraper.com`
  - Matches official Python SDK at <https://github.com/outscraper/outscraper-python>

### Added

- **Outscraper Account & Billing API Documentation** - New endpoints not available in Python SDK
  - `GET /profile/balance` - Account balance, status, and upcoming invoice
  - `GET /invoices` - User invoice history
- **Outscraper Task Management API Documentation** - Full task lifecycle control
  - `POST /tasks` - Create UI tasks programmatically
  - `POST /tasks-validate` - Validate and estimate task cost before creation
  - `PUT /tasks/{taskId}` - Restart tasks
  - `DELETE /tasks/{taskId}` - Terminate tasks
  - `GET /webhook-calls` - Failed webhook calls (last 24 hours)
  - `GET /locations` - Country locations for Google Maps searches
- **SDK vs Direct API Clarification** - Added "In SDK" column to endpoint tables
  - Clearly marked which features require direct API calls vs SDK methods
  - Added link to official SDK repository
- **Expanded Tool Coverage** - Additional tools documented
  - `yelp_reviews`, `yelp_search`, `trustpilot_search`, `yellowpages_search`
  - `contacts_and_leads`, `whitepages_phones`, `whitepages_addresses`
  - `company_websites_finder`, `similarweb`
- **Python Examples** - Comprehensive code examples for all API patterns
  - Account & Billing section (Direct API Only)
  - Task Management section (Direct API + SDK hybrid)
  - Proper initialization patterns with both SDK and direct requests

### Changed

- **Account Access Documentation** - Replaced incorrect "Account Limitations" section
  - Previously stated account info was dashboard-only (incorrect)
  - New "Account Access via API" section with accurate endpoint information

## [2.7.3] - 2025-12-04

### Fixed

- **Outscraper MCP Documentation Improvements** - Enhanced documentation quality and accuracy
  - Fixed JSON syntax error in documentation (malformed JSON block with extra braces)
  - Standardized install command from `uvx` to `uv tool run` for consistency
  - Added "Tested tools" section documenting verified functionality (Dec 2024)
  - Added OpenCode-specific troubleshooting section for `env` key and `uvx` command issues

## [2.7.2] - 2025-12-04

### Fixed

- **Outscraper MCP Server Fails to Start** - Fixed `uvx` command conflict
  - `uvx` on some systems is a different tool (not uv's uvx alias)
  - Changed to `uv tool run outscraper-mcp-server` which is the correct way to run Python tools with uv
  - Updated `generate-opencode-agents.sh`, `outscraper.md`, `outscraper.json` template, and `outscraper-config.json.txt`

## [2.7.1] - 2025-12-04

### Fixed

- **OpenCode MCP Config Validation Error** - Fixed invalid `env` key in MCP configuration
  - OpenCode does not support the `env` key for MCP server configs
  - Changed to bash wrapper pattern: `/bin/bash -c "VAR=$VAR command"`
  - Updated `generate-opencode-agents.sh`, `outscraper.md`, `outscraper.json` template, and `outscraper-config.json.txt`

## [2.7.0] - 2025-12-04

### Added

- **Outscraper MCP Server Integration** - Data extraction service for OpenCode
  - Automatic MCP server configuration in `generate-opencode-agents.sh`
  - Adds `outscraper` to MCP section with uvx command and environment variable
  - Subagent-only access pattern via `@outscraper` for controlled usage

### Changed

- **Tool-Specific Subagent Strategy** - Enhanced security model for external service tools
  - Added special handling for tool-specific subagents (outscraper, mainwp, localwp, quickfile, google-search-console)
  - Main agents (Content, Marketing, Research, Sales, SEO) no longer have direct outscraper access
  - Tools disabled globally (`outscraper_*: false`) with access only through dedicated subagents
- Updated `outscraper.md` documentation to reflect subagent-only access pattern
- Updated `outscraper-config.json.txt` agent enablement section

## [2.6.0] - 2025-12-04

### Added

- **Repomix AI Context Generation** - Configuration and documentation for Repomix integration
  - `repomix.config.json` - Default configuration with XML output, line numbers, security checks, smart includes for .md/.sh/.json.txt files
  - `.repomixignore` - Additional exclusions beyond .gitignore (symlinked dirs, binaries, generated outputs)
  - `repomix-instruction.md` - Custom AI instructions embedded in Repomix output to help AI understand codebase structure

### Changed

- Updated `.gitignore` with `repomix-output.*` patterns to exclude generated outputs
- Enhanced `README.md` with comprehensive "Repomix - AI Context Generation" section:
  - Comparison table with Augment Context Engine
  - Quick usage commands and configuration files reference
  - Key design decisions (no pre-generated files, .gitignore inheritance, Secretlint enabled, symlinks excluded)
  - MCP integration configuration example

## [2.5.3] - 2025-12-04

### Security

- **Plan+ Agent Permission Bypass Fix** - Closed vulnerability allowing read-only agent to bypass restrictions
  - Disabled `bash` tool to prevent shell command file writes
  - Disabled `task` tool to prevent spawning write-capable subagents (subagents don't inherit parent permissions)
  - Added explicit `write: deny` permission for defense in depth
  - Updated `.agent/plan-plus.md` documentation to reflect strict read-only mode

### Added

- **Permission Model Limitations Documentation** - New section in `.agent/tools/opencode/opencode.md`
  - Documents OpenCode permission inheritance behavior
  - Explains subagent permission isolation
  - Provides guidance for securing read-only agents

## [2.2.0] - 2025-11-30

### Added

- **Secretlint Integration** - Secret detection tool to prevent committing credentials
  - New `secretlint-helper.sh` for installation, scanning, and pre-commit hook management
  - Configuration files `.secretlintrc.json` and `.secretlintignore` for project-specific setup
  - Comprehensive documentation in `.agent/secretlint.md`
  - Multi-provider detection: AWS, GCP, GitHub, OpenAI, Anthropic, Slack, npm tokens
  - Private key detection: RSA, DSA, EC, OpenSSH keys
  - Database connection string scanning
  - Docker support for running scans without Node.js

### Changed

- Updated `quality-check.sh` with secretlint integration for comprehensive secret scanning
- Enhanced `pre-commit-hook.sh` with secretlint pre-commit checks
- Extended `linter-manager.sh` with secretlint as a supported security linter
- Updated `.gitignore` with exceptions for secretlint tool files

### Fixed

- Removed duplicate/unreachable return statements in helper scripts
- Replaced eval with array-based execution for improved security
- Changed hardcoded /tmp paths to mktemp for safer temporary file handling
- Added input validation for target patterns in quality scripts
- Fixed unused variables and awk field references
- Fixed markdown formatting issues

## [2.0.0] - 2025-11-29

### Added

- **Comprehensive AI Workflow Documentation** - 9 new workflow guides in `.agent/workflows/`:
  - `git-workflow.md` - Git practices and branch strategies
  - `bug-fixing.md` - Bug fix and hotfix workflows
  - `feature-development.md` - Feature development lifecycle
  - `code-review.md` - Universal code review checklist
  - `error-checking-feedback-loops.md` - CI/CD feedback automation with GitHub API
  - `multi-repo-workspace.md` - Multi-repository safety guidelines
  - `release-process.md` - Semantic versioning and release management
  - `wordpress-local-testing.md` - WordPress testing environments
  - `README.md` - Workflow index and guide
- **Quality Feedback Helper Script** - `quality-feedback-helper.sh` for GitHub API-based quality tool feedback retrieval (Codacy, CodeRabbit, SonarCloud, CodeFactor)
- OpenCode as preferred CLI AI assistant in documentation
- Grep by Vercel MCP server integration for GitHub code search
- Cross-tool AI assistant symlinks (.cursorrules, .windsurfrules, CLAUDE.md, GEMINI.md)
- OpenCode custom tool definitions in `.opencode/tool/`
- Consolidated `.agent/` directory structure
- Developer preferences guidance in `.agent/memory/README.md`

### Changed

- **Major milestone**: Comprehensive AI assistant workflow documentation
- Reorganized CLI AI assistants list with OpenCode at top
- Moved AmpCode and Continue.dev from Security section to CLI Assistants
- Updated MCP server count to 13
- Standardized service counts across documentation (30+)
- Enhanced `.markdownlint.json` configuration

### Fixed

- All CodeRabbit, Codacy, and ShellCheck review issues resolved
- Duplicate timestamp line in system-cleanup.sh
- Hardcoded path in setup-mcp-integrations.sh
- SC2155 ShellCheck violations in workflow scripts
- MD040 markdown code block language identifiers
- MD031 blank lines around code blocks

## [1.9.1] - 2024-11-28

### Added

- Snyk security scanning as 29th service integration
- Enhanced quality automation workflows

### Fixed

- Code quality improvements via automated fixes

## [1.9.0] - 2024-11-27

### Added

- Version validation workflow
- Auto-version bump scripts
- Enhanced Git CLI helpers for GitHub, GitLab, and Gitea

### Changed

- Improved quality check scripts
- Updated documentation structure

## [1.8.0] - 2024-11-19

### Added

- Zero technical debt milestone achieved
- Multi-platform quality compliance (SonarCloud, CodeFactor, Codacy)
- Universal parameter validation patterns across all provider scripts
- Automated quality tool integration

### Changed

- **Positional Parameters (S7679)**: 196 → 0 violations (100% elimination)
- **SonarCloud Issues**: 585 → 0 issues (perfect compliance)
- All provider scripts now use proper main() function wrappers
- Enhanced error handling with local variable usage

### Fixed

- Return statement issues across all scripts
- ShellCheck violations in 21 files

## [1.7.2] - 2024-11-15

### Added

- Initial MCP integrations (10 servers)
- Browser automation with Stagehand AI
- SEO tools integration (Ahrefs, Google Search Console)

### Changed

- Expanded service coverage to 26+ integrations

## [1.7.0] - 2024-11-10

### Added

- TOON Format integration for token-efficient data exchange
- DSPy integration for prompt optimization
- PageSpeed Insights and Lighthouse integration
- Updown.io monitoring integration

### Changed

- Restructured documentation for better clarity

## [1.6.0] - 2024-11-01

### Added

- Git platform CLI helpers (GitHub, GitLab, Gitea)
- Coolify and Vercel CLI integrations
- Cloudron hosting support

### Changed

- Enhanced multi-account support across providers

## [1.5.0] - 2024-10-15

### Added

- Quality CLI manager for unified tool access
- CodeRabbit AI-powered code review integration
- Qlty universal linting platform support

### Changed

- Improved quality automation workflows

## [1.0.0] - 2024-09-01

### Added

- Initial release of AI DevOps Framework
- Core provider integrations (Hostinger, Hetzner, Cloudflare)
- SSH key management utilities
- AGENTS.md guidance system
- Basic quality assurance setup

[Unreleased]: https://github.com/marcusquinn/aidevops/compare/v2.29.0...HEAD
[2.29.0]: https://github.com/marcusquinn/aidevops/compare/v2.28.0...v2.29.0
[2.28.0]: https://github.com/marcusquinn/aidevops/compare/v2.27.4...v2.28.0
[2.27.4]: https://github.com/marcusquinn/aidevops/compare/v2.27.3...v2.27.4
[2.27.3]: https://github.com/marcusquinn/aidevops/compare/v2.27.2...v2.27.3
[2.27.2]: https://github.com/marcusquinn/aidevops/compare/v2.27.1...v2.27.2
[2.27.1]: https://github.com/marcusquinn/aidevops/compare/v2.27.0...v2.27.1
[2.27.0]: https://github.com/marcusquinn/aidevops/compare/v2.26.0...v2.27.0
[2.26.0]: https://github.com/marcusquinn/aidevops/compare/v2.25.0...v2.26.0
[2.25.0]: https://github.com/marcusquinn/aidevops/compare/v2.24.0...v2.25.0
[2.24.0]: https://github.com/marcusquinn/aidevops/compare/v2.23.1...v2.24.0
[2.23.1]: https://github.com/marcusquinn/aidevops/compare/v2.23.0...v2.23.1
[2.23.0]: https://github.com/marcusquinn/aidevops/compare/v2.22.0...v2.23.0
[2.22.0]: https://github.com/marcusquinn/aidevops/compare/v2.21.0...v2.22.0
[2.21.0]: https://github.com/marcusquinn/aidevops/compare/v2.20.5...v2.21.0
[2.20.5]: https://github.com/marcusquinn/aidevops/compare/v2.20.4...v2.20.5
[2.20.4]: https://github.com/marcusquinn/aidevops/compare/v2.20.3...v2.20.4
[2.20.3]: https://github.com/marcusquinn/aidevops/compare/v2.20.2...v2.20.3
[2.20.2]: https://github.com/marcusquinn/aidevops/compare/v2.19.13...v2.20.2
[2.19.13]: https://github.com/marcusquinn/aidevops/compare/v2.19.12...v2.19.13
[2.19.12]: https://github.com/marcusquinn/aidevops/compare/v2.19.11...v2.19.12
[2.19.11]: https://github.com/marcusquinn/aidevops/compare/v2.17.1...v2.19.11
[2.17.1]: https://github.com/marcusquinn/aidevops/compare/v2.17.0...v2.17.1
[2.17.0]: https://github.com/marcusquinn/aidevops/compare/v2.16.0...v2.17.0
[2.16.0]: https://github.com/marcusquinn/aidevops/compare/v2.15.0...v2.16.0
[2.15.0]: https://github.com/marcusquinn/aidevops/compare/v2.14.0...v2.15.0
[2.14.0]: https://github.com/marcusquinn/aidevops/compare/v2.13.0...v2.14.0
[2.13.0]: https://github.com/marcusquinn/aidevops/compare/v2.12.0...v2.13.0
[2.12.0]: https://github.com/marcusquinn/aidevops/compare/v2.11.0...v2.12.0
[2.11.0]: https://github.com/marcusquinn/aidevops/compare/v2.10.0...v2.11.0
[2.10.0]: https://github.com/marcusquinn/aidevops/compare/v2.9.0...v2.10.0
[2.9.0]: https://github.com/marcusquinn/aidevops/compare/v2.8.1...v2.9.0
[2.8.1]: https://github.com/marcusquinn/aidevops/compare/v2.8.0...v2.8.1
[2.8.0]: https://github.com/marcusquinn/aidevops/compare/v2.7.4...v2.8.0
[2.7.4]: https://github.com/marcusquinn/aidevops/compare/v2.7.3...v2.7.4
[2.7.3]: https://github.com/marcusquinn/aidevops/compare/v2.7.2...v2.7.3
[2.7.2]: https://github.com/marcusquinn/aidevops/compare/v2.7.1...v2.7.2
[2.7.1]: https://github.com/marcusquinn/aidevops/compare/v2.7.0...v2.7.1
[2.7.0]: https://github.com/marcusquinn/aidevops/compare/v2.6.0...v2.7.0
[2.6.0]: https://github.com/marcusquinn/aidevops/compare/v2.5.3...v2.6.0
[2.5.3]: https://github.com/marcusquinn/aidevops/compare/v2.2.0...v2.5.3
[2.2.0]: https://github.com/marcusquinn/aidevops/compare/v2.0.0...v2.2.0
[2.0.0]: https://github.com/marcusquinn/aidevops/compare/v1.9.1...v2.0.0
[1.9.1]: https://github.com/marcusquinn/aidevops/compare/v1.9.0...v1.9.1
[1.9.0]: https://github.com/marcusquinn/aidevops/compare/v1.8.0...v1.9.0
[1.8.0]: https://github.com/marcusquinn/aidevops/compare/v1.7.2...v1.8.0
[1.7.2]: https://github.com/marcusquinn/aidevops/compare/v1.7.0...v1.7.2
[1.7.0]: https://github.com/marcusquinn/aidevops/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/marcusquinn/aidevops/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/marcusquinn/aidevops/compare/v1.0.0...v1.5.0
[1.0.0]: https://github.com/marcusquinn/aidevops/releases/tag/v1.0.0
