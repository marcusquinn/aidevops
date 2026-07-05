---
description: Audit macOS privacy permissions for aidevops host apps such as Tabby, Terminal, iTerm, OpenCode, Cursor, Claude, VS Code, Zed, and Warp
agent: local-permissions-check
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run a read-only local macOS permission diagnostic for aidevops workflows.

Arguments: $ARGUMENTS

## Procedure

1. Run the deterministic helper first:

   ```bash
   ~/.aidevops/agents/scripts/local-permissions-check-helper.sh report $ARGUMENTS
   ```

2. If the user asks for machine-readable evidence:

   ```bash
   ~/.aidevops/agents/scripts/local-permissions-check-helper.sh json $ARGUMENTS
   ```

3. To list detected host/editor apps only:

   ```bash
   ~/.aidevops/agents/scripts/local-permissions-check-helper.sh apps
   ```

## Safety

- Read-only by default: do not reset TCC, grant permissions, or intentionally
  trigger prompts.
- macOS permissions apply to the host app that launched aidevops, not to child
  `bash`, `zsh`, `opencode`, or `aidevops` processes.
- For Tabby-launched sessions with Trash cleanup failures, check Full Disk Access
  for Tabby in System Settings → Privacy & Security.

## Verification references

- `.agents/workflows/local-permissions-check.md`
- `.agents/tools/security/local-permissions-check.md`
- `.agents/scripts/tests/test-local-permissions-check-helper.sh`
