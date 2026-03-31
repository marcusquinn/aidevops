## Worker Efficiency Protocol

Maximise output per token. Avoid wasted work.

**1. Decompose with TodoWrite (MANDATORY)**
Break task into 3-7 subtasks at session start. Last subtask: `gh pr ready`. ONE `in_progress` at a time.

**2. Commit early, commit often (CRITICAL — prevents lost work)**
Commit after EACH subtask. Uncommitted work is LOST on session end.

```bash
git add -A && git commit -m 'feat: <what you just did> (<task-id>)'
```

After FIRST commit, push and create a draft PR:

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

Subsequent commits: `git push`. When done: `gh pr ready`.

**3. ShellCheck gate before push (MANDATORY for .sh files — t234)**

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

Do NOT push `.sh` files with violations. Missing shellcheck: skip and note in PR body.

**3b. PR title MUST contain task ID (MANDATORY — t318.2)**
Format: `<task-id>: <description>`. Valid task IDs:

- `tNNN` — TODO.md task (e.g., `t318.2: Verify supervisor worker PRs include task ID`)
- `GH#NNN` — GitHub issue (e.g., `GH#12455: tighten hashline-edit-format.md`)

NEVER use `qd-`, bare numbers, or `t` + GitHub issue number. CI and supervisor validate this.

**4. Offload research to ai_research (saves context)**
For files >200 lines you won't edit, use `ai_research` (~100 tokens vs ~5000):

```text
ai_research(prompt: "Find all functions that dispatch workers in supervisor-helper.sh. Return: function name, line number, key variables.", domain: "orchestration")
```

Rate limit: 10/session. Default: haiku. Do NOT offload files you need to edit.

**Domain shorthand** — auto-resolves to agent files:

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

**Parameters**: `prompt` (required), `domain`, `agents` (paths relative to `~/.aidevops/agents/`), `files` (optional line ranges e.g. `src/foo.ts:10-50`), `model` (haiku|sonnet|opus), `max_tokens` (default 500, max 4096).

**5. Parallel sub-work (MANDATORY when applicable)**
Independent subtasks (different files, no output dependency) → parallel Task tool calls in one message. ONE `in_progress` in TodoWrite — parallel Tasks delegate to sub-agents. Do NOT parallelise same-file edits or dependent subtasks.

**6. Fail fast** — Read target files, verify imports/dependencies, exit if already done.

**7. Minimise token waste** — Line ranges from search results, not full-file reads. Concise commits. One failed approach → ONE different strategy → BLOCKED.

**8. Replan when stuck** — Different strategy, not incremental patches. BLOCKED only after one alternative.

## Completion Self-Check (MANDATORY before FULL_LOOP_COMPLETE)

Before emitting FULL_LOOP_COMPLETE, you MUST:

1. **Requirements checklist**: List every requirement, mark [DONE]/[TODO]. Any [TODO] → keep working.
2. **Verification run**: Tests, shellcheck on `.sh` files, lint/typecheck if configured. Confirm output files exist.
3. **Generalization check**: Fix hardcoded values that should be parameterized.
4. **Minimal state changes**: Only modify files explicitly required. No unrequested side effects.
5. **Commit+PR gate (GH#5317 — MANDATORY)**: Before ANY completion signal:
   - `git status --porcelain` returns empty — if not, commit first.
   - PR exists: `gh pr list --head "$(git rev-parse --abbrev-ref HEAD)"` — if not, create one.
   This is the #1 failure mode: workers exit without committing or creating a PR.

FULL_LOOP_COMPLETE is IRREVERSIBLE. Extra verification costs nothing; wrong completion wastes an entire retry cycle.
