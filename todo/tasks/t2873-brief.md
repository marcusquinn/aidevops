# t2873 — Comment out OpenCode → Claude Code substitution after empirical A/B verification

## Session Origin

Interactive session. User asked whether the OpenCode → Claude Code text substitution in the OAuth-pool request path was still necessary now that build.txt + AGENTS.md are injected as user content (not system prompt). Asked for empirical curl-based testing rather than speculation, and explicitly preferred commenting code out over deletion so it can be restored if needed.

## What

In `.agents/plugins/opencode-aidevops/provider-auth-request.mjs`, the `sanitizeSystemPrompt` function applies two regex replacements to every system-prompt block:

```js
let text = item.text.replace(/OpenCode/g, "Claude Code").replace(/opencode/gi, "Claude");
```

Comment out that line. Keep the `TAG_RENAMES` loop intact — those tag substitutions are separately validated as real Anthropic third-party detection triggers (t2040). Add a block comment explaining the empirical test, the historical context, and how to re-enable.

## Why

The substitution is a cargo-cult workaround that has never been empirically verified. It was added in the original t1543 OAuth pool plugin commit (2025-09) with the comment "Anthropic server blocks 'OpenCode' string" — but the later thorough investigation in t2040 (2026-04-09) found the actual triggers were XML tags (`<directories>`, `<env>`, `<available_skills>`), not the literal word. The size-based trigger found in t2723 (2026-04-22) is handled by `redistributeSystemToMessages`. The literal word substitution survived as untested defensive code.

Cost of leaving it on: the model believes it is running in Claude Code when it is actually in OpenCode, so it gives wrong commands (`~/.claude.json` vs `~/.config/opencode/opencode.json`), wrong session DB paths, and wrong runtime-specific advice.

## How

### Files Scope

- .agents/plugins/opencode-aidevops/provider-auth-request.mjs
- todo/tasks/t2873-brief.md
- TODO.md

### Implementation

In `sanitizeSystemPrompt` (around line 114-121):

1. Comment out the existing line that does `replace(/OpenCode/g, "Claude Code").replace(/opencode/gi, "Claude")`.
2. Replace it with `let text = item.text;` so the `TAG_RENAMES` loop still operates on the input.
3. Prepend a block comment that documents:
   - the empirical A/B test result (six requests at sizes 380B–36KB, all 200 OK with raw "OpenCode")
   - the historical context (t1543, t2040, t2723)
   - the cost of leaving it on
   - how to re-enable (uncomment the original line)
   - the location of the test harness in the workspace

### Test harness

Persistent test scripts live at `~/.aidevops/.agent-workspace/work/aidevops/third-party-name-test/`:

- `ab-name-test.mjs` — three small-prompt tests (baseline, "Claude Code", "OpenCode")
- `ab-name-test-large.mjs` — three framework-shaped tests at 15K/15K/35K
- `final-validation.mjs` — round-trip through the modified `transformRequestBody`, then real API call

All scripts load a token from `~/.aidevops/oauth-pool.json` and post to `https://api.anthropic.com/v1/messages?beta=true` with the full real-CLI header set.

### Verification

Six independent tests against the live Anthropic API all returned 200 OK with the literal word "OpenCode" in the system prompt:

| Test | Size | Token | Status |
|------|------|-------|--------|
| A baseline | 380B | (none) | 200 |
| B substituted | 380B | Claude Code | 200 |
| C raw | 380B | OpenCode | 200 |
| D large control | 15K | Claude Code | 200 |
| E large raw | 15K | OpenCode | 200 |
| F stress | 35K | OpenCode | 200 |

End-to-end validation also confirmed `transformRequestBody` now passes "OpenCode" through unchanged and the resulting body returns 200 OK.

## Acceptance Criteria

- The `replace(/OpenCode/g, "Claude Code").replace(/opencode/gi, "Claude")` line is commented out, not deleted.
- A block comment above the change explains the empirical test, history, cost, and re-enable instructions.
- `transformRequestBody` and `sanitizeSystemPrompt` still apply `TAG_RENAMES`.
- `node .agents/plugins/opencode-aidevops/tests/test-intent-schema-injection.mjs` passes.
- Module imports cleanly under Node ES modules.
- Real API call returns 200 OK with the literal word "OpenCode" in the system prompt (verified via the test harness).

## Context

- `.agents/plugins/opencode-aidevops/provider-auth-request.mjs:114-121` — the function being changed
- `.agents/plugins/opencode-aidevops/provider-auth-request.mjs:97-101` — `TAG_RENAMES` (kept)
- `.agents/plugins/opencode-aidevops/provider-auth-request.mjs:128-173` — `redistributeSystemToMessages` (handles the size trigger)
- t2040 commit `cbf72cc82` — investigation that found XML tags were the real trigger
- t2723 commit `a93c114ef` — found the size + framework-pattern trigger
- `~/.aidevops/.agent-workspace/work/aidevops/third-party-name-test/` — the persistent test harness

## Tier Checklist

- `tier:simple` — single small edit in one file with verbatim oldString/newString. Brief is exact.
