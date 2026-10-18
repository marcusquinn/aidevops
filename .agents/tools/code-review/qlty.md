---
description: Qlty CLI for multi-linter code quality
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

# Qlty CLI Configuration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- Qlty: Universal code quality for 40+ languages, 70+ tools
- Credential priority: Account API Key (`qltp_...`) > Coverage Token (`qltcw_...`) > Workspace ID (UUID)
- Store credentials: `bash .agents/scripts/setup-local-api-keys.sh set qlty-account-api-key KEY`
- Organization-specific: `set qlty-ORGNAME TOKEN`, `set qlty-ORGNAME-workspace-id UUID`
- Commands: `bash .agents/scripts/qlty-cli.sh install|init|check|fmt --all|smells --all [ORG]`
- Storage: `~/.config/aidevops/api-keys` (600 permissions)
- Path: Ensure `~/.qlty/bin` in PATH
- GitHub App on organisation or private repos: monthly minutes run out; an out-of-minutes "qlty check" is billing, not a finding. Keep the app and skip the check (`reference/ci-gate-policy.md` rule 14; see "GitHub App: monthly minutes")

<!-- AI-CONTEXT-END -->

## GitHub App: monthly minutes

Qlty's GitHub App posts a "qlty check" on pull requests. Its analysis minutes are limited on private repositories and on every organisation-owned repository, public or private; only public repositories on personal accounts are unlimited. The free minutes return each month, so early-month PRs get real findings and later ones may fail with "Qlty did not run because you are out of minutes".

When setting up or managing repositories:

- Keep the app installed for its free minutes. A red out-of-minutes check is not a reason to uninstall Qlty, remove it from a repository's docs, buy credits or ask the owner, unless the owner asks about cost.
- Skip the out-of-minutes failure: don't rerun it, change code, file an issue or wait for it. Merge when the other checks pass and note the skipped check in the PR body. The merge helpers do this already (`gh-checks-wait-helper.sh` `apply_qlty_billing_policy`, `pulse-merge-required-checks.sh` `_pmrc_repo_has_qlty_credit_limit`).
- Never make "qlty check" a required status check or ruleset check on a credit-limited repository: once the minutes run out it would block every merge for the rest of the month.
- A qlty check with real findings still counts, and an out-of-minutes failure on a public personal-account repository is unexpected: report it.
- CI jobs that run the qlty CLI in a repository's own Actions (such as the aidevops Qlty Regression Gate and Qlty Smell Threshold) are separate from the app and do not use its minutes; their failures are real.

## Credentials

Three types, selected in priority order:

| Type | Key format | Scope |
|------|-----------|-------|
| Account API Key | `qltp_...` | Account-wide (preferred) |
| Coverage Token | `qltcw_...` | Org-specific fallback |
| Workspace ID | UUID | Context identifier (optional) |

Storage format in `~/.config/aidevops/api-keys`:

```bash
qlty-account-api-key=qltp_your_account_api_key_here
qlty-ORGNAME=qltcw_your_coverage_token_here
qlty-ORGNAME-workspace-id=your-workspace-uuid-here
```

## Setup

```bash
# Store credentials
bash .agents/scripts/setup-local-api-keys.sh set qlty-account-api-key YOUR_ACCOUNT_API_KEY
bash .agents/scripts/setup-local-api-keys.sh set qlty-ORGNAME YOUR_COVERAGE_TOKEN        # org fallback
bash .agents/scripts/setup-local-api-keys.sh set qlty-ORGNAME-workspace-id YOUR_UUID     # optional context

# Install and initialise
bash .agents/scripts/qlty-cli.sh install
bash .agents/scripts/qlty-cli.sh init

# Verify
bash .agents/scripts/setup-local-api-keys.sh list
bash .agents/scripts/qlty-cli.sh help
```

## Usage

```bash
# Default org
bash .agents/scripts/qlty-cli.sh check
bash .agents/scripts/qlty-cli.sh fmt --all
bash .agents/scripts/qlty-cli.sh smells --all

# Specific org
bash .agents/scripts/qlty-cli.sh check 10 ORGNAME
bash .agents/scripts/qlty-cli.sh fmt --all ORGNAME
bash .agents/scripts/qlty-cli.sh smells --all ORGNAME
```

## Multi-Org

Naming convention: `qlty-ORGNAME` (token), `qlty-ORGNAME-workspace-id` (UUID). Commands accept `ORGNAME` as last argument.

To add an org: obtain Coverage Token + Workspace ID from Qlty dashboard, store with `setup-local-api-keys.sh`.

## Integration

```bash
# Via Quality CLI Manager
bash .agents/scripts/quality-cli-manager.sh install all
bash .agents/scripts/quality-cli-manager.sh analyze qlty
```

GitHub Actions: use Coverage Token and Workspace ID as repository secrets.

## Troubleshooting

### Diagnosing a regression

When `Qlty Smell Regression` reports new `qlty:file-complexity` findings without
scores, download the failed run's SARIF artifact instead of estimating with another
complexity tool. The pinned CI installer supports Linux x86_64 only; proxy tools
can produce different totals on macOS.

Find the failed `Qlty Regression Gate` run for the PR's exact head, then set its
run ID and PR number below. Run these commands from the repository checkout:

```bash
RUN_ID=123456789  # Replace with the failed run ID
PR_NUMBER=123    # Replace with the PR number
SARIF_DIR=$(mktemp -d "${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}/qlty-sarif.XXXXXX")
gh run download "$RUN_ID" --repo marcusquinn/aidevops \
  -n "qlty-sarif-$PR_NUMBER" -D "$SARIF_DIR"
jq -r '.runs[].results[] | select(.ruleId == "qlty:file-complexity")
  | [.locations[0].physicalLocation.artifactLocation.uri, .message.text]
  | @tsv' "$SARIF_DIR/qlty-head.sarif"
```

The tab-separated output pairs each file with Qlty's exact message, including
`count = N`. The artifact also contains `qlty-base.sarif` and `qlty-report.md`;
compare the base findings to distinguish existing smells from regressions.
Artifacts expire after 14 days, so retrieve them while available.

`file-complexity` is a whole-file total, not a single function's complexity.
Split cohesive responsibilities into separate modules to reduce that total;
simplifying one function may not resolve the file-level finding. Use the pinned
Qlty results, not another analyzer's totals, to verify the change. The lowest
flagged count observed in PR #34954 was 50; this is evidence from that run, not a
universal threshold guarantee.

| Problem | Fix |
|---------|-----|
| Token not found | `setup-local-api-keys.sh list` |
| CLI not found | Add `~/.qlty/bin` to PATH |
| Permission denied | Check `~/.config/aidevops/api-keys` is mode 600 |
| Org not recognised | Verify `qlty-ORGNAME` naming matches command arg |

```bash
qlty --version
bash .agents/scripts/qlty-cli.sh check 1 ORGNAME
```
