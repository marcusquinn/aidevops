<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18460: Native prospecting project and lead-store contract

## Pre-flight

- [x] Memory recall: parent queries found no relevant lessons.
- [x] Discovery pass: 39cde6c59; existing social store/lease patterns and queued marketing decision contracts reviewed; no prospecting duplicate found.
- [x] File refs verified: knowledge_social_store.py, knowledge_social_reddit.py and social operations reference exist; proposed paths are new.
- [x] Tier: thinking; domain ownership, versioning, persistence, retention and service boundaries need coherent cross-component design.
- [x] Seeded draft PR skipped: implement against the merged predecessor contract.

## Origin

2026-09-20 OpenCode interactive; native replication requested, no Lurk integration or AnyAPI/scraping-platform replication. Parent: t18459. blocked-by:t18446 (#32058); reuse its shared decision/snapshot contract.

## What

Deliver a project-isolated prospecting store/read model and importable domain API for profiles, discovery plans, conversation evidence, scored lead versions, local dispositions, jobs/usage references and future UI/API consumers.

## Why

Persist useful leads and operator decisions independently of repeated model runs, while sharing evidence/decisions rather than creating another raw social corpus or model router.

## Tier

**Selected tier:** `tier:thinking` — define cross-component versioning and recovery before parallel domain work.

## How

### Files to Modify

- `NEW: .agents/scripts/prospecting_store.py` — SQLite domain projections and transactions.
- `NEW: .agents/scripts/prospecting_contract.py` — typed records and validation.
- `NEW: .agents/scripts/prospecting-project-helper.py` — init/import/list/feedback CLI.
- `NEW: .agents/configs/prospecting.schema.json` — versioned domain serialization.
- `NEW: .agents/reference/prospecting-contract.md` — service contract, ownership and privacy.
- `NEW: .agents/scripts/tests/test-prospecting-store.py` — focused tests and scoped fixture.

Reference `.agents/scripts/knowledge_social_store.py`, `.agents/scripts/_knowledge_social_lease.py`, `.agents/aidevops/knowledge-plane/05-social-operations.md` and t18445/t18446 outputs. Reuse stable evidence IDs/read projections; do not migrate or weaken existing social stores.

### Files Scope

- `.agents/scripts/prospecting_store.py`
- `.agents/scripts/prospecting_contract.py`
- `.agents/scripts/prospecting-project-helper.py`
- `.agents/configs/prospecting.schema.json`
- `.agents/reference/prospecting-contract.md`
- `.agents/scripts/tests/test-prospecting-store.py`
- `.agents/scripts/tests/fixtures/prospecting/store.json`

### Complete Write Surface

- **Callers/readers:** future prospecting helpers consume `.agents/scripts/prospecting_contract.py`; UI/API use the same read model.
- **Writers/mutation paths:** `.agents/scripts/prospecting_store.py` owns private project-scoped state; raw social evidence remains existing-store-owned.
- **Tests/fixtures:** `.agents/scripts/tests/test-prospecting-store.py` and synthetic store.json.
- **Schemas/config:** `.agents/configs/prospecting.schema.json`; project settings reference secret profiles, never contain secret values.
- **Generated/deployed mirrors:** source helpers deploy through `setup.sh`; no deployed edits or mandatory hosted database/auth.
- **Migrations/backfills:** `.agents/scripts/prospecting_store.py` owns new SQLite version/migration/backup behavior; existing knowledge stores are untouched.
- **Cleanup/rollback paths:** `.agents/scripts/prospecting-project-helper.py` export/retention/delete are explicit bounded operator actions; rollback preserves evidence IDs.

### Implementation Steps

1. Define project profile facts/claims, source preferences, keywords/communities, competitors, budgets and separate profile_version/discovery_version. Specify downstream collection, scoring, SERP, insights, scheduling, alert and API contracts with executable examples.
2. Model posts and comments independently by provider object ID with thread relations; one thread can contain multiple relevant asks. Store rubric/model/evidence versions, matching phrase, explanation, intent/stage, suitability and unknowns. Scores rank attention, not purchase probability or personal characteristics.
3. Support project-scoped new/saved/hidden/not-fit/reviewed/responded dispositions with history. Hidden means local feed state, never a Reddit mutation. Manual feedback never silently changes the rubric, product profile or search plan; rescoring must preserve dispositions.
4. Reuse shared decisions and raw evidence references; isolate private rows/cache per project, with no automatic cross-project data sharing. Enforce unique/replay constraints, atomic migrations and CAS/version checks for edits.
5. Provide `init`, `import --input FILE --dry-run`, `list` and bounded disposition commands. Specify retention/export/deletion and normalized job/cost records for later children. Single-operator local/private SQLite is the initial deployment shape; no Clerk/Postgres/AnyAPI/Lurk requirement.

### Hazards and Compatibility

- **Concurrency/atomicity:** design transaction/version rules for collectors, UI and routines sharing one project; test stale updates and simultaneous imports.
- **Migration/rollback:** own only new store migrations; validate backups before destructive operator cleanup, never rewrite external corpora.
- **Mixed-version/backward compatibility:** reject unknown schemas; distinguish stale profile judgments from discovery-plan changes.
- **Idempotency/retry:** exact import replay is stable; conflicting same IDs fail, user dispositions survive repeated scoring.
- **Partial failure/recovery:** interrupted writes retain receipts/original evidence; budgets/cancellation preserve unfinished criteria and resumable state.

### Verification Before Dispatch

```bash
python3 .agents/scripts/prospecting-project-helper.py import --input .agents/scripts/tests/fixtures/prospecting/store.json --dry-run
python3 .agents/scripts/tests/test-prospecting-store.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** CLI proves serialized imports; tests cover scope, version changes, disposition preservation, concurrency, retention and recovery. Reuse Python unittest; no new test platform.
- **Recovery:** checkpoint focused verified work; retain unmet criteria after a fuse and resume offline. No live service/account activation or broad repository gate.

## Acceptance Criteria

- [ ] Two synthetic projects retain distinct leads, profile/discovery versions and operator dispositions through import/replay/rescore.
- [ ] Documented domain interfaces support all later consumers and private export/retention operations.
- [ ] Reject cross-project reads, stale updates and malformed records without overwriting evidence or causing provider mutations; existing stores remain unchanged.
