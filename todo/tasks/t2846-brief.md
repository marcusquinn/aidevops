---
mode: subagent
---

# t2846: sensitivity classification schema + detector

## Pre-flight

- [x] Memory recall: `pii detection sensitivity classification` → no relevant lessons (new framework primitive)
- [x] Discovery: `tools/document/extraction-schemas/10-classification.md` exists at HEAD (currently 21 lines, accounting-only)
- [x] File refs verified: `.agents/tools/document/extraction-schemas/10-classification.md`, `.agents/scripts/document-extraction-helper.sh`, `.agents/scripts/ocr-receipt-helper.sh`
- [x] Tier: `tier:standard` — schema definition + regex/NER detector pattern; existing classification doc to extend

## Origin

- Created: 2026-04-25
- Parent task: t2840 / GH#20892
- Phase: P0.5 (sensitivity + LLM routing layer)

## What

Define the cross-cutting sensitivity classification schema (`public | internal | pii | sensitive | privileged`) and ship a local-only detector that stamps every ingested source's `meta.json` with a `sensitivity` tier. Detection runs entirely on-host (regex + entity heuristics + optional local-LLM fallback via Ollama) — no cloud calls, ever.

**Concrete deliverables:**

1. Sensitivity tier definitions in `_config/sensitivity.json` with examples, redaction rules, retention defaults, allowed-LLM-vendors policy per tier
2. Detector helper: `sensitivity-detector-helper.sh classify <source-id>` — reads source content, runs detection, writes `sensitivity` field into `meta.json`
3. Detection rules (in priority order):
   - Regex/pattern: NI numbers, payment card formats, IBAN, email addresses with personal domains, postcodes — flags `pii`
   - Filename/path heuristics: `legal/`, `privileged/`, `attorney-client/` → `privileged`
   - Maintainer override: explicit tier from a `--sensitivity` flag on `aidevops knowledge add` writes through
   - Local-LLM fallback (P0.5c dependency): for ambiguous content, route to Ollama with a sensitivity prompt
4. Extend `tools/document/extraction-schemas/10-classification.md` from accounting-only to broader business/legal/asset taxonomy with sensitivity column
5. Detection audit log: every classification recorded at `_knowledge/index/sensitivity-audit.log` (JSONL) for review/correction
6. Override CLI: `aidevops knowledge sensitivity <source-id> <tier> [--reason "..."]` for human correction with audit trail

## Why

Without a sensitivity layer, the knowledge plane is a privacy footgun. Adding it after P4-P6 ship would require migrating already-stamped sources — better to bake it in pre-MVP. The detector runs locally because trusting a cloud LLM with raw PII to classify it as PII is a bootstrap problem.

Detection accuracy is necessarily imperfect (no detector catches everything). The audit log + manual override CLI lets a human correct misclassifications without losing provenance.

## How (Approach)

1. **Tier spec** — `_config/sensitivity.json`:
   ```json
   {
     "tiers": {
       "public":     { "redact": false, "llm": "any",   "retention_years": 10 },
       "internal":   { "redact": false, "llm": "cloud", "retention_years": 7  },
       "pii":        { "redact": true,  "llm": "local-or-redacted-cloud", "retention_years": 7 },
       "sensitive":  { "redact": true,  "llm": "local", "retention_years": 7 },
       "privileged": { "redact": true,  "llm": "local-only-hard-fail", "retention_years": 10 }
     },
     "patterns": {
       "uk_ni":  { "regex": "[A-CEGHJ-PR-TW-Z]{2}[0-9]{6}[A-D]", "tier": "pii" },
       "uk_postcode": { "regex": "[A-Z]{1,2}[0-9R][0-9A-Z]?[ ]?[0-9][A-Z]{2}", "tier": "pii" },
       "iban":   { "regex": "[A-Z]{2}[0-9]{2}[A-Z0-9]{4,30}", "tier": "pii" },
       "amex":   { "regex": "3[47][0-9]{13}", "tier": "pii" }
     },
     "path_heuristics": [
       { "glob": "**/legal/**",        "tier": "privileged" },
       { "glob": "**/privileged/**",   "tier": "privileged" },
       { "glob": "**/board-minutes/**", "tier": "sensitive" }
     ]
   }
   ```
