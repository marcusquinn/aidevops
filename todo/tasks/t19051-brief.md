<!-- aidevops:brief-schema=v2 -->

## Origin

- **Created:** 2026-11-16
- **Created by:** ai-interactive (remote 3D rendering follow-up to t19048 / GH#38554)
- **Conversation context:** After the Blender render playbook (PR #38560) the user chose Runpod and asked whether to support its API via CLI, MCP or both (official MCP: github.com/runpod/runpod-mcp). Recommendation accepted: CLI-first plus an optional on-demand MCP. The user then asked to add the SaladCloud CLI (docs.salad.com/cli) in the same session.

## What

1. **Runpod MCP (on demand):** register the official hosted server `https://mcp.runpod.io/` (OAuth, no key on disk) as a disabled-by-default remote MCP named `runpod`, with the `X-Runpod-Analytics: off` header, an activation agent `runpod`, and an exact `allowedTools` list: catalog/status/log/billing/docs reads allowed; pod, network-volume, template and Serverless writes allowed only with approval (`ask`); organization admin, cost centers, clusters, secrets, registry credentials, ECR delegations, SSH-key updates, `exec-pod` and `deploy-hub-repo` denied.
2. **Runpod CLI:** new agent doc `.agents/tools/infrastructure/runpod.md` (CLI-first: `runpodctl doctor`, noun-verb commands, `--wait`, JSON errors, `network-volume upload/download` resume, `aidevops secret RUNPOD_API_KEY -- runpodctl ...`), and replace the deprecated `runpodctl config/create pod/get pod/remove pod` syntax in `cloud-gpu.md`.
3. **SaladCloud CLI:** new agent doc `.agents/tools/infrastructure/saladcloud.md` (install, `aidevops secret` env auth with `SALAD_API_KEY`/`SALAD_ORGANIZATION`/`SALAD_PROJECT`, `SALAD_CLI_NO_PROMPT=1`, `-o json`, exit codes, approval policy, render pattern with queues/interruptible nodes) and provider rows in `cloud-gpu.md` and `3d-render-backends.md`.

## Why

Runpod's `runpodctl` is agent-oriented (JSON by default, stable error codes, `--wait`, resumable volume transfers) and is the right primitive for scripted renders; the MCP adds interactive inspection but exposes about 100 tools including org admin and destructive operations, so it must stay on demand and allowlisted. SaladCloud is the cheapest interruptible RTX option in the t19048 comparison and now ships an agent-friendly CLI (v0.1.0 beta).

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Additive registry entry plus a small `headers` passthrough for remote MCP entries; the rest is documentation.

## How (Approach)

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/mcp-registry.mjs`: `runpod` remote entry after `posthog`; pass optional `headers` through `buildMcpConfigEntry` for remote entries (OpenCode remote MCP config supports `headers`).
- `EDIT: .agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs`: registration/permission assertions (model on the NetBird test).
- `NEW: .agents/tools/infrastructure/runpod.md`, `NEW: .agents/tools/infrastructure/saladcloud.md`: follow `.agents/tools/infrastructure/cloud-gpu.md` frontmatter.
- `EDIT: .agents/tools/infrastructure/cloud-gpu.md`, `.agents/tools/design/3d-render-backends.md`, `.agents/content/video-runpod.md`, `.agents/subagent-index.toon`, `.agents/reference/domain-index.md`.

### Files Scope

- `.agents/plugins/opencode-aidevops/mcp-registry.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs`
- `.agents/tools/infrastructure/runpod.md`
- `.agents/tools/infrastructure/saladcloud.md`
- `.agents/tools/infrastructure/cloud-gpu.md`
- `.agents/tools/design/3d-render-backends.md`
- `.agents/content/video-runpod.md`
- `.agents/subagent-index.toon`
- `.agents/reference/domain-index.md`
- `.agents/build-plus.md`
- `.agents/configs/allowed-urls.txt`
- `TODO.md`
- `todo/tasks/t19051-brief.md`

### Hazards and Compatibility

- Existing user `runpod` MCP entries (for example from `npx @runpod/mcp-server add --client opencode`) stay user-owned and disabled until connected; the header passthrough applies only to framework-built entries.
- `agent-mcp-tools.mjs` is not extended: its wildcard grant would widen the exact allowlist (same as `mobile-mcp`/`netbird`).
- `approvalRequiredTools` maps to OpenCode `ask`, which `opencode --auto` approves silently; activation guidance repeats the approval rule.
- Open PR #38559 (blender-render-helper.sh, GH#38556) uses deprecated `runpodctl` legacy commands; leave a review note rather than editing that PR here.

### Verification Before Dispatch

```bash
node --test .agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] `config.mcp.runpod` is a disabled remote entry for `https://mcp.runpod.io/` with `X-Runpod-Analytics: off`; `runpod_*` denied, reads `allow`, billable writes `ask`, org/secret tools absent on the `runpod` agent.
- [ ] `cloud-gpu.md` contains no deprecated `runpodctl config`, `create pod`, `get pod` or `remove pod` commands.
- [ ] Runpod and SaladCloud docs are indexed and linked from `cloud-gpu.md` and `3d-render-backends.md`.
- [ ] No account or billable resource is created during implementation.
