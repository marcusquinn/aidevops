For #32618. Runtime and adapter provenance wiring is delivered here; the live OC2 row acceptance remains open until #32619 is verified. This partial integration must not automatically close #32618.

## Summary

- Record detected OpenCode runtime version and versioned OC1/OC2 adapter identity on new `llm_requests` rows.
- Preserve environment fallback and nullable values when detection is unavailable.
- Normalize runtime identity in the existing provenance module, eliminating the PR's additional observability file-complexity smell without weakening quality gates.

## Files changed

`.agents/plugins/opencode-aidevops/observability.mjs`, `observability-provenance.mjs`, `index.mjs`, `v2.mjs`, and `tests/test-observability-provenance.mjs`.

## Verification

- Exact head: `2549a98cb473078ea4cfe83f7b11cbd593b7fd6d`.
- Focused provenance and routing-join tests: 6 passed, 0 failed, including nullable detection and SQLite insertion.
- Syntax checks and changed-file lint passed.
- Qlty regression: 68 base smells, 68 head smells; both remote Qlty gates succeeded in run `37089530325`.
- Live OC1 context capture produced a fresh request row recording verified runtime `1.18.34` and adapter `opencode-v1@3.38.0`.
- A real OC2 `2.0.3` probe completed but produced no fresh request row; this is the independently tracked #32619 defect, not a passing live acceptance result.
- Full plugin suite has unrelated source-access context failures in the headless sandbox (private socket directory absent); no source-access files changed.

## Runtime Testing

Runtime-verified for OC1 and the normal row-insertion path. OC2 live acceptance remains explicitly incomplete and owned by #32619. Historical rows are not backfilled and unavailable versions are not guessed.

## Integration decision

The repository owner's unattended backlog mission permits this verified prerequisite to merge while retaining #32618 for its remaining dependent acceptance. The previous head-fetch/quality hold is superseded by the recovered fast-forward repair and exact-head successful checks. Final release remains owned by the orchestrator.
