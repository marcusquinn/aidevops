## Worker Efficiency Protocol

Maximise your output per token. Follow these practices to avoid wasted work:

**1. Decompose with TodoWrite (MANDATORY)**
At the START of your session, break your task into 3-7 subtasks. Last subtask MUST be: 'Mark PR ready via gh pr ready'. Mark each `in_progress` when started, `completed` when done. ONE `in_progress` at a time.

**2. Commit early, commit often (CRITICAL - prevents lost work)**
After EACH implementation subtask, immediately commit. Uncommitted work is LOST if your session ends.

```bash
git add -A && git commit -m 'feat: <what you just did> (<task-id>)'
```

After your FIRST commit, push and create a draft PR:

```bash
git push -u origin HEAD
gh_issue=$(grep -E '^\s*- \[.\] <task-id> ' TODO.md 2>/dev/null | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || true)
pr_body='WIP - incremental commits'
[[ -n "$gh_issue" ]] && pr_body="${pr_body}

Ref #${gh_issue}"
SIG_FOOTER=$(~/.aidevops/agents/scripts/gh-signature-helper.sh footer --model "$ANTHROPIC_MODEL" 2>/dev/null || echo "")
pr_body="${pr_body}${SIG_FOOTER}"
gh pr create --draft --title '<task-id>: <description>' --body "$pr_body"
```

Subsequent commits just need `git push`. When done: `gh pr ready`.

**3. ShellCheck gate before push (MANDATORY for .sh files - t234)**

```bash
if command -v shellcheck &>/dev/null; then
  sc_errors=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if ! shellcheck -x -S warning -- "$f"; then
      sc_errors=$((sc_errors + 1))
    fi
  done < <(git diff --name-only origin/HEAD..HEAD 2>/dev/null | grep '\.sh$' || true)
  [[ "$sc_errors" -gt 0 ]] && echo "ShellCheck: $sc_errors file(s) failed — fix before pushing" && exit 1
else
  echo "shellcheck not installed — skipping (note in PR body)"
fi
```

Do NOT push `.sh` files with violations. If `shellcheck` not installed, skip and note in PR body.

**3b. PR title MUST contain task ID (MANDATORY - t318.2)**
Title: `<task-id>: <description>`. Task ID is one of:
- `tNNN` — TODO.md task ID (e.g., `t318.2: Verify supervisor worker PRs include task ID`)
- `GH#NNN` — GitHub issue number for quality-debt/simplification-debt work (e.g., `GH#12455: tighten hashline-edit-format.md`)

NEVER use `qd-`, bare numbers, or `t` followed by a GitHub issue number. `qd-` is for branch names only. CI and supervisor both validate this.

**4. Offload research to ai_research tool (saves context for implementation)**
For files >200 lines you do not plan to edit, use `ai_research` instead of reading directly (~100 tokens vs ~5000):

```text
ai_research(prompt: "Find all functions that dispatch workers in supervisor-helper.sh. Return: function name, line number, key variables.", domain: "orchestration")
```

Rate limit: 10/session. Default model: haiku. Do NOT offload when you need to edit the file.

**Domain shorthand** — auto-resolves to relevant agent files:

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

**Parameters**: `prompt` (required), `domain`, `agents` (paths relative to `~/.aidevops/agents/`), `files` (with optional line ranges e.g. `src/foo.ts:10-50`), `model` (haiku|sonnet|opus), `max_tokens` (default 500, max 4096).

**5. Parallel sub-work (MANDATORY when applicable)**
If two or more subtasks are independent (different files, no output dependency), launch them as parallel Task tool calls in a single message. TodoWrite still tracks ONE `in_progress` — parallel Tasks delegate concurrent work to sub-agents. Do NOT parallelise when subtasks modify the same file or B depends on A's output.

**6. Fail fast, not late**
Before writing any code: read files you plan to modify, verify imports/dependencies exist, exit immediately if the task is already done.

**7. Minimise token waste**
Use line ranges from search results, not full-file reads. Keep commit messages concise. If an approach fails, try ONE fundamentally different strategy before exiting BLOCKED.

**8. Replan when stuck, do not patch**
Step back and try a different strategy rather than incrementally patching a broken approach. Only exit BLOCKED after trying at least one alternative.

## Completion Self-Check (MANDATORY before FULL_LOOP_COMPLETE)

Before emitting FULL_LOOP_COMPLETE or marking task complete, you MUST:

1. **Requirements checklist**: List every requirement. Mark each [DONE] or [TODO]. If ANY are [TODO], keep working.
2. **Verification run**: Run tests, shellcheck on modified `.sh` files, lint/typecheck if configured. Confirm output files exist.
3. **Generalization check**: Fix hardcoded values that should be parameterized.
4. **Minimal state changes**: Only create or modify files explicitly required. No extra files or unrequested side effects.
5. **Commit+PR gate (GH#5317 — MANDATORY)**: Before emitting ANY completion signal:
   - `git status --porcelain` returns empty. If not, commit first.
   - PR exists: `gh pr list --head "$(git rev-parse --abbrev-ref HEAD)"`. If not, create one.
   This is the #1 failure mode: workers exit without committing or creating a PR.

FULL_LOOP_COMPLETE is IRREVERSIBLE and FINAL. Extra verification costs nothing; a wrong completion wastes an entire retry cycle.
