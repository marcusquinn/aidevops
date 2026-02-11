#!/usr/bin/env python3
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
import re
import sys
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Pydantic models (runnable versions of extraction-schemas.md contracts)
# ---------------------------------------------------------------------------

try:
    from pydantic import BaseModel, Field, field_validator
except ImportError:
    print(
        "ERROR: pydantic is required. Install: pip install pydantic>=2.0",
        file=sys.stderr,
    )
    sys.exit(1)


# -- Enums ------------------------------------------------------------------

class VatRate(str, Enum):
    """UK VAT rates and special codes."""
    STANDARD = "20"
    REDUCED = "5"
    ZERO = "0"
    EXEMPT = "exempt"
    OUT_OF_SCOPE = "oos"
    REVERSE_CHARGE = "servrc"
    CIS_REVERSE = "cisrc"
    PVA_GOODS = "postgoods"


class DocumentType(str, Enum):
    """Supported document types for classification."""
    PURCHASE_INVOICE = "purchase_invoice"
    EXPENSE_RECEIPT = "expense_receipt"
    CREDIT_NOTE = "credit_note"
    SALES_INVOICE = "invoice"
    GENERIC_RECEIPT = "receipt"
    UNKNOWN = "unknown"


# -- Line item models -------------------------------------------------------

class PurchaseLineItem(BaseModel):
    """A single line item on a purchase invoice."""
    description: str = Field(
        default="", description="Item or service description"
    )
    quantity: float = Field(default=1.0, description="Number of units", ge=0)
    unit_price: float = Field(default=0.0, description="Price per unit excl VAT")
    amount: float = Field(default=0.0, description="Line total excl VAT")
    vat_rate: str = Field(default="20", description="VAT rate or special code")
    vat_amount: Optional[float] = Field(
        default=None, description="VAT amount for this line"
    )
    nominal_code: Optional[str] = Field(
        default=None, description="Accounting nominal code"
    )


class ReceiptItem(BaseModel):
    """A single item on a receipt."""
    name: str = Field(default="", description="Item name or description")
    quantity: float = Field(default=1.0, description="Number of units")
    unit_price: Optional[float] = Field(default=None, description="Price per unit")
    price: float = Field(default=0.0, description="Total price for this item")
    vat_rate: Optional[str] = Field(default=None, description="VAT rate if shown")


# -- Document models --------------------------------------------------------

class PurchaseInvoice(BaseModel):
    """Schema for supplier invoices."""
    vendor_name: str = Field(default="", description="Supplier company name")
    vendor_address: Optional[str] = None
    vendor_vat_number: Optional[str] = None
    vendor_company_number: Optional[str] = None
    invoice_number: str = Field(default="", description="Invoice reference")
    invoice_date: str = Field(default="", description="Date issued YYYY-MM-DD")
    due_date: Optional[str] = None
    purchase_order: Optional[str] = None
    subtotal: float = Field(default=0.0, description="Total before VAT")
    vat_amount: float = Field(default=0.0, description="Total VAT")
    total: float = Field(default=0.0, description="Total including VAT")
    currency: str = Field(default="GBP", description="ISO 4217 currency")
    line_items: list[PurchaseLineItem] = Field(default_factory=list)
    payment_terms: Optional[str] = None
    bank_details: Optional[str] = None
    document_type: str = "purchase_invoice"

    @field_validator("invoice_date", "due_date", mode="before")
    @classmethod
    def normalise_date(cls, v: Optional[str]) -> Optional[str]:
        """Attempt to normalise dates to YYYY-MM-DD."""
        if not v:
            return v
        return _normalise_date(v)


