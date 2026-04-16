#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""OCR Extraction Pipeline for AI DevOps Framework (t012.3).

Implements the full extraction pipeline:
  Input -> Classification -> Extraction -> Validation -> Output

Features:
  - Document classification (invoice/receipt/credit-note)
  - Pydantic schema validation with UK VAT support
  - VAT arithmetic checks and confidence scoring
  - Dual-input strategy for PDFs (text + image)
  - Multi-model fallback (Gemini Flash -> Ollama -> cloud)
  - Nominal code auto-categorisation from merchant/item patterns

Usage:
  python3 extraction_pipeline.py classify <file>
  python3 extraction_pipeline.py extract <file> [--schema auto|purchase-invoice|expense-receipt|credit-note]
  python3 extraction_pipeline.py validate <json-file>
  python3 extraction_pipeline.py categorise <vendor> <description>

Author: AI DevOps Framework
Version: 1.0.0
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Optional

from pydantic import BaseModel

# Re-export public surface from decomposed modules for backwards compatibility.
from extraction_models import (  # noqa: F401
    VatRate,
    DocumentType,
    PurchaseLineItem,
    ReceiptItem,
    PurchaseInvoice,
    ExpenseReceipt,
    CreditNote,
    FieldConfidence,
    ValidationResult,
    ExtractionOutput,
    _normalise_date,
    _is_valid_date,
    classify_document,
    categorise_nominal,
)
from extraction_validate import (  # noqa: F401
    validate_vat,
    compute_confidence,
    validate_extraction,
    get_schema_class,
    parse_and_validate,
)


# ---------------------------------------------------------------------------
# CLI interface
# ---------------------------------------------------------------------------

def _print_json(obj: BaseModel | dict) -> None:
    """Print a model or dict as formatted JSON."""
    if isinstance(obj, BaseModel):
        print(obj.model_dump_json(indent=2))
    else:
        print(json.dumps(obj, indent=2, default=str))


def cmd_classify(args: list[str]) -> int:
    """Classify a document from its text content."""
    if not args:
        print("Usage: extraction_pipeline.py classify <text-file-or-string>", file=sys.stderr)
        return 1

    input_path = Path(args[0])
    if input_path.is_file():
        text = input_path.read_text(encoding="utf-8", errors="replace")
    else:
        text = " ".join(args)

    doc_type, scores = classify_document(text)
    result = {
        "classified_type": doc_type.value,
        "scores": scores,
    }
    print(json.dumps(result, indent=2))
    return 0


def cmd_validate(args: list[str]) -> int:
    """Validate an extracted JSON file."""
    if not args:
        print("Usage: extraction_pipeline.py validate <json-file> [--type <doc-type>]", file=sys.stderr)
        return 1

    json_path = Path(args[0])
    if not json_path.is_file():
        print(f"ERROR: File not found: {json_path}", file=sys.stderr)
        return 1

    # Parse optional --type
    doc_type_str = "auto"
    for i, arg in enumerate(args[1:], 1):
        if arg == "--type" and i + 1 < len(args):
            doc_type_str = args[i + 1]

    raw = json.loads(json_path.read_text())

    # Handle wrapped format (data key) or flat format
    if "data" in raw and isinstance(raw["data"], dict):
        data = raw["data"]
        doc_type_str = raw.get("document_type", doc_type_str)
    else:
        data = raw

    # Resolve document type
    if doc_type_str == "auto":
        doc_type_str = data.get("document_type", "purchase_invoice")

    type_map = {
        "purchase_invoice": DocumentType.PURCHASE_INVOICE,
        "expense_receipt": DocumentType.EXPENSE_RECEIPT,
        "credit_note": DocumentType.CREDIT_NOTE,
        "invoice": DocumentType.SALES_INVOICE,
        "receipt": DocumentType.GENERIC_RECEIPT,
    }
    doc_type = type_map.get(doc_type_str, DocumentType.PURCHASE_INVOICE)

    result = parse_and_validate(data, doc_type, str(json_path))
    _print_json(result)
    return 0 if not result.validation.requires_review else 2


def cmd_categorise(args: list[str]) -> int:
    """Auto-categorise a nominal code from vendor and description."""
    if len(args) < 1:
        print("Usage: extraction_pipeline.py categorise <vendor> [description]", file=sys.stderr)
        return 1

    vendor = args[0]
    description = " ".join(args[1:]) if len(args) > 1 else ""
    code, category = categorise_nominal(vendor, description)
    print(json.dumps({"nominal_code": code, "category": category}))
    return 0


def _parse_extract_options(args: list[str]) -> tuple[str, str, str]:
    """Parse cmd_extract CLI options. Returns (input_file, schema, privacy)."""
    input_file = args[0]
    schema = "auto"
    privacy = "local"
    i = 1
    while i < len(args):
        if args[i] == "--schema" and i + 1 < len(args):
            schema = args[i + 1]
            i += 2
        elif args[i] == "--privacy" and i + 1 < len(args):
            privacy = args[i + 1]
            i += 2
        else:
            i += 1
    return input_file, schema, privacy


_PRIVACY_BACKENDS = {
    "local": "ollama/llama3.2",
    "cloud": "openai/gpt-4o",
}

