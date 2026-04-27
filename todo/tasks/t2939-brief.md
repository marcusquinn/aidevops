# t2939 — pulse defense-in-depth restart reliability

This task is fully specified in the linked GitHub issue body.

**Issue:** [marcusquinn/aidevops#21148](https://github.com/marcusquinn/aidevops/issues/21148)

The issue body contains: problem statement, root cause analysis, four-layer
solution design, files to modify, acceptance criteria, and verification
commands. No additional brief content is needed (t2417 worker-ready heuristic).

### Files Scope

- setup-modules/schedulers.sh
- setup.sh
- .agents/scripts/pulse-watchdog-tick.sh
- .agents/scripts/tests/test-pulse-defense-restart.sh
- todo/tasks/t2939-brief.md
