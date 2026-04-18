<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2202 Brief — Fix CAS race in claim-task-id.sh producing duplicate task IDs under concurrent invocation

**Issue:** GH#19689 (marcusquinn/aidevops) — issue body is the canonical spec.

## Session origin

Filed 2026-04-18 from the t2189 interactive session (PR #19682). During filing of the follow-up issues from that session, I invoked `claim-task-id.sh --no-issue` 5 times via parallel agent tool calls. Two of those calls (calls 3 and 4) both reported successfully claiming `t2199`. Evidence is visible in `git log origin/main --oneline | grep 'chore: claim'`:

```
e6c240f2c chore: claim t2199
39c3eabf9 chore: claim t2199
```

Two separate commits, same ID. This breaks the core invariant that task IDs are globally unique. The framework's task-ID collision check workflow (t2047, `.github/workflows/task-id-collision-check.yml`) catches collisions server-side but only AFTER the fact.

## What / Why / How

See issue body at https://github.com/marcusquinn/aidevops/issues/19689 for:
- Full reproduction trace with commit SHAs
- Hypothesis: `git push` without `--force-with-lease` OR retry loop that returns stale claim on push failure
- Diagnostic plan: read claim-task-id.sh; reproduce with `sleep 0.5` + parallel invocation
- Fix options depending on diagnosis (git CAS vs lockfile CAS)
- Regression test exercising N=10 parallel invocations, asserting all IDs distinct

## Acceptance criteria

Listed in issue body. Key gate: a regression test launching 10 concurrent claims produces 10 distinct IDs; counter advances by exactly 10.

## Tier

`tier:standard` — requires careful atomicity reasoning + regression test. Not tier:simple because the fix depends on which CAS mechanism is in use, and writing the regression test requires parallel-process orchestration in bash.

## Evidence this is real

Before any code archaeology, confirm the bug with:

```bash
cd ~/Git/aidevops
for i in $(seq 5); do ~/.aidevops/agents/scripts/claim-task-id.sh --no-issue --title "repro $i" & done; wait
git log origin/main --oneline --grep="chore: claim" | head -10
```

If two lines share the same `t-ID`, the bug reproduces.