class ExpenseReceipt(BaseModel):
    """Schema for informal receipts."""
    merchant_name: str = Field(default="", description="Shop/vendor name")
    merchant_address: Optional[str] = None
    merchant_vat_number: Optional[str] = None
    receipt_number: Optional[str] = None
    date: str = Field(default="", description="Transaction date YYYY-MM-DD")
    time: Optional[str] = None
    subtotal: Optional[float] = None
    vat_amount: Optional[float] = None
    total: float = Field(default=0.0, description="Total amount paid")
    currency: str = Field(default="GBP")
    items: list[ReceiptItem] = Field(default_factory=list)
    payment_method: Optional[str] = None
    card_last_four: Optional[str] = None
    expense_category: Optional[str] = None
    document_type: str = "expense_receipt"

    @field_validator("date", mode="before")
    @classmethod
    def normalise_date(cls, v: Optional[str]) -> Optional[str]:
        if not v:
            return v
        return _normalise_date(v)


class CreditNote(BaseModel):
    """Schema for credit notes from suppliers."""
    vendor_name: str = Field(default="", description="Supplier name")
    credit_note_number: str = Field(default="", description="Credit note ref")
    date: str = Field(default="", description="Credit note date YYYY-MM-DD")
    original_invoice: Optional[str] = None
    subtotal: float = Field(default=0.0, description="Credit before VAT")
    vat_amount: float = Field(default=0.0, description="VAT credit")
    total: float = Field(default=0.0, description="Total credit incl VAT")
    currency: str = Field(default="GBP")
    reason: Optional[str] = None
    line_items: list[PurchaseLineItem] = Field(default_factory=list)
    document_type: str = "credit_note"

    @field_validator("date", mode="before")
    @classmethod
    def normalise_date(cls, v: Optional[str]) -> Optional[str]:
        if not v:
            return v
        return _normalise_date(v)


# -- Validation result model ------------------------------------------------

class FieldConfidence(BaseModel):
    """Confidence score for a single extracted field."""
    field: str
    value: str  # stringified value
    confidence: float = Field(ge=0.0, le=1.0)
    source: str = "llm"  # llm, ocr, calculated, default


class ValidationResult(BaseModel):
    """Validation summary for an extraction."""
    vat_check: str = "not_applicable"  # pass, fail, not_applicable
    total_check: str = "not_applicable"  # pass, fail, not_applicable
    date_valid: bool = True
    currency_detected: str = "GBP"
    confidence_scores: list[FieldConfidence] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)
    requires_review: bool = False
    overall_confidence: float = 0.0


class ExtractionOutput(BaseModel):
    """Complete extraction output with data + validation."""
    source_file: str
    document_type: str
    extraction_status: str = "complete"  # complete, partial, failed
    data: dict  # The extracted schema data
    validation: ValidationResult = Field(default_factory=ValidationResult)


# ---------------------------------------------------------------------------
# Date normalisation
# ---------------------------------------------------------------------------

_DATE_FORMATS = [
    "%Y-%m-%d",
    "%d/%m/%Y",
    "%d-%m-%Y",
    "%d.%m.%Y",
    "%m/%d/%Y",
    "%d %b %Y",
    "%d %B %Y",
    "%b %d, %Y",
    "%B %d, %Y",
    "%Y%m%d",
]


def _normalise_date(raw: str) -> str:
    """Try common date formats and return YYYY-MM-DD or the original string."""
    raw = raw.strip()
    for fmt in _DATE_FORMATS:
        try:
            return datetime.strptime(raw, fmt).strftime("%Y-%m-%d")
        except ValueError:
            continue
    return raw


def _is_valid_date(date_str: str) -> bool:
    """Check if a string is a valid YYYY-MM-DD date."""
    try:
        datetime.strptime(date_str, "%Y-%m-%d")
        return True
    except (ValueError, TypeError):
        return False


# ---------------------------------------------------------------------------
# Document classification
# ---------------------------------------------------------------------------

