#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
extraction_models.py - Pydantic models, enums, classification, and categorisation.

Extracted from extraction_pipeline.py to reduce file-level complexity.
Contains data models, date normalisation, document classification,
and nominal code auto-categorisation.
"""

from __future__ import annotations

import re
import sys
from datetime import datetime
from enum import Enum
from typing import Optional

try:
    from pydantic import BaseModel, Field, field_validator
except ImportError:
    print(
        "ERROR: pydantic is required. Install: pip install pydantic>=2.0",
        file=sys.stderr,
    )
    sys.exit(1)


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Line item models
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Document models
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Validation result models
# ---------------------------------------------------------------------------

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
