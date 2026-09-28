---
description: OpenCode CLI integration and configuration
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# OpenCode Integration

## Quick Reference

- **Primary Agent**: `aidevops` — full framework access
- **Subagents**: hostinger, hetzner, wordpress, seo, code-quality, browser-automation, etc.
- **Setup**: `cd ~/Git/aidevops && .agents/scripts/generate-opencode-agents.sh`
- **MCPs disabled globally** — enabled per-agent to save context tokens
- **Runtime profile**: V1 is the rollback-safe default; V2 is opt-in until its Linux-headless canary passes

| Purpose | Path |
|---------|------|
| Main config | `~/.config/opencode/opencode.json` |
| Agent files | `~/.config/opencode/agent/*.md` |
| Alternative config | `~/.opencode/` (some installations) |
| aidevops agents | `~/.aidevops/agents/` (after setup.sh) |
| Credentials | `~/.config/aidevops/credentials.sh` |

## Runtime profiles

OpenCode 1 and 2 have incompatible packages, binaries, plugin contracts, and
configuration schemas. Aidevops keeps those differences in
`.agents/configs/opencode-runtime-profiles.json`; shared plugin behavior remains
runtime-neutral.

| Profile | CLI package | Binary | Plugin implementation | Config loader | Config keys |
|---------|-------------|--------|-----------------------|---------------|-------------|
| `v1` (production default) | `opencode-ai` | `opencode` | `index.mjs` | `index.mjs` | `agent`, `plugin`, `permission`, `provider` |
| `v2` (isolated preview) | `@opencode/cli` | `opencode2` | `v2.mjs` | `v2-plugin/` | `agents`, `plugins`, `permissions`, `providers` |

Setup and update install both binaries by default. V1 keeps its existing config
and data paths; the `opencode2` shim uses private config, data, cache, state, and
temporary roots under `~/.aidevops/runtimes/opencode-v2/`. Its default server
port is `4097`, while an explicit `--port` always wins. This allows V1 and V2
sessions to run concurrently without sharing configuration or session databases.

Select V2 as the primary profile for setup and headless execution, opt out of
the preview companion installation, or explicitly roll back:

```bash
AIDEVOPS_OPENCODE_PROFILE=v2 ./setup.sh --non-interactive

# Keep a V1-only installation.
AIDEVOPS_INSTALL_OPENCODE2_PREVIEW=0 ./setup.sh --non-interactive

# Explicit rollback. This converts managed config back to V1 keys and restores
# the V1 plugin entry without deleting user-defined agents, providers, or MCPs.
AIDEVOPS_OPENCODE_PROFILE=v1 ./setup.sh --non-interactive
```

V2 rejects duplicate plugin IDs (`Duplicate plugin ID: aidevops`), so setup
registers the V2 plugin once through the config `plugins` entry and removes the
legacy managed `plugins/aidevops-v2` symlink. It falls back to the symlink only
when the config entry cannot be written. To check this, run
`opencode2 api GET /api/plugin`: it should list exactly one `aidevops` entry
with `status: active`.