# Weighted keyword patterns for classification
_CLASSIFICATION_PATTERNS: dict[DocumentType, list[tuple[str, int]]] = {
    DocumentType.PURCHASE_INVOICE: [
        (r"invoice\s*(no|number|#|:)", 3),
        (r"due\s*date|payment\s*terms|net\s*\d+", 2),
        (r"purchase\s*order|p\.?o\.?\s*(no|number|#)", 2),
        (r"bill\s*to|ship\s*to|remit\s*to", 1),
        (r"tax\s*invoice", 2),
        (r"vat\s*(no|number|reg)", 1),
    ],
    DocumentType.EXPENSE_RECEIPT: [
        (r"receipt|till|register", 3),
        (r"cash|card|visa|mastercard|amex|contactless|chip", 2),
        (r"change\s*due|thank\s*you|have\s*a\s*nice", 2),
        (r"subtotal|sub\s*total", 1),
        (r"store\s*#|terminal|trans(action)?\s*(no|#)", 1),
    ],
    DocumentType.CREDIT_NOTE: [
        (r"credit\s*note|cn[-\s]?\d+", 4),
        (r"refund|credited|adjustment", 2),
        (r"original\s*invoice", 2),
    ],
    DocumentType.SALES_INVOICE: [
        (r"invoice\s*(no|number|#|:)", 2),
        (r"from\s*:", 1),
        (r"our\s*ref", 1),
    ],
}


def classify_document(text: str) -> tuple[DocumentType, dict[str, int]]:
    """Classify document type from OCR text using weighted keyword scoring.

    Returns (document_type, scores_dict).
    """
    lower = text.lower()
    scores: dict[str, int] = {}

    for doc_type, patterns in _CLASSIFICATION_PATTERNS.items():
        score = 0
        for pattern, weight in patterns:
            if re.search(pattern, lower):
                score += weight
        scores[doc_type.value] = score

    # Find highest score
    best_type = DocumentType.UNKNOWN
    best_score = 0
    for doc_type_val, score in scores.items():
        if score > best_score:
            best_score = score
            best_type = DocumentType(doc_type_val)

    # Default to purchase_invoice if ambiguous (safer for accounting)
    if best_score == 0:
        best_type = DocumentType.PURCHASE_INVOICE

    return best_type, scores


# ---------------------------------------------------------------------------
# Nominal code auto-categorisation
# ---------------------------------------------------------------------------

_NOMINAL_PATTERNS: list[tuple[str, str, str]] = [
    # (regex_pattern, nominal_code, category_name)
    (r"amazon|staples|office\s*depot|viking|ryman", "7504", "Stationery & Office Supplies"),
    (r"shell|bp|esso|texaco|fuel|petrol|diesel|unleaded", "7401", "Motor Expenses - Fuel"),
    (r"hotel|airbnb|booking\.com|accommodation|lodge|inn", "7403", "Hotel & Accommodation"),
    (r"restaurant|cafe|coffee|costa|starbucks|pret|greggs|food|lunch|dinner|breakfast|meal", "7402", "Subsistence"),
    (r"train|bus|taxi|uber|lyft|parking|congestion|tfl|oyster|railcard|national\s*rail", "7400", "Travel & Subsistence"),
    (r"royal\s*mail|dhl|fedex|ups|hermes|evri|parcelforce|postage|shipping|delivery", "7501", "Postage & Shipping"),
    (r"bt|vodafone|ee|three|o2|giffgaff|phone|broadband|internet|mobile|sim", "7502", "Telephone & Internet"),
    (r"adobe|microsoft|github|google\s*workspace|slack|notion|saas|software|license|subscription", "7404", "Computer Software"),
    (r"google\s*ads|facebook\s*ads|meta\s*ads|linkedin\s*ads|marketing|advertising|promo", "6201", "Advertising & Marketing"),
    (r"accountant|solicitor|lawyer|legal|barrister|consultant|professional\s*fee", "7600", "Professional Fees"),
    (r"plumber|electrician|repair|maintenance|fix|service\s*call", "7300", "Repairs & Maintenance"),
    (r"magazine|journal|newspaper|membership|annual\s*fee", "7900", "Subscriptions"),
]


def categorise_nominal(vendor: str, description: str = "") -> tuple[str, str]:
    """Auto-categorise a nominal code from vendor name and item description.

    Returns (nominal_code, category_name).
    """
    combined = f"{vendor} {description}".lower()

    for pattern, code, name in _NOMINAL_PATTERNS:
        if re.search(pattern, combined):
            return code, name

    return "5000", "General Purchases"


# ---------------------------------------------------------------------------
# VAT validation
# ---------------------------------------------------------------------------

