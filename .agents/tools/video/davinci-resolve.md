---
description: Guarded DaVinci Resolve editing and optional MCP execution
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# DaVinci Resolve

Resolve is optional. The candidate `samuelgursky/davinci-resolve-mcp` has a compact
API surface, but its revision and installed exports must be verified before use.
Aidevops does not install or launch Resolve or its adapter. Offline database/XML
mutation is excluded from initial activation.

Use a duplicate project/library, record Resolve and adapter versions, timeline
frame rate, colour management, media links, captions, audio routing, and export
settings. Keep one writer. Read project/timeline state before and after every MCP
or UI mutation and stop when completion is ambiguous. A rendered file requires
frame, duration, audio, caption, and delivery inspection.

The optional `davinci-resolve` MCP profile accepts only an absolute, explicitly
configured executable after operator approval and isolation. It refuses headless
worker sessions and missing prerequisites. Connect through the `davinci-resolve`
focused agent, inspect actual tools, avoid excluded offline mutation, then
disconnect. Application purchase, installation, desktop takeover, cloud render,
and paid plugins require separate authority.
