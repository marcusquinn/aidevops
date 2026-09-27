<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Context Budget Measurement

Use `context-budget-helper.sh` to measure what OpenCode actually sends on the
first request: agent prompt, instruction files, skill catalogue, plugin
additions and tool definitions. Use it before and after any change that claims
to reduce, or might grow, always-loaded context.

## Rules

- **Tokens come from the API.** Prompt tokens = `input + cache_read + cache_write`
  from `llm_requests`. Character counts locate where context sits; they do not
  prove a saving. Char/4 estimates overstated one saving by 2-3x (GH#32592).
- **Compare like with like.** Same runtime, model, agent, turn count, headless
  mode and project directory for control and candidate.
- **Isolate.** The helper copies the runtime config into a temporary 0700 home
  and swaps only the aidevops plugin entry. Never use `OPENCODE_CONFIG_CONTENT`
  for this: it merges plugin lists and loads both plugins.

## Workflow

For usage-driven on-demand selection, count distinct sessions with a tool call
in the last 30 days against all sessions with any recorded tool call in that
window (not the number of calls). Query the read-only observability SQLite DB
at `~/.aidevops/.agent-workspace/observability/llm-requests.db`:

```sql
WITH active AS (
  SELECT DISTINCT session_id FROM tool_calls
  WHERE timestamp >= datetime('now', '-30 days')
), counts AS (
  SELECT tool_name, count(DISTINCT session_id) AS sessions FROM tool_calls
  WHERE timestamp >= datetime('now', '-30 days') GROUP BY tool_name
)
SELECT tool_name, sessions, (SELECT count(*) FROM active) AS total_sessions,
  round(100.0 * sessions / (SELECT count(*) FROM active), 3) AS percent
FROM counts ORDER BY tool_name;
```

Keep mandatory-guidance and per-agent-gated tools direct even below 2%.

```bash
# Control: deployed plugin. Two turns show the prompt-cache read on turn 2.
context-budget-helper.sh capture oc1 --turns 2 --dir <project>

# Candidate: plugin code from a checkout or linked worktree.
context-budget-helper.sh capture oc1 --turns 2 --dir <project> --plugin <worktree>

# Where the context sits, and what changed.
context-budget-helper.sh analyze <capture.json>
context-budget-helper.sh compare <control.json> <candidate.json>

# Token evidence for any window (UTC); capture prints this automatically for OC1.
context-budget-helper.sh tokens --since 2026-01-01T12:00 --model claude-haiku-4-5 --new-sessions
```

Add `--headless` to measure the worker/headless prompt (`AIDEVOPS_HEADLESS=1`).
Use `capture oc2` for OpenCode 2; OC2 does not write `llm_requests` rows yet
(GH#32619), so compare OC2 captures in characters. OC2 may send a small
tool-less title request first; compare the capture that carries the tools.

## What the captures show

- `analyze` splits the system blocks and the first message at stable markers:
  `Instructions from:` files, the skill preamble and `<skill_list>` catalogue,
  plugin additions (intent tracing, quality rules), plus a per-tool table.
- The wire-shape block checks the Anthropic OAuth invariants: two system blocks
  (billing header, Claude Code identity), `mcp__`-prefixed non-built-in tools,
  `agent__intent` on every tool, and the cache-control layout. `compare` lists
  any invariant that changed.
- A healthy turn 2 has `cache_read` equal to the turn-1 prompt prefix. A lower
  value means the prefix changed between requests.

## Scope and safety

- Candidate mode loads plugin code from the checkout; framework docs and agent
  prompts still come from the deployed `~/.aidevops/agents/`. Deploy with
  `setup.sh` before measuring doc or prompt changes, or compare before/after
  deploys.
- A checkout has no installed dependencies, so the helper links the deployed
  plugin `node_modules` into it for the run and removes the link on exit.
- Captures are request bodies only (no headers or credentials), stored 0600
  under `$AIDEVOPS_TEMP_DIR/context-budget/`. The billing `cch` value is
  redacted in all output. Probe sessions are titled `context-budget probe`.
- The capture plugins are inert unless the helper sets
  `AIDEVOPS_CONTEXT_BUDGET_OUT`, and stop after four requests or five minutes.
