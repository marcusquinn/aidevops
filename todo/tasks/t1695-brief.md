# t1695: FOSS Contribution Pipeline — Core Orchestrator + Handler Framework

## Session Origin

Interactive conversation about contributing PRs to open-source repos we use (starting with WordPress plugins like `afragen/git-updater`), using idle machine time and spare daily token budget. Discussion covered: the full scan→triage→fork→test→PR flow, per-app-type test environments (wp-env for WordPress, Docker for web apps, Xcode for macOS apps), localdev integration for HTTPS review URLs, and the distinction between upstream app contributions vs Cloudron package contributions.

## What

Create `foss-contribution-helper.sh` — the orchestration layer that enables aidevops to autonomously contribute fixes to open-source projects. The orchestrator is app_type-agnostic: it handles the universal workflow (scan issues, triage, fork, worktree, submit PR) and delegates build/test/review to type-specific handlers.

## Why

We depend on many FOSS projects (WordPress plugins, Nextcloud, EspoCRM, CLI tools, macOS apps). We have idle machine time and spare daily token budget. Contributing fixes is high-leverage: improves our own stack while giving back. The framework already has the building blocks (external repo submission rules, contribution watch, headless dispatch, localdev infrastructure) but no automated pipeline connecting them.

## How

### Core orchestrator (`foss-contribution-helper.sh`)

Subcommands:
- `add-repo <slug> [--app-type <type>]` — register a FOSS repo in repos.json with `foss: true`
- `scan [--repo <slug>]` — list actionable issues from registered FOSS repos (filters by labels, skips blocklisted repos)
- `triage <slug> <issue>` — assess fixability: is it code-level? is the repo maintained? does it accept PRs? estimate complexity
- `contribute <slug> <issue>` — full flow: fork → clone → worktree → delegate to handler → submit PR
- `status` — show active contributions, pending PRs, budget usage

### Handler interface

Each handler in `.agents/scripts/foss-handlers/` implements:
- `setup <slug> <fork-path>` — install dependencies, create test environment
- `build <slug> <fork-path>` — compile/build the project
- `test <slug> <fork-path>` — run test suite + smoke tests, report pass/fail
- `review <slug> <fork-path>` — wire up for interactive review (localdev URL or native app launch)
- `cleanup <slug> <fork-path>` — tear down test environment, deregister ports

### Integration points

- `external-repo-submissions.md` — check CONTRIBUTING.md and issue templates before PR
- `contribution-watch-helper.sh` — auto-register `contributed: true` after PR submission
- `headless-runtime-helper.sh` — dispatch workers for autonomous contributions
- `localdev-helper.sh` — HTTPS review URLs for HTTP-serving apps
- `pre-edit-check.sh` — standard worktree workflow for the fix itself

### Etiquette controls

- Max PRs per repo per week (default 2, configurable per repo)
- AI disclosure line in all PR descriptions
- Blocklist support (repos that don't want AI PRs)
- Budget ceiling: refuse contributions when daily token limit reached

## Acceptance Criteria

- [ ] `foss-contribution-helper.sh add-repo afragen/git-updater --app-type wordpress-plugin` registers in repos.json
- [ ] `foss-contribution-helper.sh scan` returns actionable issues with labels like `help wanted`, `bug`, `needs-patch`
- [ ] `foss-contribution-helper.sh contribute <slug> <issue>` completes the full fork→fix→test→PR cycle
- [ ] Handler interface documented and enforced (setup/build/test/review/cleanup)
- [ ] At least 2 handler implementations: `wordpress-plugin.sh` (t1696) and `generic.sh` (t1698)
- [ ] Etiquette controls enforced: rate limiting, disclosure, blocklist
- [ ] Budget ceiling checked before starting contribution
- [ ] `contribution-watch-helper.sh` picks up the new PR for follow-up monitoring
- [ ] PR descriptions include AI assistance disclosure and reference the upstream issue

## Context

### Existing infrastructure (already built)

- `external-repo-submissions.md` (t1407) — template compliance for external repos
- `contribution-watch-helper.sh` (t1419) — monitors replies on our PRs/issues
- `localdev-helper.sh` (t1424) — `.local` domains with branch subdomains, Traefik, mkcert
- `headless-runtime-helper.sh` — worker dispatch with provider rotation
- `wp-dev.md` — WordPress dev tooling (wp-env, LocalWP, Playwright)
- `cloudron-app-packaging.md` — Cloudron package development (distinct from upstream app contributions)

### App types (not exhaustive)

| app_type | Test environment | Review method |
|---|---|---|
| `wordpress-plugin` | wp-env + multisite | `https://plugin.local` |
| `php-composer` | composer + docker-compose | `https://app.local` |
| `node` | npm/pnpm + localdev | `https://app.local` |
| `python` | venv/poetry + docker-compose | `https://app.local` |
| `go` | go build | `https://app.local` |
| `macos-app` | Xcode / Swift Package Manager | Native app launch |
| `browser-extension` | npm + web-ext | Browser extension load |
| `cli-tool` | Language-specific build | Terminal |
| `electron` | npm + electron-builder | Native window |
| `cloudron-package` | cloudron build + install | `https://app.staging.domain` |

### Key design decision

The `app_type` describes the upstream project's own dev environment, NOT how we deploy it. A Nextcloud contribution means working with Nextcloud's PHP/composer dev setup, not Cloudron's packaging. Cloudron package contributions are a separate `app_type: cloudron-package`.

### First target

`afragen/git-updater` — 10 open issues, no issue templates or CONTRIBUTING.md (low friction), actively maintained. Issue #866 has `needs-patch` + `need-help` labels.
