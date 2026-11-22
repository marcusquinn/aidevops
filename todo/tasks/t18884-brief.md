<!-- aidevops:brief-schema=v2 -->
# t18884: Skip the aidevops session greeting when OpenCode runs as an ACP server

## Origin

- **Created:** 2026-11-07
- **Session:** opencode:interactive (Buzz Desktop OpenCode harness test, block/buzz-app#2432)
- **Created by:** ai-interactive
- **Conversation context:** A Buzz Desktop agent backed by `opencode acp` replied to its first DM with "Hi! We're running aidevops v3.39.131 in OpenCode v1.19.5." before answering. The owner asked for this to be fixed in aidevops.

## What

When OpenCode is started as an ACP server (`opencode acp`, used by Buzz Desktop, Zed and other ACP clients), the opencode-aidevops plugin must not inject the "Session-start greeting order" block. Every other system-prompt block (intent tracing, quality rules) stays. The terminal and desktop OpenCode sessions keep the greeting exactly as now.

## Why

ACP clients are chat surfaces with their own identity and threading. Each new ACP session is a new conversation thread (Buzz opens one per thread or channel), so the greeting is repeated noise in every thread and makes the agent's reply look like a canned bot response.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Small, contained change to one gate in a plugin with existing tests; the only judgement is how to detect ACP mode reliably.

## How (Approach)

- The greeting is built in `.agents/plugins/opencode-aidevops/ttsr.mjs` (`buildSessionStartGreetingInstruction`, around line 251) and gated by `shouldInjectGreeting`, which `index.mjs:527` and `v2.mjs:406` create with `createRootSessionGreetingGate({ getSession, isHeadless, log })` (`root-session-greeting-gate.mjs:21`). `isHeadless()` (`proxy-lifecycle.mjs:52`) only checks env vars.
- Add an ACP-mode check and treat it like headless for the greeting gate only. First verify what the plugin can see under `opencode acp` (OpenCode 1.19.5): `process.argv` containing the `acp` subcommand is the expected signal; record the verified signal in the PR. Do not change `isHeadless()` itself, because other features (permission broker, title status, Playwriter guard) key off it and ACP sessions are still interactive.
- Log the skip through the existing gate's `skip(sessionID, reason)` with reason `acp-server`.
- Keep `AIDEVOPS_PLUGIN_SESSION_GREETING` (`greeting.mjs:116`) working as the explicit override.

### Files to Modify

- EDIT: `.agents/plugins/opencode-aidevops/root-session-greeting-gate.mjs` — accept an `isAcpServer` predicate and skip with reason `acp-server`.
- EDIT: `.agents/plugins/opencode-aidevops/index.mjs:527` and `.agents/plugins/opencode-aidevops/v2.mjs:406` — pass the predicate.
- EDIT: `.agents/plugins/opencode-aidevops/proxy-lifecycle.mjs` — add `isAcpServer()` next to `isHeadless()` (or a small new module if that file is the wrong home).
- EDIT: `.agents/plugins/opencode-aidevops/tests/test-ttsr-system-transform.mjs` — cover ACP skip and TUI unchanged, if the existing gate tests live there; otherwise the gate's own test file.

### Files Scope

- `.agents/plugins/opencode-aidevops/root-session-greeting-gate.mjs`
- `.agents/plugins/opencode-aidevops/index.mjs`
- `.agents/plugins/opencode-aidevops/v2.mjs`
- `.agents/plugins/opencode-aidevops/proxy-lifecycle.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-ttsr-system-transform.mjs`

### Verification Before Dispatch

```bash
node --test .agents/plugins/opencode-aidevops/tests/
.agents/scripts/linters-local.sh --diff
```

- **Runtime evidence:** after `setup.sh --non-interactive`, a probe that sends `initialize`, `session/new` and one `session/prompt` ("Reply with OK") to `opencode acp` gets a reply without the "We're running aidevops" line; a normal `opencode` TUI session still starts with the greeting.

### Scope Boundaries

**Hard boundaries:** do not change `isHeadless()` semantics; do not remove the greeting for TUI/desktop sessions; no Buzz-specific detection (any ACP client gets the same behaviour).

## Acceptance Criteria

- [ ] `opencode acp` sessions get no greeting block; TUI sessions are unchanged.
- [ ] The skip is logged once per session with reason `acp-server`.
- [ ] `AIDEVOPS_PLUGIN_SESSION_GREETING` still overrides.
- [ ] Plugin tests pass.

## Relevant Files

- `.agents/plugins/opencode-aidevops/ttsr.mjs:251-265,315-329,431`
- `.agents/plugins/opencode-aidevops/root-session-greeting-gate.mjs:21`
- `.agents/plugins/opencode-aidevops/proxy-lifecycle.mjs:52`
- `.agents/plugins/opencode-aidevops/greeting.mjs:116`
