# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/marcusquinn/aidevops/compare/v2.11.0...HEAD
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
