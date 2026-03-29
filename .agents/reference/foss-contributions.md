# FOSS Contributions

> t1697 — repos.json schema extension + budget controls

AI DevOps can contribute to FOSS projects on your behalf, subject to per-repo etiquette controls and a global daily token budget. This document covers the schema, configuration, and workflow.

---

## Quick Start

1. Enable FOSS contributions globally:

```jsonc
// ~/.config/aidevops/config.jsonc
{
  "foss": {
    "enabled": true,
    "max_daily_tokens": 200000,
    "max_concurrent_contributions": 2
  }
}
```

2. Register a FOSS repo in `~/.config/aidevops/repos.json`:

```json
{
  "path": "/Users/you/Git/some-oss-project",
  "slug": "owner/some-oss-project",
  "foss": true,
  "app_type": "node",
  "foss_config": {
    "max_prs_per_week": 2,
    "token_budget_per_issue": 10000,
    "blocklist": false,
    "disclosure": true,
    "labels_filter": ["help wanted", "good first issue", "bug"]
  },
  "pulse": false,
  "priority": "tooling",
  "maintainer": "upstream-owner"
}
```

3. Check eligibility before contributing:

```bash
foss-contribution-helper.sh check owner/some-oss-project
```

---

## repos.json FOSS Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `foss` | bool | — | Mark repo as a FOSS contribution target. Required. |
| `app_type` | string | `"generic"` | App type classification (see below). |
| `foss_config` | object | — | Per-repo contribution controls. |
| `foss_config.max_prs_per_week` | int | `2` | Max PRs to open per week. |
| `foss_config.token_budget_per_issue` | int | `10000` | Max tokens per contribution attempt. |
| `foss_config.blocklist` | bool | `false` | Set `true` if maintainer asked us to stop. |
| `foss_config.disclosure` | bool | `true` | Include AI assistance note in PRs. |
| `foss_config.labels_filter` | array | `["help wanted", "good first issue", "bug"]` | Issue labels to scan for. |

### Valid `app_type` Values

| Value | Description |
|-------|-------------|
| `wordpress-plugin` | WordPress plugin (PHP) |
| `php-composer` | PHP Composer package |
| `node` | Node.js / npm package |
| `python` | Python package (pip/poetry) |
| `go` | Go module |
| `macos-app` | macOS native application |
| `browser-extension` | Browser extension (Chrome/Firefox) |
| `cli-tool` | Command-line tool (any language) |
| `electron` | Electron desktop app |
| `cloudron-package` | Cloudron app package |
| `generic` | Fallback for anything else |

---

## Global Config (`config.jsonc` `foss` section)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `foss.enabled` | bool | `false` | Master switch. All contributions refused when `false`. |
| `foss.max_daily_tokens` | int | `200000` | Daily token ceiling across all repos. Resets at UTC midnight. |
| `foss.max_concurrent_contributions` | int | `2` | Max simultaneous contribution workers. |

**Env overrides**: `AIDEVOPS_FOSS_ENABLED`, `AIDEVOPS_FOSS_MAX_DAILY_TOKENS`, `AIDEVOPS_FOSS_MAX_CONCURRENT`

---

## CLI: `foss-contribution-helper.sh`

```
foss-contribution-helper.sh scan [--dry-run]         Scan FOSS repos for contribution opportunities
foss-contribution-helper.sh check <slug> [tokens]    Check if a repo is eligible for contribution
foss-contribution-helper.sh budget                   Show current daily token usage vs ceiling
foss-contribution-helper.sh record <slug> <tokens>   Record token usage for a contribution attempt
foss-contribution-helper.sh reset                    Reset daily token counter (for testing)
foss-contribution-helper.sh status                   Show all FOSS repos and their config
foss-contribution-helper.sh help                     Show usage
```

### `check` — Pre-contribution gate

Run before dispatching any contribution worker. Returns exit 0 (eligible) or 1 (blocked).

Checks in order:
1. `foss.enabled` is `true` globally
2. Repo has `foss: true` in repos.json
3. Repo is not `blocklist: true`
4. Daily token budget has headroom for `token_budget_per_issue`
5. Weekly PR count is below `max_prs_per_week`

