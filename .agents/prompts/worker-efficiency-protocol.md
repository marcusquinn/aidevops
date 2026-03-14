## Worker Efficiency Protocol

Maximise your output per token. Follow these practices to avoid wasted work:

**1. Decompose with TodoWrite (MANDATORY)**
At the START of your session, use the TodoWrite tool to break your task into 3-7 subtasks.
Your LAST subtask must ALWAYS be: 'Push branch and create PR via gh pr create'.
Example for 'add retry logic to API client':
- Research: read existing API client code and error handling patterns
- Implement: add retry with exponential backoff to the HTTP client
- Test: write unit tests for retry behaviour (success, max retries, backoff timing)
- Integrate: update callers if the API surface changed
- Verify: run linters, shellcheck, and existing tests
- Deliver: push branch and create PR via gh pr create

Mark each subtask in_progress when you start it and completed when done.
Only have ONE subtask in_progress at a time.

**2. Commit early, commit often (CRITICAL - prevents lost work)**
After EACH implementation subtask, immediately:

```bash
git add -A && git commit -m 'feat: <what you just did> (<task-id>)'
```

Do NOT wait until all subtasks are done. If your session ends unexpectedly (context
exhaustion, crash, timeout), uncommitted work is LOST. Committed work survives.

After your FIRST commit, push and create a draft PR immediately:

```bash
git push -u origin HEAD
# t288: Include GitHub issue reference in PR body when task has ref:GH# in TODO.md
# Look up: grep -oE 'ref:GH#[0-9]+' TODO.md for your task ID, extract the number
# If found, add 'Ref #NNN' to the PR body so GitHub cross-links the issue
gh_issue=$(grep -E '^\s*- \[.\] <task-id> ' TODO.md 2>/dev/null | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || true)
pr_body='WIP - incremental commits'
[[ -n "$gh_issue" ]] && pr_body="${pr_body}

Ref #${gh_issue}"
gh pr create --draft --title '<task-id>: <description>' --body "$pr_body"
```

Subsequent commits just need `git push`. The PR already exists.
This ensures the supervisor can detect your PR even if you run out of context.
The `Ref #NNN` line cross-links the PR to its GitHub issue for auditability.

When ALL implementation is done, mark the PR as ready for review:

```bash
gh pr ready
```

If you run out of context before this step, the supervisor will auto-promote
your draft PR after detecting your session has ended.

**3. ShellCheck gate before push (MANDATORY for .sh files - t234)**
Before EVERY `git push`, check if your commits include `.sh` files:

```bash
sh_files=$(git diff --name-only origin/HEAD..HEAD 2>/dev/null | grep '\.sh$' || true)
if [[ -n "$sh_files" ]]; then
  echo "Running ShellCheck on modified .sh files..."
  sc_failed=0
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    if ! shellcheck -x -S warning "$f"; then
      sc_failed=1
    fi
  done <<< "$sh_files"
  if [[ "$sc_failed" -eq 1 ]]; then
    echo "ShellCheck violations found - fix before pushing."
    # Fix the violations, then git add -A && git commit --amend --no-edit
  fi
fi
```

This catches CI failures 5-10 min earlier. Do NOT push .sh files with ShellCheck violations.
If `shellcheck` is not installed, skip this gate and note it in the PR body.

**3b. PR title MUST contain task ID (MANDATORY - t318.2)**
When creating a PR, the title MUST start with the task ID: `<task-id>: <description>`.
Example: `t318.2: Verify supervisor worker PRs include task ID`
The CI pipeline and supervisor both validate this. PRs without task IDs fail the check.
If you used `gh pr create --draft --title '<task-id>: <description>'` as instructed above,
this is already handled. This note reinforces: NEVER omit the task ID from the PR title.

**4. Offload research to ai_research tool (saves context for implementation)**
Reading large files (500+ lines) consumes your context budget fast. Instead of reading
entire files yourself, call the `ai_research` MCP tool with a focused question:

```text
ai_research(prompt: "Find all functions that dispatch workers in supervisor-helper.sh. Return: function name, line number, key variables.", domain: "orchestration")
```

The tool spawns a sub-worker via the Anthropic API with its own context window.
You get a concise answer that costs ~100 tokens instead of ~5000 from reading directly.
Rate limit: 10 calls per session. Default model: haiku (cheapest).

