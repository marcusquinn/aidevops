<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# Prospecting workbench

The workbench is a static, local operator surface served by `prospecting-service-helper.py` at `/ui/`. Start it only with a local store and explicitly supplied UI directory:

```bash
python3 .agents/scripts/prospecting-service-helper.py --store "$HOME/.aidevops/prospecting" serve --ui-dir .agents/templates/prospecting-workbench
```

It reads the versioned `/v1` contract and never renders source evidence as HTML. Browser actions are restricted to the owner-only typed endpoints described in `.agents/configs/prospecting-openapi.json`; unavailable authority, a missing budget, or an expired session disables controls rather than guessing success.

## Operator workflow

1. Select an authorized project and check the local API status.
2. Complete onboarding from an approved URL, snapshot, or manual facts; preserve provenance and missing evidence.
3. Review evidence-linked leads and set only a local workflow disposition. The workbench has no public reply or DM controls.
4. Use SEO and insight views as observations: filtered/organic coverage, stale states, and source records are not conversion or market-share claims.
5. Review usage, activity, schedules, and alerts. Manual scans require owner authority and a bounded configured budget.

## Evidence handoff

Capture desktop and mobile viewport screenshots (maximum dimension 1568px), console/network errors, keyboard focus, contrast, and 200% zoom findings using `browser-qa-helper.sh`. Keep screenshots free of real prospect data and credentials. Report partial, offline, conflict, and expired-session states explicitly.