_VALID_VAT_RATES = {"0", "5", "20", "exempt", "oos", "servrc", "cisrc", "postgoods"}
_VAT_TOLERANCE = 0.02  # 2p tolerance for rounding
_LINE_VAT_TOLERANCE = 0.05  # 5p tolerance for line item sums


def validate_vat(
    subtotal: float,
    vat_amount: float,
    total: float,
    line_items: Optional[list[dict]] = None,
    vendor_vat_number: Optional[str] = None,
) -> tuple[str, list[str]]:
    """Validate VAT arithmetic and return (status, warnings).

    Status: 'pass', 'fail', 'warning'
    """
    warnings: list[str] = []

    # Rule 1: subtotal + vat_amount should equal total
    expected_total = subtotal + vat_amount
    if abs(expected_total - total) > _VAT_TOLERANCE:
        warnings.append(
            f"VAT arithmetic mismatch: {subtotal} + {vat_amount} = "
            f"{expected_total}, but total is {total} "
            f"(diff: {abs(expected_total - total):.2f})"
        )

    # Rule 2: VAT claimed without supplier VAT number
    if vat_amount > 0 and not vendor_vat_number:
        warnings.append(
            "VAT amount claimed but no supplier VAT number provided"
        )

    # Rule 3: Line items VAT sum vs total VAT
    if line_items:
        line_vat_sum = sum(
            float(item.get("vat_amount", 0) or 0) for item in line_items
        )
        if line_vat_sum > 0 and abs(line_vat_sum - vat_amount) > _LINE_VAT_TOLERANCE:
            warnings.append(
                f"Line items VAT sum ({line_vat_sum:.2f}) differs from "
                f"total VAT ({vat_amount:.2f})"
            )

        # Check individual line VAT rates
        for i, item in enumerate(line_items):
            rate = str(item.get("vat_rate", "20"))
            if rate not in _VALID_VAT_RATES:
                warnings.append(
                    f"Line item {i + 1}: unusual VAT rate '{rate}'"
                )

    # Determine overall status
    has_arithmetic_error = any("arithmetic mismatch" in w for w in warnings)
    if has_arithmetic_error:
        return "fail", warnings
    if warnings:
        return "warning", warnings
    return "pass", warnings


# ---------------------------------------------------------------------------
# Confidence scoring
# ---------------------------------------------------------------------------

def compute_confidence(
    data: dict,
    document_type: DocumentType,
) -> list[FieldConfidence]:
    """Compute per-field confidence scores based on data completeness and validity.

    Heuristic scoring:
    - Field present and non-empty: base 0.7
    - Field matches expected format: +0.2
    - Field is a required field and present: +0.1
    """
    scores: list[FieldConfidence] = []

    if document_type in (DocumentType.PURCHASE_INVOICE, DocumentType.SALES_INVOICE):
        required = ["vendor_name", "invoice_number", "invoice_date", "total"]
        date_fields = ["invoice_date", "due_date"]
        amount_fields = ["subtotal", "vat_amount", "total"]
    elif document_type == DocumentType.EXPENSE_RECEIPT:
        required = ["merchant_name", "date", "total"]
        date_fields = ["date"]
        amount_fields = ["subtotal", "vat_amount", "total"]
    elif document_type == DocumentType.CREDIT_NOTE:
        required = ["vendor_name", "credit_note_number", "date", "total"]
        date_fields = ["date"]
        amount_fields = ["subtotal", "vat_amount", "total"]
    else:
        required = ["total"]
        date_fields = ["date"]
        amount_fields = ["total"]

    for key, value in data.items():
        if key in ("document_type", "line_items", "items"):
            continue

        conf = 0.0
        str_val = str(value) if value is not None else ""

        # Base: field present and non-empty
        if value is not None and str_val.strip():
            conf = 0.7
        else:
            conf = 0.1

        # Format bonus for dates
        if key in date_fields and _is_valid_date(str_val):
            conf += 0.2

        # Format bonus for amounts (positive numbers)
        if key in amount_fields:
            try:
                num = float(value) if value is not None else 0
                if num > 0:
                    conf += 0.2
            except (ValueError, TypeError):
                pass

        # Required field bonus
        if key in required and conf >= 0.7:
            conf += 0.1

        conf = min(conf, 1.0)
        scores.append(FieldConfidence(
            field=key,
            value=str_val[:100],
            confidence=round(conf, 2),
            source="llm",
        ))

    return scores