```bash
# Check with default budget (10000 tokens)
foss-contribution-helper.sh check owner/repo

# Check with custom token estimate
foss-contribution-helper.sh check owner/repo 8000
```

### `record` — Post-contribution accounting

Call after a contribution attempt completes (success or failure) to update the daily token counter and weekly PR count.

```bash
foss-contribution-helper.sh record owner/repo 7500
```

### `budget` — Daily usage summary

```bash
foss-contribution-helper.sh budget
# FOSS Contribution Budget
#   Enabled:              true
#   Max daily tokens:     200000
#   Used today:           12500 (6%)
#   Remaining:            187500
#   Max concurrent:       2
```

---

## Contribution Workflow

```
1. foss-contribution-helper.sh check <slug>   ← gate: eligible?
2. Dispatch contribution worker               ← /full-loop or headless
3. Worker implements fix, opens PR            ← includes disclosure note if disclosure: true
4. foss-contribution-helper.sh record <slug> <tokens>  ← accounting
```

### Disclosure Note

When `disclosure: true` (default), contribution PRs include a footer:

> This PR was prepared with AI assistance (aidevops.sh). All changes have been reviewed for correctness.

Set `disclosure: false` per-repo to omit this note.

---

## Blocklist

If a maintainer asks you to stop contributing to their repo, set `blocklist: true` in `foss_config`. The helper will refuse all future contribution attempts for that repo.

```json
"foss_config": {
  "blocklist": true
}
```

The `scan` command skips blocklisted repos. The `check` command returns exit 1 with a clear message.

---

## State File

Budget state is persisted at `~/.aidevops/cache/foss-contribution-state.json`.

```json
{
  "date": "2026-03-28",
  "daily_tokens_used": 12500,
  "contributions": {
    "owner/repo": {
      "last_attempt": "2026-03-28T10:15:00Z",
      "total_tokens": 12500,
      "prs_by_week": {
        "2026-13": 1
      }
    }
  }
}
```

The daily counter resets automatically when the UTC date changes. Use `foss-contribution-helper.sh reset` to clear it manually (testing only).

---

## Examples

### Register a WordPress plugin for FOSS contributions

```json
{
  "path": "/Users/you/Git/wordpress/some-plugin",
  "slug": "wpallstars/some-plugin",
  "foss": true,
  "app_type": "wordpress-plugin",
  "foss_config": {
    "max_prs_per_week": 1,
    "token_budget_per_issue": 8000,
    "blocklist": false,
    "disclosure": true,
    "labels_filter": ["help wanted", "bug", "needs-patch"]
  },
  "pulse": false,
  "contributed": true,
  "priority": "product",
  "maintainer": "upstream-maintainer"
}
```

### Register a Go CLI tool

```json
{
  "path": "/Users/you/Git/some-go-tool",
  "slug": "org/some-go-tool",
  "foss": true,
  "app_type": "go",
  "foss_config": {
    "max_prs_per_week": 2,
    "token_budget_per_issue": 15000,
    "blocklist": false,
    "disclosure": true,
    "labels_filter": ["help wanted", "good first issue"]
  },
  "pulse": false,
  "priority": "tooling",
  "maintainer": "upstream-maintainer"
}
```

### Scan all eligible repos (dry run)

```bash
foss-contribution-helper.sh scan --dry-run
# Scanning FOSS contribution targets...
#
#   ELIGIBLE wpallstars/some-plugin (app_type=wordpress-plugin, labels=[help wanted,bug], budget=8000)
#   ELIGIBLE org/some-go-tool (app_type=go, labels=[help wanted,good first issue], budget=15000)
#
# Summary: 2 eligible, 0 skipped
# (dry-run: no contributions dispatched)
```

---

## Related

- `contribution-watch-helper.sh` — monitors external issues/PRs for reply (read-only, no contribution dispatch)
- `reference/external-repo-submissions.md` — etiquette for external repo submissions
- `reference/services.md` — Contribution Watch service docs
