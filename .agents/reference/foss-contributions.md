# FOSS Contributions

> t1697 — repos.json schema extension + budget controls

AI DevOps can contribute to FOSS projects subject to per-repo etiquette controls and a global daily token budget.

## Global Config (`config.jsonc`)

```jsonc
// ~/.config/aidevops/config.jsonc
{ "foss": { "enabled": true, "max_daily_tokens": 50000, "max_concurrent_contributions": 2 } }
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `foss.enabled` | bool | `false` | Master switch — all contributions refused when `false` |
| `foss.max_daily_tokens` | int | `50000` | Daily token ceiling across all repos (resets UTC midnight) |
| `foss.max_concurrent_contributions` | int | `2` | Max simultaneous contribution workers |

**Env overrides**: `AIDEVOPS_FOSS_ENABLED`, `AIDEVOPS_FOSS_MAX_DAILY_TOKENS`, `AIDEVOPS_FOSS_MAX_CONCURRENT`

## repos.json Registration

Add a FOSS repo to `~/.config/aidevops/repos.json`:

```json
{
  "path": "/Users/you/Git/some-oss-project",
  "slug": "owner/some-oss-project",
  "foss": true,
  "app_type": "wordpress-plugin",
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

### `foss_config` Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_prs_per_week` | int | `2` | Max PRs to open per week |
| `token_budget_per_issue` | int | `10000` | Max tokens per contribution attempt |
| `blocklist` | bool | `false` | Set `true` if maintainer asked us to stop |
| `disclosure` | bool | `true` | Include AI assistance note in PRs |
| `labels_filter` | array | `["help wanted", "good first issue", "bug"]` | Issue labels to scan for |

### Valid `app_type` Values

`wordpress-plugin` | `php-composer` | `node` | `python` | `go` | `macos-app` | `browser-extension` | `cli-tool` | `electron` | `cloudron-package` | `generic` (default)

## CLI: `foss-contribution-helper.sh`

```text
foss-contribution-helper.sh scan [--dry-run]         Scan FOSS repos for opportunities
foss-contribution-helper.sh check <slug> [tokens]    Pre-contribution eligibility gate (exit 0/1)
foss-contribution-helper.sh budget                   Show daily token usage vs ceiling
foss-contribution-helper.sh record <slug> <tokens>   Record token usage after attempt
foss-contribution-helper.sh reset                    Reset daily counter (testing only)
foss-contribution-helper.sh status                   Show all FOSS repos and config
```

### `check` Gate Order

1. `foss.enabled` is `true` globally
2. Repo has `foss: true` in repos.json
3. Repo is not `blocklist: true`
4. Daily token budget has headroom for `token_budget_per_issue`
5. Weekly PR count is below `max_prs_per_week`

```bash
foss-contribution-helper.sh check owner/repo        # default budget (10000)
foss-contribution-helper.sh check owner/repo 8000   # custom estimate
```

## Contribution Workflow

```text
1. foss-contribution-helper.sh check <slug>              ← gate: eligible?
2. Dispatch contribution worker (/full-loop or headless)  ← implements fix, opens PR
3. foss-contribution-helper.sh record <slug> <tokens>     ← post-attempt accounting
```

**Disclosure**: When `disclosure: true` (default), PRs include: "This PR was prepared with AI assistance (aidevops.sh). All changes have been reviewed for correctness." Set `false` per-repo to omit.

**Blocklist**: If a maintainer asks you to stop, set `blocklist: true` in `foss_config`. Both `scan` and `check` will refuse that repo.

## State File

Budget state persisted at `~/.aidevops/cache/foss-contribution-state.json`. Tracks daily token usage, per-repo totals, and weekly PR counts. Daily counter resets on UTC date change. Use `reset` subcommand to clear manually (testing only).

## Scan Example

```bash
foss-contribution-helper.sh scan --dry-run
# Scanning FOSS contribution targets...
#   ELIGIBLE wpallstars/some-plugin (app_type=wordpress-plugin, budget=8000)
#   ELIGIBLE org/some-go-tool (app_type=go, budget=15000)
# Summary: 2 eligible, 0 skipped (dry-run: no contributions dispatched)
```

## Related

- `contribution-watch-helper.sh` — monitors external issues/PRs for reply (read-only, no contribution dispatch)
- `reference/external-repo-submissions.md` — etiquette for external repo submissions
- `reference/services.md` — Contribution Watch service docs
