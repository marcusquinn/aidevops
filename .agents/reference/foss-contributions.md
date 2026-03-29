# FOSS Contributions

> t1697 — repos.json schema extension + budget controls

AI DevOps can contribute to FOSS projects subject to per-repo etiquette controls and a global daily token budget.

---

## Quick Start

1. Enable globally in `~/.config/aidevops/config.jsonc`:

```jsonc
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
    "disclosure": true,
    "labels_filter": ["help wanted", "good first issue", "bug"]
  },
  "pulse": false,
  "priority": "tooling",
  "maintainer": "upstream-owner"
}
```

3. Gate before contributing: `foss-contribution-helper.sh check owner/some-oss-project`

---

## repos.json FOSS Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `foss` | bool | — | Mark repo as a FOSS contribution target. Required. |
| `app_type` | string | `"generic"` | App type classification (see below). |
| `foss_config.max_prs_per_week` | int | `2` | Max PRs to open per week. |
| `foss_config.token_budget_per_issue` | int | `10000` | Max tokens per contribution attempt. |
| `foss_config.blocklist` | bool | `false` | Set `true` if maintainer asked us to stop. |
| `foss_config.disclosure` | bool | `true` | Include AI assistance note in PRs. |
| `foss_config.labels_filter` | array | `["help wanted", "good first issue", "bug"]` | Issue labels to scan for. |

### Valid `app_type` Values

`wordpress-plugin` · `php-composer` · `node` · `python` · `go` · `macos-app` · `browser-extension` · `cli-tool` · `electron` · `cloudron-package` · `generic`

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

```text
foss-contribution-helper.sh scan [--dry-run]         Scan FOSS repos for contribution opportunities
foss-contribution-helper.sh check <slug> [tokens]    Pre-contribution gate (exit 0=eligible, 1=blocked)
foss-contribution-helper.sh budget                   Show daily token usage vs ceiling
foss-contribution-helper.sh record <slug> <tokens>   Record token usage after contribution attempt
foss-contribution-helper.sh reset                    Reset daily token counter (testing only)
foss-contribution-helper.sh status                   Show all FOSS repos and their config
```

### `check` Gate Order

1. `foss.enabled` is `true` globally
2. Repo has `foss: true` in repos.json
3. Repo is not `blocklist: true`
4. Daily token budget has headroom for `token_budget_per_issue`
5. Weekly PR count is below `max_prs_per_week`

---

## Workflow

`check` → dispatch worker (`/full-loop` or headless) → worker implements + opens PR → `record`

### Disclosure Note

When `disclosure: true` (default), PRs include:

> This PR was prepared with AI assistance (aidevops.sh). All changes have been reviewed for correctness.

### Blocklist

If a maintainer asks you to stop, set `foss_config.blocklist: true`. Both `scan` and `check` refuse blocklisted repos.

---

## State

Budget state: `~/.aidevops/cache/foss-contribution-state.json`. Daily counter resets at UTC date change. `reset` command clears manually (testing only).

```json
{
  "date": "2026-03-28",
  "daily_tokens_used": 12500,
  "contributions": {
    "owner/repo": {
      "last_attempt": "2026-03-28T10:15:00Z",
      "total_tokens": 12500,
      "prs_by_week": { "2026-13": 1 }
    }
  }
}
```

---

## Related

- `contribution-watch-helper.sh` — monitors external issues/PRs for reply (read-only, no contribution dispatch)
- `reference/external-repo-submissions.md` — etiquette for external repo submissions
- `reference/services.md` — Contribution Watch service docs
