---
description: AI DevOps code review tools and resources
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

# AI DevOps Resources

<!-- AI-CONTEXT-START -->

## Quick Reference

- Linter manager: `bash .agents/scripts/linter-manager.sh detect|install-detected|install-all|install [lang]`
- Languages: Python (pycodestyle, Pylint, Bandit, Ruff), JS/TS (Oxlint, ESLint), CSS (Stylelint), Shell (ShellCheck), Docker (Hadolint), YAML (Yamllint)
- Platforms: CodeRabbit (AI review, no auto-fix), Codacy (40+ langs, auto-fix), SonarCloud (enterprise, no auto-fix), Qlty (70+ tools, auto-format), CodeFactor (reference only)
- Auto-fix rates: Qlty CLI 80-95%, Codacy CLI 70-90%, ESLint 60-80%
- Config files: `.eslintrc.*`, `.pylintrc`, `.shellcheckrc`, `.hadolint.yaml`, `.stylelintrc.*`
- Best practices: start conservative, customise gradually, version-control configs

<!-- AI-CONTEXT-END -->

## Language-Specific Linters

| Language | Tools | Config |
|----------|-------|--------|
| **Python** | pycodestyle, Pylint, Bandit, Ruff | `setup.cfg`, `.pylintrc`, `.bandit`, `pyproject.toml` |
| **JavaScript/TypeScript** | Oxlint, ESLint | `.eslintrc.*`, `tsconfig.json`, `.oxlintrc.json` |
| **CSS/SCSS/Less** | Stylelint | `.stylelintrc.*`, `stylelint.config.js` |
| **Shell** | ShellCheck | `.shellcheckrc` |
| **Docker** | Hadolint | `.hadolint.yaml` |
| **YAML** | Yamllint | `.yamllint.yaml` |
| **Go** | Revive | `revive.toml` |
| **PHP** | PHP_CodeSniffer | `phpcs.xml` |
| **Ruby** | RuboCop, bundler-audit, Brakeman | `.rubocop.yml` |
| **Java** | Checkstyle | `checkstyle.xml` |
| **C#** | StyleCop.Analyzers | `.editorconfig` |
| **Swift** | SwiftLint | `.swiftlint.yml` |
| **Kotlin** | Detekt | `detekt.yml` |
| **Dart** | Linter for Dart | `analysis_options.yaml` |
| **R** | Lintr | `.lintr` |
| **C/C++** | CppLint, Flawfinder | `CPPLINT.CFG` |
| **Haskell** | HLint | `.hlint.yaml` |
| **Groovy** | CodeNarc | `codenarc.xml` |
| **PowerShell** | PSScriptAnalyzer | `PSScriptAnalyzerSettings.psd1` |
| **Security** | Trivy | `trivy.yaml` |

Reference: [CodeFactor Analysis Tools](https://docs.codefactor.io/bootcamp/analysis-tools/)

## Linter Manager

```bash
bash .agents/scripts/linter-manager.sh detect           # detect languages
bash .agents/scripts/linter-manager.sh install-detected # install for detected langs
bash .agents/scripts/linter-manager.sh install-all      # install all supported
bash .agents/scripts/linter-manager.sh install python   # install for specific lang
```

## Quality Platforms

| Platform | Integration | Auto-Fix | Notes |
|----------|-------------|----------|-------|
| **CodeRabbit** | CLI | No | AI-powered PR review, contextual suggestions |
| **Codacy** | CLI + Web | Yes | 40+ languages, safe-violation auto-fix |
| **SonarCloud** | CLI + Web | No | Enterprise analysis, security + tech-debt tracking |
| **Qlty** | CLI | Yes | 70+ tools, 40+ languages, auto-formatting |
| **CodeFactor** | Web only | No | Reference linter collection |

## Auto-Fix Tools

| Tool | Languages | Fix Types | Time Savings |
|------|-----------|-----------|--------------|
| **Qlty CLI** | 40+ | Formatting, linting, smells | 80-95% |
| **Codacy CLI** | Multi | Style, best practices, security | 70-90% |
| **ESLint** | JS/TS | Style, best practices | 60-80% |
| **Pylint** | Python | Style, code quality | 50-70% |
| **RuboCop** | Ruby | Style, best practices | 60-80% |
| **SwiftLint** | Swift | Style, best practices | 50-70% |

## Additional Resources

- [ESLint Rules](https://eslint.org/docs/rules/)
- [Pylint Messages](https://pylint.pycqa.org/en/latest/technical_reference/features.html)
- [ShellCheck Wiki](https://github.com/koalaman/shellcheck/wiki)
- [Stylelint Rules](https://stylelint.io/user-guide/rules/list)
- [Awesome Static Analysis](https://github.com/analysis-tools-dev/static-analysis)
