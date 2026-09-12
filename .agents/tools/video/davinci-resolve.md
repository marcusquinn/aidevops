---
description: Optional bounded Resolve MCP timeline, grading and delivery operations
mode: subagent
tools:
  "*": false
  read: true
  aidevops_mcp: true
  davinci-resolve_*: true
permission:
  "*": deny
  read: allow
  aidevops_mcp: allow
  davinci-resolve_*: allow
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# DaVinci Resolve

This is an optional integration, not an installed-app assumption. Operate only
the supplied brief and project/timeline copy. Do not delegate, install, upload,
purchase or change operator consent. Preserve sources and inspect state first.

## Integration

The MIT [samuelgursky/davinci-resolve-mcp](https://github.com/samuelgursky/davinci-resolve-mcp)
wraps Resolve's scripting API. Reviewed revision:
`c8fbe1887324de9d897e6036efcde60417e33e8c`. The launcher selects the compact
`src/server.py` surface, not `--full` or the optional offline database/XML server.
Published tool-count/API-coverage claims are not proof of support for every GUI
operation. Discover the connected schema and installed app capabilities.

An operator provisions the reviewed source and its documented Python requirements
in a separate venv inside an isolated system. Python 3.10+ is the initial floor;
the installed Resolve build may impose tighter Python/OS/codec requirements.
Studio external scripting should be Local, never network-exposed. Free-edition
bridges are version-sensitive and need separate review; do not install a bypass
when normal scripting is unavailable.

```text
AIDEVOPS_RESOLVE_MCP_SOURCE=/absolute/path/to/reviewed/davinci-resolve-mcp
AIDEVOPS_RESOLVE_MCP_PYTHON=/absolute/path/to/venv/bin/python
AIDEVOPS_RESOLVE_APP=/absolute/path/to/installed/Resolve
AIDEVOPS_RESOLVE_ISOLATED=1
AIDEVOPS_RESOLVE_CODE_EXECUTION=approved
```

The operator supplies these paths and attestations, never the agent. A venv,
loopback connection or MCP-only container is not a sandbox. The source must be
clean and match the reviewed pin; transitive dependencies are not locked by it.
Verify vendor `RESOLVE_SCRIPT_API`/`RESOLVE_SCRIPT_LIB` paths where required.

Run `python3 scripts/creative-mcp-launcher.py davinci-resolve check` for a
non-installing prerequisite check. Connect `davinci-resolve` with `aidevops_mcp`,
discover tools on the next step, and disconnect after work. Registration stays
disabled at startup. Restart after deployment/config changes. A path check is
not proof of licence, scripting readiness, installed dependencies or live editing.

## Verification

Inspect current project, timeline, timebase, media links and colour settings.
Save a copy before editing. Use supported API operations for media/timeline,
grading/Fusion/audio and render jobs; unsupported actions need an approved UI
workflow, not guessed API names. Do not change databases directly as a fallback.

Read back ranges, clip placement and settings. Export a short representative
section, inspect frames/listen, then run the approved delivery job. Check codecs,
duration, frame rate, channels, missing media/fonts/LUTs and reopened project.
Keep source/edit/render/review/approval states distinct. Inherit
`workflows/creative-production.md` for budgets, artifacts and scoped learning.
