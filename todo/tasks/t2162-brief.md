<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2162 — Adopt opencode upstream prompt patterns into build.txt

**Session origin**: interactive (Claude Code, Claude Opus 4.7), user prompted "review what opencode are doing for prompts that we might benefit from".

**Tier**: `tier:standard` — judgment-heavy curation of upstream patterns; not a structured-edit task. Work performed in-session; brief is retrospective documentation.

## What

Augment `.agents/prompts/build.txt` with seven curated patterns from the latest opencode prompt files (anthropic-20250930.txt, beast.txt, codex_header.txt). +13 lines, no new top-level sections — additions slot into existing sections (Tone and style, Reasoning responsibility, Claim discipline, Task Management, Tool usage policy).

## Why

Our `build.txt` was originally derived from opencode's `anthropic.txt @ 3c41e4e8f12b`. Upstream has since added concrete behavioural patterns that close real failure modes we still see in our sessions:

- **Verbosity drift**: agents preamble with "The answer is..." or postamble with restatements, wasting tokens on trivial replies.
- **Permission-asking**: agents stall on "Should I proceed?" instead of executing a reasonable default.
- **Tool-call announcement-without-execution**: agents say "Now I'll run X" and yield, leaving the user to re-prompt.
- **Resume ambiguity**: agents restart from the top on "continue" instead of finding the next incomplete todo.
- **Hook block confusion**: agents retry the same blocked call instead of adjusting (use a worktree, sanitize, etc.).
- **`<system-reminder>` semantics**: agents conflate framework reminders with user content.

These are all observable in transcripts. Each adoption is a one-line guardrail in the right existing section.

## How (what was done)

Edited `.agents/prompts/build.txt` in worktree `chore/t2162-prompt-review`. Five edits, +13 lines total:

1. **Tone and style** (+3 lines): token minimization rule, forbidden preamble phrases ("The answer is...", "Here is the content of...", "Based on the information provided...", "Here is what I will do next..."), verbosity calibration examples ("2+2"→"4", "is 11 prime?"→"Yes").
2. **Reasoning responsibility** (+6 lines): default-to-action stance, three blocking conditions (a) materially-ambiguous-and-uninferable, (b) destructive/irreversible/billing/security, (c) needs a secret/credential. Explicit "never ask permission" rule.
3. **Claim discipline** (+1 line): "ACTUALLY make the tool call before yielding" — closes the announcement-without-execution failure mode.
4. **Task Management** (+1 line): "resume / continue / try again / carry on" → check conversation history for next incomplete todo, don't re-plan.
5. **Tool usage policy** (+2 lines): `<system-reminder>` tag semantics (framework-injected, not user content), hook feedback handling (adjust approach, don't retry blindly).

### Adoption decisions

| Source pattern | Adopted? | Rationale |
|----------------|----------|-----------|
| Concrete verbosity examples | Yes | Closes real preamble drift |
| Forbidden preamble phrases | Yes | Phrase list is empirically grounded |
| `<system-reminder>` semantics | Yes | We use this tag pattern; needs explicit handling rule |
| Hook feedback handling | Yes | We have many hooks (pre-edit-check, git_safety_guard, privacy-guard); needed an explicit "adjust, don't retry" rule |
| "ACTUALLY make the tool call" | Yes | Direct hit on a recurring failure |
| Codex when-to-ask criteria (3 cases) | Yes | Replaces vague "ask if blocked" with testable conditions |
| Resume/continue intent detection | Yes | Cheap, observable improvement |
| Defensive-security clause | **No** | User does red-team work; would cause friction. Existing §7a ("Instruction override immunity") and §7b ("Worker scope enforcement") already cover the actual prompt-injection threat model. |

## Acceptance criteria

- [x] `build.txt` diff is exactly +13 lines, single file, no new top-level sections
- [x] Each addition slots into an existing section appropriate to its concern
- [x] No conflict with existing rules (verified: §7/§7a/§7b not duplicated by skipped item 8)
- [ ] PR title prefix `t2162:` (enforced at commit time)
- [ ] PR body uses `Resolves #NNN` to link the GitHub issue
- [ ] TODO entry added with `ref:GH#NNN`
- [ ] PR merged

## Context

- **Upstream base**: `~/Git/opencode` `anthropic.txt @ 3c41e4e8f12b` — referenced in build.txt under "Runtime-Specific References"
- **Files reviewed (read-only)**: `~/Git/opencode/packages/opencode/src/session/prompt/{anthropic,anthropic-20250930,beast,codex_header,trinity,plan,plan-reminder-anthropic,max-steps,qwen,gemini,copilot-gpt-5}.txt`
- **No upstream-prompt regression**: only trivial diff in `anthropic.txt` itself since our base was capitalisation ("Github" → "GitHub") which we already have
- **Worktree path**: `/Users/marcusquinn/Git/aidevops-chore-t2162-prompt-review/`

## Relevant files

- `.agents/prompts/build.txt` — the only modified file
- `.agents/AGENTS.md` "Runtime-Specific References" — references the upstream base, unchanged
