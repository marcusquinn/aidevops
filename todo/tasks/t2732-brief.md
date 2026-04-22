# t2732: SonarCloud S1481/S1066/S100 false-positive inventory and classification

**Phase 1** of parent #20401 decomposition.

Canonical brief is the GitHub issue body: https://github.com/marcusquinn/aidevops/issues/20453

## Summary

Inventory and classify all SonarCloud S1481 (unused local variables), S1066 (collapsible if), and S100 (function naming) findings across `.agents/scripts/`. Produce a ranked table with three-way classification: `{false-positive, legitimate-smell, tactical-exemption}`.

## Dependencies

- None (first phase)

## Blocks

- t2733 (#20454) — Phase 2 config exclusions depend on this evidence
- t2734 (#20455) — Phase 3 pragmas depend on this + Phase 2