2. **Detector helper** — `scripts/sensitivity-detector-helper.sh`:
   - `classify <source-id>` — read content (text-extracted; for binary/PDF, use `document-extraction-helper.sh` to get text first), apply regex patterns, path heuristics, maintainer overrides, local-LLM fallback
   - `audit-log <source-id> <tier> <evidence>` — append to JSONL
   - `override <source-id> <tier> <reason>` — manual correction
3. **Local-LLM fallback** — placeholder until P0.5c lands; until then, ambiguous content defaults to next-higher tier (precautionary). Once P0.5c ships, route through `llm-routing-helper.sh route --task classify --tier-hint <output-of-regex-pass>`.
4. **Integrate with knowledge add** — extend `knowledge-helper.sh add` (from t2843) to call `sensitivity-detector-helper.sh classify` after sha256 + meta bootstrap, write tier into `meta.json`.
5. **Extend classification taxonomy doc** — rewrite `tools/document/extraction-schemas/10-classification.md` to cover invoice/contract/bank_statement/financial_statement/t_and_c/payment_receipt/declaration/handbook/email/legal_advice/board_minutes/strategy/research and add `sensitivity` column.
6. **Tests** — covers regex hits, path heuristics, override flow, ambiguous-content fallback, audit log correctness

### Files Scope

- NEW: `.agents/scripts/sensitivity-detector-helper.sh`
- NEW: `.agents/templates/sensitivity-config.json` (default `_config/sensitivity.json`)
- EDIT: `.agents/tools/document/extraction-schemas/10-classification.md` (broader taxonomy + sensitivity column)
- EDIT: `.agents/scripts/knowledge-helper.sh` (call detector during `add`)
- EDIT: `.agents/templates/knowledge-config.json` (reference sensitivity defaults)
- NEW: `.agents/tests/test-sensitivity-detector.sh`
- EDIT: `.agents/aidevops/knowledge-plane.md` (add sensitivity section)

## Acceptance Criteria

- [ ] `sensitivity-detector-helper.sh classify <source-id>` writes `sensitivity` field into `meta.json` with one of 5 tiers
- [ ] UK NI number, IBAN, postcode, payment card patterns each correctly flag `pii`
- [ ] Path-based override (`legal/`, `privileged/`) correctly flags `privileged`
- [ ] Manual `--sensitivity privileged` flag on `knowledge add` overrides detector
- [ ] Override CLI: `aidevops knowledge sensitivity <source-id> internal --reason "...corrected"` updates meta.json + audit log
- [ ] Detection runs entirely offline — verifiable by disabling network and running detector on test corpus
- [ ] Audit log at `_knowledge/index/sensitivity-audit.log` records every classification with timestamp + actor + evidence + tier
- [ ] Extended classification taxonomy covers invoice/contract/bank_statement/legal_advice/board_minutes/etc with sensitivity column
- [ ] ShellCheck zero violations
- [ ] Tests pass: `bash .agents/tests/test-sensitivity-detector.sh`
- [ ] Documentation: `.agents/aidevops/knowledge-plane.md` sensitivity section

## Dependencies

- **Blocked by:** t2844 (P0a — meta.json schema must exist)
- **Soft-blocked by:** t2848 (P0.5c Ollama) for local-LLM fallback; until then, precautionary default works
- **Blocks:** t2847 (P0.5b LLM routing reads sensitivity tier), all P4-P6 (cases plane and AI comms must respect tier)

## Reference

- Parent brief: `todo/tasks/t2840-brief.md` § "Sensitivity tiers"
- Existing taxonomy: `.agents/tools/document/extraction-schemas/10-classification.md` (extend, do not replace)
- Pattern to follow: `.agents/scripts/document-extraction-helper.sh` (similar single-file analysis pattern)