V1 loads the framework guide through its config `instructions`. V2's upstream
migration guide says `instructions` requires no migration, but aidevops setup
also links `~/.aidevops/agents/AGENTS.md` to
`~/.aidevops/runtimes/opencode-v2/config/opencode/AGENTS.md`; a user-authored
file there is kept. The V2 background service serves every later session, so
the shim drops caller session identity, headless flags, and bundle pins before
any command without `--standalone`/`--server` (GH#32498). A TUI started from a
Tabby recovery marker directory opens that marker's project directory instead.
Plugin log lines `Session greeting skipped for <session>: <reason>` explain a
missing greeting. To check parity, compare a fresh session's `core/instructions`
in the V2 `instruction_state` table with the V1 system prompt.

V2 promotion requires all six gates below. The weekly Linux canary checks both
profiles but does not substitute for the other gates. Until all pass, do not
change the profile document's `default` from `v1`.

| Gate | Check before promotion |
|------|------------------------|
| Plugin loaded and tools present | `AIDEVOPS_OPENCODE_PROFILE=v2 .agents/scripts/opencode-pin-canary.sh canary latest` (plugin health marker and aidevops tools); inspect the native tool diff. |
| Security hooks | `node --test .agents/plugins/opencode-aidevops/tests/test-permission-broker.mjs` and manually deny an unsafe edit in a V2 session. |
| Lifecycle cleanup | Manually start then exit a standalone V2 session and verify the event subscription and MCP connections close without residual processes. |
| OAuth/MCP | Manually check a V2 OAuth-backed model and connect/disconnect one configured MCP server using the isolated profile. |
| Headless execution | The `OpenCode Pin Canary` workflow runs isolated baseline/candidate probes for both profiles; inspect the V2 artifact and result. |
| V1 rollback | `bash .agents/scripts/tests/test-opencode-runtime-profile.sh` then `AIDEVOPS_OPENCODE_PROFILE=v1 ./setup.sh --non-interactive` on an isolated installation and confirm V1 config and plugin are restored. |

The V2 pin remains 2.0.3 until a passing current-release V2 canary qualifies
the new version. Do not infer compatibility from the V1 result.

The "via aidevops" Anthropic 4.x picker entries were OpenCode 1 config-hook
injections, not a separate OAuth transport; its native Anthropic models still
use the pool auth hook. OpenCode 2 uses its own provider-request auth adapter,
and does not call the OpenCode 1 picker config hook. The OpenCode 1 request-time
budget (240K generally, 500K for specified newer Anthropic families, 180K
target for Haiku 4.5) is independent of the optional V2 policy below. OpenCode
2.0.3's
`session.context` exposes only a model reference; its automatic compaction
uses `min(input - buffer, context - max(min(output, 32K), buffer))` when input
is set; without input, only the second term applies. The SDK
allows `catalog.transform` to edit model limits, but this mutates picker
metadata and cannot distinguish native from explicit user limits. Its optional
compaction threshold only works in provider-compaction mode; enabling that
mode changes compaction behavior. The opt-in V2 policy deliberately caps larger
input limits instead, without changing the compaction mechanism. Do not claim
the V1 per-family targets apply to V2. If the launcher is not on `PATH`, use the
managed
`~/.local/bin/opencode2` shim; invoking the raw binary under
`~/.aidevops/runtimes/opencode-v2/runtime/node_modules/.bin/` bypasses its
private config/data/auth isolation.

### Maintaining agent parity

The canonical main-agent roster is `.agents/subagent-index.toon` and its root
`.agents/<source>.md` files. V1 uses the generated agent configuration and its
config hook; V2's `v2-agent-profiles.mjs` registers those same sources with the
native `agent.transform` SDK, makes Build+ the default and removes built-in
Build only when the canonical Build+ source loads. Operator-supplied profiles
with the same name take precedence. Explicit `tools: ... false` source rules
become V2 deny rules; unrecognised tool syntax fails closed rather than quietly
granting access. Neither adapter should register every leaf as a primary agent.

When adding, renaming, or modifying a primary agent, update the root source and
index, confirm V1's generated profile, and run the V2 roster/permission tests
(`node --test .agents/plugins/opencode-aidevops/tests/test-v2-agent-profiles.mjs`)
plus the existing V1 agent generator checks. After deployment, restart each
runtime and inspect both agent selectors and the resolved Build+ prompt. Do not
infer V2 parity from a successful built-in Build session or a plugin import.

### Optional V2 240K local compaction target

V2 keeps its native limits by default. To opt into a 240,000-token usable-input
target across models with larger windows, merge this into
`~/.config/aidevops/settings.json` (do not replace other settings):

```json
{
  "runtime": {
    "opencode": { "v2_compaction_target": 240000 }
  }
}
```

Restart the **V2 background service and client** to apply the change. OpenCode
2.0.3 uses a 20K local-compaction buffer by default, so the opt-in catalogue
transform caps a large model's `limit.input` at 260K; the local threshold then
becomes 240K. The model's context, output, name, and variants stay native. Models
whose smaller native input or physical context already triggers earlier are not
expanded. This is an explicit policy override: it also caps any larger
user-supplied model input limit, because V2's catalogue transform does not expose
the limit's provenance. Remove `v2_compaction_target` to restore native limits.
If the host's `compaction.buffer` differs from 20K, set
`runtime.opencode.v2_compaction_buffer` to the same integer; a mismatch changes
the effective trigger. The option does not take effect when the host has disabled
automatic compaction. Test the resolved model and threshold before relying on
it for expensive long-context work.

The V2 preview does not copy V1's mutable OpenCode auth database or aidevops
OAuth pool. For pooled Anthropic and OpenAI auth, enroll independently into the
shim's private pool (never copy the V1 pool):

```bash
AIDEVOPS_OAUTH_POOL_FILE="$HOME/.aidevops/runtimes/opencode-v2/auth/oauth-pool.json" \
  "$HOME/.aidevops/agents/scripts/oauth-pool-helper.sh" add anthropic
AIDEVOPS_OAUTH_POOL_FILE="$HOME/.aidevops/runtimes/opencode-v2/auth/oauth-pool.json" \
AIDEVOPS_OPENAI_ADD_MODE=callback \
  "$HOME/.aidevops/agents/scripts/oauth-pool-helper.sh" add openai
AIDEVOPS_OAUTH_POOL_FILE="$HOME/.aidevops/runtimes/opencode-v2/auth/oauth-pool.json" \
  "$HOME/.aidevops/agents/scripts/oauth-pool-helper.sh" status all
```

OpenAI's default pool-helper device flow invokes V1 `opencode providers login`
and reads V1's auth file; the callback mode above avoids touching V1. Restart
the managed `~/.local/bin/opencode2` launcher after adding accounts. V2's
`auth login` and `auth list` refer to its separate native integration credentials,
not aidevops pool enrollment: the V2 adapter currently registers request hooks
for Anthropic and OpenAI, not a pool login method. Google and Cursor pool
accounts are not consumed by that adapter; qualify their native V2 integrations
independently before advertising subscription-based auth. The
aidevops OAuth callback server serializes concurrent interactive login flows on
its shared loopback port, while each OAuth pool locks token refresh and rotation
writes. Normal authenticated sessions may run concurrently. Editing sessions
must still use separate linked Git worktrees.

## Authentication

See `tools/opencode/opencode-anthropic-auth.md` for full auth setup (OAuth pool, API key, version-specific notes).

> Do NOT add `opencode-anthropic-auth` to `opencode.json` plugins — double-loading causes a TypeError.

## Agent Architecture

| Agent | Description | MCPs Enabled |
|-------|-------------|--------------|
| `aidevops` | Full framework (primary) | context7 |
| `hostinger` | Hosting, WordPress, DNS | hostinger-api |
| `hetzner` | Cloud infrastructure | hetzner-* (4 accounts) |
| `wordpress` | Local dev, MainWP | localwp, context7 |
| `seo` | Search Console, Ahrefs | gsc, ahrefs |
| `code-quality` | Quality scanning + learning loop | context7 |
| `browser-automation` | Testing, scraping | chrome-devtools, context7 |
| `git-platforms` | GitHub, GitLab, Gitea | context7 |
| `dns-providers` | DNS management | hostinger-api (DNS) |
| `agent-review` | Session analysis, improvements | (read/write only) |

## Configuration

MCPs defined `enabled: false` globally; each subagent enables its own tools. Agent markdown format (`~/.config/opencode/agent/*.md`):

```markdown
---
description: Short description
mode: subagent
temperature: 0.1
tools:
  bash: true
  mcp-name_*: true
---
```

V1 `opencode.json` pattern: `"mcp": { "name": { ..., "enabled": false } }` + `"agent": { "name": { "tools": { "name_*": true } } }`.

V2 uses `"mcp": { "servers": { "name": { ..., "disabled": true } } }`,
`"agents"`, ordered `"permissions"`, and the V2 plugin's MCP/tool transforms.

## Usage

**Tab**: cycle agents. **@agent-name**: invoke subagent (one per message).

### Workflow Order

| Phase | Agents | Execution |
|-------|--------|-----------|
| 1. Plan/Research | @context7-mcp-setup, @seo, @browser-automation | Parallel |
| 2. Infrastructure | @dns-providers → @hetzner → @hostinger | Sequential |
| 3. Development | @wordpress, @git-platforms, @crawl4ai-usage | Parallel |
| 4. Quality | @code-standards → @agent-review | Sequential (always last) |

### End-of-Session (MANDATORY)

1. **@code-standards** — fix quality issues
2. **@agent-review** — analyze session, suggest improvements, optionally create PR

`@agent-review` has restricted bash — only `git *` and `gh pr *` commands allowed.

## CLI Testing

TUI requires restart for config changes. Use CLI for quick iteration:

```bash
opencode run "List your available tools" --agent SEO
opencode run "Quick test" --agent Build+ --model anthropic/claude-sonnet-4-6

# Isolated V2 preview
opencode2 run "List your available tools" --agent SEO

# Persistent server (keeps MCPs warm)
opencode serve --port 4096                                             # Terminal 1
opencode run --attach http://localhost:4096 "Test query" --agent SEO  # Terminal 2

# Helper shortcuts
~/.aidevops/agents/scripts/opencode-test-helper.sh test-mcp dataforseo SEO
~/.aidevops/agents/scripts/opencode-test-helper.sh list-tools Build+
~/.aidevops/agents/scripts/opencode-test-helper.sh serve 4096
```

**Adding a new MCP:** Edit `opencode.json` → test with CLI → fix errors → restart TUI → update `generate-opencode-agents.sh`.

## MCP Server Configuration

Credentials in `~/.config/aidevops/credentials.sh`:

```bash
export HOSTINGER_API_TOKEN="your-token"
export HCLOUD_TOKEN_PROJECT="your-token"   # Hetzner per-account
# GSC: service account JSON at ~/.config/aidevops/gsc-credentials.json
```

**MCP env var limitation:** OpenCode `environment` blocks do NOT expand `${VAR}` — use bash wrapper:

```json
"ahrefs": {
  "type": "local",
  "command": ["/bin/bash", "-c", "API_KEY=$AHREFS_API_KEY /opt/homebrew/bin/npx -y @ahrefs/mcp@latest"]
}
```

## Troubleshooting

| Problem | Steps |
|---------|-------|
| MCPs not loading | Check `enabled` in opencode.json → verify env vars → test MCP command manually |
| Agent not found | Check file in `~/.config/opencode/agent/` → verify YAML frontmatter → restart |
| Tools not available | Check tools enabled in agent config → verify glob patterns → check MCP responding |

## Permission Model

Subagents do NOT inherit parent permission restrictions. Parent `write: false` does not apply to spawned subagents.

| Configuration | Actually Read-Only? |
|---------------|---------------------|
| `write: false, edit: false, task: true` | **NO** — subagents can write |
| `write: false, edit: false, bash: true` | **NO** — bash can write files |
| `write: false, edit: false, bash: false, task: false` | **YES** |

For true read-only: set both `bash: false` AND `task: false`.

```json
"@plan-plus": {
  "permission": { "edit": "deny", "write": "deny", "bash": "deny" },
  "tools": { "write": false, "edit": false, "bash": false, "task": false, "read": true, "glob": true, "grep": true, "webfetch": true }
}
```

## Parallel Sessions

See `workflows/session-manager.md` for session lifecycle, terminal tab spawning, and worktree integration.

```bash
opencode run "Task description" --agent Build+ --title "Task Name" &
opencode serve --port 4097
opencode run --attach http://localhost:4097 "Task" --agent Build+
~/.aidevops/agents/scripts/worktree-helper.sh add feature/parallel-task
```

**Docs**: [Agents](https://opencode.ai/docs/agents) · [MCP Servers](https://opencode.ai/docs/mcp-servers/)
