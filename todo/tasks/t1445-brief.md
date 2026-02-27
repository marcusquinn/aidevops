---
mode: subagent
---
# t1445: Improve performance and resilience patterns

## Origin

- **Created:** 2026-02-27
- **Session:** claude-code:full-loop
- **Created by:** ai-interactive
- **Parent task:** GH#2414 (coderabbit pulse finding #10)
- **Conversation context:** CodeRabbit pulse review identified performance and resilience nits across helper scripts — synchronized retries, hardcoded polling intervals, and unnecessary subprocesses in echo|grep patterns.

## What

Improve shell script resilience and performance across the framework:
1. Add jitter to exponential backoff sleep calls to prevent thundering herd on synchronized retries
2. Parameterize hardcoded polling/rate-limit intervals via environment variables with sane defaults
3. Replace `echo "$var" | grep -q` patterns with bash builtins (`[[ ... == *...* ]]`) where appropriate

## Why

- Synchronized retries across multiple concurrent workers can cause thundering herd effects on shared resources (GitHub API, Docker, etc.)
- Hardcoded polling intervals prevent tuning for different environments (CI vs local, free tier vs paid API)
- `echo | grep` spawns two subprocesses per check; bash builtins are zero-cost

## How (Approach)

- Add `RANDOM % backoff` jitter to existing exponential backoff loops in `claim-task-id.sh`, `ip-reputation-helper.sh`, `migrate-pr-backfill.sh`
- Add env-var-with-default constants (`${VAR:-default}`) for rate-limit delays in `crawl4ai-helper.sh`, `email-design-test-helper.sh`, `mainwp-helper.sh`, `pagespeed-helper.sh`, `accessibility-audit-helper.sh`, `thumbnail-helper.sh`, `virustotal-helper.sh`
- Replace `echo "$PATH" | grep -q "dir"` with `[[ ":$PATH:" != *":dir:"* ]]` in setup modules
- Replace `echo "$var" | grep -q "str"` with `[[ "$var" == *"str"* ]]` in non-test scripts

## Acceptance Criteria

- [x] Backoff sleeps in claim-task-id.sh, ip-reputation-helper.sh, migrate-pr-backfill.sh include jitter
  ```yaml
  verify:
    method: codebase
    pattern: "RANDOM.*backoff|jitter"
    path: ".agents/scripts/claim-task-id.sh"
  ```
- [x] Polling intervals parameterized via env vars in 7+ helper scripts
  ```yaml
  verify:
    method: bash
    run: "rg -c 'RATE_LIMIT_DELAY:-|POLL_INTERVAL:-|STARTUP_WAIT:-|POLL_MAX_ATTEMPTS:-' .agents/scripts/ | wc -l | xargs test 5 -le"
  ```
- [x] PATH checks in setup modules use bash builtins instead of echo|grep
  ```yaml
  verify:
    method: codebase
    pattern: 'echo.*PATH.*grep'
    path: "setup-modules/"
    expect: absent
  ```
- [x] ShellCheck clean (no new violations)
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/claim-task-id.sh .agents/scripts/ip-reputation-helper.sh .agents/scripts/migrate-pr-backfill.sh setup-modules/core.sh setup-modules/agent-deploy.sh 2>&1 | grep -v SC1091 | grep -v SC2015 | grep -c 'error' | xargs test 0 -eq"
  ```

## Context & Decisions

- Only active (non-archived) scripts modified; `supervisor-archived/` left untouched
- Test files (`tests/`) left with echo|grep — standard test assertion pattern, not a performance concern
- `setup.sh:70` echo|grep kept — it's a general-purpose function checking arbitrary labels
- `grep -oE` extraction patterns kept — bash builtins can't extract regex matches
- One-shot startup waits (localhost-helper, crewai-helper) not parameterized — not thundering herd risks

## Relevant Files

- `.agents/scripts/claim-task-id.sh:420-429` — CAS retry backoff
- `.agents/scripts/ip-reputation-helper.sh:646-648` — rate limit retry
- `.agents/scripts/migrate-pr-backfill.sh:132-136` — PR fetch retry
- `.agents/scripts/crawl4ai-helper.sh:44,605,665,738` — container startup wait
- `.agents/scripts/email-design-test-helper.sh:37-38` — EOA poll interval
- `.agents/scripts/mainwp-helper.sh:20,453,474` — bulk API rate limit
- `.agents/scripts/pagespeed-helper.sh:18,404` — bulk audit rate limit
- `.agents/scripts/accessibility-audit-helper.sh:24,585` — bulk audit rate limit
- `.agents/scripts/thumbnail-helper.sh:34,698` — YouTube API rate limit
- `.agents/scripts/virustotal-helper.sh:25` — VT API rate limit
- `setup-modules/core.sh:333,367` — PATH checks
- `setup-modules/agent-deploy.sh:403` — PATH check
- `setup-modules/migrations.sh:611` — validation output check
- `setup-modules/tool-install.sh:232` — architecture check
- `.agents/scripts/codacy-cli-chunked.sh:159` — tool category check

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Identify all patterns across codebase |
| Implementation | 30m | Apply jitter, parameterize, replace patterns |
| Testing | 10m | ShellCheck all modified files |
| **Total** | **~1h** | |
