---
description: Convert actionable report findings into tracked tasks and issues
agent: Build+
mode: subagent
---

Convert actionable findings from an audit/review report into tracked TODO tasks and linked GitHub issues.

Input file: `$ARGUMENTS`

## Format

One finding per line — `severity|title|details`. Severity is `critical`, `high`, `medium`, `low`, or `info` (defaults to `medium` if omitted).

```text
high|Harden prompt-guard fallback on malformed markdown|Reject malformed HTML comments before rendering summary
medium|Add retries for Codacy API timeout|Use capped exponential backoff in codacy-cli.sh
low|Improve stale worker log wording|Clarify blocked vs failed in watchdog output
```

## Command

```bash
~/.aidevops/agents/scripts/findings-to-tasks-helper.sh create \
  --input <path/to/actionable-findings.txt> \
  --repo-path "$(git rev-parse --show-toplevel)" \
  --source <custom-source>  # any free-form tag, not validated — e.g. security-audit, code-review, seo-audit
```

Optional flags: `--labels "label1,label2"` · `--tags "tag1,tag2"` · `--dry-run` · `--no-issue` · `--allow-partial`

## Completion Rule

Done only when helper output confirms full coverage:

- `actionable_findings_total=<N>`
- `deferred_tasks_created=<N>`
- `coverage=100%`

If `coverage` is below 100%, continue task creation until all actionable findings are tracked.
