# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- OpenCode as preferred CLI AI assistant in documentation
- Greptile MCP server integration for GitHub code search
- Cross-tool AI assistant symlinks (.cursorrules, .windsurfrules, CLAUDE.md, GEMINI.md)
- OpenCode custom tool definitions in `.opencode/tool/`
- Consolidated `.agent/` directory structure

### Changed

- Reorganized CLI AI assistants list with OpenCode at top
- Moved AmpCode and Continue.dev from Security section to CLI Assistants
- Updated MCP server count to 13
- Standardized service counts across documentation (30+)

### Fixed

- Duplicate timestamp line in system-cleanup.sh
- Hardcoded path in setup-mcp-integrations.sh

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

[Unreleased]: https://github.com/marcusquinn/aidevops/compare/v1.9.1...HEAD
[1.9.1]: https://github.com/marcusquinn/aidevops/compare/v1.9.0...v1.9.1
[1.9.0]: https://github.com/marcusquinn/aidevops/compare/v1.8.0...v1.9.0
[1.8.0]: https://github.com/marcusquinn/aidevops/compare/v1.7.2...v1.8.0
[1.7.2]: https://github.com/marcusquinn/aidevops/compare/v1.7.0...v1.7.2
[1.7.0]: https://github.com/marcusquinn/aidevops/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/marcusquinn/aidevops/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/marcusquinn/aidevops/compare/v1.0.0...v1.5.0
[1.0.0]: https://github.com/marcusquinn/aidevops/releases/tag/v1.0.0