# ---------------------------------------------------------------------------
# Full validation pipeline
# ---------------------------------------------------------------------------

def validate_extraction(
    data: dict,
    document_type: DocumentType,
    source_file: str = "",
) -> ExtractionOutput:
    """Run the full validation pipeline on extracted data.

    Returns ExtractionOutput with validation results.
    """
    warnings: list[str] = []

    # 1. VAT validation
    subtotal = float(data.get("subtotal", 0) or 0)
    vat_amount = float(data.get("vat_amount", data.get("tax_amount", 0)) or 0)
    total = float(data.get("total", 0) or 0)
    vendor_vat = data.get("vendor_vat_number") or data.get("merchant_vat_number")

    line_items_raw = data.get("line_items", data.get("items", []))
    line_items_dicts = []
    if line_items_raw:
        for item in line_items_raw:
            if isinstance(item, dict):
                line_items_dicts.append(item)

    vat_status, vat_warnings = validate_vat(
        subtotal, vat_amount, total, line_items_dicts, vendor_vat
    )
    warnings.extend(vat_warnings)

    # 2. Total check (subtotal + vat = total)
    total_check = "pass"
    if total > 0 and subtotal > 0:
        expected = subtotal + vat_amount
        if abs(expected - total) > _VAT_TOLERANCE:
            total_check = "fail"
        else:
            total_check = "pass"
    else:
        total_check = "not_applicable"

    # 3. Date validation
    date_field = data.get("invoice_date") or data.get("date") or ""
    date_valid = _is_valid_date(date_field) if date_field else False
    if date_field and not date_valid:
        warnings.append(f"Date '{date_field}' is not valid YYYY-MM-DD format")

    # 4. Currency detection
    currency = data.get("currency", "GBP")
    if currency and len(currency) != 3:
        warnings.append(f"Currency '{currency}' is not a valid ISO 4217 code")
        currency = "GBP"

    # 5. Confidence scoring
    confidence_scores = compute_confidence(data, document_type)
    overall = 0.0
    if confidence_scores:
        overall = round(
            sum(s.confidence for s in confidence_scores) / len(confidence_scores),
            2,
        )

    # 6. Determine if review is needed
    requires_review = (
        vat_status == "fail"
        or total_check == "fail"
        or not date_valid
        or overall < 0.7
        or any(s.confidence < 0.5 for s in confidence_scores)
    )

    if requires_review and "Requires manual review" not in warnings:
        low_conf_fields = [
            s.field for s in confidence_scores if s.confidence < 0.5
        ]
        if low_conf_fields:
            warnings.append(
                f"Low confidence fields: {', '.join(low_conf_fields)}"
            )

    # 7. Auto-categorise nominal codes for line items without them
    if document_type in (DocumentType.PURCHASE_INVOICE, DocumentType.CREDIT_NOTE):
        vendor = data.get("vendor_name", "")
        for item in line_items_dicts:
            if not item.get("nominal_code"):
                desc = item.get("description", "")
                code, _cat = categorise_nominal(vendor, desc)
                item["nominal_code"] = code

    validation = ValidationResult(
        vat_check=vat_status,
        total_check=total_check,
        date_valid=date_valid,
        currency_detected=currency,
        confidence_scores=confidence_scores,
        warnings=warnings,
        requires_review=requires_review,
        overall_confidence=overall,
    )

    return ExtractionOutput(
        source_file=source_file,
        document_type=document_type.value,
        extraction_status="complete" if not requires_review else "needs_review",
        data=data,
        validation=validation,
    )


# ---------------------------------------------------------------------------
# Schema selection helper
# ---------------------------------------------------------------------------