_SCHEMA_TYPE_MAP = {
    "purchase-invoice": DocumentType.PURCHASE_INVOICE,
    "purchase_invoice": DocumentType.PURCHASE_INVOICE,
    "expense-receipt": DocumentType.EXPENSE_RECEIPT,
    "expense_receipt": DocumentType.EXPENSE_RECEIPT,
    "credit-note": DocumentType.CREDIT_NOTE,
    "credit_note": DocumentType.CREDIT_NOTE,
    "invoice": DocumentType.SALES_INVOICE,
    "receipt": DocumentType.GENERIC_RECEIPT,
}


def _auto_classify_file(input_file: str) -> DocumentType:
    """Read file and auto-classify its document type."""
    try:
        from docling.document_converter import DocumentConverter  # pylint: disable=import-outside-toplevel
        converter = DocumentConverter()
        doc_result = converter.convert(input_file)
        text = doc_result.document.export_to_markdown()
    except ImportError:
        text = Path(input_file).read_text(encoding="utf-8", errors="replace")
    doc_type, _scores = classify_document(text)
    return doc_type


def _validate_extract_preconditions(args: list[str]) -> Optional[tuple[str, str, str]]:
    """Validate preconditions for extract command. Returns (input_file, schema, privacy) or None."""
    if not args:
        print("Usage: extraction_pipeline.py extract <file> [--schema auto|purchase-invoice|expense-receipt|credit-note] [--privacy local|cloud]", file=sys.stderr)
        return None

    input_file, schema, privacy = _parse_extract_options(args)

    if not Path(input_file).is_file():
        print(f"ERROR: File not found: {input_file}", file=sys.stderr)
        return None

    return input_file, schema, privacy


def _resolve_doc_type(schema: str, input_file: str) -> DocumentType:
    """Resolve document type from schema name or by auto-classifying the file."""
    if schema == "auto":
        return _auto_classify_file(input_file)
    return _SCHEMA_TYPE_MAP.get(schema, DocumentType.PURCHASE_INVOICE)


def _load_extractor(llm_backend: str) -> Optional[object]:
    """Load and configure the ExtractThinker extractor. Returns None on import error."""
    try:
        from extract_thinker import Extractor  # pylint: disable=import-outside-toplevel
    except ImportError:
        print(
            "ERROR: extract-thinker required. Install: pip install extract-thinker",
            file=sys.stderr,
        )
        return None
    extractor = Extractor()
    extractor.load_document_loader("docling")
    extractor.load_llm(llm_backend)
    return extractor


def _run_extraction(extractor: object, input_file: str, schema_cls: type) -> Optional[dict]:
    """Run extraction and return raw data dict, or None on error."""
    try:
        result = extractor.extract(input_file, schema_cls)
        return result.model_dump()
    except Exception as e:  # pylint: disable=broad-exception-caught
        print(f"Extraction error: {e}", file=sys.stderr)
        return None


def cmd_extract(args: list[str]) -> int:
    """Extract structured data from a file (requires Docling + ExtractThinker)."""
    preconditions = _validate_extract_preconditions(args)
    if not preconditions:
        return 1

    input_file, schema, privacy = preconditions
    llm_backend = _PRIVACY_BACKENDS.get(privacy, "ollama/llama3.2")
    doc_type = _resolve_doc_type(schema, input_file)

    schema_cls = get_schema_class(doc_type)
    if not schema_cls:
        print(f"No schema available for type: {doc_type.value}", file=sys.stderr)
        return 1

    extractor = _load_extractor(llm_backend)
    if not extractor:
        return 1

    print(f"Extracting from {input_file} (type={doc_type.value}, llm={llm_backend})...", file=sys.stderr)

    raw_data = _run_extraction(extractor, input_file, schema_cls)
    if raw_data is None:
        return 1

    output = parse_and_validate(raw_data, doc_type, input_file)
    _print_json(output)
    return 0 if not output.validation.requires_review else 2


def main() -> int:
    """CLI entry point."""
    if len(sys.argv) < 2:
        print("Usage: extraction_pipeline.py <command> [args]")
        print("")
        print("Commands:")
        print("  classify   <text-file>     Classify document type from text")
        print("  extract    <file>          Extract structured data (requires Docling + ExtractThinker)")
        print("  validate   <json-file>     Validate extracted JSON")
        print("  categorise <vendor> [desc] Auto-categorise nominal code")
        print("")
        print("Options:")
        print("  --schema <name>    Schema: auto, purchase-invoice, expense-receipt, credit-note")
        print("  --privacy <mode>   Privacy: local (Ollama), cloud (OpenAI)")
        print("  --type <type>      Document type for validation")
        return 0

    command = sys.argv[1]
    args = sys.argv[2:]

    commands = {
        "classify": cmd_classify,
        "extract": cmd_extract,
        "validate": cmd_validate,
        "categorise": cmd_categorise,
        "categorize": cmd_categorise,  # US spelling alias
    }

    handler = commands.get(command)
    if not handler:
        print(f"Unknown command: {command}", file=sys.stderr)
        return 1

    return handler(args)


if __name__ == "__main__":
    sys.exit(main())
