# t2733: SonarCloud S1481/S1066/S100 config-level rule exclusions

**Phase 2** of parent #20401 decomposition.

Canonical brief is the GitHub issue body: https://github.com/marcusquinn/aidevops/issues/20454

## Summary

Add config-level exclusions for S1481, S1066, and S100 in `sonar-project.properties`, scoped to `**/*.sh`. Eliminates ~293 false-positive findings from the SonarCloud dashboard.

## Dependencies

- t2732 (#20453) — Phase 1 evidence must confirm these are false-positives

## Blocks

- t2734 (#20455) — Phase 3 handles anything that survives config-level exclusions
