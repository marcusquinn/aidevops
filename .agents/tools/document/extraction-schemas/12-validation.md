# Confidence and Validation

Each extraction should include a validation summary:

```json
{
  "extraction": { "...schema fields..." },
  "validation": {
    "vat_check": "pass",
    "total_check": "pass",
    "date_valid": true,
    "currency_detected": "GBP",
    "confidence": {
      "vendor_name": 0.95,
      "total": 0.99,
      "vat_amount": 0.85,
      "line_items": 0.80
    },
    "warnings": [],
    "requires_review": false
  }
}
```

Fields with confidence below 0.7 should be flagged for manual review.
