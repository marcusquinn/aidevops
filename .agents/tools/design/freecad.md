---
description: Bounded FreeCAD MCP operations on an approved isolated CAD project
mode: subagent
tools:
  "*": false
  read: true
  aidevops_mcp: true
  freecad_*: true
permission:
  "*": deny
  read: allow
  aidevops_mcp: allow
  freecad_*: allow
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# FreeCAD

Operate only the supplied brief and project copy. Do not delegate, install,
upload, purchase, or change operator consent. Preserve units, constraints, stable
part IDs and original files. Return state readback and verified artifacts, not
claims that successful Python execution proves valid geometry.

## Integration and setup

The MIT [neka-nat/freecad-mcp](https://github.com/neka-nat/freecad-mcp) is a
community adapter, not an official FreeCAD guarantee. Reviewed revision:
`5dbfe2c80b53c3102bff0723951676e16edf2d84`, package 0.1.23, server Python 3.12+.
It uses an add-on inside FreeCAD and a separate stdio MCP client process.

Only after explicit approval, an operator provisions that pinned source and its
dependencies in an isolated system, installs the matching add-on and starts its
loopback RPC bridge. Keep auto-start off. Both app and MCP have code-execution
privileges; a venv or a server-only container is not a sandbox.

Set these in the MCP client's environment, using real absolute paths:

```text
AIDEVOPS_FREECAD_MCP_SOURCE=/absolute/path/to/reviewed/freecad-mcp
AIDEVOPS_FREECAD_MCP_PYTHON=/absolute/path/to/venv/bin/python
AIDEVOPS_FREECAD_APP=/absolute/path/to/installed/FreeCAD
AIDEVOPS_FREECAD_ISOLATED=1
AIDEVOPS_FREECAD_CODE_EXECUTION=approved
```

The last two values are operator attestations, never agent-set defaults. The
source checkout must match the launcher pin and be clean. Install dependencies
in a separate venv; source pins do not lock transitive dependencies.

`python3 scripts/creative-mcp-launcher.py freecad check` validates the local
prerequisites without downloading, starting an app or connecting its bridge.
In OpenCode call `aidevops_mcp` with `connect`, name `freecad`, then discover tools
on the next step. Disconnect after the task. Registration is disabled at startup;
restart the runtime after deploying changed profiles.

## Execution and verification

- Inspect document, units, object IDs and proposed changes before mutations.
- `execute_code` runs on the GUI thread. Async work must commit document/view
  changes on that thread; shared namespaces are not independent workspaces.
- `execute_code_headless` uses a separate process on the MCP server machine, not
  necessarily the GUI host. Check executable and file locality; save to a new file.
- A timeout after execution begins is not proof of rollback. Inspect job/RPC status
  before retry; never blindly restart the user's FreeCAD instance.
- Verify recompute errors, shape validity, dimensions, counts and exported solids.
  FEM results require correct materials, loads, constraints and solver review;
  availability of an FEM tool does not certify engineering correctness.
- UI gaps use an approved desktop per `creative-execution.md`, owned by the primary.

The generic capability inventory is not a live connection claim. Launcher checks,
MCP initialization and actual app operations are distinct readiness evidence.
Inherit `workflows/creative-production.md` and scoped session learning.
