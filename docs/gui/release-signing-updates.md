<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GUI release, signing, and updates

The current macOS launcher is unsigned and local-only. It is suitable for manual
developer installs, not public auto-update distribution.

Update notification contract:

- aidevops may update in the background through existing framework update flows.
- The GUI API reports both the running app version and the installed deployed
  agents version from `~/.aidevops/agents/VERSION`.
- When those versions differ, the dashboard shows a restart-required message.
- The macOS launcher also posts a local notification before opening the app when
  the installed version differs from the app's checked-out `VERSION` file.

Before publishing signed desktop artifacts, add:

- Tauri sidecar policy for the local API;
- Apple signing and notarization evidence;
- signed update metadata and checksum/provenance files;
- artifact redaction scans for logs, bundles, and update metadata;
- rollback instructions for failed desktop updates.
