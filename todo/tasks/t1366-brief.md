# t1366: Add git-commit correlation to session miner for productivity analysis

## Origin

- **Created:** 2026-03-01
- **Session:** claude-code:interactive
- **Created by:** ai-interactive (user-requested)
- **Conversation context:** User shared [douglance/devsql](https://github.com/douglance/devsql) — a Rust tool that creates SQL virtual tables over Claude Code session data + git history, enabling queries like "which prompts led to the most commits?" Analysis concluded we already have session mining (`session-miner-pulse.sh`) and cross-session memory, but we lack the git-conversation correlation that is devsql's core insight.

## What

Add a git-correlation step to the session miner extraction pipeline that cross-references session activity with git commit outcomes. For each session, compute:

1. **Commits produced** — `git log` entries authored during or shortly after the session window
2. **Files changed** — diff stats (insertions, deletions, files touched) for those commits
3. **Productivity score** — commits per session, lines changed per message count
4. **Prompt-to-commit mapping** — which user prompts preceded productive commits (by timestamp proximity)

Output: a `git_correlation` section in the session miner's extraction output that the LLM analysis phase can use to identify high-productivity prompt patterns.

## Why

Our session miner currently analyses sessions in isolation — it sees tool usage patterns, error rates, and conversation flow, but has no visibility into whether a session actually produced useful code. DevSQL's insight is that the most valuable signal is the correlation between prompts and git outcomes. Adding this gives us:

- "Which prompt styles lead to productive sessions?" (actionable for prompt improvement)
- "Which repos/task types have the worst prompt-to-commit ratio?" (identifies where the framework needs improvement)
- "What time of day / session length correlates with productivity?" (scheduling insights)

## How (Approach)

### Files to modify

- `.agents/scripts/session-miner/extract.py` — Add git correlation extraction
- `.agents/scripts/session-miner-pulse.sh` — Pass repo paths to extractor, include git data in LLM analysis prompt

### Implementation

1. **Extract session time windows**: The extractor already parses session timestamps. For each session, determine `start_time` and `end_time` (first and last message timestamps).

2. **Query git log for the session window**: For each session that has a `cwd` or project path:
   ```bash
   git -C <project_path> log --after=<start_time> --before=<end_time+1h> \
     --format='%H|%aI|%s' --shortstat
   ```
   The +1h buffer accounts for commits made shortly after the last prompt.

3. **Compute correlation metrics**:
   - `commits_count`: number of commits in the window
   - `files_changed`: total files touched
   - `insertions` / `deletions`: total line changes
   - `messages_count`: number of user messages in the session
   - `productivity_ratio`: `commits_count / messages_count`
   - `prompt_commit_pairs`: list of (prompt_text, commit_summary) pairs matched by timestamp proximity (<5 min)

4. **Add to extraction output**: Include `git_correlation` dict in the per-session JSON that the compressor and LLM analysis phase consume.

5. **Update LLM analysis prompt**: Add a section asking the LLM to identify patterns in high-productivity vs low-productivity sessions based on the git correlation data.

### Edge cases

- Sessions with no `cwd` / project path: skip git correlation, mark as `git_correlation: null`
- Repos not accessible (deleted, moved): graceful skip with warning
- Sessions spanning midnight or multiple days: use full time range
- Multiple repos in one session: correlate with each repo independently

## Acceptance Criteria

1. `session-miner-pulse.sh` produces git correlation data for sessions that have a project path
2. The extraction output includes `commits_count`, `productivity_ratio`, and `prompt_commit_pairs` per session
3. The LLM analysis phase receives and comments on productivity patterns
4. Sessions without git data are gracefully skipped (no errors)
5. Existing session miner functionality is not broken (backward compatible output format)

## Estimates

- **Effort:** ~3h
- **Model tier:** sonnet
- **Risk:** Low — additive change to existing pipeline, no breaking changes
