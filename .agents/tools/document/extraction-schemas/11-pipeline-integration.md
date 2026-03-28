# Extraction Pipeline Integration

## Single Document

```bash
# Extract with specific schema
document-extraction-helper.sh extract invoice.pdf --schema purchase-invoice --privacy local

# Auto-classify and extract
document-extraction-helper.sh extract document.pdf --schema auto --privacy local
```

## Batch Processing

```bash
# Process folder of mixed documents
document-extraction-helper.sh batch ./receipts/ --schema auto --privacy local

# Process only invoices
document-extraction-helper.sh batch ./invoices/ --schema purchase-invoice
```

## Full Pipeline (Extract -> Validate -> Record)

```bash
# 1. Extract
document-extraction-helper.sh extract invoice.pdf --schema purchase-invoice --privacy local

# 2. Review extracted JSON (human or AI validation)
cat ~/.aidevops/.agent-workspace/work/document-extraction/invoice-extracted.json

# 3. Record in QuickFile (t012.4)
quickfile-helper.sh record-purchase invoice-extracted.json --auto-supplier

# Or for expense receipts (auto-categorises nominal code):
quickfile-helper.sh record-expense receipt-extracted.json --auto-supplier

# Batch record all extracted files:
quickfile-helper.sh batch-record ~/.aidevops/.agent-workspace/work/ocr-receipts/
```
