<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1407: Check contributing guidelines before filing issues/PRs on external repos

## Origin

- **Created:** 2026-03-06
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human, with AI assistance)
- **Conversation context:** Filed a detailed bug report on anomalyco/opencode (#16209) that was auto-closed by their template compliance bot because we didn't use their Bug Report template. The issue content was excellent but the format didn't match their `.github/ISSUE_TEMPLATE/bug-report.yml`. Their `compliance-close.yml` workflow gives 2 hours to fix formatting, then auto-closes. 214+ issues and 126+ PRs have been closed by this mechanism on that repo alone.

## What

Add guidance and a pre-submission check so aidevops agents format issues and PRs correctly when filing on external (non-maintained) repos. When `gh issue create --repo <external-slug>` or `gh pr create` targets a repo not in our repos.json, the agent should:

1. Fetch the repo's issue templates via `gh api repos/{slug}/contents/.github/ISSUE_TEMPLATE/`
2. Fetch `CONTRIBUTING.md` if it exists
3. Format the issue/PR body to match the required template structure
4. For issue templates that are YAML forms (GitHub's structured format), replicate the `### Label` section headers that GitHub generates when the form is submitted via the web UI

## Why

Without this, well-crafted issues get auto-closed by template compliance bots, wasting the effort of writing them and requiring manual resubmission. This is increasingly common — many large repos use AI-powered compliance checking (opencode uses Sonnet to check template compliance). The 2-hour auto-close window is easy to miss, especially for headless/automated submissions.

## How (Approach)

Two changes:

### 1. Add guidance to `prompts/build.txt` (agent-level rule)

Add a section under the existing GitHub/issue creation guidance:

```
# External repo issue/PR submission
- Before `gh issue create --repo <slug>` on a repo not in repos.json:
  1. Check for issue templates: `gh api repos/{slug}/contents/.github/ISSUE_TEMPLATE/`
  2. Check for CONTRIBUTING.md: `gh api repos/{slug}/contents/CONTRIBUTING.md`
  3. If templates exist, format the issue body to match the required template
  4. YAML form templates generate `### Label` headers — replicate this structure
```

### 2. Add practical examples to `tools/git/github-cli.md`

Add an "External Repo Submissions" section with:
- How to discover and read issue templates
- How to map YAML form fields to markdown sections
- Example of converting a free-form issue to a template-compliant one

No helper script needed — this is judgment-based guidance, not a deterministic check. The agent reads the template and formats accordingly.

## Acceptance Criteria

- [ ] `prompts/build.txt` contains guidance about checking contributing guidelines before filing on external repos
  ```yaml
  verify:
    method: codebase
    pattern: "contributing guidelines|issue template|external repo"
    path: ".agents/prompts/build.txt"
  ```
- [ ] `tools/git/github-cli.md` contains a section on external repo submissions with template discovery examples
  ```yaml
  verify:
    method: codebase
    pattern: "ISSUE_TEMPLATE|external.*repo|contributing"
    path: ".agents/tools/git/github-cli.md"
  ```
- [ ] Guidance covers both issues and PRs
  ```yaml
  verify:
    method: subagent
    prompt: "Review the changes to build.txt and github-cli.md. Does the guidance cover both issue creation AND PR creation on external repos? Does it explain how to discover and use issue templates?"
    files: ".agents/prompts/build.txt,.agents/tools/git/github-cli.md"
  ```
- [ ] Lint clean (`shellcheck` / `markdownlint`)

## Context & Decisions

- **Why guidance, not a script:** This is a judgment call (which template to use, how to map content to fields) — per the "Intelligence Over Determinism" principle, this belongs in agent guidance, not a bash script.
- **Why not check all repos:** Only external repos need this. Our own repos either have no templates or we control the templates. The check is "is this repo in repos.json?" — if not, check their guidelines.
- **Resubmitted issue:** The original opencode issue was resubmitted as #16269 using their Bug Report template format.
- **Scale of the problem:** opencode alone has 214+ issues and 126+ PRs auto-closed by template compliance. This is a growing pattern across popular repos.

## Relevant Files

- `.agents/prompts/build.txt` — main agent rules, add external repo submission guidance
- `.agents/tools/git/github-cli.md` — GitHub CLI reference, add template discovery section
- `.agents/scripts/commands/log-issue-aidevops.md` — existing issue creation workflow (internal only, but pattern to reference)

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing critical, but prevents future auto-closures on external repos
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Review existing build.txt and github-cli.md sections |
| Implementation | 1h | Add guidance to both files |
| Testing | 30m | Verify guidance is clear, lint clean |
| **Total** | **~2h** | |