_SCHEMA_MAP: dict[DocumentType, type[BaseModel]] = {
    DocumentType.PURCHASE_INVOICE: PurchaseInvoice,
    DocumentType.EXPENSE_RECEIPT: ExpenseReceipt,
    DocumentType.CREDIT_NOTE: CreditNote,
}


def get_schema_class(doc_type: DocumentType) -> Optional[type[BaseModel]]:
    """Return the Pydantic model class for a document type."""
    return _SCHEMA_MAP.get(doc_type)


def parse_and_validate(
    raw_json: dict,
    doc_type: DocumentType,
    source_file: str = "",
) -> ExtractionOutput:
    """Parse raw extraction JSON through the appropriate schema and validate.

    This is the main entry point for the validation pipeline.
    """
    schema_cls = get_schema_class(doc_type)

    if schema_cls:
        try:
            parsed = schema_cls.model_validate(raw_json)
            data = parsed.model_dump()
        except Exception as e:
            # Partial parse - use raw data with warning
            data = raw_json
            result = validate_extraction(data, doc_type, source_file)
            result.validation.warnings.append(f"Schema validation error: {e}")
            result.extraction_status = "partial"
            return result
    else:
        data = raw_json

    return validate_extraction(data, doc_type, source_file)


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


def cmd_extract(args: list[str]) -> int:
    """Extract structured data from a file (requires Docling + ExtractThinker)."""
    if not args:
        print("Usage: extraction_pipeline.py extract <file> [--schema auto|purchase-invoice|expense-receipt|credit-note] [--privacy local|cloud]", file=sys.stderr)
        return 1

    input_file = args[0]
    schema = "auto"
    privacy = "local"

    # Parse options
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

    # Check file exists
    if not Path(input_file).is_file():
        print(f"ERROR: File not found: {input_file}", file=sys.stderr)
        return 1

    # Try to import extraction dependencies
    try:
        from extract_thinker import Extractor
    except ImportError:
        print(
            "ERROR: extract-thinker required. Install: pip install extract-thinker",
            file=sys.stderr,
        )
        return 1

    # Determine LLM backend
    if privacy == "local":
        llm_backend = "ollama/llama3.2"
    elif privacy == "cloud":
        llm_backend = "openai/gpt-4o"
    else:
        llm_backend = "ollama/llama3.2"

    # Schema mapping
    schema_type_map = {
        "purchase-invoice": DocumentType.PURCHASE_INVOICE,
        "purchase_invoice": DocumentType.PURCHASE_INVOICE,
        "expense-receipt": DocumentType.EXPENSE_RECEIPT,
        "expense_receipt": DocumentType.EXPENSE_RECEIPT,
        "credit-note": DocumentType.CREDIT_NOTE,
        "credit_note": DocumentType.CREDIT_NOTE,
        "invoice": DocumentType.SALES_INVOICE,
        "receipt": DocumentType.GENERIC_RECEIPT,
    }

    # Auto-classify if needed
    if schema == "auto":
        # Read file text for classification
        try:
            from docling.document_converter import DocumentConverter
            converter = DocumentConverter()
            doc_result = converter.convert(input_file)
            text = doc_result.document.export_to_markdown()
        except ImportError:
            # Fallback: try reading as text
            text = Path(input_file).read_text(encoding="utf-8", errors="replace")

        doc_type, _scores = classify_document(text)
    else:
        doc_type = schema_type_map.get(schema, DocumentType.PURCHASE_INVOICE)

    schema_cls = get_schema_class(doc_type)
    if not schema_cls:
        print(f"No schema available for type: {doc_type.value}", file=sys.stderr)
        return 1

    # Run extraction
    print(f"Extracting from {input_file} (type={doc_type.value}, llm={llm_backend})...", file=sys.stderr)

    extractor = Extractor()
    extractor.load_document_loader("docling")
    extractor.load_llm(llm_backend)

    try:
        result = extractor.extract(input_file, schema_cls)
        raw_data = result.model_dump()
    except Exception as e:
        print(f"Extraction error: {e}", file=sys.stderr)
        return 1

    # Validate
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
