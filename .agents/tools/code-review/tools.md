---
description: Code review tools — linters, quality platforms, and config references
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Code Review Tools

<!-- AI-CONTEXT-START -->

## Quick Reference

- Linter manager: `linter-manager.sh detect|install-detected|install-all|install [lang]`
- Config files: `.eslintrc.*`, `.pylintrc`, `.shellcheckrc`, `.hadolint.yaml`, `.stylelintrc.*`
- Best practices: start conservative, customize gradually, version control configs

## Language Linters

| Language | Tools | Config |
|----------|-------|--------|
| Python | pycodestyle, Pylint, Bandit, Ruff | `setup.cfg`, `.pylintrc`, `.bandit`, `pyproject.toml` |
| JavaScript/TypeScript | Oxlint, ESLint | `.eslintrc.*`, `.oxlintrc.json` |
| CSS/SCSS/Less | Stylelint 16.25.0 | `.stylelintrc*` |
| Shell | ShellCheck 0.11.0 | `.shellcheckrc` |
| Docker | Hadolint 2.14.0 | `.hadolint.yaml` |
| YAML | Yamllint 1.37.1 | `.yamllint*` |
| Go | Revive 1.12.0 | `revive.toml` |
| PHP | PHP_CodeSniffer 3.13.5 | `phpcs.xml` |
| Ruby | RuboCop, bundler-audit, Brakeman | `.rubocop.yml` |
| Java | Checkstyle 12.1.1 | `checkstyle.xml` |
| C# | StyleCop.Analyzers | `.editorconfig` |
| Swift | SwiftLint 0.62.1 | `.swiftlint.yml` |
| Kotlin | Detekt 1.23.8 | `detekt.yml` |
| Dart | Linter for Dart 3.10.0 | `analysis_options.yaml` |
| R | Lintr 3.2.0 | `.lintr` |
| C/C++ | CppLint, Flawfinder | `CPPLINT.CFG` |
| Haskell | HLint 3.10 | `.hlint.yaml` |
| Groovy | CodeNarc 3.6.0 | `codenarc.xml` |
| PowerShell | PSScriptAnalyzer 1.24.0 | `PSScriptAnalyzerSettings.psd1` |
| Security | Trivy 0.67.2 | `trivy.yaml` |

Reference: [CodeFactor Analysis Tools](https://docs.codefactor.io/bootcamp/analysis-tools/)

## Quality Platforms

| Platform | Integration | Auto-Fix | Notes |
|----------|-------------|----------|-------|
| CodeRabbit | CLI | No | AI-powered PR review, contextual suggestions |
| Codacy | CLI + Web | Yes (70-90%) | 40+ langs, style/best-practices/security |
| SonarCloud | CLI + Web | No | Enterprise analysis, security vuln detection, tech debt |
| Qlty | CLI | Yes (80-95%) | 70+ tools, 40+ langs, auto-formatting |
| CodeFactor | Web only | No | Reference collection for tool selection |
| ESLint | CLI | Yes (60-80%) | JS/TS style + best practices |

## Rule References

- [ESLint Rules](https://eslint.org/docs/rules/)
- [Pylint Messages](https://pylint.pycqa.org/en/latest/technical_reference/features.html)
- [ShellCheck Wiki](https://github.com/koalaman/shellcheck/wiki)
- [Stylelint Rules](https://stylelint.io/user-guide/rules/list)
- [Awesome Static Analysis](https://github.com/analysis-tools-dev/static-analysis)

<!-- AI-CONTEXT-END -->
