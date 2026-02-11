---
description: QuickFile accounting API integration via MCP server
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

# QuickFile Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: QuickFile UK accounting operations - invoices, clients, purchases, banking, reports
- **Tool Prefix**: `quickfile_*`
- **MCP Server**: [quickfile-mcp](https://github.com/marcusquinn/quickfile-mcp) (TypeScript, stdio)
- **Credentials**: `~/.config/.quickfile-mcp/credentials.json`
- **API Docs**: https://api.quickfile.co.uk/
- **Config Template**: `configs/mcp-templates/quickfile.json`

**Common Tasks**:

| Task | Tool |
|------|------|
| Account info | `quickfile_system_get_account` |
| Find clients | `quickfile_client_search` |
| List invoices | `quickfile_invoice_search` |
| Create invoice | `quickfile_invoice_create` |
| P&L report | `quickfile_report_profit_loss` |
| Outstanding debts | `quickfile_report_ageing` |

**Example Prompts**:

- "Show my QuickFile account details"
- "Find all unpaid invoices"
- "Create an invoice for Client X for consulting services"
- "Get this year's profit and loss report"

<!-- AI-CONTEXT-END -->

## Description

This agent provides access to QuickFile UK accounting software through the
[quickfile-mcp](https://github.com/marcusquinn/quickfile-mcp) MCP server.
QuickFile is a free UK cloud accounting platform for small to medium businesses,
supporting HMRC MTD (Making Tax Digital), VAT filing, and Open Banking feeds.

Use it for:

- **Client Management**: Create, search, update clients and contacts
- **Invoicing**: Create and send invoices, estimates, credit notes
- **Purchases**: Record purchase invoices from suppliers
- **Supplier Management**: Full supplier CRUD operations
- **Banking**: View accounts, balances, and transactions
- **Reporting**: P&L, Balance Sheet, VAT, Ageing reports
- **System**: Account details, event log, notes

## Purchase/Expense Recording Workflow

The OCR extraction pipeline (t012.3) feeds into QuickFile via `quickfile-helper.sh` (t012.4):

```text
Receipt/Invoice (photo/scan/PDF)
        |
   [OCR Extract]  ocr-receipt-helper.sh extract file
        |
   [Prepare JSON]  ocr-receipt-helper.sh quickfile file
        |
   [Record]  quickfile-helper.sh record-purchase file-quickfile.json
        |
   [MCP Calls]  AI executes: supplier_search -> supplier_create -> purchase_create
```

### Quick Start

```bash
# Full pipeline: extract + prepare + generate MCP instructions
ocr-receipt-helper.sh quickfile invoice.pdf

# Or step by step:
ocr-receipt-helper.sh extract invoice.pdf          # Step 1: Extract
quickfile-helper.sh preview invoice-quickfile.json  # Step 2: Preview
quickfile-helper.sh record-purchase invoice-quickfile.json  # Step 3: Record

# Expense receipts (auto-categorises nominal code):
quickfile-helper.sh record-expense receipt-quickfile.json --auto-supplier

# Batch process a folder:
quickfile-helper.sh batch-record ~/.aidevops/.agent-workspace/work/ocr-receipts/
```

### Supplier Resolution

The helper automatically generates supplier lookup/creation instructions:

1. `quickfile_supplier_search` with extracted vendor/merchant name
2. If found: uses the returned SupplierId
3. If not found (with `--auto-supplier`): `quickfile_supplier_create`

### Nominal Code Auto-Categorisation

For expense receipts, `quickfile-helper.sh record-expense` auto-categorises:

| Merchant Pattern | Nominal Code | Category |
|-----------------|-------------|----------|
| Shell, BP, fuel | 7401 | Motor Expenses - Fuel |
| Hotel, Airbnb | 7403 | Hotel & Accommodation |
| Restaurant, cafe | 7402 | Subsistence |
| Train, taxi, Uber | 7400 | Travel & Subsistence |
| Amazon, office supplies | 7504 | Stationery & Office Supplies |
| Adobe, Microsoft, SaaS | 7404 | Computer Software |
| *Default* | 5000 | General Purchases |

Override with `--nominal <code>`. Full list: `quickfile_report_chart_of_accounts`.

### Related Scripts

| Script | Purpose |
|--------|---------|
| `quickfile-helper.sh` | QuickFile recording bridge (supplier resolve, purchase/expense create) |
| `ocr-receipt-helper.sh` | OCR extraction pipeline (scan, extract, batch, quickfile) |
| `document-extraction-helper.sh` | General document extraction (Docling + ExtractThinker) |
| `extraction_pipeline.py` | Pydantic validation, VAT checks, confidence scoring |

## Prerequisites

- **Node.js 18+**: Required to run the MCP server
- **QuickFile Account**: Free at https://www.quickfile.co.uk/
- **API Credentials**: Account Number, API Key, Application ID

## Installation

```bash
# Clone and build the MCP server
cd ~/Git
git clone https://github.com/marcusquinn/quickfile-mcp.git
cd quickfile-mcp
npm install && npm run build

# Or use setup.sh (handles everything automatically)
./setup.sh  # Select "Setup QuickFile MCP" when prompted
```

## Credential Setup

Create credentials file (never commit this):

```bash
mkdir -p ~/.config/.quickfile-mcp && chmod 700 ~/.config/.quickfile-mcp
```

Create `~/.config/.quickfile-mcp/credentials.json`:

```json
{
  "accountNumber": "YOUR_ACCOUNT_NUMBER",
  "apiKey": "YOUR_API_KEY",
  "applicationId": "YOUR_APPLICATION_ID"
}
```

```bash
chmod 600 ~/.config/.quickfile-mcp/credentials.json
```

**Where to find credentials:**

| Credential | Location |
|------------|----------|
| Account Number | Top-right corner of QuickFile dashboard |
| API Key | Account Settings > 3rd Party Integrations > API Key |
| Application ID | Account Settings > Create a QuickFile App > Application ID |

## AI Assistant Configurations

### OpenCode

Add to `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "quickfile": {
      "type": "local",
      "command": ["node", "/path/to/quickfile-mcp/dist/index.js"],
      "enabled": true
    }
  }
}
```

### Claude Code

```bash
claude mcp add quickfile node ~/Git/quickfile-mcp/dist/index.js
```

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "quickfile": {
      "command": "node",
      "args": ["/path/to/quickfile-mcp/dist/index.js"]
    }
  }
}
```

### Cursor

Add to `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "quickfile": {
      "command": "node",
      "args": ["/path/to/quickfile-mcp/dist/index.js"]
    }
  }
}
```

### Gemini CLI

Add to `~/.gemini/settings.json`:

```json
{
  "mcpServers": {
    "quickfile": {
      "command": "node",
      "args": ["/path/to/quickfile-mcp/dist/index.js"]
    }
  }
}
```

### GitHub Copilot

Add to `.vscode/mcp.json` in project root:

```json
{
  "servers": {
    "quickfile": {
      "type": "stdio",
      "command": "node",
      "args": ["/path/to/quickfile-mcp/dist/index.js"]
    }
  }
}
```

See `configs/mcp-templates/quickfile.json` for all AI assistant configurations
(Zed, Kilo Code, Kiro, Droid).

## Available Tools (37 tools)

### System (3 tools)

- `quickfile_system_get_account` - Account details (company, VAT status, year end)
- `quickfile_system_search_events` - Search the audit event log
- `quickfile_system_create_note` - Add notes to invoices, clients, etc.

### Clients (7 tools)

- `quickfile_client_search` - Search clients by name, email, postcode
- `quickfile_client_get` - Get full client details
- `quickfile_client_create` - Create a new client
- `quickfile_client_update` - Update client details
- `quickfile_client_delete` - Delete a client
- `quickfile_client_insert_contacts` - Add contacts to a client
- `quickfile_client_login_url` - Get passwordless login URL for client portal

### Invoices (8 tools)

- `quickfile_invoice_search` - Search invoices by type, client, date, status
- `quickfile_invoice_get` - Get full invoice with line items
- `quickfile_invoice_create` - Create invoice, estimate, or credit note
- `quickfile_invoice_delete` - Delete an invoice
- `quickfile_invoice_send` - Send invoice by email
- `quickfile_invoice_get_pdf` - Get PDF download URL
- `quickfile_estimate_accept_decline` - Accept or decline an estimate
- `quickfile_estimate_convert_to_invoice` - Convert estimate to invoice

### Purchases (4 tools)

- `quickfile_purchase_search` - Search purchase invoices
- `quickfile_purchase_get` - Get purchase details
- `quickfile_purchase_create` - Create purchase invoice
- `quickfile_purchase_delete` - Delete purchase invoice

### Suppliers (4 tools)

- `quickfile_supplier_search` - Search suppliers
- `quickfile_supplier_get` - Get supplier details
- `quickfile_supplier_create` - Create a new supplier
- `quickfile_supplier_delete` - Delete a supplier

### Banking (5 tools)

- `quickfile_bank_get_accounts` - List all bank accounts
- `quickfile_bank_get_balances` - Get account balances
- `quickfile_bank_search` - Search transactions
- `quickfile_bank_create_account` - Create a bank account
- `quickfile_bank_create_transaction` - Add bank transaction

### Reports (6 tools)

- `quickfile_report_profit_loss` - Profit & Loss report
- `quickfile_report_balance_sheet` - Balance Sheet report
- `quickfile_report_vat_obligations` - VAT returns (filed & open)
- `quickfile_report_ageing` - Debtor/Creditor ageing
- `quickfile_report_chart_of_accounts` - List nominal codes
- `quickfile_report_subscriptions` - Recurring subscriptions

## Example Prompts

### Account Overview

"Show me my QuickFile account details and this year's financial summary"

### Client Operations

"Search for clients in London"
"Create a new client for Acme Ltd with email john@acme.com"
"Update client 12345 with new address"

### Invoice Operations

"List all unpaid invoices from the last 30 days"
"Create an invoice for client 12345 for 8 hours of consulting at GBP 100/hour"
"Send invoice 67890 to the client"
"Get the PDF for invoice 67890"

### Financial Reports

"Generate a profit and loss report for Q1 2024"
"Show me the balance sheet as of today"
"List all open VAT returns"
"Show me the debtor ageing report"

### Purchase Operations

"Record a purchase invoice from Amazon for GBP 50 office supplies"
"List all purchases from supplier 11111"

## API Rate Limits

- **Default**: 1000 API calls per day per account
- **Reset**: Daily at approximately midnight
- **Increase**: Contact QuickFile support

## Security Notes

- Credentials stored in `~/.config/.quickfile-mcp/credentials.json`
- File should have 600 permissions (owner read/write only)
- API calls authenticated via MD5 hash (AccountNumber + APIKey + SubmissionNumber)
- Each API request uses a unique submission number (no replay attacks)
- Debug mode (`QUICKFILE_DEBUG=1`) redacts credentials in output

## Verification

After setup, test with:

```text
"Show me my QuickFile account details"
```

Expected: Returns company name, VAT status, financial year end, and account metadata.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Credentials not found | Create `~/.config/.quickfile-mcp/credentials.json` with accountNumber, apiKey, applicationId |
| Authentication failed | Verify all 3 credential values are correct |
| Rate limit exceeded | Wait until midnight for reset, or contact QuickFile support |
| Build failed | Ensure Node.js 18+: `node --version` |
| MCP not responding | Rebuild: `cd ~/Git/quickfile-mcp && npm run build`. Restart AI tool. |

**Debug mode**: `QUICKFILE_DEBUG=1 node ~/Git/quickfile-mcp/dist/index.js`

**Resources**:

| Resource | URL |
|----------|-----|
| MCP Server Repo | https://github.com/marcusquinn/quickfile-mcp |
| QuickFile Support | https://support.quickfile.co.uk/ |
| Community Forum | https://community.quickfile.co.uk/ |
| API Documentation | https://api.quickfile.co.uk/ |
| Context7 API Index | https://context7.com/websites/api_quickfile_co_uk |

## Related Agents

- `@accounts` - Parent agent for accounting operations
- `@aidevops` - For infrastructure operations
