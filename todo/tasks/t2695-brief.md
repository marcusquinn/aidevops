<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2695 — Remove unsupported `headRefName` JSON field from `gh search prs` calls

**Canonical brief:** [GH#20314](https://github.com/marcusquinn/aidevops/issues/20314)

The issue body on GH#20314 is worker-ready (per t2417 heuristic): it contains
Task/Why/How/Acceptance/Reproducer/Suggested Fix sections with exact `file:line`
references, a confirming live `gh` call, and an explicit measurement
(`errors=1` per pulse cycle → `errors=0` after fix).

This stub exists only to satisfy the brief-file structural requirement.

## Session Origin

Interactive session (marcusquinn), macOS, 2026-04-21. User directed attention to
[GH#20314](https://github.com/marcusquinn/aidevops/issues/20314) filed by Linux
contributor robstiles, asking whether it affected macOS. Platform-agnostic —
the rejection is server-side at the GitHub Search API, not `gh` client.

## How

### Files Scope

- `.agents/scripts/pulse-batch-prefetch-helper.sh`
