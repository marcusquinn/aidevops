---
description: Bounded Ableton Live MCP composition and editing with telemetry disabled
mode: subagent
tools:
  "*": false
  read: true
  aidevops_mcp: true
  ableton_*: true
permission:
  "*": deny
  read: allow
  aidevops_mcp: allow
  ableton_*: allow
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Ableton Live

Operate only the supplied musical brief and Live Set copy. No delegation,
installation, uploads, purchases or operator-consent changes. Preserve original
recordings and projects. Use the parent's model/effort unless explicitly pinned.

## Integration

The MIT [ahujasid/ableton-mcp](https://github.com/ahujasid/ableton-mcp) is a
community adapter. Reviewed revision `8731a47a415f1590f50bdb3b4ac4f06d8328cf0b`,
package 1.4.0, Python 3.10+. It requires Live and the matching Remote Script;
actual edition/version/plugin compatibility and export paths must be tested.

Upstream documents default-on telemetry including prompts, notes, track/clip
names and device settings. The launcher forces telemetry and dataset collection
off and strips unrelated inherited credentials/import hooks. This is not a
network sandbox: provision both app and MCP in an approved isolated environment.

An operator installs the pinned source and dependencies in a separate venv,
installs/enables the matching Remote Script, and supplies absolute paths:

```text
AIDEVOPS_ABLETON_MCP_SOURCE=/absolute/path/to/reviewed/ableton-mcp
AIDEVOPS_ABLETON_MCP_PYTHON=/absolute/path/to/venv/bin/python
AIDEVOPS_ABLETON_APP=/absolute/path/to/installed/Live
AIDEVOPS_ABLETON_ISOLATED=1
AIDEVOPS_ABLETON_CODE_EXECUTION=approved
```

Only the operator sets the attestations after approving code execution/isolation.
The source must be clean and match the launcher pin. The bridge must bind loopback;
the client uses literal `127.0.0.1`, `ABLETON_PORT` defaults to 9877. Do not expose
the Remote Script on a LAN/public address or start it automatically.

Run `python3 scripts/creative-mcp-launcher.py ableton check`, then connect the
disabled-by-default `ableton` MCP through `aidevops_mcp`. Discover actual tools on
the following step and disconnect afterward. Checks do not install dependencies,
start Live, establish a licence, or prove a handshake. Restart after profile changes.

## Working pattern

Inspect tracks/clips/devices, tempo, meter, arrangement and selected Set before
editing. Plan section boundaries and keep stable names/IDs. Apply bounded changes,
read them back and save a new project. Never infer that clip creation also provides
arrangement export, stem rendering or plugin automation; verify those capabilities.

Use silent/virtual audio output for background work. Playback/recording through
physical devices requires its own authority. Keep sample/plugin licences and
dependencies in the project manifest; collect assets where supported.

Verify saved project reopening, export duration/format/channels, peak/loudness and
missing assets. Actual listening is required for musical judgment; a tool-only
profile reports it unavailable and returns a preview for an audio-capable reviewer.
Use `workflows/creative-production.md` for quality, budget, Git and learning.
