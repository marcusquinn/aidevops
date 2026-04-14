<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2185: opencode plugin — rename stripMcpPrefix → restoreLowercaseToolNames and document tool-name rewrite trade-off

## Origin

- **Created:** 2026-04-14
- **Session:** opencode (interactive)
- **Conversation context:** Follow-up nits from interactive code review of the parent change in `.agents/plugins/opencode-aidevops/provider-auth.mjs` — the replacement of the `mcp_` prefixing strategy with Claude CLI CapCase tool-name canonicalisation. Parent change was uncommitted in the canonical main checkout when the review ran. This task carries both the parent change and the review fixes into a single PR.

## What

Single file: `.agents/plugins/opencode-aidevops/provider-auth.mjs`.

1. **Rename `stripMcpPrefix` → `restoreLowercaseToolNames`.** Old name lies — the function no longer strips `mcp_`, it inverts the CapCase → lowercase mapping built from `CANONICAL_TOOL_NAMES_INVERSE`. Caller in `makeStreamPullHandler` updated.
2. **Expand docstring on `restoreLowercaseToolNames`** to document the known trade-off: the new regex matches any `"name": "..."` field in the SSE stream, not only `tool_use` blocks. Blast radius is bounded by the 9-entry canonical map (only 9 specific CapCase names are eligible for rewrite), but a literal JSON fragment like `{"name": "Read"}` inside a text content delta would be rewritten to lowercase. A stricter lookbehind on `tool_use` would require buffering across SSE chunks. Accepted as a known limitation.
3. **Update stale docstrings** on `prefixToolNames`, `prefixToolUseBlocks`, `makeStreamPullHandler`, the response stream wrapper, and `createProviderAuthHook` to describe canonicalisation (lowercase → CapCase) instead of the removed `TOOL_PREFIX` constant and `mcp_` prefixing.

**Explicitly out of scope:**

- Function names `prefixToolNames` / `prefixToolUseBlocks` are NOT renamed. They still "prefix" in a loose sense and renaming would balloon the diff without behavioural benefit.
- No test coverage added — the plugin directory has no test harness, so adding one is a separate scope.

## Why

The parent change landed the behavioural fix correctly but left:

- A function whose name actively misleads the next reader (`stripMcpPrefix` implies prefix removal, actual behaviour is case inversion).
- A widened regex whose trade-off is invisible at the call site — a later maintainer could "tighten" it without understanding why the wide match is acceptable.
- Stale comments referencing a removed constant (`TOOL_PREFIX`) and an obsolete strategy (`mcp_`).

All three erode readability of a hot-path file that gates every opencode → Anthropic request.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** 1 file.
- [x] **Complete code blocks for every edit?** Yes — pure rename + docs, diff already applied and verified.
- [x] **No judgment or design decisions?** Yes — parent PR already settled the canonicalisation strategy.
- [x] **No error handling or fallback logic to design?** Yes — zero behavioural change.
- [x] **Estimate 1h or less?** ~15 minutes.
- [x] **4 or fewer acceptance criteria?** Yes — 4.

**Selected tier:** `tier:simple`.

## How (Approach)

Pattern reference: the existing `CANONICAL_TOOL_NAMES` / `CANONICAL_TOOL_NAMES_INVERSE` block (parent change) is the only place where the trade-off surfaces. Document it in the immediately adjacent docstring.

All edits preserve existing semantics — this is a pure rename + documentation pass. Verified in a worktree before the PR was opened:

```bash
# No stale references remain
grep -n "stripMcpPrefix\|TOOL_PREFIX\|mcp_" .agents/plugins/opencode-aidevops/provider-auth.mjs
# (no output)

# Syntax clean
node --check .agents/plugins/opencode-aidevops/provider-auth.mjs
# (passes)
```

## Acceptance Criteria

- [ ] `grep -n "stripMcpPrefix\|TOOL_PREFIX\|mcp_" .agents/plugins/opencode-aidevops/provider-auth.mjs` returns no matches
  ```yaml
  verify:
    method: bash
    run: "! grep -qE 'stripMcpPrefix|TOOL_PREFIX|mcp_' .agents/plugins/opencode-aidevops/provider-auth.mjs"
  ```
- [ ] `node --check .agents/plugins/opencode-aidevops/provider-auth.mjs` passes
  ```yaml
  verify:
    method: bash
    run: "node --check .agents/plugins/opencode-aidevops/provider-auth.mjs"
  ```
- [ ] `restoreLowercaseToolNames` docstring mentions the `"name": "..."` regex trade-off
  ```yaml
  verify:
    method: codebase
    pattern: "Known trade-off.*\"name\""
    path: ".agents/plugins/opencode-aidevops/provider-auth.mjs"
  ```
- [ ] Function is referenced by its new name from `makeStreamPullHandler`
  ```yaml
  verify:
    method: codebase
    pattern: "restoreLowercaseToolNames"
    path: ".agents/plugins/opencode-aidevops/provider-auth.mjs"
  ```

## Context & Decisions

- **Why not rename `prefixToolNames` / `prefixToolUseBlocks` as well?** They still perform a name transformation on tool definitions / tool_use blocks; "prefix" is a loose but acceptable label. Renaming would touch more call sites, churn the diff, and force every future reader to re-learn the naming without a correctness payoff.
- **Why not tighten the regex to `tool_use` contexts only?** SSE chunks don't align with JSON object boundaries. A stricter lookbehind or JSON-aware parser would need buffering across chunks and introduce latency + complexity on the hot path. The inverse-map guard already bounds the blast radius to 9 specific canonical names — a literal `{"name": "Read"}` inside a text delta is theoretical, not observed.
- **Why no test harness added?** `.agents/plugins/opencode-aidevops/` has no tests at all — adding the first test scaffold is its own task, not a nit fix follow-up.

## Relevant Files

- `.agents/plugins/opencode-aidevops/provider-auth.mjs` — the only file this task touches
- `CANONICAL_TOOL_NAMES` block (~:369) — the canonicalisation contract this documentation describes

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Rename + docstring edits | 10m | 3 edit blocks, one file |
| Syntax + grep verification | 2m | `node --check`, `grep -n` |
| Commit + PR | 3m | Conventional commit, PR body |
| **Total** | **~15m** | |
