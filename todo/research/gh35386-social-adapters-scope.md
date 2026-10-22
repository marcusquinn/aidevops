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
