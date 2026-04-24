# repos.json Field Reference

Config file: `~/.config/aidevops/repos.json`. Structure: `{"initialized_repos": [...], "git_parent_dirs": [...]}`.

**CRITICAL:** New entries MUST go inside the `initialized_repos` array — never as top-level keys. After any write, validate: `jq . ~/.config/aidevops/repos.json > /dev/null`. A malformed file silently breaks the pulse for ALL repos.

## Core Fields

| Field | Type | Description |
|-------|------|-------------|
| `slug` | string | `owner/repo` — ALWAYS use this for `gh` commands, never guess org names |
| `pulse` | bool | `true` = active development, tasks, issues. `false` = no task management |
| `local_only` | bool | No remote; skip all `gh` operations |
| `priority` | string | `"tooling"` (infrastructure), `"product"` (user-facing), `"profile"` (docs-only) |
| `maintainer` | string | GitHub username. Auto-detected from `gh api user`; falls back to slug owner |
| `role` | string | `"maintainer"` or `"contributor"`. Controls which pulse scanners run |
| `init_scope` | string | `"minimal"`, `"standard"` (default), or `"public"`. Controls `aidevops init` scaffolding |

### `role` detail

- **`maintainer`** (default for repos you own): all scanners run
- **`contributor`** (default for repos owned by others): session-miner insights only — files sanitized `contributor-insight` issues upstream from instruction candidates and error patterns in the contributor's own sessions. Privacy: strips private repo slugs, local file paths, credentials, email addresses.

Auto-detected from slug owner vs `gh api user` when omitted.

### `init_scope` detail

- `minimal`: project-specific files only (TODO.md, AGENTS.md, .aidevops.json, .gitignore, .gitattributes)
- `standard`: adds DESIGN.md, MODELS.md, collaborator pointers, README.md
- `public`: adds LICENCE, CHANGELOG.md, CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md

Auto-inferred when absent: `local_only`/no-remote → `minimal`; others → `standard`. Stored in `.aidevops.json` per project. Preserved on re-registration.

## Scheduling and Lifecycle Fields

| Field | Type | Example | Description |
|-------|------|---------|-------------|
| `pulse_hours` | object | `{"start": 17, "end": 5}` | Limits dispatch to window (24h local time). Overnight supported. Omit for 24/7. |
| `pulse_interval` | integer | `600` | Minimum seconds between dispatch polls for this repo. Default: omit (poll every cycle). Min: 60. Useful for contributor-role repos with low activity — e.g. 600 polls every 5 cycles instead of every cycle, reducing GraphQL budget consumption ~5×. State: `~/.aidevops/logs/pulse-last-per-repo.json`. |
| `pulse_expires` | string | `"2026-05-01"` | Past this date, pulse auto-sets `pulse: false`. Useful for temporary windows. |

## Contribution and FOSS Fields

| Field | Type | Description |
|-------|------|-------------|
| `contributed` | bool | External repos authored/commented on. Read-only monitoring; no merge/dispatch/TODO powers. Managed by `contribution-watch-helper.sh`. |
| `foss` | bool | FOSS contribution target. Enables `foss-contribution-helper.sh` budget enforcement. Combine with `app_type` and `foss_config`. See `reference/foss-contributions.md`. |
| `app_type` | string | FOSS repo type: `wordpress-plugin`, `php-composer`, `node`, `python`, `go`, `macos-app`, `browser-extension`, `cli-tool`, `electron`, `cloudron-package`, `generic` |
| `foss_config` | object | Per-repo FOSS controls (see below) |

### `foss_config` object fields

| Key | Default | Description |
|-----|---------|-------------|
| `max_prs_per_week` | 2 | Weekly PR budget |
| `token_budget_per_issue` | 10000 | Enforced by `foss-contribution-helper.sh check` |
| `blocklist` | false | Maintainer opt-out flag |
| `disclosure` | true | AI note in PRs |
| `labels_filter` | `["help wanted", "good first issue", "bug"]` | Issue labels to target |

## Review Gate Configuration

`review_gate` — per-repo review gate configuration (t2123, GH#19173; extended in t2139, GH#19251). Controls behaviour when review bots rate-limit or post placeholder comments.

```json
{
  "rate_limit_behavior": "pass",
  "min_edit_lag_seconds": 30,
  "tools": {
    "coderabbitai": {
      "rate_limit_behavior": "wait",
      "min_edit_lag_seconds": 90
    }
  }
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `rate_limit_behavior` | `"pass"` | `"pass"` exits 0 on rate-limit; `"wait"` keeps polling |
| `min_edit_lag_seconds` | 30 | Seconds a bot comment must be "settled" before it counts. Defeats CodeRabbit's two-phase placeholder (stub at ~14s, final edit at ~90-120s). |
| `tools` | — | Per-tool overrides keyed by bot login (`coderabbitai`, `gemini-code-assist`, `augment-code`, `augmentcode`, `copilot`) |

Resolution order (per field independently): per-tool > per-repo > env var (`REVIEW_GATE_RATE_LIMIT_BEHAVIOR` / `REVIEW_BOT_MIN_EDIT_LAG_SECONDS`) > hard default.

CLI: `aidevops review-gate --help` — configure `rate_limit_behavior` without hand-editing JSON.

## Platform Integration

| Field | Values | Description |
|-------|--------|-------------|
| `platform` | `"shopify"` | Platform-specific MCP server integration. `"shopify"` enables `shopify-dev-mcp` (schema-aware GraphQL, Liquid validation, Admin API). Requires Shopify CLI 3.93.0+. Config: `configs/mcp-templates/shopify-dev-mcp-config.json.txt`. |
