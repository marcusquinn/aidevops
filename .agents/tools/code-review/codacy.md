---
description: Codacy local analysis (Codacy Analysis CLI), quality gates, and API operations
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Codacy Integration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Local analysis:** `codacy-cli.sh` wraps the [Codacy Analysis CLI](https://docs.codacy.com/codacy-analysis-cli/)
  (npm `@codacy/analysis-cli`, command `codacy-analysis`, Node.js 20+). It replaces Codacy CLI v2.
- **Install:** `bash .agents/scripts/codacy-cli.sh install` (pinned version, `npm -g --ignore-scripts`).
- **Configure:** `codacy-cli.sh init` pulls the repository's Codacy Cloud rules when a token is available (`remote`), otherwise detects the stack locally (`auto`). `--force` regenerates.
- **Analyze:** `codacy-cli.sh analyze --diff` (changed files), `--staged` (pre-commit), `--pr`, or no scope (whole repo). `--sarif [FILE]` writes SARIF.
- **Exit codes:** `0` no issues, `1` issues found or failure, `2` usage/setup error or analyzer tool errors (results still written; a full aidevops scan currently reports Opengrep/Bandit tool errors).
- **No auto-fix:** Codacy has no fix mode; `--fix` and `quality-cli-manager.sh analyze codacy-fix` remain only as deprecated aliases that run analysis.
- **Status:** `codacy-cli.sh status` (exit 1 when the CLI is missing).

## Quality Gate Settings

**Current gate (PR and commits):** max 10 new issues, minimum severity Warning.

**Historical rationale (GH#4910, t1489):** Originally 0 max new issues. Tripped 4x during extract-function refactoring — new helper functions add complexity counts, subprocess calls trigger Bandit warnings. The grade remained A during that investigation. Raised to 10 Warning+ to absorb refactoring noise; this historical decision does not establish today's grade or justify ignoring genuine new findings.

**Do not change thresholds merely to improve a badge.** Evaluate the live project grade, analysis completeness, and individual findings together. A passing per-PR issue-count gate does not establish an A-grade repository.

## Local Pre-Push Checks (GH#4939)

`linters-local.sh` includes checks aligned with Codacy's complexity engine, catching issues locally before push:

| Check | Codacy equivalent | Warning | Blocking | Gate |
|-------|-------------------|---------|----------|------|
| `function-complexity` | Function length | >50 lines | >100 lines | `function-complexity` |
| `nesting-depth` | Cyclomatic complexity | >5 levels | >8 levels | `nesting-depth` |
| `file-size` | Non-README Markdown length | >1000 lines at root / >500 elsewhere | New violations | `file-size` |
| `python-complexity` | Lizard CCN | >8 (advisory) | — | `python-complexity` |

`python-complexity` runs Lizard (same tool Codacy uses) and Pyflakes locally.

Markdown size remediation: first review the whole document for concision without losing any detail (remove repetition/wordiness, consolidate duplicated sections, use tables where clearer). Apply that pass when possible; only then split/index, and use a justified bypass only when that is insufficient. See [large-file guidance](../../reference/large-file-split.md#markdown-size-remediation).

Use the checked-in linter and CI policy as the authority for thresholds. Pay down existing debt through bounded fixes; do not increase allowances to pass a quality campaign.

CI enforcement: `.github/workflows/code-quality.yml` runs the same checks on every PR via the `complexity-check` job, blocking merges that exceed thresholds.

Skip via bundle config: add gate names to `skip_gates` in the project bundle.

## Codacy API Patterns (verified working)

### Project-token naming and scale

Treat a repository-scoped token's storage name as part of its scope. Use
`CODACY_<OWNER>_<REPOSITORY>_PROJECT_TOKEN` (uppercase, with non-alphanumeric
characters replaced by underscores), for example
`CODACY_MARCUSQUINN_AIDEVOPS_PROJECT_TOKEN`. This prevents one repository's
token from silently replacing another as the managed repository set grows.

`CODACY_PROJECT_TOKEN` is Codacy's standard process-level variable and remains a
compatibility interface for tools that require that exact name; it should not be
the default persistent identity for multiple repositories. Inject or map only
the selected repository token into that variable for the lifetime of one
command. Until aidevops secret injection supports environment-name aliases,
repository-specific direct API operations should read the scoped secret by its
exact stored name rather than persisting another generic copy. Never put either
token value in a command argument, repository file, log, issue, or chat.

Codacy project-token authentication uses the `project-token` HTTP header. The
older account token uses `api-token`; using the wrong header can look like a
permission failure even when the token itself is valid. A valid project token
can authenticate repository reads while still receiving `403` for privileged
operations; successful authentication is not proof of mutation authority.

### Verified repository policy audit (2026-09-08)

Codacy's repository tool endpoint is the authority for effective tool state;
the legacy `engines.*.enabled` entries in `.codacy.yml` do not enable or disable
tools. The verified aidevops policy uses the dedicated `aidevops modern
runtimes` coding standard with these 16 tools enabled: Agentlinter, Bandit,
Biome, Brakeman, ESLint, Hadolint, Jackson Linter, markdownlint, Opengrep,
Pylint, RuboCop, ShellCheck, SQLint, Stylelint, Trivy, and TSQLLint.
PMD and Prospector remain disabled. Lizard has been off in every coding
standard of every organization since 2026-10-09: it repeated the complexity
findings that PHP Mess Detector and SonarCloud already report. The local
`python-complexity` gate still runs Lizard, so Python CCN is checked before push. Bandit, Biome, markdownlint, and ShellCheck
report that they use their checked-in native configuration files.

The language-settings API exposes enabled/detected languages and extensions,
not an ECMAScript-version selector. JavaScript and TypeScript are detected and
enabled. This repository declares ES modules and Node.js 20 or newer, and its
TypeScript server check targets ES2022. Therefore the ES3/ES5 compatibility
patterns `ESLint8_es-x_no-modules`,
`ESLint8_es-x_no-block-scoped-variables`, and
`ESLint8_es-x_no-trailing-commas` are intentionally disabled. `Bandit_B404` is
also disabled because `.bandit` documents the narrower subprocess rules that
remain active. Before correction, exact-SHA overview counts were 84
(`no-modules`), 56 (`no-block-scoped-variables`), 40 (`no-trailing-commas`),
and 83 (`B404`). A normal exact-SHA reanalysis cleared the three ESLint counts.
A subsequent Codacy Support cache-cleared reanalysis still retained 83 historical
B404 issue records even though the effective pattern endpoint and `.bandit` both
disable B404. The issue overview therefore does not prove current policy drift
for a disabled pattern. Use the effective pattern endpoint as the policy
authority; do not bulk-ignore records, weaken Bandit, or rewrite safe subprocess
imports to manipulate historical issue totals. Keep the live standard and native
files aligned; changing the inert `.codacy.yml` engine map is not a tool-setting
migration.

```bash
# Commit delta statistics (new issues count + complexity delta)
curl -s -H "api-token: $CODACY_API_TOKEN" \
  "https://app.codacy.com/api/v3/analysis/organizations/gh/marcusquinn/repositories/aidevops/commits/<SHA>/deltaStatistics"

# Per-file new issues (paginate with cursor)
curl -s -H "api-token: $CODACY_API_TOKEN" \
  "https://app.codacy.com/api/v3/analysis/organizations/gh/marcusquinn/repositories/aidevops/commits/<SHA>/files?limit=100"
# Filter: .data[] | select(.quality.deltaNewIssues > 0)

# Search all issues (POST, filter by language)
curl -s -H "api-token: $CODACY_API_TOKEN" -H "Content-Type: application/json" \
  -X POST "https://app.codacy.com/api/v3/analysis/organizations/gh/marcusquinn/repositories/aidevops/issues/search?limit=50" \
  -d '{"languages": ["Python"]}'
```

## Quality-sweep health telemetry

The daily quality sweep reads the repository summary and issue overview without
changing Codacy settings. It renders grade, issue count, analysed LOC, complex
files, analysed SHA, an analysis-health state, and a separate A-grade target.

For a read-only remote report without posting to GitHub or running other scanners:

```bash
bash .agents/scripts/stats-quality-sweep-tools.sh codacy OWNER/REPO /path/to/repo
```

The command uses the existing Codacy account token from secure storage. It only
updates the local healthy-sample file when the evidence permits it. Override
`QUALITY_SWEEP_STATE_DIR` to isolate a diagnostic run from daily-sweep state.

The verified API v3.1.0 contracts are:

- Repository summary: `GET /analysis/organizations/gh/{owner}/repositories/{repo}`;
  fields are `data.gradeLetter`, `data.issuesCount`, `data.loc`,
  `data.complexFilesCount`, and `data.lastAnalysedCommit.sha`.
- Issue overview: `POST /analysis/organizations/gh/{owner}/repositories/{repo}/issues/overview`
  with `{"branchName":"<summary branch>"}`; complete rule counts are under
  `data.counts.patterns[]` as `id` and `total`. A first search page is not an
  aggregate and must never establish zero policy drift.
- The summary defaults to Codacy's configured default branch, not a hard-coded
  `main`. Its analysed SHA must match `git ls-remote origin HEAD`.

| State | Meaning | Operator response |
|-------|---------|-------------------|
| `BASELINE_UNKNOWN` | A current, drift-free analysis was recorded, but no trusted prior sample exists. | Independently check indexing scope before relying on the new baseline. |
| `HEALTHY` | The analysed SHA matches the remote default head, LOC is at least 80% of the healthy high-water sample, and overview data is valid and drift-free. | Treat the telemetry as comparable; this does not mean grade A. |
| `STALE_ANALYSIS` | Codacy analysed a different commit from the remote default head. | Request/retry analysis; do not compare findings yet. |
| `INDEX_DEGRADED` | Current analysed LOC is below 80% of the last healthy sample. | Investigate Codacy indexing; the healthy denominator is retained. |
| `POLICY_DRIFT` | A monitored drift sentinel has a non-zero overview count. | Investigate coding-standard drift; do not change external settings from the sweep. |
| `UNKNOWN` | An API, parse, remote-SHA, or state-write failure prevented a trustworthy classification. | Resolve telemetry failure and retain the previous baseline. |

Healthy samples are stored atomically in `QUALITY_SWEEP_STATE_DIR` per repository.
Stale, degraded, policy-drift, malformed, and API-failure samples never replace
that baseline, including on first observation. Small LOC drops retain the entire
prior sample, so successive drops cannot gradually normalize a collapsed index.
An intentional analysis-scope reduction requires an independently verified new
baseline; do not erase state merely to clear an index warning.
The monitored drift sentinels are `ESLint8_es-x_no-modules`,
`ESLint8_es-x_no-block-scoped-variables`, and
`ESLint8_es-x_no-trailing-commas`; their counts are observational evidence, not
permission to alter Codacy, ESLint, or exclusions. `Bandit_B404` is intentionally
disabled in both effective service policy and `.bandit`; its retained historical
issue records do not indicate current policy drift.

The separate **Grade target** is `A / AT_TARGET`, `A / BELOW_TARGET`, or
`A / UNVERIFIED`. Only a current A with `HEALTHY` analysis is verified at target.
A current B–F remains below target even if indexing or policy needs investigation;
stale, invalid, or incomplete telemetry cannot verify the target.

## Restoring and maintaining A

1. **Verify the denominator first.** Compare the live summary with
   `GET /analysis/organizations/gh/{owner}/repositories/{repo}/commit-statistics?days=10`
   and the corresponding Git changes. On 2026-08-29 the aidevops index dropped from
   814,993 to 285,591 LOC while findings changed from 2,361 to 2,356. Do not describe
   such a discontinuity as thousands of newly introduced defects.
2. **Recover indexing through authorised Codacy operations.** The documented
   `POST /organizations/gh/{owner}/repositories/{repo}/reanalyzeCommit` accepts
   `{"commitUuid":"<verified SHA>","cleanCache":true}`, but Codacy Support
   confirmed that cache-cleared analysis is restricted to its internal Super
   Admin role. The published schema may advertise project-token
   authentication even though a valid repository token receives `403`. Use the
   ordinary UI **Reanalyze** action only for a normal rerun; an index incident
   requiring cache clearance must go to Codacy Support. Verify the completed
   analysis and restored scope, not just an accepted request. Do not repeat a
   denied request, create synthetic source edits, or expand exclusions.
3. **Triage genuine findings in small batches.** Start with security/error findings,
   then high-density complexity, duplication and unused-code hotspots. Inspect
   actual callsites and preserve behaviour. Incorrect language-version rules need
   a documented configuration correction, not obsolete rewrites or blanket ignores.
   Codacy's configuration file cannot enable/disable tools; verify actual tool
   settings rather than assuming `engines.*.enabled` entries take effect.
4. **Prevent new debt.** Run scoped local lint and applicable existing tests, review
   exact-head Codacy annotations, and retain required PR gates. A tolerated new-issue
   count is not a daily debt budget. The daily sweep must surface below-target and
   unknown states for investigation, with deduplicated, owner-assigned remediation.
5. **Verify publication honestly.** Record the analysed SHA and live grade after
   merge/release. Keep the live badge visible; never substitute a hard-coded A or
   zero-findings claim. A release can deliver safeguards without proving restoration:
   report any unresolved service-side blocker separately and keep that objective open.

Sources: [API schema](https://api.codacy.com/api/api-docs/swagger.yaml),
[Codacy configuration](https://docs.codacy.com/repositories-configure/codacy-configuration-file/),
[quality metrics](https://docs.codacy.com/faq/code-analysis/which-metrics-does-codacy-calculate/).
Codacy's numeric grade boundaries and metric weights are not published there;
use `gradeLetter` rather than inventing a numeric A cutoff.

**Updating quality gate via API:**

```bash
# Update PR gate
curl -s -H "api-token: $CODACY_API_TOKEN" \
  "https://app.codacy.com/api/v3/organizations/gh/marcusquinn/repositories/aidevops/settings/quality/pull-requests" \
  -X PUT -H "Content-Type: application/json" \
  -d '{"issueThreshold":{"threshold":10,"minimumSeverity":"Warning"}}'

# Update commits gate
curl -s -H "api-token: $CODACY_API_TOKEN" \
  "https://app.codacy.com/api/v3/organizations/gh/marcusquinn/repositories/aidevops/settings/quality/commits" \
  -X PUT -H "Content-Type: application/json" \
  -d '{"issueThreshold":{"threshold":10,"minimumSeverity":"Warning"}}'
```

### Changing the organisation coding standard

While a coding standard is applied, repository-level pattern changes return
`409`; change the standard instead. Tool on/off changes have a command that
runs steps 1-4 (draft, trap repair, diff, promote only on an exact diff):

```bash
bash .agents/scripts/codacy-cli.sh standard list [--org ORG] [--tool Lizard]
bash .agents/scripts/codacy-cli.sh standard set-tool --org ORG --standard ID \
  --tool Lizard --enabled false            # dry run: deletes the draft
bash .agents/scripts/codacy-cli.sh standard set-tool ... --promote
```

It reads `CODACY_API_TOKEN` (injected with `aidevops secret` when unset), is a
no-op when the tool already has the requested state, and deletes the draft on
any error. Undo a promotion by running it with the opposite `--enabled`. The
manual steps below cover pattern-level edits. All paths are under
`/api/v3/organizations/gh/{org}` (operation IDs from the API schema):

1. **Create a draft copy** (`createCodingStandard`):
   `POST /coding-standards?sourceCodingStandard={id}` with `{name, languages}`.
   The draft keeps the source's default status and linked repositories.
2. **Edit the draft** (`updateCodingStandardToolConfiguration`):
   `PATCH /coding-standards/{draft}/tools/{toolUuid}` with
   `{"enabled": true, "patterns": [{"id": "<pattern>", "enabled": false}]}` → `204`.
   Only listed patterns change; at most 1000 patterns per call.
3. **Diff source and draft before promoting.** For each standard, list tools
   (`GET /coding-standards/{id}/tools`) and enabled patterns per enabled tool
   (`GET /coding-standards/{id}/tools/{uuid}/patterns?enabled=true&limit=1000`,
   following `pagination.cursor`). The diff must equal the intended change.
   Trap: a draft copy can **enable tools that were off in the source** (observed:
   Agentlinter, 102 patterns). Disable such tools in the draft only, with
   `{"enabled": false, "patterns": []}`; never edit the source.
4. **Promote** (`promoteDraftCodingStandard`): `POST /coding-standards/{draft}/promote`
   applies the draft to its repositories and replaces the old standard.
5. **Verify the effective policy** per repository (`listRepositoryToolPatterns`):
   `GET /api/v3/analysis/organizations/gh/{org}/repositories/{repo}/tools/{uuid}/patterns?search=<pattern>`.

<!-- AI-CONTEXT-END -->

## Usage

### Setup

```bash
bash .agents/scripts/codacy-cli.sh install     # npm @codacy/analysis-cli (pinned)
# Pull Codacy Cloud rules with the repository-scoped token from secure storage:
aidevops secret CODACY_<OWNER>_<REPO>_PROJECT_TOKEN -- bash .agents/scripts/codacy-cli.sh init
bash .agents/scripts/codacy-cli.sh status
```

`init` writes `.codacy/codacy.config.json` (plus a baseline). In aidevops it is
gitignored because Codacy Cloud is authoritative and `init --remote` re-syncs in
full; other repositories may commit both files so the team shares one policy.
Without a token, `init` falls back to `auto` (local stack detection), which does
not match the Cloud coding standard. Use `init remote --force` to switch.

Token resolution, environment only: `CODACY_PROJECT_TOKEN`, then
`CODACY_<OWNER>_<REPO>_PROJECT_TOKEN` (mapped for that process), then
`CODACY_API_TOKEN` or `codacy-analysis login` credentials. Coordinates derive
from the `origin` remote; override with `CODACY_PROVIDER`,
`CODACY_ORGANIZATION`, `CODACY_REPOSITORY`.

### Analyze

```bash
bash .agents/scripts/codacy-cli.sh analyze --diff            # changed vs default branch
bash .agents/scripts/codacy-cli.sh analyze --diff origin/main
bash .agents/scripts/codacy-cli.sh analyze --staged          # pre-commit gate
bash .agents/scripts/codacy-cli.sh analyze --tool shellcheck .agents/scripts/foo.sh
bash .agents/scripts/codacy-cli.sh analyze --sarif           # whole repo → codacy-results.sarif
bash .agents/scripts/codacy-cli.sh upload codacy-results.sarif
```

The first run downloads missing analyzers (Python venvs, portable Ruby, Opengrep,
Hadolint) into `~/.codacy`; later runs reuse them. `--no-install` skips that,
`--inspect` reports availability only. Tool IDs are case-sensitive
(`codacy-analysis info`). Uploading only helps when the Codacy repository has
**Run analysis on your build server** enabled; Codacy Cloud otherwise analyzes
commits itself.

### CI/CD Integration

`.github/workflows/code-review-monitoring.yml` installs the CLI and runs
`monitor-code-review.sh monitor`, which analyzes changed files on pull requests
(`CODACY_ANALYZE_ARGS=--diff origin/<base>`) and the whole repository on
push/schedule, then uploads `codacy-results.sarif` to GitHub code scanning. It is
report-only and fail-open; Codacy Cloud remains the PR quality gate.
