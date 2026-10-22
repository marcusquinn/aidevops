For #35365. Independent bounded continuation after PR #35368; do not close the tracking objective.

## Authorized outcome

Reduce the pre-existing production findings below with behavior-preserving refactors. Preserve public signatures, credential/privacy boundaries, admission safety, transaction ordering, observability and existing output. No publication, data migration, dependency upgrades, suppression, exemptions, threshold/config/CI changes, or test weakening. Keep each PR at most five changed files; select a smaller subset if integration requires more paths and create exact follow-ups for the remainder.

### Files Scope

- `.agents/scripts/_knowledge_social_linkedin_reader.py`
- `.agents/scripts/_knowledge_social_meta_reader.py`
- `.agents/scripts/_knowledge_social_notion_reader.py`
- `.agents/scripts/_knowledge_social_outbound.py`
- `.agents/scripts/_knowledge_social_outbound_integrity.py`
- `todo/research/gh35386-social-adapters-scope.md`

## Current evidence

Original Qlty 0.652.0 --all scan on PR #35368 head 1d19767af9ba628bbdc54b172c4ffdc7917cdcef, based on default 845999a7bfc84fe403a58770fd29f8648472227b; CI pins 0.643.0. Original inventory: 87 records (52 file-complexity, 24 similarity-location records, 4 boolean-logic, 3 function-parameters, 3 function-complexity, 1 return-statements).

- LinkedIn reader: similar-code, 12 lines/10 locations (mass 86), 15 lines/6 locations (mass 124).
- Meta reader: similar-code, 10 lines/10 locations (mass 86), 11 lines/6 locations (mass 124).
- Notion reader: similar-code, 10 lines/10 locations (mass 86).
- Outbound: file-complexity, count 69.

## Integration scope correction and selected slice (2026-10-22)

Assigned executor verified collaborator-authored open issue, active assignment and unchanged brief. Default HEAD is 5a4a36846bed84a4b72c18d75d99f853435d5341. Prework found no outbound collision; PR #35416 independently introduces `_knowledge_social_reader_contract.py` for other readers. Do not compete with that shared abstraction.

Select the outbound finding for this PR. The new adjacent integrity module owns bounded payload validation, canonical versioned intent hashing and stored-row verification. Existing outbound exports (including private names consumed by claim/runtime/tests) remain compatible through explicit reexports. Creation, approval, revocation, cancellation and transaction ordering stay in the existing module. This is reversible extraction within authorized behavior, not a new security guarantee. Three changed files including this brief; no test changes.

Exact remaining continuation: after PR #35416 lands, adapt LinkedIn/Meta/Notion readers to its ReaderContract without changing public signatures, exact error messages, limits, credential rejection or provider allowlists. Targets are the three original reader paths plus the existing shared contract only if required. Verify with `bash .agents/tests/test-knowledge-social-linkedin.sh`, `bash .agents/tests/test-knowledge-social-meta.sh`, `bash .agents/tests/test-knowledge-social-notion.sh`, and same-mode Qlty per-path/per-rule counts. This issue remains open to track that remainder; outbound PR uses For #35386 and For #35365, not a closing keyword.

## Reference and implementation

Use narrow responsibility extraction with unchanged public exports and safety guards. Public API parameter signatures must remain explicit, never untyped variadic wrappers or wrapper-only debt hiding. Persist directly necessary adjacent integration before editing; explicit exclusions stay binding.

## Verification

Capture SHA/tool version and same-mode before/after counts with `qlty smells --all --sarif --no-snippets --quiet`. Runner provides Qlty 0.631.0: compare only this version against itself, not original or CI versions. All introduced findings must remain zero. Run `git diff --check`, `.agents/scripts/linters-local.sh --changed --base-ref origin/main`, `bash .agents/tests/test-knowledge-social-operations.sh`, and affected existing provider outbound tests. Record unavailable tools and CI equivalents, not invented results. Keep unrelated historical failures separate.

## Acceptance

Deliver a measurable selected-slice reduction in a pushed non-draft PR using For #35365 and For #35386. Keep this leaf open for the exact reader continuation above. Recheck concurrent PRs and never overwrite another worker's work.

## Selected-slice results

Production head: e3477574f4c8f5b8d17609b33d3b1fe20daa1ad8, compared with default 5a4a36846bed84a4b72c18d75d99f853435d5341. Subsequent changes to this document do not change the production tree.

Qlty 0.631.0, exact same command `qlty smells --all --sarif --no-snippets --quiet` before and after:

