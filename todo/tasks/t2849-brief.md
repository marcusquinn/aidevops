---
mode: subagent
---

# t2849: kind-aware enrichment + structured field extraction

## Pre-flight

- [x] Memory recall: `extraction structured field schema document` → `ocr-receipt-helper.sh` and `document-extraction-helper.sh` exist; receipt-only today
- [x] Discovery: `ocr-receipt-helper.sh` is production-quality for receipts; pattern is generalisable
- [x] File refs verified: `.agents/scripts/ocr-receipt-helper.sh`, `.agents/scripts/document-extraction-helper.sh`, `.agents/tools/document/extraction-schemas/10-classification.md`
- [x] Tier: `tier:standard` — generalises an existing pattern from receipts to broader doc-type taxonomy

## Origin

- Created: 2026-04-25
- Parent task: t2840 / GH#20892
- Phase: P1 (kind-aware enrichment)

## What

Generalise the existing receipt-extraction pattern (`ocr-receipt-helper.sh`) into a kind-aware extraction helper that handles invoice / contract / bank_statement / financial_statement / t_and_c / payment_receipt / declaration / handbook / email / legal_advice / board_minutes. Each kind has a JSON schema declaring the structured fields to extract; extracted fields land in `_knowledge/sources/<id>/extracted.json` with provenance per field.

**Concrete deliverables:**

1. `scripts/document-enrich-helper.sh enrich <source-id>` — detects kind from `meta.json`, runs kind-specific extractor, writes `extracted.json`
2. Schema directory `tools/document/extraction-schemas/<kind>.json` — one schema per supported kind, declares fields + types + LLM extraction prompts
3. Initial schema set (MVP): invoice, contract, bank_statement, financial_statement, payment_receipt, email — plus a generic `document` fallback
4. Provenance per field: `extracted.json` records `{value, confidence, source: "regex"|"llm"|"manual", evidence_excerpt: "...", page: N}` per field
5. Routing through t2847's LLM router with appropriate sensitivity tier
6. CLI: `aidevops knowledge enrich <source-id>` invokes helper; `aidevops knowledge enrich --kind <override>` allows manual kind override

## Why

A flat blob of OCR text per source has limited utility. With structured extraction, downstream work (case attaching, KPI feedback, AI drafts) can query specific fields ("amount > £5k", "contract end date in next 90 days", "all bank statements for Q1"). Without it, every consumer would re-parse text — wasted work and inconsistent results.

Generalising from `ocr-receipt-helper.sh` rather than rewriting preserves what works (PDF-to-text pipeline, error handling, idempotency) and adds taxonomy-driven dispatch.

## How (Approach)

1. **Schema format** — `tools/document/extraction-schemas/invoice.json`:
   ```json
   {
     "kind": "invoice",
     "fields": [
       { "name": "supplier_name",  "type": "string", "extractor": "llm", "prompt": "Extract the supplier company name." },
       { "name": "invoice_number", "type": "string", "extractor": "regex", "pattern": "(?i)invoice[ #]+([A-Z0-9-]+)" },
       { "name": "invoice_date",   "type": "date",   "extractor": "llm", "prompt": "Extract the invoice date in ISO format." },
       { "name": "total_amount",   "type": "number", "extractor": "llm" },
       { "name": "currency",       "type": "string", "extractor": "llm" },
       { "name": "line_items",     "type": "array",  "extractor": "llm" }
     ]
   }
   ```
2. **Enrich helper** — `scripts/document-enrich-helper.sh`:
   - `enrich <source-id>`: read `meta.json` → kind; load `extraction-schemas/<kind>.json`; for each field, dispatch to regex or LLM extractor; collect into `extracted.json` with provenance
   - `_extract_regex <pattern> <text-file>` — captures with confidence=high if matched
   - `_extract_llm <field-spec> <text-file>` — composes a prompt, routes via `llm-routing-helper.sh route --tier <meta.sensitivity>`, parses JSON response
   - Idempotent: re-runs only re-extract changed schema fields
3. **MVP schemas** — write the 6+1 schema files (invoice, contract, bank_statement, financial_statement, payment_receipt, email, generic document fallback)
4. **CLI integration** — extend `aidevops knowledge enrich <id>` and add a routine `r041` that runs enrichment on freshly-promoted sources (`status: sources` and no `extracted.json` yet)
5. **Tests** — covers regex extraction, LLM extraction (with mocked routing), idempotent re-run, schema validation, manual kind override
6. **Cost budget** — log per-source enrichment cost via `llm-routing-helper.sh` (already records); optional `--max-cost <USD>` flag bails early

### Files Scope

- NEW: `.agents/scripts/document-enrich-helper.sh`
- NEW: `.agents/tools/document/extraction-schemas/{invoice,contract,bank_statement,financial_statement,payment_receipt,email,generic}.json` (7 files)
- EDIT: `.agents/tools/document/extraction-schemas/10-classification.md` (link new schemas)
- EDIT: `.agents/scripts/knowledge-helper.sh` (add `enrich` subcommand)
- EDIT: `TODO.md` (add `r041` enrichment routine entry — done in this task's PR)
- NEW: `.agents/tests/test-document-enrich.sh`
- EDIT: `.agents/aidevops/knowledge-plane.md` (enrichment section)

## Acceptance Criteria

- [ ] `aidevops knowledge enrich <invoice-source-id>` produces `extracted.json` with at least 5 of 6 invoice fields populated
- [ ] Each extracted field has provenance: source (regex|llm|manual), confidence, evidence_excerpt, page (where applicable)
- [ ] Re-running `enrich` on the same source is idempotent (no LLM re-call if `extracted.json` already covers schema)
- [ ] Manual override: `--kind contract` correctly switches the schema applied
- [ ] LLM extraction routes through `llm-routing-helper.sh` with the source's `sensitivity` tier (verifiable in audit log)
- [ ] Bank-statement schema correctly extracts account number (regex), period, opening/closing balance, transaction list
- [ ] Routine `r041` runs every 30 min on the pulse, picks up newly-promoted sources, idempotent
- [ ] ShellCheck zero violations
- [ ] Tests pass: `bash .agents/tests/test-document-enrich.sh`
- [ ] Documentation: schema authoring guide in `.agents/aidevops/knowledge-plane.md`

## Dependencies

- **Blocked by:** t2844 (P0a directory + meta.json), t2843 (P0b CLI surface), t2847 (P0.5b LLM routing for LLM-extractor fields)
- **Soft-blocked by:** t2846 (P0.5a sensitivity tier needed for routing)
- **Blocks:** P4 (cases query enriched fields), P6 (drafts use enriched data verbatim)

## Reference

- Parent brief: `todo/tasks/t2840-brief.md` § "Kind-aware enrichment"
- Pattern to generalise from: `.agents/scripts/ocr-receipt-helper.sh` (already production-quality)
- Existing extraction surface: `.agents/scripts/document-extraction-helper.sh`
- Taxonomy doc: `.agents/tools/document/extraction-schemas/10-classification.md` (extended in P0.5a)
