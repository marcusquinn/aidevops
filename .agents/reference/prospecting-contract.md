---
description: Project-isolated prospecting evidence, scoring, and disposition contract
---

# Prospecting contract

The prospecting store is a private, single-operator read model for deciding which
evidence deserves attention. It does not collect social content, mutate provider
state, route models, or estimate purchase probability or personal
characteristics. `_knowledge` remains the authority for raw social evidence;
this store keeps project-specific facts, plans, scores, and operator decisions
around stable evidence pointers.

## Ownership and isolation

- `.agents/scripts/prospecting_store.py` exclusively owns the local SQLite file.
- Each query and mutation requires an exact `project_id`; there is no global lead
  listing or automatic cross-project sharing.
- Objects reference `evidence_id`, `corpus_id`, `canonical_plane: "_knowledge"`,
  and `authority: "projection"`. The store never copies raw post/comment text.
- Secret profile **references** may appear in a project profile. Secret values,
  cookies, credentials, provider responses, and filesystem paths may not.
- Posts and comments are separate provider objects. Multiple `lead_id` records
  may point to one object so a thread can contain several independent asks.

The initial deployment is private local SQLite with mode-0700 directories and a
mode-0600 database. It requires no hosted database, auth service, AnyAPI, Lurk,
or scraping platform.

## Version and transaction rules

`profile_version` covers product facts, claims, competitors, budgets, and secret
profile references. `discovery_version` independently covers keywords,
communities, source preferences, and result budgets. Editing either uses
compare-and-swap against its stored version and appends an immutable version row.
A stale writer fails without changing either document.

Imports use `BEGIN IMMEDIATE`, foreign keys, and a canonical JSON digest. Exact
replay returns the existing receipt. Reusing a provider object ID, lead ID, or
project version with different content fails the whole transaction. SQLite's
busy timeout serializes simultaneous local importers; stale disposition and
profile/discovery edits are rejected by version checks.

Unknown schema versions fail closed. Schema migration is atomic and owned only
by this new store. Destructive project deletion first checkpoints SQLite, copies
the database, validates the backup with `PRAGMA integrity_check`, and requires
the exact stored project name. External corpora are never rewritten or deleted.

## Lead and disposition semantics

Every lead records the matching phrase, explanation, intent, stage, suitability,
unknowns, score, rubric version, model version, and evidence version. Scores rank
operator attention only. They are not purchase probability, protected-trait
inference, or permission to contact someone.

Local states are `new`, `saved`, `hidden`, `not-fit`, `reviewed`, and
`responded`. `hidden` changes only the local feed. Every transition appends
history and requires the current disposition version. Rescoring changes score
metadata while preserving disposition history. Manual feedback never silently
changes a rubric, product profile, or discovery plan.

## Commands

Use a private store path explicitly in automation, or set
`AIDEVOPS_PROSPECTING_DIR`:

```bash
python3 .agents/scripts/prospecting-project-helper.py \
  --store PRIVATE_DIR import \
  --input .agents/scripts/tests/fixtures/prospecting/store.json --dry-run

python3 .agents/scripts/prospecting-project-helper.py \
  --store PRIVATE_DIR init --input PROJECT.json

python3 .agents/scripts/prospecting-project-helper.py \
  --store PRIVATE_DIR list --project PROJECT_ID --disposition saved

python3 .agents/scripts/prospecting-project-helper.py \
  --store PRIVATE_DIR disposition --project PROJECT_ID --lead LEAD_ID \
  --set reviewed --expected-version 1

python3 .agents/scripts/prospecting-project-helper.py \
  --store PRIVATE_DIR export --project PROJECT_ID

python3 .agents/scripts/prospecting-project-helper.py \
  --store PRIVATE_DIR delete --project PROJECT_ID --confirm-name PROJECT_NAME
```

`import --dry-run` validates serialization without opening or creating a store.
Export contains project settings and the bounded lead read model, not raw social
evidence. Retention automation should export required decisions, run bounded
project deletion, retain the verified backup under the operator's private
retention policy, and separately apply the owning `_knowledge` policy if raw
evidence must expire.

## Consumer contracts

All later consumers import `prospecting_contract.py` and use
`aidevops.prospecting/v1`; they must not write SQLite directly.

| Consumer | Input | Output / boundary |
|---|---|---|
| Collection | profile/discovery versions, stable source preference | `_knowledge` evidence pointer; never raw content here |
| Scoring | project versions plus evidence projection | versioned lead; disposition remains unchanged |
| SERP/search | contemporaneous observation evidence | source-tagged lead candidate, never account-history substitution |
| Insights | bounded project lead read model | aggregate explanations with evidence IDs |
| Scheduling/alerts | project ID, disposition/version filters | local job/reference; no provider mutation |
| UI/API | exact authenticated project ID | same ranked lead fields and CAS versions as the CLI |

Future workers record normalized job identity, kind, status, input/output
references, and timestamps in `jobs`. Usage records contain provider, unit,
decimal quantity, optional cost/currency, and a job reference. Cancellation or
budget exhaustion leaves an unfinished job and its completed evidence/import
receipts intact so later routines can resume without claiming completeness.

## Recovery checklist

1. Retry an exact import: the prior digest returns as replayed.
2. On a conflict, inspect provider object/lead IDs and their evidence versions;
   do not overwrite the stored receipt.
3. On a stale edit, reload the current project or disposition version and make an
   explicit new decision.
4. On interrupted writes, SQLite rollback preserves the previous project,
   receipt, dispositions, and evidence pointers.
5. Restore only from a private validated store backup; rebuilding scores from
   evidence must still preserve exported operator dispositions.
