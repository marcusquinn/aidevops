# t1991: Map OpenCode reasoning level to Claude CLI --effort flag

## Origin

- **Created:** 2026-04-12
- **Session:** Claude Code CLI
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** none (follow-up from claudecli transport proxy, PR #18343/#18345)
- **Conversation context:** During testing of the new claudecli transport proxy in OpenCode, we observed that the reasoning level picker (low/medium/high/max) appears for claudecli models because `reasoning: true` is set in the model definition, but the selected level is silently ignored — the proxy doesn't pass it to Claude CLI. The `--effort` flag (`low`, `medium`, `high`, `max`) was discovered during CLI `--help` review.

## What

When a user selects a reasoning/thinking level in OpenCode's model picker for a `claudecli` model, the proxy must extract that level from the incoming request and pass it as `--effort <level>` to the Claude CLI subprocess. The mapping:

| OpenCode reasoning level | Claude CLI `--effort` |
|--------------------------|----------------------|
| `low` | `low` |
| `medium` | `medium` |
| `high` | `high` |
| `max` | `max` |

If no reasoning level is provided in the request, omit `--effort` entirely (let CLI use its default).

## Why

Currently the reasoning picker shows and the user expects it to work, but the selection has no effect. This is a UX gap — the user thinks they're controlling thinking depth but they're not. The Claude CLI `--effort` flag is the supported way to control this.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** (2 files: claude-proxy.mjs, possibly config-hook.mjs)
- [x] **Complete code blocks for every edit?** (yes, exact edits below)
- [x] **No judgment or design decisions?** (straight mapping, no ambiguity)
- [x] **No error handling or fallback logic to design?** (omit flag when absent, no error path)
- [x] **Estimate 1h or less?** (yes, ~30 min)
- [x] **4 or fewer acceptance criteria?** (3 criteria)

All checked = `tier:simple`.

**Selected tier:** `tier:simple`

**Tier rationale:** Direct 1:1 mapping, 2 files, exact code blocks provided. No design decisions.

## How (Approach)

### Files to Modify

- EDIT: `.agents/plugins/opencode-aidevops/claude-proxy.mjs:886-910` — extract reasoning level from request, pass to `buildClaudeArgs`
- EDIT: `.agents/plugins/opencode-aidevops/claude-proxy.mjs:440-482` — add `--effort` to CLI args

### Reference Pattern

The existing `--model` argument pattern in `buildClaudeArgs` (line 445-446): add `--effort` the same way.

### Implementation

**Step 1: Extract reasoning level from the incoming OpenAI-format request in `handleChatCompletions`**

OpenCode sends reasoning config in the request body. The exact field depends on the OpenAI-compatible SDK — likely `body.reasoning_effort` or similar. Check what `@ai-sdk/openai-compatible` sends. Common patterns:

- `reasoning_effort: "low" | "medium" | "high"` (OpenAI native)
- `thinking: { budget_tokens: N }` (Anthropic native, unlikely via OpenAI-compat)

In `handleChatCompletions` (around line 899-910), after building the `body` object, extract the effort level:

```js
// After: stream: incoming.stream !== false,
// Add:
const EFFORT_LEVELS = new Set(["low", "medium", "high", "max"]);
const effortLevel = typeof incoming.reasoning_effort === "string" && EFFORT_LEVELS.has(incoming.reasoning_effort)
  ? incoming.reasoning_effort
  : null;
// Add to body:
body.effortLevel = effortLevel;
```

**Step 2: Pass `--effort` in `buildClaudeArgs`**

In `buildClaudeArgs` (around line 440-482), after the `--model` arg, add:

```js
// After: body.model,
// Add:
if (body.effortLevel) {
  args.push("--effort", body.effortLevel);
}
```

### Verification

```bash
# 1. Start OpenCode with a claudecli model
# 2. Select "high" reasoning level in the picker
# 3. Send a message
# 4. Check proxy logs for --effort in the CLI args:
grep -i effort /tmp/claude-proxy-last-request.json  # (with CLAUDE_PROXY_DEBUG_DUMP=1)
# Or check stderr logs for the spawned command
```

### Discovery needed

Before implementing, verify what field name OpenCode/`@ai-sdk/openai-compatible` uses to send the reasoning level. Check:
1. `incoming.reasoning_effort` (OpenAI convention)
2. `incoming.reasoning` (might be an object)
3. Log the full `incoming` object in the proxy to see what arrives

If the field name differs, adjust the extraction accordingly.

## Acceptance Criteria

1. Selecting a reasoning level in OpenCode's picker for a claudecli model results in `--effort <level>` being passed to the Claude CLI subprocess
2. When no reasoning level is selected, `--effort` is omitted entirely (CLI default behavior preserved)
3. Invalid/unknown levels are ignored (no `--effort` passed)

## Context

- Claude CLI v2.1.104 at `/opt/homebrew/bin/claude`
- `--effort` flag: `low`, `medium`, `high`, `max` (from `claude --help`)
- Proxy file: `.agents/plugins/opencode-aidevops/claude-proxy.mjs` (1009 lines after v3.7.0)
- Model definitions already have `reasoning: true` so the picker shows
- The `anthropic` provider path handles thinking via `provider-auth.mjs` (`thinking: {type: "adaptive"}`) — that's separate and must not be touched
