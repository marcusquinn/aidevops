<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Conversational Memory Lookup

When the user references past work — "remember when we...", "that thing we built",
"last week we did...", "the session where...", "we already solved this" — they are
recalling something from a previous session. The current session has no memory of it
unless you actively search. This is a judgment call, not a keyword trigger.

Progressive discovery — same principle as agent context loading. Search from
short-term/local (instant, free) through long-term/remote (API calls, expensive).
Stop as soon as you have enough context to respond. Don't search all sources for
every vague reference — match the source to the question.

## Tier 1 — Local cached (instant, zero cost)

1. **Cross-session memory**: `memory-helper.sh recall "keywords"` (CLI) or `aidevops_memory` MCP tool with `action: "recall"` — curated signal, most likely to have the answer. Solutions, decisions, preferences, patterns.
2. **TODO.md + completed tasks**: `rg "keyword" TODO.md` — task IDs, PR numbers, completion dates, brief descriptions of all past work.

## Tier 2 — Local indexed (fast, local I/O)

3. **Git history**: `git log --all --oneline --grep="keyword"` — commits, branches, PRs, code changes. High volume but precise when the keyword is specific.
4. **Session transcripts (Claude Code)**: `~/.claude/transcripts/*.jsonl` — full JSONL conversation logs. `rg "keyword" ~/.claude/transcripts/`. Recovers exact conversation context, what was discussed, tool calls made. For structured field searches, pipe through jq: `rg -l "keyword" ~/.claude/transcripts/ | xargs -I{} jq 'select(.type=="assistant") | .message.content' {}`
5. **Session database**: runtime-specific — see AGENTS.md for paths per runtime.
6. **Observability metrics**: `~/.aidevops/.agent-workspace/observability/metrics.jsonl` — JSONL log of LLM request metadata, costs, models, tokens per session. Fields per record: provider, model, session_id, request_id, project, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, cost_input, cost_output, cost_total, stop_reason, git_branch, recorded_at. Example: `jq -s '[.[] | select(.project=="aidevops")] | group_by(.model) | map({model:.[0].model, total_cost:([.[].cost_total] | add), requests:length})' ~/.aidevops/.agent-workspace/observability/metrics.jsonl`

## Tier 3 — Remote targeted (API calls, need a specific number)

7. **GitHub issue/PR comments**: `gh issue view {num} --comments --repo {slug}`, `gh pr view {num} --comments --repo {slug}`, or the API equivalents `gh api repos/{slug}/issues/{num}/comments` and `gh api repos/{slug}/pulls/{num}/comments` (for inline review comments). Discussion, review feedback, decisions made in threads — context that never reaches git or memory. Get the issue/PR number from TODO.md first.

## Tier 4 — Remote broad (expensive, last resort)

8. **GitHub search**: `gh search issues "keyword" --repo {slug}` (issues), `gh search prs "keyword" --repo {slug}` (PRs), `gh search code "keyword" --repo {slug}` (code). Broad search when you don't know the issue/PR number.
9. **GitHub discussions**: `gh api repos/{slug}/discussions` (if enabled). Long-form design discussions, RFCs, community Q&A.
10. **GitHub wiki**: `gh api repos/{slug}/pages` or clone the wiki repo (`git clone https://github.com/{slug}.wiki.git`). Persistent documentation that may contain architectural decisions, onboarding guides, or historical context.

## Examples

- "Remember that auth fix?" → memory recall + git log.
- "What did we discuss about the database schema?" → memory recall + transcripts.
- "How much did last week's batch run cost?" → observability metrics.
- "What did the reviewer say about that PR?" → TODO.md (get PR#) + PR comments.
- "Was there a discussion about the migration?" → GitHub discussions/wiki.
