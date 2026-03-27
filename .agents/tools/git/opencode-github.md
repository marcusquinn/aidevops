---
description: OpenCode GitHub App integration for AI-powered issue/PR automation
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# OpenCode GitHub Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Setup**: `opencode github install` (automated)
- **Trigger**: `/opencode` or `/oc` in any issue/PR comment
- **App**: https://github.com/apps/opencode-agent
- **Docs**: https://opencode.ai/docs/github/

| Command | Result |
|---------|--------|
| `/oc explain this` | AI analyzes issue/PR and replies |
| `/oc fix this` | Creates branch, implements fix, opens PR |
| `/oc review this PR` | Reviews code, suggests improvements |
| `/oc add error handling here` | Line-specific fix (in Files tab) |

**Requirements**: GitHub App installed, workflow file (`.github/workflows/opencode.yml`), secret (`ANTHROPIC_API_KEY` or other provider). Runs on YOUR GitHub Actions runners.

<!-- AI-CONTEXT-END -->

## Installation

**Automated**: `opencode github install` (walks through App install → workflow → secrets).

**Manual**:

1. **Install App**: https://github.com/apps/opencode-agent — install for repo or org.

2. **Create `.github/workflows/opencode.yml`**:

```yaml
name: opencode
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]

jobs:
  opencode:
    if: |
      contains(github.event.comment.body, '/oc') ||
      contains(github.event.comment.body, '/opencode')
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: write
      pull-requests: write
      issues: write
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 1

      - name: Run OpenCode
        uses: sst/opencode/github@latest
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
        with:
          model: anthropic/claude-sonnet-4-6
```

**3. Add Secrets**: Repository Settings → Secrets and variables → Actions. Add `ANTHROPIC_API_KEY`. Other providers: `OPENAI_API_KEY`, `GOOGLE_API_KEY`.

## Usage

Commands work in issue comments, PR comments, and PR file-level comments (line-specific). `/oc` can appear anywhere in a comment (e.g., `This needs validation. /oc add input validation`). Line-specific comments (PR Files tab) give OpenCode exact file/line/diff context.

## Configuration

```yaml
- uses: sst/opencode/github@latest
  with:
    model: anthropic/claude-sonnet-4-6  # Required
    agent: build                                # Optional: agent to use
    share: true                                 # Optional: share session (default: true for public repos)
    prompt: |                                   # Optional: custom prompt
      Review this PR focusing on:
      - Security issues
      - Performance problems
    token: ${{ secrets.CUSTOM_TOKEN }}         # Optional: custom GitHub token
```

**Token options**: Default = OpenCode App Token (commits as "opencode-agent"). Use `token: ${{ secrets.GITHUB_TOKEN }}` for built-in runner token (no app needed), or a PAT for commits under your identity.

## Check Setup / Troubleshooting

```bash
~/.aidevops/agents/scripts/opencode-github-setup-helper.sh check
```

| Problem | Check |
|---------|-------|
| Not responding | Workflow exists? Actions tab shows run? Secrets configured? |
| Permission denied | Workflow `permissions` block has all 4 scopes (id-token, contents, pull-requests, issues) |
| App not installed | Install at https://github.com/apps/opencode-agent, or use `GITHUB_TOKEN` instead |

## Security

Runs on YOUR runners (code never leaves your environment). Secrets stored in GitHub Secrets. All actions visible in Actions tab audit trail.

### Hardening (Recommended)

The basic workflow allows ANY user to trigger AI commands. Restrict to trusted users by adding to the workflow job `if`:

```yaml
(github.event.comment.author_association == 'OWNER' ||
 github.event.comment.author_association == 'MEMBER' ||
 github.event.comment.author_association == 'COLLABORATOR')
```

**Full security**: See `git/opencode-github-security.md` — trusted user validation, `ai-approved` label gates, prompt injection detection, audit logging.

```bash
# Quick setup with max security
cp .github/workflows/opencode-agent.yml .github/workflows/opencode.yml
gh label create "ai-approved" --color "0E8A16" --description "Issue approved for AI agent"
gh label create "security-review" --color "D93F0B" --description "Requires security review"
```

## Integration with aidevops

OpenCode PRs trigger existing CI workflows. Configure the prompt for aidevops conventions:

```yaml
prompt: |
  Use conventional commits, create feature/ or bugfix/ branches,
  include ## Summary in PR description, run quality checks before committing.
```

## Related

- **Security hardening**: `git/opencode-github-security.md`
- **GitLab integration**: `git/opencode-gitlab.md`
- **GitHub CLI**: `git/github-cli.md`
- **GitHub Actions**: `git/github-actions.md`
- **Git workflow**: `workflows/git-workflow.md`
