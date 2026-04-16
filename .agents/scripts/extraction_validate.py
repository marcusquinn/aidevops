#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
extraction_validate.py - VAT validation, confidence scoring, and extraction pipeline.

Extracted from extraction_pipeline.py to reduce file-level complexity.
Contains VAT arithmetic checks, per-field confidence scoring, the full
validation pipeline, and schema-based parsing.
"""

from __future__ import annotations

from typing import Optional

from pydantic import BaseModel

from extraction_models import (
    DocumentType,
    ExtractionOutput,
    FieldConfidence,
    PurchaseInvoice,
    ExpenseReceipt,
    CreditNote,
    ValidationResult,
    _is_valid_date,
    categorise_nominal,
)


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

def _get_field_rules(
    document_type: DocumentType,
) -> tuple[list[str], list[str], list[str]]:
    """Return (required, date_fields, amount_fields) for a document type."""
    if document_type in (DocumentType.PURCHASE_INVOICE, DocumentType.SALES_INVOICE):
        return (
            ["vendor_name", "invoice_number", "invoice_date", "total"],
            ["invoice_date", "due_date"],
            ["subtotal", "vat_amount", "total"],
        )
    if document_type == DocumentType.EXPENSE_RECEIPT:
        return (
            ["merchant_name", "date", "total"],
            ["date"],
            ["subtotal", "vat_amount", "total"],
        )
    if document_type == DocumentType.CREDIT_NOTE:
        return (
            ["vendor_name", "credit_note_number", "date", "total"],
            ["date"],
            ["subtotal", "vat_amount", "total"],
        )
    return (["total"], ["date"], ["total"])


def _is_positive_number(value) -> bool:
    """Check if value is a positive number."""
    try:
        return float(value) > 0 if value is not None else False
    except (ValueError, TypeError):
        return False


def _score_field(
    key: str,
    value,
    required: list[str],
    date_fields: list[str],
    amount_fields: list[str],
) -> FieldConfidence:
    """Compute confidence score for a single field."""
    str_val = str(value) if value is not None else ""
    conf = 0.7 if (value is not None and str_val.strip()) else 0.1

    if key in date_fields and _is_valid_date(str_val):
        conf += 0.2
    if key in amount_fields and _is_positive_number(value):
        conf += 0.2
    if key in required and conf >= 0.7:
        conf += 0.1

    return FieldConfidence(
        field=key,
        value=str_val[:100],
        confidence=round(min(conf, 1.0), 2),
        source="llm",
    )


def compute_confidence(
    data: dict,
    document_type: DocumentType,
) -> list[FieldConfidence]:
    """Compute per-field confidence scores based on data completeness and validity."""
    required, date_fields, amount_fields = _get_field_rules(document_type)
    skip_keys = {"document_type", "line_items", "items"}

    return [
        _score_field(key, value, required, date_fields, amount_fields)
        for key, value in data.items()
        if key not in skip_keys
    ]


# ---------------------------------------------------------------------------
# Full validation pipeline
# ---------------------------------------------------------------------------

def _extract_line_item_dicts(data: dict) -> list[dict]:
    """Extract line item dicts from data, filtering non-dict entries."""
    line_items_raw = data.get("line_items", data.get("items", []))
    if not line_items_raw:
        return []
    return [item for item in line_items_raw if isinstance(item, dict)]


def _validate_total_check(subtotal: float, vat_amount: float, total: float) -> str:
    """Check if subtotal + vat_amount equals total."""
    if total <= 0 or subtotal <= 0:
        return "not_applicable"
    expected = subtotal + vat_amount
    return "fail" if abs(expected - total) > _VAT_TOLERANCE else "pass"


def _validate_date_field(data: dict, warnings: list[str]) -> bool:
    """Validate date field and append warning if invalid. Returns date_valid."""
    date_field = data.get("invoice_date") or data.get("date") or ""
    if not date_field:
        return False
    date_valid = _is_valid_date(date_field)
    if not date_valid:
        warnings.append(f"Date '{date_field}' is not valid YYYY-MM-DD format")
    return date_valid


def _validate_currency(data: dict, warnings: list[str]) -> str:
    """Validate currency code and return normalised value."""
    currency = data.get("currency", "GBP")
    if currency and len(currency) != 3:
        warnings.append(f"Currency '{currency}' is not a valid ISO 4217 code")
        return "GBP"
    return currency


def _has_low_confidence_fields(confidence_scores: list[FieldConfidence]) -> bool:
    """Check if any field has confidence below threshold."""
    return any(s.confidence < 0.5 for s in confidence_scores)


def _needs_review(
    vat_status: str,
    total_check: str,
    date_valid: bool,
    overall: float,
    confidence_scores: list[FieldConfidence],
) -> bool:
    """Determine if extraction requires manual review."""
    has_check_failure = vat_status == "fail" or total_check == "fail"
    has_quality_issue = not date_valid or overall < 0.7
    return has_check_failure or has_quality_issue or _has_low_confidence_fields(confidence_scores)


def _auto_categorise_line_items(
    data: dict,
    document_type: DocumentType,
    line_items_dicts: list[dict],
) -> None:
    """Auto-assign nominal codes to line items missing them."""
    if document_type not in (DocumentType.PURCHASE_INVOICE, DocumentType.CREDIT_NOTE):
        return
    vendor = data.get("vendor_name", "")
    for item in line_items_dicts:
        if not item.get("nominal_code"):
            desc = item.get("description", "")
            code, _cat = categorise_nominal(vendor, desc)
            item["nominal_code"] = code


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
    line_items_dicts = _extract_line_item_dicts(data)

    vat_status, vat_warnings = validate_vat(
        subtotal, vat_amount, total, line_items_dicts, vendor_vat
    )
    warnings.extend(vat_warnings)

    # 2. Total check
    total_check = _validate_total_check(subtotal, vat_amount, total)

    # 3. Date validation
    date_valid = _validate_date_field(data, warnings)

    # 4. Currency detection
    currency = _validate_currency(data, warnings)

    # 5. Confidence scoring
    confidence_scores = compute_confidence(data, document_type)
    overall = 0.0
    if confidence_scores:
        overall = round(
            sum(s.confidence for s in confidence_scores) / len(confidence_scores),
            2,
        )

    # 6. Determine if review is needed
    requires_review = _needs_review(
        vat_status, total_check, date_valid, overall, confidence_scores
    )

    if requires_review and "Requires manual review" not in warnings:
        low_conf_fields = [
            s.field for s in confidence_scores if s.confidence < 0.5
        ]
        if low_conf_fields:
            warnings.append(
                f"Low confidence fields: {', '.join(low_conf_fields)}"
            )

    # 7. Auto-categorise nominal codes
    _auto_categorise_line_items(data, document_type, line_items_dicts)

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
# Schema selection and parse-and-validate entry point
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
