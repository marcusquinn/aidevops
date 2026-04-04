<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1546: Setup/update: guide users to configure OAuth pool when built-in anthropic-auth is removed in OpenCode v1.2.30

## Session Origin

Full-loop worker session — issue GH#5312 (ref GH#5311 in TODO.md). OpenCode v1.2.30 removes the
built-in `anthropic-auth` plugin that previously provided `opencode auth login` → "Anthropic →
Claude Pro/Max". Users who relied on this flow will lose OAuth access. The aidevops OAuth pool
(t1543, `oauth-pool.mjs`) is the replacement — it provides the same OAuth flow with multi-account
rotation. Setup and update flows need to detect this version change and guide users to the pool.

## What

1. Update `setup_opencode_plugins()` in `setup-modules/mcp-setup.sh` to:
   - Detect OpenCode v1.2.30+ (where built-in anthropic-auth is removed)
   - Print a clear guidance message directing users to configure the OAuth pool
   - Explain the `opencode auth login` → "Anthropic Pool" flow as the replacement
2. Update `opencode-anthropic-auth.md` to document the v1.2.30 removal and the OAuth pool as
   the canonical replacement for all versions going forward.

## Why

- OpenCode v1.2.30 removes the built-in `anthropic-auth` plugin without a migration guide
- Users who relied on `opencode auth login` → "Claude Pro/Max" will silently lose OAuth access
- The aidevops OAuth pool (t1543) already provides the replacement — it just needs to be surfaced
  during setup/update so users know to configure it
- Without this guidance, users will hit auth failures and not know why

## How

### `setup-modules/mcp-setup.sh` — `setup_opencode_plugins()`

After the aidevops plugin is registered, add a version check:

```bash
local oc_version
oc_version=$(opencode --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
```

Compare major.minor.patch against 1.2.30. If >= 1.2.30, print guidance:
- Built-in anthropic-auth removed in v1.2.30
- Use `opencode auth login` → "Anthropic Pool" (provided by aidevops plugin)
- Link to `opencode-anthropic-auth.md` for details

### `opencode-anthropic-auth.md`

Add a new section at the top (after the existing DEPRECATED notice) documenting:
- v1.2.30 removes built-in anthropic-auth entirely
- The aidevops OAuth pool (`oauth-pool.mjs`) is the replacement
- How to add accounts: `opencode auth login` → "Anthropic Pool"
- How to manage accounts: `/model-accounts-pool list|status|remove`

## Acceptance Criteria

1. `setup_opencode_plugins()` detects OpenCode >= v1.2.30 and prints OAuth pool guidance
2. Guidance message includes the exact `opencode auth login` → "Anthropic Pool" flow
3. `opencode-anthropic-auth.md` documents v1.2.30 removal and OAuth pool replacement
4. ShellCheck passes on `mcp-setup.sh`
5. markdownlint passes on `opencode-anthropic-auth.md`

## Context

- OAuth pool implementation: `.agents/plugins/opencode-aidevops/oauth-pool.mjs` (t1543, GH#5243)
- Pool login flow: `opencode auth login` → select "Anthropic Pool" → enter email → OAuth browser flow
- Pool management: `/model-accounts-pool list|status|remove <email>|reset-cooldowns`
- Pool file: `~/.aidevops/oauth-pool.json` (separate from OpenCode's `auth.json`)
- Version where built-in auth removed: OpenCode v1.2.30
- Version where built-in auth was added: OpenCode v1.1.36