**Domain shorthand** - auto-resolves to relevant agent files:

| Domain | Agents loaded |
|--------|--------------|
| git | git-workflow, github-cli, conflict-resolution |
| planning | plans, beads |
| code | code-standards, code-simplifier |
| seo | seo, dataforseo, google-search-console |
| content | content, research, writing |
| wordpress | wp-dev, mainwp |
| browser | browser-automation, playwright |
| deploy | coolify, coolify-cli, vercel |
| security | tirith, encryption-stack |
| mcp | build-mcp, server-patterns |
| agent | build-agent, agent-review |
| framework | architecture, setup |
| release | release, version-bump |
| pr | pr, preflight |
| orchestration | headless-dispatch |
| context | model-routing, toon, mcp-discovery |
| video | video-prompt-design, remotion, wavespeed |
| voice | speech-to-speech, voice-bridge |
| mobile | agent-device, maestro |
| hosting | hostinger, cloudflare, hetzner |
| email | email-testing, email-delivery-test |
| accessibility | accessibility, accessibility-audit |
| containers | orbstack |
| vision | overview, image-generation |

**Parameters** (for `ai_research`): `prompt` (required), `domain` (shorthand above), `agents` (comma-separated paths relative to ~/.aidevops/agents/), `files` (paths with optional line ranges e.g. "src/foo.ts:10-50"), `model` (haiku|sonnet|opus), `max_tokens` (default 500, max 4096).

**When to offload**: Any time you would read >200 lines of a file you do not plan to edit,
or when you need to understand a codebase pattern across multiple files.

**When NOT to offload**: When you need to edit the file (you must read it yourself for
the Edit tool to work), or when the answer is a simple grep/rg query.

**5. Parallel sub-work (MANDATORY when applicable)**
After creating your TodoWrite subtasks, check: do any two subtasks modify DIFFERENT files?
If yes, you SHOULD parallelise where possible. Use `ai_research` for read-only research
tasks that do not require file edits.

**Decision heuristic**: If your TodoWrite has 3+ subtasks and any two do not modify the same
files, the independent ones can run in parallel. Common parallelisable patterns:
- Use `ai_research` to understand a codebase pattern while you implement in another file
- Run `ai_research(domain: "code")` to check conventions while writing new code

**Do NOT parallelise when**: subtasks modify the same file, or subtask B depends on
subtask A's output (e.g., B imports a function A creates). When in doubt, run sequentially.

**6. Fail fast, not late**
Before writing any code, verify your assumptions:
- Read the files you plan to modify (stale assumptions waste entire sessions)
- Check that dependencies/imports you plan to use actually exist in the project
- If the task seems already done, EXIT immediately with explanation - do not redo work

**7. Minimise token waste**
- Do not read entire large files - use line ranges from search results
- Do not output verbose explanations in commit messages - be concise
- If an approach fails, try ONE fundamentally different strategy before exiting BLOCKED

**8. Replan when stuck, do not patch**
If your first approach is not working, step back and consider a fundamentally different
strategy instead of incrementally patching the broken approach. A fresh approach often
succeeds where incremental fixes fail. Only exit with BLOCKED after trying at least one
alternative strategy.

## Completion Self-Check (MANDATORY before FULL_LOOP_COMPLETE)

Before emitting FULL_LOOP_COMPLETE or marking task complete, you MUST:

1. **Requirements checklist**: List every requirement from the task description as a
   numbered checklist. Mark each [DONE] or [TODO]. If ANY are [TODO], do NOT mark
   complete - keep working.

2. **Verification run**: Execute available verification:
   - Run tests if the project has them
   - Run shellcheck on any .sh files you modified
   - Run lint/typecheck if configured
   - Confirm output files exist and have expected content

3. **Generalization check**: Would your solution still work if input values, file
   contents, or dimensions changed? If you hardcoded something that should be
   parameterized, fix it before completing.

4. **Minimal state changes**: Only create or modify files explicitly required by the
   task. Do not leave behind extra files, modified configs, or side effects that were
   not requested.

FULL_LOOP_COMPLETE is IRREVERSIBLE and FINAL. You have unlimited iterations but only
one submission. Extra verification costs nothing; a wrong completion wastes an entire
retry cycle.
