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

### Auto-response to maintainer feedback

The orchestrator includes a `respond` subcommand for the PR feedback loop:

```
foss-contribution-helper.sh respond <slug> <pr-number>
```

Flow:
1. `contribution-watch-helper.sh` detects new comment on our PR (existing)
2. `prompt-guard-helper.sh scan` on comment body before LLM sees it
   - Clean → auto-dispatch response worker
   - Flagged → quarantine for human review, no auto-response
3. Worker runs in sandboxed context (fake HOME, scoped token, fork worktree only):
   - Code change requested → apply fix, run handler tests, push to fork, comment
   - Question → answer from code context
   - Rejection → close gracefully, note in `foss_config`
   - Approval → no action needed

Safety boundaries:
- Worker sandboxing (t1412): scoped GitHub token (fork-only write), fake HOME, network tiering
- No access to secrets or private repos from the worker context
- Only auto-responds on `foss: true` repos — regular `contributed: true` repos still require interactive human response
- Worst case (prompt-guard miss): worker writes to our fork and posts a comment. No secret exposure, no private repo access, no upstream merge capability.

Pulse integration: `contribution-watch-helper.sh scan` detects items needing response. For `foss: true` repos, the pulse auto-dispatches a response worker instead of just surfacing in the greeting.

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
- [ ] `foss-contribution-helper.sh respond <slug> <pr>` auto-responds to clean maintainer feedback
- [ ] Flagged comments (prompt-guard) are quarantined, not auto-responded to
- [ ] Response worker is sandboxed: scoped token, fork-only write, no secret access

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
