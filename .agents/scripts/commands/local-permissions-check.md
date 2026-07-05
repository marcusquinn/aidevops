---
description: Audit local host/runtime permissions for aidevops on macOS, Linux, Windows, and WSL
agent: local-permissions-check
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run a read-only local permission/capability diagnostic for aidevops workflows.
macOS reports TCC host-app privacy state; Linux, Windows, and WSL report safe
session, sandbox, filesystem, execution-policy, and UI automation caveats.

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
  trigger prompts; do not change Windows execution policy, start services, or use
  sudo/admin privileges.
- macOS permissions apply to the host app that launched aidevops, not to child
  `bash`, `zsh`, `opencode`, or `aidevops` processes.
- For Tabby-launched sessions with Trash cleanup failures, check Full Disk Access
  for Tabby in System Settings → Privacy & Security.
- Linux Wayland screenshots/UI automation often require desktop portals; X11,
  Flatpak, Snap, containers, and WSL have separate boundaries.
- Windows/WSL reports are advisory unless a safe shell signal exists; protected
  folders and Defender Controlled Folder Access usually require manual checking.

## Verification references

- `.agents/workflows/local-permissions-check.md`
- `.agents/tools/security/local-permissions-check.md`
- `.agents/scripts/tests/test-local-permissions-check-helper.sh`
