<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Memory recall: `netbird mcp aidevops registry launcher` → 0 relevant hits
- [x] Discovery pass: no registry entry, launcher or issue covers NetBird MCP. Precedents: `backblaze-b2` (launcher + `aidevops secret` injection, `mcp-registry.mjs:702-726`), `mobile-mcp` (exact `allowedTools`, `mcp-registry.mjs:597-635`).
- [x] Tier: `tier:standard`. Additive registry entry, launcher and doc section; no shared-contract change.

## Origin

- **Created:** 2026-11-14
- **Created by:** ai-interactive (cloudron-netbird-app 2.7.5 MCP release session)
- **Conversation context:** The user asked to add NetBird's new MCP server (https://docs.netbird.io/manage/mcp-server) to aidevops after the Cloudron package shipped MCP support (marcusquinn/cloudron-netbird-app PR #248, release v2.7.5), store the credential as an aidevops secret and test it against the live app.

## What

Register NetBird's self-hosted management MCP (`https://<management>/api/mcp`) as an on-demand aidevops MCP named `netbird`:

1. `netbird-mcp-launcher.sh` bridges the endpoint to stdio with pinned `mcp-remote@0.16.6` (`--transport http-only`). It resolves the token secret from `NETBIRD_MCP_SECRET` or `aidevops secret default netbird`, and the URL from `NETBIRD_MCP_URL` or the credential-registry account name (hostname). `aidevops secret NAME --` injects the token; mcp-remote expands `${NAME}` in `--header` itself, so the value never reaches argv or config.
2. Registry entry: disabled by default, activation agent `netbird` from `services/networking/netbird.md`, exact `allowedTools` = the 33 read-only NetBird 0.83.1 tools (mirrors the Cloudron guide's `NB_MCP_TOOLS` set), so write tools are denied client-side even if the server exposes them.
3. Doc section in `netbird.md`: setup with an Auditor service-user token, secret/account/default commands, dry-run validation, overrides and the rights caveat.

## Why

NetBird 0.83 added an embedded MCP server. A secret-injecting launcher keeps self-hosted URLs and tokens out of shared config, and the read-only allowlist matches the best-practice "read first" guidance.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Follows two existing registry patterns exactly; no changes to shared plugin logic.

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/netbird-mcp-launcher.sh`: model on `.agents/scripts/backblaze-b2-mcp-launcher.sh` (dry-run env, explicit returns, `exec aidevops secret … --`).
- `EDIT: .agents/plugins/opencode-aidevops/mcp-registry.mjs`: entry after `backblaze-b2`, `allowedTools` as in `mobile-mcp`.
- `EDIT: .agents/services/networking/netbird.md`: `mcp: [netbird]` frontmatter and "MCP Server (aidevops `netbird`)" section.
- `EDIT: .agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs`: registration/permission assertions.

### Files Scope

- `.agents/scripts/netbird-mcp-launcher.sh`
- `.agents/plugins/opencode-aidevops/mcp-registry.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs`
- `.agents/services/networking/netbird.md`
- `todo/tasks/t18998-brief.md`
- `TODO.md`

### Complete Write Surface

- **Callers/readers:** `registerMcpServers`, `registerOnDemandMcpAgents`, `aidevops_mcp` name enum (derived from the registry).
- **Writers/mutation paths:** none beyond generated OpenCode config.
- **Schemas/config:** none new; env overrides `NETBIRD_MCP_SECRET`, `NETBIRD_MCP_URL`, `NETBIRD_MCP_LAUNCHER_DRY_RUN`.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts` and the plugin.
- **Migrations/backfills:** none.
- **Cleanup/rollback paths:** revert; the entry is disabled until connected.
- **Existing verification/tests:** plugin `node --test` suite.

### Hazards and Compatibility

- `aidevops secret inventory` fails closed on non-conforming gopass names, so the launcher uses `resolve`/`check`/`describe` instead.
- `agent-mcp-tools.mjs` is intentionally not extended: its wildcard grant would widen the exact allowlist (same as `mobile-mcp`).

### Verification Before Dispatch

```bash
node --test .agents/plugins/opencode-aidevops/tests/
shellcheck .agents/scripts/netbird-mcp-launcher.sh
NETBIRD_MCP_LAUNCHER_DRY_RUN=1 bash .agents/scripts/netbird-mcp-launcher.sh
```

- **Surface mapping:** registry/permission assertions in `test-mcp-activation.mjs`; launcher validated by dry run and a live stdio probe.
- **Broad verification trigger:** Not required.

## Acceptance Criteria

- [x] `config.mcp.netbird` is a disabled local entry pointing at the launcher; `netbird_*` denied with the 33 read tools allowed on the `netbird` agent.

  ```yaml
  verify:
    method: bash
    run: "node --test .agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs"
  ```

- [x] Live stdio probe against a 0.83.1 server with an Auditor service-user token: `initialize` → `netbird-management`, `tools/list` → 33 tools, no write tools, `list_peers` succeeds.
- [x] ShellCheck clean.

## Context & Decisions

- Cloudron package guide: marcusquinn/cloudron-netbird-app `docs/MCP-SERVER.md` (v2.7.5).
- OAuth via mcp-remote is possible but sessions are lost on every app restart (in-memory store); a PAT is the stable unattended path. The Auditor role, not the tool list, is what blocks REST writes with that token.
