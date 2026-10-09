# Migrate Codacy local analysis to the Codacy Analysis CLI (`@codacy/analysis-cli`)

## Origin

- Created: 2026-10-09, interactive session (ai-interactive), requested by maintainer.
- Source: https://docs.codacy.com/codacy-analysis-cli/

## What

Replace the dead Codacy CLI v2 (`codacy-cli`) integration with Codacy's current
Codacy Analysis CLI (`codacy-analysis`, npm `@codacy/analysis-cli`, Node 20+).

## Why

- `.agents/scripts/codacy-cli.sh` wraps `codacy-cli` v2, which is not installed and
  whose Linux binary was removed; `.github/workflows/code-review-monitoring.yml:79-81`
  skips Codacy entirely, so CI has no local Codacy analysis.
- `codacy-cli.sh analyze --fix` is documented as auto-fix, but neither CLI offers a fix mode.
- The new CLI's `init --remote <provider> <org> <repo>` pulls the effective Codacy
  Cloud policy, giving local/CI parity with PR analysis; `analyze --staged|--diff|--pr`
  exits 1 on findings, so it can gate changes.

## How

### Files to Modify

- EDIT: `.agents/scripts/codacy-cli.sh` — rewrite around `codacy-analysis`
  (install via npm, init remote/auto/default/local, update-config, analyze with
  scope flags + SARIF/JSON output, upload, status). Tokens only via environment,
  never argv; support `CODACY_<OWNER>_<REPO>_PROJECT_TOKEN` scoped names.
- DELETE: `.agents/scripts/codacy-cli-chunked.sh`, `.agents/scripts/tests/test-codacy-cli-chunked-help.sh`
  (chunking is superseded by `--tool`, `--parallel-tools`, `--tool-timeout`).
- EDIT: `tests/test-smoke-help.sh` — drop the chunked entry.
- EDIT: `.agents/scripts/monitor-code-review.sh`, `.agents/scripts/quality-cli-manager.sh`,
  `.agents/scripts/setup-linters-wizard.sh` — remove false auto-fix claims.
- EDIT: `.github/workflows/code-review-monitoring.yml` — install pinned CLI and run analysis.
- EDIT: `.agents/tools/code-review/codacy.md` — document the new CLI.
- EDIT: `.gitignore` — ignore `.codacy/` and `codacy-results.sarif`.

### Files Scope

- `.agents/scripts/codacy-cli.sh`
- `.agents/scripts/codacy-cli-chunked.sh`
- `.agents/scripts/tests/test-codacy-cli-chunked-help.sh`
- `tests/test-smoke-help.sh`
- `.agents/scripts/monitor-code-review.sh`
- `.agents/scripts/quality-cli-manager.sh`
- `.agents/scripts/setup-linters-wizard.sh`
- `.github/workflows/code-review-monitoring.yml`
- `.agents/tools/code-review/codacy.md`
- `.gitignore`

### Verification

- `shellcheck` on changed scripts; `.agents/scripts/linters-local.sh`.
- Runtime: `codacy-cli.sh install|init|analyze|status` against this repository.

## Acceptance Criteria

- [x] `codacy-cli.sh` drives `codacy-analysis`; no `codacy-cli` v2 references remain.
- [x] `analyze` returns 0 (clean), 1 (findings) and 2 (usage/setup error, or
      analyzer tool errors with results still written) distinctly.
- [x] Tokens are never passed on the command line.
- [x] CI installs the pinned CLI and runs Codacy analysis (fail-open; the existing
      `upload-sarif` step publishes `codacy-results.sarif`).
- [x] Docs no longer claim Codacy CLI auto-fix.
- [x] ShellCheck clean on changed scripts. `tests/test-smoke-help.sh` aborts at the
      help section on `main` too (pre-existing `set -e` issue, tracked separately).