| Rule / path | Before | After |
| --- | --- | --- |
| file-complexity / outbound | 1 (complexity 69) | 0 |
| all rules / new integrity module | 0 (absent) | 0 |
| all rules / LinkedIn, Meta, Notion readers | 0 each | 0 each |
| file-complexity / repository | 46 | 45 |
| function-parameters / repository | 5 | 5 |
| boolean-logic / repository | 4 | 4 |
| function-complexity / repository | 3 | 3 |
| return-statements / repository | 1 | 1 |
| similar-code / repository | 18 | 18 |
| total / repository | 77 | 76 |

No introduced findings in either changed Python path. The original reader duplication evidence came from a different version and is not claimed as locally reproduced or fixed. Its exact follow-up is above.

## Runtime Testing

- Risk: high (integrity checks adjacent to authorization); verification: runtime-verified for the extracted functions, not a claim that the entire shell suite passed.
- AST comparison against the pre-extraction Git blob: all five extracted functions are identical. Public same-name imports and signatures preserved. Remaining transaction statements unchanged in the diff.
- Direct runtime smoke: 19 passing checks using real SQLite rows for intent versions 1/2/3, payload/hash/version/legacy-field tampering rejection, empty/NUL/oversized payload rejection and exact payload bound acceptance. No provider requests or persistent data writes.
- File-backed SQLite lifecycle smoke using the real schema: create, idempotent recovery, approve, revoke, cancel, rejected intent mutation and rejected empty payload with rollback all passed; temporary fixture removed after closing the database. In-memory migration was unsuitable because raw recovery requires a file-backed store; no production change was made for that test setup constraint.
- `env PYTHONPATH=.agents/scripts python3 .agents/scripts/tests/test-social-linkedin-youtube-outbound.py`: 9 tests passed.
- `python3 .agents/scripts/tests/test-social-meta-tiktok-outbound.py`: 6 tests passed.
- `bash .agents/tests/test-knowledge-social-operations.sh`: pre-existing initial import failure at line 322, `RedditPreparedProvider` imported from `_knowledge_social_outbound_provider` instead of the dedicated Reddit module. Both test and provider are byte-unchanged from origin/main; provider was last changed by abadc6df8 (#30273), test by d043d0083. Do not repair outside this slice or report this suite as passing.
- `git diff --check`: passed. `linters-local.sh --changed --base-ref origin/main`: passed, including Secretlint and Python 3.9 annotation checks. Markdownlint unavailable locally; CI equivalent is the `markdownlint` job in `.github/workflows/code-quality.yml`. Ruff module unavailable; no local Ruff success claimed. Qlty/CI owns its configured lint checks.
- Required pre-push `bun run typecheck`: passed after `bun install --frozen-lockfile` restored worktree-local dependencies; no dependency or lockfile changes.
- Independent static review: no material defects found in import direction, exception identity, validation order, API compatibility, transaction boundaries or runtime consumers. Limit: no complete transitive import graph review. Direct self-review concurs; review bundle digest at production head: `4e25884602dc369f6d0da49f28437169438b81c6e564cd25cf25de688286a574`.

## Acceptance self-review

| Criterion | Outcome | Evidence / disposition |
| --- | --- | --- |
| Measurable bounded reduction | satisfied | One outbound finding removed; 77 to 76 total, no introduced findings |
| Behavior and public signatures | satisfied | AST-identical helpers, explicit reexports, runtime smoke and 15 existing tests |
| Safety, transaction order, privacy | satisfied | No transaction or authorization changes; independent static review and integrity rejection checks |
| At most five changed files | satisfied | Two Python files plus this brief |
| No exclusions weakened | satisfied | No config, dependency, threshold, suppression or test edits |
| Full original reader cleanup | deferred | Original issue retained open with exact dependency, target paths and verification above |
| Existing operations suite | pre-existing failure | Unchanged stale Reddit import; not an extraction regression |

<!-- MERGE_SUMMARY -->

## Completion Summary

- **What**: Extract bounded payload and versioned intent integrity from outbound authorization state; remove one Qlty file-complexity finding with no new findings.
- **Issue**: For #35386; For #35365. Keep both open for remaining work.
- **Files changed**: `_knowledge_social_outbound.py`, `_knowledge_social_outbound_integrity.py`, and this scoped evidence brief.
- **Testing**: Same-version full SARIF scans, AST equality, 19 integrity checks, real SQLite lifecycle/rollback smoke, 15 existing provider tests, local changed-file lint and pre-push TypeScript check. The unrelated stale Reddit test import and unavailable local linters are explicitly recorded above.
- **Key decisions**: Do not compete with PR #35416's shared reader contract; retain the exact reader continuation on #35386. No publication or dependency/configuration/test changes.
