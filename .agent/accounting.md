---
name: accounting
description: Financial operations and accounting - QuickFile integration, invoicing, expense tracking
---

# Accounting - Main Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Financial operations and accounting
- **Primary Tool**: QuickFile (UK accounting)

**Subagents** (`services/accounting/`):
- `quickfile.md` - QuickFile MCP integration

**Typical Tasks**:
- Invoice management
- Expense tracking
- Financial reporting
- Client/supplier management
- Bank reconciliation

<!-- AI-CONTEXT-END -->

## Accounting Workflows

### QuickFile Integration

Use `services/accounting/quickfile.md` for:
- Creating and sending invoices
- Recording expenses
- Managing clients and suppliers
- Bank transaction matching
- Financial reports

### Invoice Management

- Create invoices from quotes
- Track payment status
- Send reminders
- Record payments

### Expense Tracking

- Categorize expenses
- Match bank transactions
- Track by project/client
- VAT handling (UK)

### Reporting

- Profit and loss
- Balance sheet
- VAT returns
- Cash flow

### Integration Points

- `sales.md` - Quote to invoice
- `services/` - Project-based billing

*See `services/accounting/quickfile.md` for detailed QuickFile operations.*
