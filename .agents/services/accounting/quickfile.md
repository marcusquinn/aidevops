---
description: QuickFile UK accounting API — invoices, clients, purchases, banking, reports via MCP
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: true
  quickfile_*: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# QuickFile Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Tool Prefix**: `quickfile_*` (37 tools)
- **MCP Server**: [quickfile-mcp](https://github.com/marcusquinn/quickfile-mcp) (TypeScript, stdio)
- **Credentials**: `~/.config/.quickfile-mcp/credentials.json`
- **API Docs**: https://api.quickfile.co.uk/
- **Config Template**: `configs/mcp-templates/quickfile.json`
- **Related**: `@accounts` (parent), `@aidevops` (infrastructure)

| Task | Tool |
|------|------|
| Account info | `quickfile_system_get_account` |
| Find clients | `quickfile_client_search` |
| List invoices | `quickfile_invoice_search` |
| Create invoice | `quickfile_invoice_create` |
| P&L report | `quickfile_report_profit_loss` |
| Outstanding debts | `quickfile_report_ageing` |

<!-- AI-CONTEXT-END -->

## Purchase/Expense Recording Workflow

OCR extraction pipeline (t012.3) feeds into QuickFile via `quickfile-helper.sh` (t012.4):

```text
Receipt/Invoice → [ocr-receipt-helper.sh extract] → [ocr-receipt-helper.sh quickfile]
               → [quickfile-helper.sh record-purchase] → supplier_search → purchase_create
```

```bash
# Full pipeline
ocr-receipt-helper.sh quickfile invoice.pdf

# Step by step
ocr-receipt-helper.sh extract invoice.pdf
quickfile-helper.sh preview invoice-quickfile.json
quickfile-helper.sh record-purchase invoice-quickfile.json

# Expense receipts (auto-categorises nominal code)
quickfile-helper.sh record-expense receipt-quickfile.json --auto-supplier

# Batch process a folder
quickfile-helper.sh batch-record ~/.aidevops/.agent-workspace/work/ocr-receipts/
```

### Supplier Resolution

1. `quickfile_supplier_search` with extracted vendor name
2. Found → use SupplierId
3. Not found + `--auto-supplier` → `quickfile_supplier_create`

### Nominal Code Auto-Categorisation

| Merchant Pattern | Nominal Code | Category |
|-----------------|-------------|----------|
| Shell, BP, fuel | 7401 | Motor Expenses - Fuel |
| Hotel, Airbnb | 7403 | Hotel & Accommodation |
| Restaurant, cafe | 7402 | Subsistence |
| Train, taxi, Uber | 7400 | Travel & Subsistence |
| Amazon, office supplies | 7504 | Stationery & Office Supplies |
| Adobe, Microsoft, SaaS | 7404 | Computer Software |
| *Default* | 5000 | General Purchases |

Override: `--nominal <code>`. Full list: `quickfile_report_chart_of_accounts`.

| Script | Purpose |
|--------|---------|
| `quickfile-helper.sh` | QuickFile recording bridge (supplier resolve, purchase/expense create) |
| `ocr-receipt-helper.sh` | OCR extraction pipeline (scan, extract, batch, quickfile) |
| `document-extraction-helper.sh` | General document extraction (Docling + ExtractThinker) |
| `extraction_pipeline.py` | Pydantic validation, VAT checks, confidence scoring |

## Installation

Requires Node.js 18+, QuickFile account (free at https://www.quickfile.co.uk/), API credentials.

```bash
# Option A: setup.sh (recommended)
./setup.sh  # Select "Setup QuickFile MCP"

# Option B: manual
cd ~/Git && git clone https://github.com/marcusquinn/quickfile-mcp.git
cd quickfile-mcp && npm install && npm run build
```

### Credential Setup

```bash
mkdir -p ~/.config/.quickfile-mcp && chmod 700 ~/.config/.quickfile-mcp
# Create ~/.config/.quickfile-mcp/credentials.json:
# { "accountNumber": "...", "apiKey": "...", "applicationId": "..." }
chmod 600 ~/.config/.quickfile-mcp/credentials.json
```

| Credential | Location in QuickFile |
|------------|----------------------|
| Account Number | Top-right corner of dashboard |
| API Key | Account Settings > 3rd Party Integrations > API Key |
| Application ID | Account Settings > Create a QuickFile App > Application ID |

### AI Assistant Configuration

All configs: `command: node`, `args: ["/path/to/quickfile-mcp/dist/index.js"]`. See `configs/mcp-templates/quickfile.json` for ready-to-use snippets (Claude Code, Claude Desktop, Cursor, OpenCode, Gemini CLI, GitHub Copilot, Zed, Kilo Code, Kiro, Droid).

Claude Code quick-add: `claude mcp add quickfile node ~/Git/quickfile-mcp/dist/index.js`

## Available Tools (37)

**System (3):** `quickfile_system_get_account`, `quickfile_system_search_events`, `quickfile_system_create_note`

**Clients (7):** `quickfile_client_search`, `quickfile_client_get`, `quickfile_client_create`, `quickfile_client_update`, `quickfile_client_delete`, `quickfile_client_insert_contacts`, `quickfile_client_login_url`

**Invoices (8):** `quickfile_invoice_search`, `quickfile_invoice_get`, `quickfile_invoice_create`, `quickfile_invoice_delete`, `quickfile_invoice_send`, `quickfile_invoice_get_pdf`, `quickfile_estimate_accept_decline`, `quickfile_estimate_convert_to_invoice`

**Purchases (4):** `quickfile_purchase_search`, `quickfile_purchase_get`, `quickfile_purchase_create`, `quickfile_purchase_delete`

**Suppliers (4):** `quickfile_supplier_search`, `quickfile_supplier_get`, `quickfile_supplier_create`, `quickfile_supplier_delete`

**Banking (5):** `quickfile_bank_get_accounts`, `quickfile_bank_get_balances`, `quickfile_bank_search`, `quickfile_bank_create_account`, `quickfile_bank_create_transaction`

**Reports (6):** `quickfile_report_profit_loss`, `quickfile_report_balance_sheet`, `quickfile_report_vat_obligations`, `quickfile_report_ageing`, `quickfile_report_chart_of_accounts`, `quickfile_report_subscriptions`

## Security & Rate Limits

- Credentials: `~/.config/.quickfile-mcp/credentials.json` (600 perms, never commit)
- Auth: MD5 hash (AccountNumber + APIKey + SubmissionNumber) — unique per request (no replay)
- Debug: `QUICKFILE_DEBUG=1` redacts credentials in output
- Rate limit: 1000 API calls/day per account, resets ~midnight. Contact support to increase.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Credentials not found | Create `~/.config/.quickfile-mcp/credentials.json` with all 3 fields |
| Authentication failed | Verify accountNumber, apiKey, applicationId are correct |
| Rate limit exceeded | Wait until midnight or contact QuickFile support |
| Build failed | Ensure Node.js 18+: `node --version` |
| MCP not responding | `cd ~/Git/quickfile-mcp && npm run build`, then restart AI tool |

Verify setup: prompt `"Show me my QuickFile account details"` — expect company name, VAT status, year end.

**Resources**: [MCP Repo](https://github.com/marcusquinn/quickfile-mcp) | [Support](https://support.quickfile.co.uk/) | [Community](https://community.quickfile.co.uk/) | [API Docs](https://api.quickfile.co.uk/) | [Context7](https://context7.com/websites/api_quickfile_co_uk)
