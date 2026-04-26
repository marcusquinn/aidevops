<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Document Classification

Before extraction, classify the document to select the correct schema and sensitivity tier.

## Document Type Classification

```text
Classification signals:
  "Invoice" / "Tax Invoice"     -> purchase-invoice (if from supplier)
                                -> invoice (if issued by you)
  "Receipt" / "Till Receipt"    -> expense-receipt
  "Credit Note" / "CN-"        -> credit-note
  "Estimate" / "Quote"         -> Not an extraction target (skip)
  "Statement"                  -> Not an extraction target (skip)

Disambiguation:
  - Your company name in "From" field -> invoice (you issued it)
  - Your company name in "To" field   -> purchase-invoice (supplier issued it)
  - No invoice number + till format   -> expense-receipt
```

## Sensitivity Classification

Every classified document must also receive a sensitivity tier. Run `sensitivity-detector-helper.sh classify <source-id>` after ingestion — it stamps `meta.json` automatically.

Manual override: `sensitivity-detector-helper.sh override <source-id> <tier> --reason "..."`

## Document Taxonomy with Sensitivity

| Document Type | Description | Typical Sensitivity | Auto-Detection Signal |
|---------------|-------------|---------------------|-----------------------|
| `invoice` | Invoice issued by you | `internal` | Issued-by company name in From field |
| `purchase-invoice` | Invoice from supplier | `internal` | Supplier name in From; your name in To |
| `expense-receipt` | Till receipt / small purchase | `internal` | No invoice number, till format |
| `credit-note` | Credit memo from supplier | `internal` | "Credit Note" / "CN-" header |
| `bank-statement` | Bank account statement | `pii` | Account number, sort code, IBAN, transactions |
| `financial-statement` | P&L, balance sheet, management accounts | `internal` or `sensitive` | Company financials; board-level if `board/` path |
| `payment-receipt` | Payment confirmation | `pii` | Card/bank numbers, transaction IDs |
| `contract` | Commercial contract | `internal` or `sensitive` | "Agreement", "Terms and Conditions", counterparty details |
| `t-and-c` | Terms and conditions (standard) | `internal` | Boilerplate legal language, no personal parties |
| `declaration` | Statutory or regulatory declaration | `pii` or `sensitive` | Names, NI numbers, signatures, regulatory body |
| `handbook` | Employee/operational handbook | `internal` | HR policy language |
| `email` | Email correspondence | `pii` | Email addresses, names, personal content |
| `legal-advice` | Solicitor / counsel advice | `privileged` | "Without Prejudice", law firm letterhead; path `legal/` |
| `board-minutes` | Board meeting minutes | `sensitive` | "Minutes of Board Meeting"; path `board-minutes/` or `board/` |
| `strategy` | Business strategy / roadmap | `sensitive` | "Strategic Plan", "Roadmap", "Confidential"; path `strategy/` |
| `research` | Market or technical research | `internal` | Research report format, citations |

### Sensitivity Tiers

| Tier | Redact | LLM Policy | Retention | Description |
|------|--------|------------|-----------|-------------|
| `public` | No | Any | 10 yr | Public-facing content — marketing, open data |
| `internal` | No | Cloud OK | 7 yr | Internal business docs — not personal data |
| `pii` | Yes | Local or redacted cloud | 7 yr | Personal data — names, IDs, addresses, payment |
| `sensitive` | Yes | Local only | 7 yr | Sensitive business — board, strategy, HR |
| `privileged` | Yes | Local hard-fail | 10 yr | Legally privileged — attorney-client, regulatory |

Tier precedence (highest wins when multiple signals): `privileged > sensitive > pii > internal > public`

Config: `_knowledge/_config/sensitivity.json` — see `.agents/templates/sensitivity-config.json` for defaults.
