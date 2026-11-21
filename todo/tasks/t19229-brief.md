## What

Stop aidevops-signed comments from matching the OpenCode `/oc` / `/opencode` trigger gate, in the framework workflow and in every template it ships. Move the global serialization from the workflow level to the mutating job so unrelated comments can no longer cancel a genuine pending `/oc` run.

## Why

Evidence (2026-11-21, `marcusquinn/aidevops`):

- The gate in `.github/workflows/opencode-agent.yml` is `contains(github.event.comment.body, '/oc') || contains(github.event.comment.body, '/opencode')`. Every aidevops signature footer contains `[OpenCode](https://opencode.ai)`, and `//opencode.ai` contains `/opencode`, so every signed pulse/worker/interactive comment passes it. The in-script rule (`/(^|\s)\/(oc|opencode)\b/m`) then rejects the comment after Security Validation, Audit Log and Security Block Notification have already used runners.
- `OpenCode AI Agent` created 1,450 runs in about 24h. In a 50-run sample, 30 were `cancelled`, 12 `skipped`, 8 `success`. Cancelled run 44851503197 (triggered by `sonarqubecloud[bot]`) has **zero jobs**. The run-level `concurrency: { group: opencode-agent, cancel-in-progress: false }` keeps one running and one pending run, so each new comment run replaces the pending one before any job `if:` is evaluated. A genuine `/oc` command waiting in the pending slot is therefore cancelled by the next unrelated comment.
- Templates are worse: `configs/mcp-templates/opencode-github-workflow.yml`, the `cmd_create_workflow` heredoc in `.agents/scripts/opencode-github-setup-helper.sh`, and both snippets in `.agents/tools/git/opencode-github.md` run `anomalyco/opencode/github` **directly** behind the same `contains()` gate with `contents: write`. In a repo that uses them, every aidevops-signed comment starts a paid agent run. The documented "hardening" (`author_association` OWNER/MEMBER/COLLABORATOR) does not help, because signed comments are posted by the owner account.
- A managed downstream repo carrying a copy of this workflow measured about 2,500 runs/day on its self-hosted runner pool from the same gate; it is tracked separately in that repo. This issue fixes the framework source and templates.

## How

- Replace each `contains(body, '/oc') || contains(body, '/opencode')` gate with a whitespace-anchored approximation of the script rule, using GitHub expressions only:
  `startsWith(body, '/oc') || startsWith(body, '/opencode') || contains(body, ' /oc') || contains(body, ' /opencode') || contains(body, fromJSON('"\n/oc"')) || contains(body, fromJSON('"\n/opencode"'))`
  (`fromJSON` decodes the newline; `\r\n` bodies still match `\n/…`). `//opencode.ai` no longer matches because it is preceded by `/`, not whitespace or line start. Keep the in-script regex as the authoritative check.
- `.github/workflows/opencode-agent.yml`: remove the workflow-level `concurrency` block and add job-level `concurrency: { group: opencode-agent, cancel-in-progress: false }` to the `opencode-agent` job only. The global group still serializes repository-mutating runs; Security Validation and Audit Log run unserialized and cheap.
- Update the comment above the old concurrency block, which currently says no-op comments are filtered "before they enter this queue"; that was never true for run-level concurrency.
- Apply the same gate to `configs/mcp-templates/opencode-github-workflow.yml`, the `opencode-github-setup-helper.sh` heredoc, and `.agents/tools/git/opencode-github.md` (basic and hardening snippets).

## Files Scope

- `.github/workflows/opencode-agent.yml`
- `configs/mcp-templates/opencode-github-workflow.yml`
- `.agents/scripts/opencode-github-setup-helper.sh`
- `.agents/tools/git/opencode-github.md`

## Acceptance

- A comment whose body starts with `/oc …` or contains ` /opencode …` mid-line still runs Security Validation.
- A signed comment with no command (only the `[OpenCode](https://opencode.ai)` footer) creates a run whose jobs are all skipped.
- No `OpenCode AI Agent` run is cancelled by concurrency before its jobs are evaluated; only the `opencode-agent` job serializes.
- `bash .agents/scripts/tests/test-opencode-agent-workflow-security.sh`, `actionlint` (if installed) and `shellcheck .agents/scripts/opencode-github-setup-helper.sh` pass.

## Verification

- After merge: `gh api "repos/marcusquinn/aidevops/actions/workflows/opencode-agent.yml/runs?created=>=<merge time>&per_page=50" --jq '[.workflow_runs[].conclusion] | group_by(.) | map({c: .[0], n: length})'` shows `skipped` instead of `cancelled` and `success` for signed comments.
