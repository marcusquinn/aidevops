---
description: Read-only workflow for diagnosing macOS privacy permissions needed by aidevops host apps
agent: local-permissions-check
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Use this workflow when aidevops cannot access Trash, protected Library data,
screenshots, UI automation, Apple Events, microphone/camera, Contacts, Calendar,
or Reminders from a macOS-launched session.

## First command

Run the helper before interpreting symptoms:

```bash
~/.aidevops/agents/scripts/local-permissions-check-helper.sh report --active-host
```

Use `json --active-host` for machine-readable evidence and `apps` for installed
host/editor inventory.

## Interpretation

- macOS grants privacy permissions to the parent host app, not the child shell or
  CLI process. If the session is launched through Tabby, grant Tabby.
- Full Disk Access (`kTCCServiceSystemPolicyAllFiles`) is the main permission for
  Trash cleanup, protected `Library` paths, repo metadata, and runtime data.
- Files and Folders scoped access may still matter for Desktop, Documents,
  Downloads, Network volumes, or Removable volumes.
- Accessibility and Automation/Apple Events are for UI automation, Finder,
  System Events, Terminal/iTerm/Tabby, Notes, Calendar, and Contacts control.
- Screen Recording is required for screenshots and UI verification.
- Microphone, Camera, Contacts, Calendar, and Reminders are optional and should
  be granted only for workflows that explicitly need them.
- `unknown` is not equivalent to `granted`; it usually means the TCC database is
  unreadable from the current host app or the macOS schema could not be queried.

## Safety rules

- Do not run `tccutil reset` as part of this diagnostic.
- Do not programmatically grant permissions; macOS requires user action.
- Do not print raw TCC rows, private local paths, repo basenames, or directory
  listings in issue comments or public logs.
- Opening System Settings is optional user action; the default helper is
  read-only and does not open it.

## Verification

```bash
bash .agents/scripts/tests/test-local-permissions-check-helper.sh
shellcheck .agents/scripts/local-permissions-check-helper.sh .agents/scripts/tests/test-local-permissions-check-helper.sh
```
