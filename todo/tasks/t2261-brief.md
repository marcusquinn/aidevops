<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2261: localdev-helper.sh branch is slow due to port scan in 3100-3999 range

## Origin

- **Created:** 2026-04-18
- **Session:** Claude Code (interactive, t2249 session)
- **Observation:** User flagged `localdev-helper.sh branch` as slow; log line `No available ports in range 3100-3999` suggests serial scanning across ~900 ports. User explicitly deferred investigation to a separate task to avoid scope-creep.

## What

`localdev-helper.sh branch` is slow at startup because port selection walks the 3100-3999 range one port at a time. Exact bottleneck unconfirmed — needs measurement before fix per AGENTS.md "Performance Optimization" rule (performance issues without evidence are invalid).

## Why

Observable user-visible delay on an operation that should be sub-second. Measurement-first, then fix.

## How

### Phase 1 — profile

```bash
time .agents/scripts/localdev-helper.sh branch
bash -x .agents/scripts/localdev-helper.sh branch 2>&1 | ts '%.s' | head -50
```

Identify which step dominates. Add timing to PR body.

### Phase 2 — if port scan confirmed as dominant

Replace serial scan with ONE of:

- **`lsof` batch query:**
  ```bash
  lsof -iTCP:3100-3999 -sTCP:LISTEN -nP | awk 'NR>1{split($9,a,":"); print a[2]}'
  ```
- **`netstat` batch query** (no `lsof` dependency):
  ```bash
  netstat -anp tcp | awk '/LISTEN/ && $4 ~ /\.[0-9]+$/ {split($4,a,"."); print a[length(a)]}'
  ```
- **Random-then-retry:** pick a random port in range, fall back to next on `EADDRINUSE`. Cheapest if the range is usually sparse.

### Phase 3 — re-measure

Before/after timing in PR body. Target: <1s for port selection on a clean dev machine.

## Tier

Tier:standard. Profile-first then fix; small code change but needs evidence-based decision making.

## Acceptance

- [ ] `localdev-helper.sh branch` completes port selection in <1s on a clean dev machine.
- [ ] Before/after timing documented in PR body (actual numbers, not estimates).
- [ ] No regression in port-collision detection (must still skip busy ports).

## Relevant files

- `.agents/scripts/localdev-helper.sh` — `branch` handler; port-selection logic
