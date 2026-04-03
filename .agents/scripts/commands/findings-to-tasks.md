---
description: Convert actionable report findings into tracked tasks and issues
agent: Build+
mode: subagent
---

Convert actionable findings from an audit/review report into tracked TODO tasks and linked GitHub issues.

Input file: `$ARGUMENTS`

## Required Format

```text
severity|title|details
high|Harden prompt-guard fallback on malformed markdown|Reject malformed HTML comments before rendering summary
medium|Add retries for Codacy API timeout|Use capped exponential backoff in codacy-cli.sh
low|Improve stale worker log wording|Clarify blocked vs failed in watchdog output
```

Severity defaults to `medium` if omitted.

## Command

```bash
~/.aidevops/agents/scripts/findings-to-tasks-helper.sh create \
  --input <path/to/actionable-findings.txt> \
  --repo-path "$(git rev-parse --show-toplevel)" \
  --source <security-audit|code-review|seo-audit|accessibility|performance>
```

- `--labels "label1,label2"` — add extra issue labels
- `--tags "tag1,tag2"` — add extra TODO hashtags
- `--dry-run` — preview without allocating task IDs
- `--no-issue` — allocate task IDs without creating GitHub issues
- `--allow-partial` — allow non-100% conversion (normally treated as failure)

## Completion Rule

Complete only when helper output confirms full conversion coverage:

- `actionable_findings_total=<N>`
- `deferred_tasks_created=<N>`
- `coverage=100%`

If `coverage` is below 100%, continue task creation until all actionable findings are tracked.
