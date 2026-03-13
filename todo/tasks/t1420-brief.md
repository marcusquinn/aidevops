# t1420: Add maintainer field to repos.json for code-simplifier assignment fallback

## Session Origin

Interactive session, `/full-loop` dispatch from GH#3937.

## What

Add a `maintainer` field to each repo entry in `~/.config/aidevops/repos.json`. This field stores the GitHub username of the person responsible for reviewing code-simplifier issues and other maintainer-gated workflows for that repo.

## Why

The code-simplifier agent (`.agents/tools/code-review/code-simplifier.md`) already references `repos.json`'s `maintainer` field in its Human Gate Workflow (line 311), but the field doesn't exist in any repo entry. Currently the fallback is to parse the owner from the slug (`cut -d/ -f1`), which breaks when the repo owner org differs from the actual maintainer (e.g., `webapp/webapp` is maintained by an individual user, not the org slug owner).

## How

1. Add `"maintainer": "<github-username>"` to each repo entry in repos.json
2. Add a `get_repo_maintainer` helper function to `aidevops.sh` that reads the field with slug-owner fallback
3. Update `register_repo` in `aidevops.sh` to auto-detect maintainer from `gh api` when registering new repos
4. Update AGENTS.md repo registration docs to mention the maintainer field
5. Verify code-simplifier.md's existing jq example works with the new field

## Acceptance Criteria

- [ ] Every repo entry in repos.json has a `maintainer` field
- [ ] `get_repo_maintainer` function exists in aidevops.sh and returns the correct username
- [ ] Fallback chain: maintainer field > slug owner > empty string
- [ ] code-simplifier.md jq example works against the updated repos.json
- [ ] ShellCheck passes on modified shell scripts
- [ ] No breaking changes to existing repos.json consumers

## Context

- code-simplifier.md lines 306-313: existing reference to maintainer field
- repos.json: `~/.config/aidevops/repos.json` (user config, not committed)
- aidevops.sh: `register_repo` function (lines 147-204)
- pulse-wrapper.sh: reads repos.json for pulse-enabled repos
