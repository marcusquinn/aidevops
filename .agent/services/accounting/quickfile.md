# QuickFile Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: QuickFile UK accounting operations - invoices, clients, purchases, banking, reports
- **Tool Prefix**: `quickfile_*`
- **Credentials**: `~/.config/.quickfile-mcp/credentials.json`

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

This agent provides access to QuickFile UK accounting software through the MCP server. Use it for:

- **Client Management**: Create, search, update clients and contacts
- **Invoicing**: Create and send invoices, estimates, credit notes
- **Purchases**: Record purchase invoices from suppliers
- **Banking**: View accounts, balances, and transactions
- **Reporting**: P&L, Balance Sheet, VAT, Ageing reports

## Available Tools

### System
- `quickfile_system_get_account` - Account details
- `quickfile_system_search_events` - Event log
- `quickfile_system_create_note` - Add notes

### Clients
- `quickfile_client_search` - Search clients
- `quickfile_client_get` - Get client details
- `quickfile_client_create` - New client
- `quickfile_client_update` - Update client
- `quickfile_client_delete` - Delete client
- `quickfile_client_insert_contacts` - Add contact
- `quickfile_client_login_url` - Client portal URL

### Invoices
- `quickfile_invoice_search` - Search invoices
- `quickfile_invoice_get` - Get invoice
- `quickfile_invoice_create` - Create invoice/estimate
- `quickfile_invoice_delete` - Delete invoice
- `quickfile_invoice_send` - Email invoice
- `quickfile_invoice_get_pdf` - Get PDF URL
- `quickfile_estimate_accept_decline` - Accept/decline estimate
- `quickfile_estimate_convert_to_invoice` - Convert to invoice

### Purchases
- `quickfile_purchase_search` - Search purchases
- `quickfile_purchase_get` - Get purchase
- `quickfile_purchase_create` - Create purchase
- `quickfile_purchase_delete` - Delete purchase

### Suppliers
- `quickfile_supplier_search` - Search suppliers
- `quickfile_supplier_get` - Get supplier
- `quickfile_supplier_create` - New supplier
- `quickfile_supplier_delete` - Delete supplier

### Banking
- `quickfile_bank_get_accounts` - List accounts
- `quickfile_bank_get_balances` - Get balances
- `quickfile_bank_search` - Search transactions
- `quickfile_bank_create_account` - New account
- `quickfile_bank_create_transaction` - Add transaction

### Reports
- `quickfile_report_profit_loss` - P&L report
- `quickfile_report_balance_sheet` - Balance sheet
- `quickfile_report_vat_obligations` - VAT returns
- `quickfile_report_ageing` - Debtor/creditor ageing
- `quickfile_report_chart_of_accounts` - Nominal codes
- `quickfile_report_subscriptions` - Recurring items

## Example Prompts

### Account Overview
"Show me my QuickFile account details and this year's financial summary"

### Client Operations
"Search for clients in London"
"Create a new client for Acme Ltd with email john@acme.com"
"Update client 12345 with new address"

### Invoice Operations
"List all unpaid invoices from the last 30 days"
"Create an invoice for client 12345 for 8 hours of consulting at £100/hour"
"Send invoice 67890 to the client"
"Get the PDF for invoice 67890"

### Financial Reports
"Generate a profit and loss report for Q1 2024"
"Show me the balance sheet as of today"
"List all open VAT returns"
"Show me the debtor ageing report"

### Purchase Operations
"Record a purchase invoice from Amazon for £50 office supplies"
"List all purchases from supplier 11111"

## Security Notes

- Credentials stored in `~/.config/.quickfile-mcp/credentials.json`
- File should have 600 permissions
- API calls are authenticated via MD5 hash
- Default rate limit: 1000 calls/day

## Related Agents

- `@aidevops` - For infrastructure operations
- `@code-quality` - For code review

## Reference

- [QuickFile API Documentation](https://api.quickfile.co.uk/)
- [AGENTS.md](../AGENTS.md) - Full documentation
